//
//  GPUImageProcessor.m
//  图像处理器（旋转/镜像/格式转换/用户变换）
//

#import "GPUImageProcessor.h"
#import "VCamNotify.h"
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

// ===== VideoToolbox 类型手动声明（不依赖 SDK 头）=====
typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
typedef struct OpaqueVTPixelRotationSession *VTPixelRotationSessionRef;
OSStatus VTPixelTransferSessionCreate(CFAllocatorRef, VTPixelTransferSessionRef *);
OSStatus VTPixelTransferSessionTransferImage(VTPixelTransferSessionRef, CVPixelBufferRef, CVPixelBufferRef);
OSStatus VTSessionSetProperty(CFTypeRef session, CFStringRef propertyKey, CFTypeRef propertyValue);

typedef OSStatus (*VTPixelRotationSessionCreateFunc)(CFAllocatorRef, VTPixelRotationSessionRef *);
typedef OSStatus (*VTPixelRotationSessionTransferImageFunc)(VTPixelRotationSessionRef, CVPixelBufferRef, CVPixelBufferRef);

// ===== 日志 =====
extern BOOL vcam_log_budget_take(void);

static BOOL vcam_log_enabled(void) {
    static int cached = -1;
    if (cached < 0) {
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
            if (!d) d = [NSDictionary dictionaryWithContentsOfFile:@"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
            if (d) cached = d[@"logEnabled"] ? [d[@"logEnabled"] boolValue] : 0;
        } @catch (NSException *e) {}
    }
    return cached == 1;
}

static void vcam_gpu_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    if (!vcam_log_budget_take()) return;
    @try {
        NSString *logPath = @"/tmp/vcam_gpu_log.txt";
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) {
            [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

// ============================================================
//  文件级零分配数据结构
// ============================================================

// 统计槽位
typedef struct {
    uint32_t fmt;
    uint32_t w, h;
    uint64_t renders;
    uint64_t pixels;
    double   s1TotalMs;
    uint64_t s1Cnt;
    double   s2TotalMs;
    uint64_t s2Cnt;
} VCamStatSlot;
#define kVcamStatSlots 12
static VCamStatSlot gVcamStatSlots[kVcamStatSlots];

// 私有格式车道 staging 槽（按源尺寸缓存）
typedef struct {
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;
} VCamLaneStagingSlot;
#define kVcamLaneStagingMax 4
static VCamLaneStagingSlot gVcamLaneStaging[kVcamLaneStagingMax];

// 绿线修复：per-ratio 预裁剪 staging 槽
typedef struct {
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;
    CFAbsoluteTime lastUse;
} VCamCropStagingSlot;
#define kVcamCropStagingMax 4
static VCamCropStagingSlot gVcamCropStaging[kVcamCropStagingMax];
static VTPixelTransferSessionRef gVcamNormalSession = NULL;

// 发热优化：私有格式 YUV 域上采样中转槽
typedef struct {
    uint32_t fmt;
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;
    CFAbsoluteTime lastUse;
} VCamYuvStagingSlot;
#define kVcamYuvStagingMax 4
static VCamYuvStagingSlot gVcamYuvStaging[kVcamYuvStagingMax];

// 拆段 memo
static uint32_t gVcamYuvSplitFmt[4] = {0, 0, 0, 0};
static int8_t gVcamYuvSplitOk[4] = {0, 0, 0, 0};
static int8_t vcamYuvSplitState(uint32_t fmt) {
    for (int i = 0; i < 4; i++) if (gVcamYuvSplitFmt[i] == fmt) return gVcamYuvSplitOk[i];
    return 0;
}
static void vcamYuvSplitDisable(uint32_t fmt) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvSplitFmt[i] == fmt) { gVcamYuvSplitOk[i] = -1; return; }
    }
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvSplitFmt[i] == 0) { gVcamYuvSplitFmt[i] = fmt; gVcamYuvSplitOk[i] = -1; return; }
    }
}

// 直转快路径 memo
static uint32_t gVcamYuvDirectFmt[4] = {0, 0, 0, 0};
static int8_t gVcamYuvDirectOk[4] = {0, 0, 0, 0};
static uint8_t gVcamYuvDirectFails[4] = {0, 0, 0, 0};
static CFAbsoluteTime gVcamYuvDirectFailAt[4] = {0, 0, 0, 0};
static int8_t vcamYuvDirectState(uint32_t fmt) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvDirectFmt[i] == fmt) {
            if (gVcamYuvDirectOk[i] == -1 && gVcamYuvDirectFails[i] < 3 &&
                gVcamYuvDirectFailAt[i] > 0 &&
                (CFAbsoluteTimeGetCurrent() - gVcamYuvDirectFailAt[i]) > 30.0) {
                return 0;
            }
            return gVcamYuvDirectOk[i];
        }
    }
    return 0;
}
static void vcamYuvDirectSet(uint32_t fmt, int8_t ok) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvDirectFmt[i] == fmt) {
            if (ok == -1) {
                gVcamYuvDirectFails[i]++;
                gVcamYuvDirectFailAt[i] = CFAbsoluteTimeGetCurrent();
            }
            gVcamYuvDirectOk[i] = ok; return;
        }
    }
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvDirectFmt[i] == 0) {
            gVcamYuvDirectFmt[i] = fmt; gVcamYuvDirectOk[i] = ok;
            if (ok == -1) {
                gVcamYuvDirectFails[i] = 1;
                gVcamYuvDirectFailAt[i] = CFAbsoluteTimeGetCurrent();
            }
            return;
        }
    }
}

// YUV staging 两步法 memo
static uint32_t gVcamYuvStageFmt[4] = {0, 0, 0, 0};
static int8_t gVcamYuvStageOk[4] = {0, 0, 0, 0};
static int8_t vcamYuvStageState(uint32_t fmt) {
    for (int i = 0; i < 4; i++) if (gVcamYuvStageFmt[i] == fmt) return gVcamYuvStageOk[i];
    return 0;
}
static void vcamYuvStageSet(uint32_t fmt, int8_t ok) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvStageFmt[i] == fmt) { gVcamYuvStageOk[i] = ok; return; }
    }
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvStageFmt[i] == 0) { gVcamYuvStageFmt[i] = fmt; gVcamYuvStageOk[i] = ok; return; }
    }
}

// YUV 中转 staging 槽
typedef struct {
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;
} VCamYuvLaneSlot;
#define kVcamYuvLaneMax 4
static VCamYuvLaneSlot gVcamYuvLane[kVcamYuvLaneMax];

// 车道熔断 memo
static uint32_t gVcamLaneMemoFmt[4] = {0, 0, 0, 0};
static BOOL gVcamLaneMemoOff[4] = {NO, NO, NO, NO};
static CFAbsoluteTime gVcamLaneMemoOffAt[4] = {0, 0, 0, 0};
static void vcamLaneMemoInvalidate(uint32_t fmt, BOOL off) {
    for (int i = 0; i < 4; i++) {
        if (gVcamLaneMemoFmt[i] == fmt) {
            if (off && !gVcamLaneMemoOff[i]) gVcamLaneMemoOffAt[i] = CFAbsoluteTimeGetCurrent();
            gVcamLaneMemoOff[i] = off; return;
        }
    }
    gVcamLaneMemoFmt[fmt & 3] = fmt;
    if (off) gVcamLaneMemoOffAt[fmt & 3] = CFAbsoluteTimeGetCurrent();
    gVcamLaneMemoOff[fmt & 3] = off;
}
static BOOL vcamLaneMemoExpired(uint32_t fmt) {
    for (int i = 0; i < 4; i++) {
        if (gVcamLaneMemoFmt[i] == fmt) {
            return gVcamLaneMemoOff[i] && gVcamLaneMemoOffAt[i] > 0 &&
                   (CFAbsoluteTimeGetCurrent() - gVcamLaneMemoOffAt[i]) > 30.0;
        }
    }
    return NO;
}

static int32_t gVcamLaneFailCnt[4] = {0, 0, 0, 0};
static int vcamLaneFailSlot(uint32_t fmt) {
    for (int i = 0; i < 4; i++) if (gVcamLaneMemoFmt[i] == fmt) return i;
    return (int)(fmt & 3);
}
static void vcamLaneNoteSuccess(uint32_t fmt) {
    gVcamLaneFailCnt[vcamLaneFailSlot(fmt)] = 0;
}

// 视频切换重置车道记忆
void vcamLaneResetAllMemos(void) {
    memset(gVcamYuvDirectFmt, 0, sizeof(gVcamYuvDirectFmt));
    memset(gVcamYuvDirectOk, 0, sizeof(gVcamYuvDirectOk));
    memset(gVcamYuvDirectFails, 0, sizeof(gVcamYuvDirectFails));
    memset(gVcamYuvDirectFailAt, 0, sizeof(gVcamYuvDirectFailAt));
    memset(gVcamYuvStageFmt, 0, sizeof(gVcamYuvStageFmt));
    memset(gVcamYuvStageOk, 0, sizeof(gVcamYuvStageOk));
    memset(gVcamYuvSplitFmt, 0, sizeof(gVcamYuvSplitFmt));
    memset(gVcamYuvSplitOk, 0, sizeof(gVcamYuvSplitOk));
    memset(gVcamLaneMemoFmt, 0, sizeof(gVcamLaneMemoFmt));
    memset(gVcamLaneMemoOff, 0, sizeof(gVcamLaneMemoOff));
    memset(gVcamLaneMemoOffAt, 0, sizeof(gVcamLaneMemoOffAt));
    memset(gVcamLaneFailCnt, 0, sizeof(gVcamLaneFailCnt));
}

// ============================================================
//  类扩展
// ============================================================
@interface GPUImageProcessor ()
// 4 套 VT session（按用途隔离）
@property (nonatomic, assign) VTPixelTransferSessionRef bgraTransferSession;
@property (nonatomic, assign) VTPixelTransferSessionRef yuvTransferSession;
@property (nonatomic, assign) VTPixelTransferSessionRef privateTransferSession;
@property (nonatomic, assign) VTPixelTransferSessionRef prerenderTransferSession;

// 千面模型固定车道锁
@property (nonatomic, strong) NSLock *laneLockBGRA;
@property (nonatomic, strong) NSLock *laneLockYUV;
@property (nonatomic, strong) NSLock *laneLockPrivate;
@property (nonatomic, assign) VTPixelTransferSessionRef twoStepS1Session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *laneFailCounts;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *laneDisabled;

// 两步法 per-key 池（备用）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *twoStepSessionPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *twoStepStagingPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepTokenPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepFailCountPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepDisabledPool;

// 一步直转 per-stream 池
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *oneStepSessionPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSLock *> *oneStepKeyLockPool;
@property (nonatomic, strong) NSLock *rotationRenderLock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSLock *> *twoStepKeyLockPool;

// 组 staging + 结果缓存
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *groupStagingPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *groupTokenPool;
@property (nonatomic, strong) NSLock *groupGlobalLock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *groupSessionPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *groupSizePool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *resultCachePool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *resultBlitSessionPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *resultCacheTokenPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastReqTokenPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *resultBlitDisabledPool;

// 旋转 session
@property (nonatomic, assign) VTPixelRotationSessionRef pixelRotationSession;
@property (nonatomic, assign) VTPixelRotationSessionRef renderRotationSession;
@property (nonatomic, assign) CVPixelBufferRef adaptiveRotateCache;
@property (nonatomic, assign) size_t adaptiveRotateCacheW;
@property (nonatomic, assign) size_t adaptiveRotateCacheH;
@property (nonatomic, assign) OSType adaptiveRotateCacheFmt;
@property (nonatomic, assign) uint64_t adaptiveRotatedGen;

// LRU / 锁
@property (nonatomic, strong) NSMutableArray<NSString *> *streamKeyOrder;
@property (nonatomic, strong) NSLock *statsLock;
@property (nonatomic, strong) NSLock *poolDictLock;

// 旋转 API 函数指针 + 常量
@property (nonatomic, assign) VTPixelRotationSessionCreateFunc createRotationSession;
@property (nonatomic, assign) VTPixelRotationSessionTransferImageFunc transferRotationImage;
@property (nonatomic, assign) CFStringRef rotationPropertyKey;
@property (nonatomic, assign) CFStringRef rotationCCW90Value;
@property (nonatomic, assign) CFStringRef rotationCW90Value;
@property (nonatomic, assign) CFStringRef rotation180Value;
@property (nonatomic, assign) CFStringRef flipHorizontalKey;

// 预渲染旋转 3 槽池
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool0;
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool1;
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool2;
@property (nonatomic, assign) int prerenderRotateSlot;

// 用户变换画布 3 槽池
@property (nonatomic, assign) CVPixelBufferRef userCanvasPool0;
@property (nonatomic, assign) CVPixelBufferRef userCanvasPool1;
@property (nonatomic, assign) CVPixelBufferRef userCanvasPool2;
@property (nonatomic, assign) int userCanvasSlot;
@property (nonatomic, assign) CVPixelBufferRef userShrinkBuffer;
@property (nonatomic, assign) CVPixelBufferRef userPieceBuffer;
@property (nonatomic, assign) VTPixelTransferSessionRef userTransferSession;

// CIContext（软件渲染回退）
@property (nonatomic, strong) CIContext *preprocessContext;
@property (nonatomic, strong) CIContext *renderContext;

// GPU 探测（永久禁用，保留属性供未来验证）
@property (nonatomic, strong) CIContext *ciGPUContext;
@property (nonatomic, assign) BOOL metalAvailable;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *gpuImgTokenPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CIImage *> *gpuImgOutPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *oneStepFailPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *oneStepDisabledPool;

// BGRA buffer 池字典
@property (nonatomic, strong) NSMutableDictionary *bgraBufferPoolMap;

- (CVPixelBufferRef)scaleToBGRA:(CVPixelBufferRef)input width:(size_t)width height:(size_t)height CF_RETURNS_RETAINED;
@end

// 前向声明
static void vcamMirrorRowsInPlace(CVPixelBufferRef pb);
static BOOL vcamCopyPlanes(CVPixelBufferRef src, CVPixelBufferRef dst);
static void vcamSyncColorAttachments(CVPixelBufferRef src, CVPixelBufferRef dst);

// ============================================================
//  @implementation
// ============================================================
@implementation GPUImageProcessor

- (instancetype)init {
    self = [super init];
    if (self) {
        _rotationAngle = 0;
        _sourceRotation = 0;
        _mirrored = NO;
        _userPanX = 0.0;
        _userPanY = 0.0;
        _userZoom = 1.0;
        _rotationApiAvailable = NO;
        _bgraTransferSession = NULL;
        _yuvTransferSession = NULL;
        _privateTransferSession = NULL;
        _prerenderTransferSession = NULL;
        _pixelRotationSession = NULL;

        _bgraBufferPoolMap = [[NSMutableDictionary alloc] init];
        _twoStepSessionPool = [[NSMutableDictionary alloc] init];
        _twoStepStagingPool = [[NSMutableDictionary alloc] init];
        _twoStepTokenPool = [[NSMutableDictionary alloc] init];
        _twoStepFailCountPool = [[NSMutableDictionary alloc] init];
        _twoStepDisabledPool = [[NSMutableDictionary alloc] init];
        _oneStepSessionPool = [[NSMutableDictionary alloc] init];
        _oneStepKeyLockPool = [[NSMutableDictionary alloc] init];
        _rotationRenderLock = [[NSLock alloc] init];
        _twoStepKeyLockPool = [[NSMutableDictionary alloc] init];
        _adaptiveRotatedGen = 0;
        _streamKeyOrder = [NSMutableArray array];
        memset(gVcamStatSlots, 0, sizeof(gVcamStatSlots));

        _gpuImgTokenPool = [NSMutableDictionary dictionary];
        _gpuImgOutPool = [NSMutableDictionary dictionary];
        _oneStepFailPool = [NSMutableDictionary dictionary];
        _oneStepDisabledPool = [NSMutableDictionary dictionary];
        _groupStagingPool = [[NSMutableDictionary alloc] init];
        _groupTokenPool = [[NSMutableDictionary alloc] init];
        _groupGlobalLock = [[NSLock alloc] init];
        _groupSessionPool = [[NSMutableDictionary alloc] init];
        _groupSizePool = [[NSMutableDictionary alloc] init];
        _resultCachePool = [[NSMutableDictionary alloc] init];
        _resultBlitSessionPool = [[NSMutableDictionary alloc] init];
        _resultCacheTokenPool = [[NSMutableDictionary alloc] init];
        _lastReqTokenPool = [[NSMutableDictionary alloc] init];
        _resultBlitDisabledPool = [[NSMutableDictionary dictionary] init];
        _statsLock = [[NSLock alloc] init];
        _poolDictLock = [[NSLock alloc] init];

        _laneLockBGRA = [[NSLock alloc] init];
        _laneLockYUV = [[NSLock alloc] init];
        _laneLockPrivate = [[NSLock alloc] init];
        _twoStepS1Session = NULL;
        _laneFailCounts = [NSMutableDictionary dictionary];
        _laneDisabled = [NSMutableDictionary dictionary];

        // 软件渲染 CIContext（回退用）
        @try {
            _preprocessContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @YES
            }];
            _renderContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @YES
            }];
        } @catch (NSException *e) {
            _preprocessContext = nil;
            _renderContext = nil;
        }

        // GPU 探测（永久禁用，记录设备能力）
        _metalAvailable = NO;
        @try {
            typedef void *(*CreateDeviceFn)(void);
            CreateDeviceFn createDevice = (CreateDeviceFn)dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");
            if (createDevice) {
                id device = (__bridge id)createDevice();
                (void)device;
            }
        } @catch (NSException *e) {}

        [self setupBGRATransferSession];
        [self setupYUVTransferSession];
        [self setupPrerenderTransferSession];
        [self setupPixelRotationSession];
        vcam_gpu_log(@"[vcam] GPUImageProcessor initialized");
    }
    return self;
}

- (void)dealloc {
    typedef void (*InvalidateFunc)(VTPixelTransferSessionRef);
    InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");

    if (_bgraTransferSession && invalidate) invalidate(_bgraTransferSession);
    if (_yuvTransferSession && invalidate) invalidate(_yuvTransferSession);
    if (_prerenderTransferSession && invalidate) invalidate(_prerenderTransferSession);
    if (_userTransferSession && invalidate) invalidate(_userTransferSession);
    if (_privateTransferSession && invalidate) invalidate(_privateTransferSession);
    if (_twoStepS1Session && invalidate) invalidate(_twoStepS1Session);

    // 车道 staging 槽
    for (int i = 0; i < kVcamLaneStagingMax; i++) {
        if (gVcamLaneStaging[i].staging) {
            CVPixelBufferRelease(gVcamLaneStaging[i].staging);
            gVcamLaneStaging[i].staging = NULL;
        }
    }

    // 预渲染旋转 3 槽池
    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef b = [self prerenderRotateBufferAtSlot:i];
        if (b) CVPixelBufferRelease(b);
        [self setPrerenderRotateBuffer:NULL atSlot:i];
    }
    // 用户变换画布 3 槽池
    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef b = [self userCanvasAtSlot:i];
        if (b) CVPixelBufferRelease(b);
        [self setUserCanvas:NULL atSlot:i];
    }
    if (_userShrinkBuffer) CVPixelBufferRelease(_userShrinkBuffer);
    if (_userPieceBuffer) CVPixelBufferRelease(_userPieceBuffer);
    if (_adaptiveRotateCache) CVPixelBufferRelease(_adaptiveRotateCache);

    // 旋转 session
    typedef void (*InvalidateRotFunc)(VTPixelRotationSessionRef);
    InvalidateRotFunc invalidateRot = (InvalidateRotFunc)dlsym(RTLD_DEFAULT, "VTPixelRotationSessionInvalidate");
    if (invalidateRot) {
        if (_pixelRotationSession) invalidateRot(_pixelRotationSession);
        if (_renderRotationSession) invalidateRot(_renderRotationSession);
    }

    // 池字典
    for (NSValue *v in _twoStepSessionPool.allValues) {
        VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[v pointerValue];
        if (s && invalidate) invalidate(s);
    }
    for (NSValue *v in _twoStepStagingPool.allValues) {
        CVPixelBufferRef b = (CVPixelBufferRef)[v pointerValue];
        if (b) CVPixelBufferRelease(b);
    }
    for (NSValue *v in _oneStepSessionPool.allValues) {
        VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[v pointerValue];
        if (s && invalidate) invalidate(s);
    }
    for (id key in _bgraBufferPoolMap) {
        CVPixelBufferPoolRef pool = (__bridge CVPixelBufferPoolRef)_bgraBufferPoolMap[key];
        CVPixelBufferPoolRelease(pool);
    }
    [_bgraBufferPoolMap removeAllObjects];

    vcam_gpu_log(@"[vcam] GPUImageProcessor deallocated");
}

#pragma mark - Session 初始化

- (void)setupBGRATransferSession {
    if (_bgraTransferSession) return;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_bgraTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_bgraTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] BGRA VTPixelTransferSession created");
    }
}

- (void)setupYUVTransferSession {
    if (_yuvTransferSession) return;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_yuvTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_yuvTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] YUV VTPixelTransferSession created");
    }
}

- (void)setupPrerenderTransferSession {
    if (_prerenderTransferSession) return;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_prerenderTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_prerenderTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] Prerender VTPixelTransferSession created");
    }
}

- (void)setupPixelRotationSession {
    if (_pixelRotationSession) return;

    // dlopen VideoToolbox（dlsym RTLD_DEFAULT 在 mediaserverd 里找不到私有符号）
    void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox",
                      RTLD_LAZY | RTLD_GLOBAL);
    void *base = vt ? vt : RTLD_DEFAULT;

    _createRotationSession = (VTPixelRotationSessionCreateFunc)dlsym(base, "VTPixelRotationSessionCreate");
    _transferRotationImage = (VTPixelRotationSessionTransferImageFunc)dlsym(base, "VTPixelRotationSessionRotateImage");

    // 属性 key / value（CFStringRef 全局变量，需解引用）
    void *rotSym = dlsym(base, "kVTPixelRotationPropertyKey_Rotation");
    _rotationPropertyKey = rotSym ? *(CFStringRef *)rotSym : CFSTR("Rotation");
    void *ccwSym = dlsym(base, "kVTRotation_CCW90");
    _rotationCCW90Value = ccwSym ? *(CFStringRef *)ccwSym : CFSTR("CCW90");
    void *cwSym = dlsym(base, "kVTRotation_CW90");
    _rotationCW90Value = cwSym ? *(CFStringRef *)cwSym : CFSTR("CW90");
    void *r180Sym = dlsym(base, "kVTRotation_180");
    _rotation180Value = r180Sym ? *(CFStringRef *)r180Sym : CFSTR("180");
    void *flipSym = dlsym(base, "kVTPixelRotationPropertyKey_FlipHorizontalOrientation");
    _flipHorizontalKey = flipSym ? *(CFStringRef *)flipSym : CFSTR("FlipHorizontalOrientation");

    if (!_createRotationSession || !_transferRotationImage) {
        _rotationApiAvailable = NO;
        vcam_gpu_log(@"[vcam] VTPixelRotationSession API unavailable");
        return;
    }

    OSStatus status = _createRotationSession(kCFAllocatorDefault, &_pixelRotationSession);
    if (status == noErr) {
        _rotationApiAvailable = YES;
        OSStatus st2 = _createRotationSession(kCFAllocatorDefault, &_renderRotationSession);
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] rotation session created (render=%d)", (int)st2]);
    } else {
        _rotationApiAvailable = NO;
    }
}

#pragma mark - 3 槽存取 helper

- (CVPixelBufferRef)prerenderRotateBufferAtSlot:(int)slot {
    if (slot == 0) return _prerenderRotatePool0;
    if (slot == 1) return _prerenderRotatePool1;
    return _prerenderRotatePool2;
}

- (void)setPrerenderRotateBuffer:(CVPixelBufferRef)buf atSlot:(int)slot {
    if (slot == 0) _prerenderRotatePool0 = buf;
    else if (slot == 1) _prerenderRotatePool1 = buf;
    else _prerenderRotatePool2 = buf;
}

- (CVPixelBufferRef)userCanvasAtSlot:(int)slot {
    if (slot == 0) return _userCanvasPool0;
    if (slot == 1) return _userCanvasPool1;
    return _userCanvasPool2;
}

- (void)setUserCanvas:(CVPixelBufferRef)buf atSlot:(int)slot {
    if (slot == 0) _userCanvasPool0 = buf;
    else if (slot == 1) _userCanvasPool1 = buf;
    else _userCanvasPool2 = buf;
}

#pragma mark - CPU 镜像（原地行反转）

// 420f/420v Y 平面 1 字节/px，UV 平面 2 字节/px（CbCr 对不可拆），BGRA 4 字节/px
static void vcamMirrorRowsInPlace(CVPixelBufferRef pb) {
    if (!pb) return;
    CVPixelBufferLockBaseAddress(pb, 0);
    int planes = (int)CVPixelBufferGetPlaneCount(pb);
    if (planes <= 0) {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        size_t w = CVPixelBufferGetWidth(pb) * 4;
        size_t h = CVPixelBufferGetHeight(pb);
        for (size_t y = 0; y < h && base; y++) {
            uint8_t *row = base + y * bpr;
            for (size_t l = 0, r = w - 4; l < r; l += 4, r -= 4) {
                uint32_t t = *(uint32_t *)(row + l);
                *(uint32_t *)(row + l) = *(uint32_t *)(row + r);
                *(uint32_t *)(row + r) = t;
            }
        }
    } else {
        for (int p = 0; p < planes; p++) {
            uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, p);
            size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, p);
            size_t pw = CVPixelBufferGetWidthOfPlane(pb, p);
            size_t ph = CVPixelBufferGetHeightOfPlane(pb, p);
            size_t px = (p == 0) ? 1 : 2;
            size_t rowBytes = pw * px;
            for (size_t y = 0; y < ph && base; y++) {
                uint8_t *row = base + y * bpr;
                for (size_t l = 0, r = rowBytes - px; l < r; l += px, r -= px) {
                    for (size_t b = 0; b < px; b++) {
                        uint8_t t = row[l + b];
                        row[l + b] = row[r + b];
                        row[r + b] = t;
                    }
                }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

// 逐平面复制（格式/尺寸需一致，bytesPerRow 允许不同 → 逐行 min 拷贝）
static BOOL vcamCopyPlanes(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return NO;
    if (CVPixelBufferGetPixelFormatType(src) != CVPixelBufferGetPixelFormatType(dst)) return NO;
    int planes = (int)CVPixelBufferGetPlaneCount(src);
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);
    if (planes <= 0) {
        uint8_t *s = (uint8_t *)CVPixelBufferGetBaseAddress(src);
        uint8_t *d = (uint8_t *)CVPixelBufferGetBaseAddress(dst);
        size_t sbpr = CVPixelBufferGetBytesPerRow(src), dbpr = CVPixelBufferGetBytesPerRow(dst);
        size_t w = CVPixelBufferGetWidth(src) * 4, h = CVPixelBufferGetHeight(src);
        for (size_t y = 0; y < h && s && d; y++) memcpy(d + y * dbpr, s + y * sbpr, w);
    } else {
        for (int p = 0; p < planes; p++) {
            uint8_t *s = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(src, p);
            uint8_t *d = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, p);
            size_t sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t dbpr = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            size_t px = (p == 0) ? 1 : 2;
            size_t w = CVPixelBufferGetWidthOfPlane(src, p) * px;
            size_t h = CVPixelBufferGetHeightOfPlane(src, p);
            for (size_t y = 0; y < h && s && d; y++) memcpy(d + y * dbpr, s + y * sbpr, w);
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return YES;
}

// 色彩附件同步
static void vcamSyncColorAttachments(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return;
    static CFStringRef keys[3];
    static dispatch_once_t onceTok;
    dispatch_once(&onceTok, ^{
        keys[0] = kCVImageBufferColorPrimariesKey;
        keys[1] = kCVImageBufferTransferFunctionKey;
        keys[2] = kCVImageBufferYCbCrMatrixKey;
    });
    for (int i = 0; i < 3; i++) {
        CFTypeRef v = CVBufferGetAttachment(src, keys[i], NULL);
        if (v) CVBufferSetAttachment(dst, keys[i], v, kCVAttachmentMode_ShouldPropagate);
    }
}

#pragma mark - 旋转 + 镜像（预渲染路径）

// 总旋转 = 视频自带(sourceRotation) + 用户手动(rotationAngle)
// VT 只做纯旋转（永不设 flip 属性 —— 420f 上 VT flip 报 -12914）
// 镜像由 CPU 行反转实现
- (CVPixelBufferRef)rotateAndMirrorIfNeeded:(CVPixelBufferRef)input CF_RETURNS_RETAINED {
    if (!input) return NULL;
    int total = (_sourceRotation + _rotationAngle) % 360;
    if (total < 0) total += 360;
    BOOL needRotate = (total != 0);
    BOOL needMirror = _mirrored;
    if (!needRotate && !needMirror) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    OSType fmt = CVPixelBufferGetPixelFormatType(input);

    // 阶段 1：纯旋转（VT）
    CVPixelBufferRef work = NULL;
    BOOL workIsWritable = NO;
    if (needRotate && _rotationApiAvailable && _pixelRotationSession && _transferRotationImage) {
        size_t rotW = (total == 90 || total == 270) ? inH : inW;
        size_t rotH = (total == 90 || total == 270) ? inW : inH;
        int slot = _prerenderRotateSlot;
        _prerenderRotateSlot = (slot + 1) % 3;
        CVPixelBufferRef dst = [self prerenderRotateBufferAtSlot:slot];
        if (!dst || CVPixelBufferGetWidth(dst) != rotW || CVPixelBufferGetHeight(dst) != rotH ||
            CVPixelBufferGetPixelFormatType(dst) != fmt) {
            if (dst) CVPixelBufferRelease(dst);
            dst = NULL;
            OSStatus cst = CVPixelBufferCreate(kCFAllocatorDefault, rotW, rotH, fmt, NULL, &dst);
            if (cst != noErr || !dst) {
                [self setPrerenderRotateBuffer:NULL atSlot:slot];
            } else {
                [self setPrerenderRotateBuffer:dst atSlot:slot];
            }
        }
        if (dst) {
            CFTypeRef rotValue;
            if (total == 90)       rotValue = _rotationCW90Value;
            else if (total == 270) rotValue = _rotationCCW90Value;
            else                   rotValue = _rotation180Value;
            VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, rotValue);
            OSStatus st = _transferRotationImage(_pixelRotationSession, input, dst);
            if (st == noErr) {
                work = CVPixelBufferRetain(dst);
                workIsWritable = YES;
            }
        }
    }
    if (!work) {
        work = (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    // 阶段 2：镜像
    if (!needMirror) return work;
    if (workIsWritable) {
        vcamMirrorRowsInPlace(work);
        return work;
    }
    // mirror-only：复制到几何槽再反转
    int mslot = _prerenderRotateSlot;
    _prerenderRotateSlot = (mslot + 1) % 3;
    CVPixelBufferRef mb = [self prerenderRotateBufferAtSlot:mslot];
    if (!mb || CVPixelBufferGetWidth(mb) != inW || CVPixelBufferGetHeight(mb) != inH ||
        CVPixelBufferGetPixelFormatType(mb) != fmt) {
        if (mb) CVPixelBufferRelease(mb);
        mb = NULL;
        CVPixelBufferRef created = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, inW, inH, fmt, NULL, &created) == noErr && created) {
            [self setPrerenderRotateBuffer:created atSlot:mslot];
            mb = created;
        } else {
            [self setPrerenderRotateBuffer:NULL atSlot:mslot];
        }
    }
    if (mb && vcamCopyPlanes(work, mb)) {
        vcamMirrorRowsInPlace(mb);
        CVPixelBufferRelease(work);
        return CVPixelBufferRetain(mb);
    }
    return work;
}

#pragma mark - 自适应正交旋转（render 路径）

// 源/目标宽高比正交（一横一竖）时 CCW90 旋转
// 判定基准 = 假想 manualRotation=0 的源宽高比（manual 90/270 时先翻回）
- (CVPixelBufferRef)adaptiveRotateIfNeeded:(CVPixelBufferRef)src
                               targetWidth:(size_t)targetW
                              targetHeight:(size_t)targetH
                                     token:(uint64_t)token CF_RETURNS_RETAINED {
    if (!src) return NULL;
    if (!_rotationApiAvailable || !_renderRotationSession) {
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }

    size_t srcW = CVPixelBufferGetWidth(src);
    size_t srcH = CVPixelBufferGetHeight(src);
    if (!srcW || !srcH || !targetW || !targetH) {
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }

    int manualRot = _rotationAngle % 360;
    if (manualRot < 0) manualRot += 360;
    size_t baseW = srcW, baseH = srcH;
    if (manualRot % 180 == 90) {
        baseW = srcH;
        baseH = srcW;
    }

    double srcRatio = (double)baseW / (double)baseH;
    double dstRatio = (double)targetW / (double)targetH;
    BOOL orthogonal = (srcRatio > 1.0 && dstRatio < 1.0) || (srcRatio < 1.0 && dstRatio > 1.0);
    if (!orthogonal) {
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }

    [_rotationRenderLock lock];
    OSType fmt = CVPixelBufferGetPixelFormatType(src);

    // 同帧复用
    if (token != 0 && _adaptiveRotatedGen == token && _adaptiveRotateCache &&
        _adaptiveRotateCacheW == srcH && _adaptiveRotateCacheH == srcW &&
        _adaptiveRotateCacheFmt == fmt) {
        CVPixelBufferRef hit = CVPixelBufferRetain(_adaptiveRotateCache);
        [_rotationRenderLock unlock];
        return hit;
    }

    CVPixelBufferRef rotated = NULL;
    if (_adaptiveRotateCache && _adaptiveRotateCacheW == srcH &&
        _adaptiveRotateCacheH == srcW && _adaptiveRotateCacheFmt == fmt) {
        rotated = CVPixelBufferRetain(_adaptiveRotateCache);
    } else {
        OSStatus cc = CVPixelBufferCreate(kCFAllocatorDefault, srcH, srcW, fmt, NULL, &rotated);
        if (cc != noErr || !rotated) {
            [_rotationRenderLock unlock];
            return (CVPixelBufferRef)CVPixelBufferRetain(src);
        }
        if (_adaptiveRotateCache) CVPixelBufferRelease(_adaptiveRotateCache);
        _adaptiveRotateCache = CVPixelBufferRetain(rotated);
        _adaptiveRotateCacheW = srcH;
        _adaptiveRotateCacheH = srcW;
        _adaptiveRotateCacheFmt = fmt;
    }

    VTSessionSetProperty(_renderRotationSession, _rotationPropertyKey, _rotationCCW90Value);
    OSStatus st = _transferRotationImage(_renderRotationSession, src, rotated);
    if (st == noErr && token != 0) _adaptiveRotatedGen = token;
    [_rotationRenderLock unlock];
    if (st != noErr) {
        CVPixelBufferRelease(rotated);
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }
    return rotated;
}

@end
