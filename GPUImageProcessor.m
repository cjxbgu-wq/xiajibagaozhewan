//
//  GPUImageProcessor.m
//  图像处理器（旋转/镜像/格式转换/用户变换 + 绿边修复）
//

#import "GPUImageProcessor.h"
#import "VCamNotify.h"
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
typedef struct OpaqueVTPixelRotationSession *VTPixelRotationSessionRef;
OSStatus VTPixelTransferSessionCreate(CFAllocatorRef, VTPixelTransferSessionRef *);
OSStatus VTPixelTransferSessionTransferImage(VTPixelTransferSessionRef, CVPixelBufferRef, CVPixelBufferRef);
OSStatus VTSessionSetProperty(CFTypeRef session, CFStringRef propertyKey, CFTypeRef propertyValue);
typedef OSStatus (*VTPixelRotationSessionCreateFunc)(CFAllocatorRef, VTPixelRotationSessionRef *);
typedef OSStatus (*VTPixelRotationSessionTransferImageFunc)(VTPixelRotationSessionRef, CVPixelBufferRef, CVPixelBufferRef);

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

typedef struct {
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;
} VCamLaneStagingSlot;
#define kVcamLaneStagingMax 4
static VCamLaneStagingSlot gVcamLaneStaging[kVcamLaneStagingMax];

// ★ 绿边修复: 整数预裁剪槽 (per-ratio, BGRA)
typedef struct {
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;
    CFAbsoluteTime lastUse;
} VCamCropStagingSlot;
#define kVcamCropStagingMax 4
static VCamCropStagingSlot gVcamCropStaging[kVcamCropStagingMax];
static VTPixelTransferSessionRef gVcamNormalSession = NULL;

typedef struct {
    uint32_t fmt;
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;
    CFAbsoluteTime lastUse;
} VCamYuvStagingSlot;
#define kVcamYuvStagingMax 4
static VCamYuvStagingSlot gVcamYuvStaging[kVcamYuvStagingMax];

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

typedef struct {
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;
} VCamYuvLaneSlot;
#define kVcamYuvLaneMax 4
static VCamYuvLaneSlot gVcamYuvLane[kVcamYuvLaneMax];

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
//  前向声明
// ============================================================
static void vcamMirrorRowsInPlace(CVPixelBufferRef pb);
static BOOL vcamCopyPlanes(CVPixelBufferRef src, CVPixelBufferRef dst);
static void vcamSyncColorAttachments(CVPixelBufferRef src, CVPixelBufferRef dst);
static void vcamTrimFractionalCrop(CVPixelBufferRef src, CVPixelBufferRef dst, BOOL *fixH, BOOL *fixV);
static VCamLaneStagingSlot *vcamPrivateStagingFor(size_t srcW, size_t srcH);
static BOOL vcamPrivateLaneTransfer(GPUImageProcessor *self,
                                    CVPixelBufferRef src, CVPixelBufferRef dst,
                                    uint64_t token);

// ============================================================
//  类扩展
// ============================================================
@interface GPUImageProcessor ()
@property (nonatomic, assign) VTPixelTransferSessionRef bgraTransferSession;
@property (nonatomic, assign) VTPixelTransferSessionRef yuvTransferSession;
@property (nonatomic, assign) VTPixelTransferSessionRef privateTransferSession;
@property (nonatomic, assign) VTPixelTransferSessionRef prerenderTransferSession;

@property (nonatomic, strong) NSLock *laneLockBGRA;
@property (nonatomic, strong) NSLock *laneLockYUV;
@property (nonatomic, strong) NSLock *laneLockPrivate;
@property (nonatomic, assign) VTPixelTransferSessionRef twoStepS1Session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *laneFailCounts;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *laneDisabled;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *twoStepSessionPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *twoStepStagingPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepTokenPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepFailCountPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepDisabledPool;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *oneStepSessionPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSLock *> *oneStepKeyLockPool;
@property (nonatomic, strong) NSLock *rotationRenderLock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSLock *> *twoStepKeyLockPool;

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

@property (nonatomic, assign) VTPixelRotationSessionRef pixelRotationSession;
@property (nonatomic, assign) VTPixelRotationSessionRef renderRotationSession;
@property (nonatomic, assign) CVPixelBufferRef adaptiveRotateCache;
@property (nonatomic, assign) size_t adaptiveRotateCacheW;
@property (nonatomic, assign) size_t adaptiveRotateCacheH;
@property (nonatomic, assign) OSType adaptiveRotateCacheFmt;
@property (nonatomic, assign) uint64_t adaptiveRotatedGen;

@property (nonatomic, strong) NSMutableArray<NSString *> *streamKeyOrder;
@property (nonatomic, strong) NSLock *statsLock;
@property (nonatomic, strong) NSLock *poolDictLock;

@property (nonatomic, assign) VTPixelRotationSessionCreateFunc createRotationSession;
@property (nonatomic, assign) VTPixelRotationSessionTransferImageFunc transferRotationImage;
@property (nonatomic, assign) CFStringRef rotationPropertyKey;
@property (nonatomic, assign) CFStringRef rotationCCW90Value;
@property (nonatomic, assign) CFStringRef rotationCW90Value;
@property (nonatomic, assign) CFStringRef rotation180Value;
@property (nonatomic, assign) CFStringRef flipHorizontalKey;

@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool0;
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool1;
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool2;
@property (nonatomic, assign) int prerenderRotateSlot;

@property (nonatomic, assign) CVPixelBufferRef userCanvasPool0;
@property (nonatomic, assign) CVPixelBufferRef userCanvasPool1;
@property (nonatomic, assign) CVPixelBufferRef userCanvasPool2;
@property (nonatomic, assign) int userCanvasSlot;
@property (nonatomic, assign) CVPixelBufferRef userShrinkBuffer;
@property (nonatomic, assign) CVPixelBufferRef userPieceBuffer;
@property (nonatomic, assign) VTPixelTransferSessionRef userTransferSession;

@property (nonatomic, strong) CIContext *preprocessContext;
@property (nonatomic, strong) CIContext *renderContext;

@property (nonatomic, strong) CIContext *ciGPUContext;
@property (nonatomic, assign) BOOL metalAvailable;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *gpuImgTokenPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CIImage *> *gpuImgOutPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *oneStepFailPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *oneStepDisabledPool;

@property (nonatomic, strong) NSMutableDictionary *bgraBufferPoolMap;

- (void)setupBGRATransferSession;
- (void)setupYUVTransferSession;
- (void)setupPrerenderTransferSession;
- (void)setupPixelRotationSession;

- (CVPixelBufferRef)createBufferWithWidth:(size_t)width height:(size_t)height format:(OSType)format CF_RETURNS_RETAINED;
- (CVPixelBufferRef)convertWithCoreImage:(CVPixelBufferRef)input
                                toFormat:(OSType)format
                                  width:(size_t)width
                                 height:(size_t)height CF_RETURNS_RETAINED;
- (CVPixelBufferPoolRef)getOrCreatePoolForWidth:(size_t)width height:(size_t)height format:(OSType)format;
- (void)touchStreamKeyLRU:(NSString *)key;
- (void)evictStreamKeyResourcesLocked:(NSString *)old;

- (void)noteStreamRenderFmt:(uint32_t)fmt w:(uint32_t)w h:(uint32_t)h pixels:(uint64_t)px;
- (void)noteStageTimingFmt:(uint32_t)fmt w:(uint32_t)w h:(uint32_t)h stage:(int)stage ms:(double)ms;

- (CVPixelBufferRef)prerenderRotateBufferAtSlot:(int)slot;
- (void)setPrerenderRotateBuffer:(CVPixelBufferRef)buf atSlot:(int)slot;
- (CVPixelBufferRef)userCanvasAtSlot:(int)slot;
- (void)setUserCanvas:(CVPixelBufferRef)buf atSlot:(int)slot;

// ★ 绿边修复
- (VTPixelTransferSessionRef)normalTransferSession;
- (CVPixelBufferRef)cropStagingForRatio:(CVPixelBufferRef)staging
                                    dst:(CVPixelBufferRef)dst
                               srcToken:(uint64_t)srcToken;
@end

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
        vcam_gpu_log(@"[vcam] GPUImageProcessor initialized (with green-edge fix)");
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

    for (int i = 0; i < kVcamLaneStagingMax; i++) {
        if (gVcamLaneStaging[i].staging) {
            CVPixelBufferRelease(gVcamLaneStaging[i].staging);
            gVcamLaneStaging[i].staging = NULL;
        }
    }
    for (int i = 0; i < kVcamCropStagingMax; i++) {
        if (gVcamCropStaging[i].staging) {
            CVPixelBufferRelease(gVcamCropStaging[i].staging);
            gVcamCropStaging[i].staging = NULL;
        }
    }
    if (gVcamNormalSession && invalidate) {
        invalidate(gVcamNormalSession);
        gVcamNormalSession = NULL;
    }

    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef b = [self prerenderRotateBufferAtSlot:i];
        if (b) CVPixelBufferRelease(b);
        [self setPrerenderRotateBuffer:NULL atSlot:i];
    }
    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef b = [self userCanvasAtSlot:i];
        if (b) CVPixelBufferRelease(b);
        [self setUserCanvas:NULL atSlot:i];
    }
    if (_userShrinkBuffer) CVPixelBufferRelease(_userShrinkBuffer);
    if (_userPieceBuffer) CVPixelBufferRelease(_userPieceBuffer);
    if (_adaptiveRotateCache) CVPixelBufferRelease(_adaptiveRotateCache);

    typedef void (*InvalidateRotFunc)(VTPixelRotationSessionRef);
    InvalidateRotFunc invalidateRot = (InvalidateRotFunc)dlsym(RTLD_DEFAULT, "VTPixelRotationSessionInvalidate");
    if (invalidateRot) {
        if (_pixelRotationSession) invalidateRot(_pixelRotationSession);
        if (_renderRotationSession) invalidateRot(_renderRotationSession);
    }

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
    VTPixelTransferSessionRef s = NULL;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &s);
    if (status == noErr && s) {
        VTSessionSetProperty(s, CFSTR("ScalingMode"), CFSTR("Trim"));
        _bgraTransferSession = s;
    }
}

- (void)setupYUVTransferSession {
    if (_yuvTransferSession) return;
    VTPixelTransferSessionRef s = NULL;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &s);
    if (status == noErr && s) {
        VTSessionSetProperty(s, CFSTR("ScalingMode"), CFSTR("Trim"));
        _yuvTransferSession = s;
    }
}

- (void)setupPrerenderTransferSession {
    if (_prerenderTransferSession) return;
    VTPixelTransferSessionRef s = NULL;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &s);
    if (status == noErr && s) {
        VTSessionSetProperty(s, CFSTR("ScalingMode"), CFSTR("Trim"));
        _prerenderTransferSession = s;
    }
}

- (void)setupPixelRotationSession {
    if (_pixelRotationSession) return;

    void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox",
                      RTLD_LAZY | RTLD_GLOBAL);
    void *base = vt ? vt : RTLD_DEFAULT;

    _createRotationSession = (VTPixelRotationSessionCreateFunc)dlsym(base, "VTPixelRotationSessionCreate");
    _transferRotationImage = (VTPixelRotationSessionTransferImageFunc)dlsym(base, "VTPixelRotationSessionRotateImage");

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
        return;
    }

    VTPixelRotationSessionRef s = NULL;
    OSStatus status = _createRotationSession(kCFAllocatorDefault, &s);
    if (status == noErr && s) {
        _rotationApiAvailable = YES;
        _pixelRotationSession = s;
        VTPixelRotationSessionRef rs = NULL;
        OSStatus st2 = _createRotationSession(kCFAllocatorDefault, &rs);
        if (st2 == noErr && rs) _renderRotationSession = rs;
    } else {
        _rotationApiAvailable = NO;
    }
}

#pragma mark - 3 槽存取

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

#pragma mark - 静态辅助函数

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

// ★ 绿边修复: Trim crop offset 非整数判定
static void vcamTrimFractionalCrop(CVPixelBufferRef src, CVPixelBufferRef dst, BOOL *fixH, BOOL *fixV) {
    *fixH = NO; *fixV = NO;
    if (!src || !dst) return;
    size_t srcW = CVPixelBufferGetWidth(src), srcH = CVPixelBufferGetHeight(src);
    size_t dstW = CVPixelBufferGetWidth(dst), dstH = CVPixelBufferGetHeight(dst);
    if (!srcW || !srcH || !dstW || !dstH) return;
    double sc = MAX((double)dstW / srcW, (double)dstH / srcH);
    double cropW = srcW * sc - dstW;
    double cropH = srcH * sc - dstH;
    if (cropW > 0.5) {
        double off = cropW / 2.0;
        *fixH = (fabs(off - floor(off + 0.5)) > 1e-3);
    }
    if (cropH > 0.5) {
        double off = cropH / 2.0;
        *fixV = (fabs(off - floor(off + 0.5)) > 1e-3);
    }
}

#pragma mark - 旋转 + 镜像

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

    if (!needMirror) return work;
    if (workIsWritable) {
        vcamMirrorRowsInPlace(work);
        return work;
    }

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

#pragma mark - 自适应正交旋转

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

#pragma mark - 缓冲池

- (CVPixelBufferPoolRef)getOrCreatePoolForWidth:(size_t)width height:(size_t)height format:(OSType)format {
    if (width == 0 || height == 0) return NULL;
    @synchronized(self) {
        NSString *key = [NSString stringWithFormat:@"%zu_%zu_%u", width, height, (unsigned)format];
        id existing = _bgraBufferPoolMap[key];
        if (existing) return (__bridge CVPixelBufferPoolRef)existing;

        [self touchStreamKeyLRU:key];

        NSDictionary *poolAttributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @2,
        };
        NSDictionary *pixelBufferAttributes = @{
            (id)kCVPixelBufferWidthKey:  @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferPixelFormatTypeKey: @(format),
        };

        CVPixelBufferPoolRef pool = NULL;
        OSStatus status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
            (__bridge CFDictionaryRef)poolAttributes,
            (__bridge CFDictionaryRef)pixelBufferAttributes, &pool);
        if (status != noErr) {
            status = CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                (__bridge CFDictionaryRef)pixelBufferAttributes, &pool);
        }
        if (status == noErr && pool) {
            _bgraBufferPoolMap[key] = (__bridge id)pool;
            return pool;
        }
        return NULL;
    }
}

- (CVPixelBufferRef)getOrCreateBGRABufferWithWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED {
    @synchronized(self) {
        CVPixelBufferPoolRef pool = [self getOrCreatePoolForWidth:width height:height
                                                           format:kCVPixelFormatType_32BGRA];
        CVPixelBufferRef buffer = NULL;
        if (pool) {
            if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == noErr && buffer) {
                return buffer;
            }
        }
        OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                              kCVPixelFormatType_32BGRA, NULL, &buffer);
        if (status != noErr) return NULL;
        return buffer;
    }
}

- (CVPixelBufferRef)createBufferWithWidth:(size_t)width height:(size_t)height format:(OSType)format CF_RETURNS_RETAINED {
    CVPixelBufferRef buffer = NULL;
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, NULL, &buffer);
    if (status != noErr) return NULL;
    return buffer;
}

- (void)configureWithWidth:(size_t)width height:(size_t)height format:(OSType)format {
    [self getOrCreatePoolForWidth:width height:height format:format];
}

#pragma mark - ★ 绿边修复 (新增)

- (VTPixelTransferSessionRef)normalTransferSession {
    if (!gVcamNormalSession) {
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &gVcamNormalSession) == noErr) {
            VTSessionSetProperty(gVcamNormalSession, CFSTR("ScalingMode"), CFSTR("Normal"));
            VTSessionSetProperty(gVcamNormalSession, CFSTR("RealTime"), kCFBooleanTrue);
            vcam_gpu_log(@"[vcam] Normal transfer session created (green-edge fix)");
        }
    }
    return gVcamNormalSession;
}

- (CVPixelBufferRef)cropStagingForRatio:(CVPixelBufferRef)staging
                                    dst:(CVPixelBufferRef)dst
                               srcToken:(uint64_t)srcToken {
    if (!staging || !dst) return NULL;
    size_t sw = CVPixelBufferGetWidth(staging), sh = CVPixelBufferGetHeight(staging);
    size_t dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
    if (!sw || !sh || !dw || !dh) return NULL;

    double r = (double)dw / dh;
    size_t cw, ch;
    if ((double)sw / sh > r) { ch = sh; cw = (size_t)(sh * r); }
    else                     { cw = sw; ch = (size_t)(sw / r); }
    cw &= ~(size_t)1; ch &= ~(size_t)1;
    if (cw < 4 || ch < 4 || cw > sw || ch > sh) return NULL;
    size_t cx = (((sw - cw) / 2) & ~(size_t)1);
    size_t cy = (((sh - ch) / 2) & ~(size_t)1);

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    VCamCropStagingSlot *slot = NULL;
    int lruIdx = 0;
    for (int i = 0; i < kVcamCropStagingMax; i++) {
        if (gVcamCropStaging[i].staging &&
            gVcamCropStaging[i].w == cw && gVcamCropStaging[i].h == ch) {
            slot = &gVcamCropStaging[i]; break;
        }
        if (gVcamCropStaging[i].lastUse < gVcamCropStaging[lruIdx].lastUse) lruIdx = i;
    }
    if (!slot) {
        int idx = -1;
        for (int i = 0; i < kVcamCropStagingMax; i++) {
            if (!gVcamCropStaging[i].staging) { idx = i; break; }
        }
        if (idx < 0) {
            idx = lruIdx;
            CVPixelBufferRelease(gVcamCropStaging[idx].staging);
            gVcamCropStaging[idx].staging = NULL;
        }
        CVPixelBufferRef nb = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, cw, ch,
                                kCVPixelFormatType_32BGRA, NULL, &nb) != noErr || !nb) return NULL;
        gVcamCropStaging[idx].w = cw;
        gVcamCropStaging[idx].h = ch;
        gVcamCropStaging[idx].staging = nb;
        gVcamCropStaging[idx].token = 0;
        gVcamCropStaging[idx].lastUse = now;
        slot = &gVcamCropStaging[idx];
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Crop staging built %zux%zu (slot %d)", cw, ch, idx]);
    }
    slot->lastUse = now;
    if (slot->token == srcToken && srcToken != 0) return slot->staging;

    BOOL copied = NO;
    if (CVPixelBufferLockBaseAddress(staging, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
        if (CVPixelBufferLockBaseAddress(slot->staging, 0) == kCVReturnSuccess) {
            uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddress(staging);
            uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddress(slot->staging);
            size_t srb = CVPixelBufferGetBytesPerRow(staging);
            size_t drb = CVPixelBufferGetBytesPerRow(slot->staging);
            if (sb && db && srb >= cw * 4 && drb >= cw * 4) {
                size_t rowBytes = cw * 4;
                for (size_t y = 0; y < ch; y++) {
                    memcpy(db + y * drb, sb + (cy + y) * srb + cx * 4, rowBytes);
                }
                slot->token = srcToken;
                copied = YES;
            }
            vcamSyncColorAttachments(staging, slot->staging);
            CVPixelBufferUnlockBaseAddress(slot->staging, 0);
        }
        CVPixelBufferUnlockBaseAddress(staging, kCVPixelBufferLock_ReadOnly);
    }
    return copied ? slot->staging : NULL;
}

#pragma mark - 私有车道

static VCamLaneStagingSlot *vcamPrivateStagingFor(size_t srcW, size_t srcH) {
    VCamLaneStagingSlot *slot = NULL;
    for (int i = 0; i < kVcamLaneStagingMax; i++) {
        if (gVcamLaneStaging[i].staging &&
            gVcamLaneStaging[i].w == srcW && gVcamLaneStaging[i].h == srcH) {
            slot = &gVcamLaneStaging[i];
            break;
        }
    }
    if (!slot) {
        for (int i = 0; i < kVcamLaneStagingMax; i++) {
            if (!gVcamLaneStaging[i].staging) {
                CVPixelBufferRef nb = NULL;
                if (CVPixelBufferCreate(kCFAllocatorDefault, srcW, srcH,
                                        kCVPixelFormatType_32BGRA, NULL, &nb) == noErr && nb) {
                    gVcamLaneStaging[i].w = srcW;
                    gVcamLaneStaging[i].h = srcH;
                    gVcamLaneStaging[i].staging = nb;
                    gVcamLaneStaging[i].token = 0;
                    slot = &gVcamLaneStaging[i];
                }
                break;
            }
        }
    }
    return slot;
}

// ★ 私有格式车道: s1 staging (BGRA) → s2 加绿边修复 + Normal 缩放
static BOOL vcamPrivateLaneTransfer(GPUImageProcessor *self,
                                    CVPixelBufferRef src, CVPixelBufferRef dst,
                                    uint64_t token) {
    VTPixelTransferSessionRef s1 = self.twoStepS1Session;
    VTPixelTransferSessionRef s2 = self.privateTransferSession;
    if (!s1) {
        VTPixelTransferSessionRef newS1 = NULL;
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &newS1) == noErr && newS1) {
            VTSessionSetProperty(newS1, CFSTR("ScalingMode"), CFSTR("Trim"));
            VTSessionSetProperty(newS1, CFSTR("RealTime"), kCFBooleanTrue);
            self.twoStepS1Session = newS1;
            s1 = newS1;
        }
    }
    if (!s2) {
        VTPixelTransferSessionRef newS2 = NULL;
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &newS2) == noErr && newS2) {
            VTSessionSetProperty(newS2, CFSTR("ScalingMode"), CFSTR("Trim"));
            VTSessionSetProperty(newS2, CFSTR("RealTime"), kCFBooleanTrue);
            self.privateTransferSession = newS2;
            s2 = newS2;
        }
    }
    if (!s1 || !s2) return NO;

    size_t srcW = CVPixelBufferGetWidth(src);
    size_t srcH = CVPixelBufferGetHeight(src);
    VCamLaneStagingSlot *slot = vcamPrivateStagingFor(srcW, srcH);
    if (!slot) return NO;

    BOOL ok = NO;
    if (token != 0 && slot->token == token) {
        ok = YES;
    } else {
        OSStatus st1 = VTPixelTransferSessionTransferImage(s1, src, slot->staging);
        if (st1 == noErr) {
            slot->token = token;
            ok = YES;
        } else {
            slot->token = 0;
        }
    }
    if (!ok) return NO;

    // ★ 绿边修复: BGRA staging → 私有目标, 检查 Trim crop 是否非整数
    CVPixelBufferRef s2src = slot->staging;
    VTPixelTransferSessionRef s2sess = s2;
    BOOL fixH = NO, fixV = NO;
    vcamTrimFractionalCrop(slot->staging, dst, &fixH, &fixV);
    if (fixH || fixV) {
        CVPixelBufferRef cropped = [self cropStagingForRatio:slot->staging
                                                         dst:dst
                                                    srcToken:slot->token];
        if (cropped) {
            VTPixelTransferSessionRef ns = [self normalTransferSession];
            if (ns) {
                s2src = cropped;
                s2sess = ns;
                static CFAbsoluteTime lastLog = 0;
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - lastLog > 5.0) {
                    lastLog = now;
                    vcam_gpu_log([NSString stringWithFormat:
                        @"[vcam] green-edge fix (private lane) %zux%zu -> %zux%zu",
                        srcW, srcH, CVPixelBufferGetWidth(dst), CVPixelBufferGetHeight(dst)]);
                }
            }
        }
    }

    OSStatus st2 = VTPixelTransferSessionTransferImage(s2sess, s2src, dst);
    return (st2 == noErr);
}

#pragma mark - transferPixelBuffer (绿边修复调用)

- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst {
    return [self transferPixelBuffer:src toPixelBuffer:dst token:0];
}

- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst token:(uint64_t)token {
    if (!src || !dst) return NO;

    OSType dstFormat = CVPixelBufferGetPixelFormatType(dst);

    BOOL laneOff = NO;
    int hit = -1;
    for (int i = 0; i < 4; i++) {
        if (gVcamLaneMemoFmt[i] == dstFormat) { hit = i; laneOff = gVcamLaneMemoOff[i]; break; }
    }
    if (hit < 0) {
        laneOff = [_laneDisabled[@(dstFormat)] boolValue];
        vcamLaneMemoInvalidate((uint32_t)dstFormat, laneOff);
    }
    if (laneOff && vcamLaneMemoExpired((uint32_t)dstFormat)) {
        vcamLaneMemoInvalidate((uint32_t)dstFormat, NO);
        gVcamLaneFailCnt[vcamLaneFailSlot((uint32_t)dstFormat)] = 0;
        @synchronized(self) { _laneDisabled[@(dstFormat)] = @NO; }
        laneOff = NO;
    }
    if (laneOff) return NO;

    BOOL isYuvLane = ((dstFormat & 0xffffffef) == '420f' || dstFormat == 0x70343230);
    BOOL isBgraLane = (dstFormat == kCVPixelFormatType_32BGRA);

    if (!isBgraLane && !isYuvLane) {
        [_laneLockPrivate lock];
        BOOL ok = vcamPrivateLaneTransfer(self, src, dst, token);
        [_laneLockPrivate unlock];
        if (ok) {
            vcamLaneNoteSuccess((uint32_t)dstFormat);
            [self noteStreamRenderFmt:(uint32_t)dstFormat
                                    w:(uint32_t)CVPixelBufferGetWidth(dst)
                                    h:(uint32_t)CVPixelBufferGetHeight(dst)
                               pixels:(uint64_t)CVPixelBufferGetWidth(dst) * CVPixelBufferGetHeight(dst)];
            return YES;
        }
        int32_t fails = ++gVcamLaneFailCnt[vcamLaneFailSlot((uint32_t)dstFormat)];
        if (fails >= 2) {
            @synchronized(self) { _laneDisabled[@(dstFormat)] = @YES; }
            vcamLaneMemoInvalidate((uint32_t)dstFormat, YES);
        }
        return NO;
    }

    VTPixelTransferSessionRef session = isBgraLane ? _bgraTransferSession : _yuvTransferSession;
    NSLock *laneLock = isBgraLane ? _laneLockBGRA : _laneLockYUV;
    if (!session) {
        if (isBgraLane) [self setupBGRATransferSession];
        else [self setupYUVTransferSession];
        session = isBgraLane ? _bgraTransferSession : _yuvTransferSession;
    }
    if (!session || !laneLock) return NO;

    [laneLock lock];

    // ★ 绿边修复 (标准 YUV 车道): BGRA 源 → YUV420 dst 且 Trim crop offset 非整数
    // → 用整数预裁剪 + Normal 缩放
    CVPixelBufferRef xferSrc = src;
    VTPixelTransferSessionRef xferSess = session;
    if (isYuvLane && !isBgraLane &&
        CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA) {
        BOOL fixH = NO, fixV = NO;
        vcamTrimFractionalCrop(src, dst, &fixH, &fixV);
        if (fixH || fixV) {
            [_laneLockPrivate lock];
            CVPixelBufferRef cropped = [self cropStagingForRatio:src dst:dst srcToken:token];
            if (cropped) {
                VTPixelTransferSessionRef ns = [self normalTransferSession];
                if (ns) {
                    xferSrc = cropped;
                    xferSess = ns;
                    static CFAbsoluteTime lastLog = 0;
                    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                    if (now - lastLog > 5.0) {
                        lastLog = now;
                        vcam_gpu_log([NSString stringWithFormat:
                            @"[vcam] green-edge fix (YUV lane) %zux%zu -> %zux%zu",
                            CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src),
                            CVPixelBufferGetWidth(dst), CVPixelBufferGetHeight(dst)]);
                    }
                }
            }
            [_laneLockPrivate unlock];
        }
    }

    CFAbsoluteTime tOp = CFAbsoluteTimeGetCurrent();
    OSStatus status = VTPixelTransferSessionTransferImage(xferSess, xferSrc, dst);
    [self noteStageTimingFmt:(uint32_t)dstFormat
                            w:(uint32_t)CVPixelBufferGetWidth(dst)
                            h:(uint32_t)CVPixelBufferGetHeight(dst)
                        stage:2
                           ms:(CFAbsoluteTimeGetCurrent() - tOp) * 1000.0];
    [laneLock unlock];

    if (status == noErr) {
        vcamLaneNoteSuccess((uint32_t)dstFormat);
        [self noteStreamRenderFmt:(uint32_t)dstFormat
                                w:(uint32_t)CVPixelBufferGetWidth(dst)
                                h:(uint32_t)CVPixelBufferGetHeight(dst)
                           pixels:(uint64_t)CVPixelBufferGetWidth(dst) * CVPixelBufferGetHeight(dst)];
        return YES;
    }
    int32_t fails = ++gVcamLaneFailCnt[vcamLaneFailSlot((uint32_t)dstFormat)];
    if (fails >= 2) {
        @synchronized(self) { _laneDisabled[@(dstFormat)] = @YES; }
        vcamLaneMemoInvalidate((uint32_t)dstFormat, YES);
    }
    return NO;
}

#pragma mark - crop fill 缩放

- (CVPixelBufferRef)scaleToBGRA:(CVPixelBufferRef)input
                          width:(size_t)width
                         height:(size_t)height CF_RETURNS_RETAINED {
    if (!input || !_preprocessContext) return NULL;
    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    if (!inW || !inH || !width || !height) return NULL;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NULL;

    CVPixelBufferRef output = [self getOrCreateBGRABufferWithWidth:width height:height];
    if (!output) return NULL;

    CGFloat scale = MAX((CGFloat)width / (CGFloat)inW, (CGFloat)height / (CGFloat)inH);
    CGFloat scaledW = (CGFloat)inW * scale;
    CGFloat scaledH = (CGFloat)inH * scale;
    CGFloat offsetX = ((CGFloat)width - scaledW) / 2.0;
    CGFloat offsetY = ((CGFloat)height - scaledH) / 2.0;

    CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
    t = CGAffineTransformTranslate(t, offsetX / scale, offsetY / scale);
    CIImage *scaled = [image imageByApplyingTransform:t];

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_preprocessContext render:scaled toCVPixelBuffer:output
                        bounds:CGRectMake(0, 0, (CGFloat)width, (CGFloat)height)
                    colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);
    return output;
}

#pragma mark - 用户缩放/平移烘焙

- (CVPixelBufferRef)bakeUserTransformIntoCanvas:(CVPixelBufferRef)input CF_RETURNS_RETAINED {
    if (!input) return NULL;
    double z = _userZoom;
    if (z < 0.5) z = 0.5;
    if (z > 4.0) z = 4.0;
    if (fabs(z - 1.0) < 0.001 && _userPanX == 0.0 && _userPanY == 0.0) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }
    if (CVPixelBufferGetPlaneCount(input) != 2) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }
    size_t W = CVPixelBufferGetWidth(input);
    size_t H = CVPixelBufferGetHeight(input);
    if (W < 16 || H < 16) return (CVPixelBufferRef)CVPixelBufferRetain(input);

    OSType fmt = CVPixelBufferGetPixelFormatType(input);

    int slot = _userCanvasSlot;
    _userCanvasSlot = (slot + 1) % 3;
    CVPixelBufferRef canvas = [self userCanvasAtSlot:slot];
    if (!canvas || CVPixelBufferGetWidth(canvas) != W || CVPixelBufferGetHeight(canvas) != H ||
        CVPixelBufferGetPixelFormatType(canvas) != fmt) {
        if (canvas) CVPixelBufferRelease(canvas);
        canvas = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, W, H, fmt, NULL, &canvas) != noErr || !canvas) {
            [self setUserCanvas:NULL atSlot:slot];
            return (CVPixelBufferRef)CVPixelBufferRetain(input);
        }
        [self setUserCanvas:canvas atSlot:slot];
    }

    CFDictionaryRef colorAtts = CVBufferGetAttachments(input, kCVAttachmentMode_ShouldPropagate);
    if (colorAtts) {
        CVBufferSetAttachments(canvas, colorAtts, kCVAttachmentMode_ShouldPropagate);
    }

    double ww = (double)W / z;
    double wh = (double)H / z;
    double wx = ((double)W - ww) / 2.0 - _userPanX * (double)W;
    double wy = ((double)H - wh) / 2.0 - _userPanY * (double)W;

    long sx0 = (long)MAX(wx, 0.0), sy0 = (long)MAX(wy, 0.0);
    long sx1 = (long)MIN(wx + ww, (double)W), sy1 = (long)MIN(wy + wh, (double)H);
    sx0 &= ~1L; sy0 &= ~1L; sx1 &= ~1L; sy1 &= ~1L;

    CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(canvas, 0);

    void (^copyRegion)(CVPixelBufferRef, CVPixelBufferRef, size_t, size_t, size_t, size_t, size_t, size_t) =
    ^(CVPixelBufferRef d, CVPixelBufferRef s, size_t dX, size_t dY, size_t sX, size_t sY, size_t w, size_t h) {
        for (int p = 0; p < 2; p++) {
            uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(s, p);
            uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(d, p);
            if (!sb || !db) continue;
            size_t sbpr = CVPixelBufferGetBytesPerRowOfPlane(s, p);
            size_t dbpr = CVPixelBufferGetBytesPerRowOfPlane(d, p);
            size_t rowBytes = w;
            size_t rows = (p == 0) ? h : h / 2;
            size_t yDiv = (p == 0) ? 1 : 2;
            for (size_t y = 0; y < rows; y++) {
                memcpy(db + (dY / yDiv + y) * dbpr + dX,
                       sb + (sY / yDiv + y) * sbpr + sX, rowBytes);
            }
        }
    };

    void (^clearBlack)(CVPixelBufferRef) = ^(CVPixelBufferRef b) {
        int yBlack = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? 0 : 16;
        uint8_t *yb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, 0);
        uint8_t *uvb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, 1);
        size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(b, 0);
        size_t uvbpr = CVPixelBufferGetBytesPerRowOfPlane(b, 1);
        size_t w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b);
        if (yb) for (size_t y = 0; y < h; y++) memset(yb + y * ybpr, yBlack, w);
        if (uvb) for (size_t y = 0; y < h / 2; y++) memset(uvb + y * uvbpr, 128, w);
    };

    if (sx1 <= sx0 || sy1 <= sy0) {
        clearBlack(canvas);
    } else {
        size_t sw = (size_t)(sx1 - sx0), sh = (size_t)(sy1 - sy0);
        double kx = (double)W / ww;
        long dx0 = lround(((double)sx0 - wx) * kx) & ~1L;
        long dy0 = lround(((double)sy0 - wy) * kx) & ~1L;
        long dx1 = lround(((double)sx1 - wx) * kx) & ~1L;
        long dy1 = lround(((double)sy1 - wy) * kx) & ~1L;
        if (dx0 < 0) dx0 = 0; if (dy0 < 0) dy0 = 0;
        if (dx1 > (long)W) dx1 = (long)W;
        if (dy1 > (long)H) dy1 = (long)H;
        if (dx1 > dx0 && dy1 > dy0) {
            size_t dw = (size_t)(dx1 - dx0), dh = (size_t)(dy1 - dy0);
            clearBlack(canvas);

            if (fabs(kx - 1.0) < 0.001) {
                copyRegion(canvas, input, (size_t)dx0, (size_t)dy0,
                           (size_t)sx0, (size_t)sy0, dw, dh);
            } else {
                if (!_userShrinkBuffer ||
                    CVPixelBufferGetWidth(_userShrinkBuffer) != sw ||
                    CVPixelBufferGetHeight(_userShrinkBuffer) != sh ||
                    CVPixelBufferGetPixelFormatType(_userShrinkBuffer) != fmt) {
                    if (_userShrinkBuffer) CVPixelBufferRelease(_userShrinkBuffer);
                    _userShrinkBuffer = NULL;
                    CVPixelBufferCreate(kCFAllocatorDefault, sw, sh, fmt, NULL, &_userShrinkBuffer);
                }
                if (_userShrinkBuffer) {
                    CVPixelBufferLockBaseAddress(_userShrinkBuffer, 0);
                    copyRegion(_userShrinkBuffer, input, 0, 0, (size_t)sx0, (size_t)sy0, sw, sh);
                    CVPixelBufferUnlockBaseAddress(_userShrinkBuffer, 0);

                    if (!_userTransferSession) {
                        VTPixelTransferSessionRef us = NULL;
                        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &us) == noErr && us) {
                            VTSessionSetProperty(us, CFSTR("ScalingMode"), CFSTR("Trim"));
                            VTSessionSetProperty(us, CFSTR("RealTime"), kCFBooleanTrue);
                            _userTransferSession = us;
                        }
                    }
                    if (_userTransferSession) {
                        if (!_userPieceBuffer ||
                            CVPixelBufferGetWidth(_userPieceBuffer) != dw ||
                            CVPixelBufferGetHeight(_userPieceBuffer) != dh ||
                            CVPixelBufferGetPixelFormatType(_userPieceBuffer) != fmt) {
                            if (_userPieceBuffer) CVPixelBufferRelease(_userPieceBuffer);
                            _userPieceBuffer = NULL;
                            CVPixelBufferCreate(kCFAllocatorDefault, dw, dh, fmt, NULL, &_userPieceBuffer);
                        }
                        if (_userPieceBuffer &&
                            VTPixelTransferSessionTransferImage(_userTransferSession,
                                _userShrinkBuffer, _userPieceBuffer) == noErr) {
                            CVPixelBufferLockBaseAddress(_userPieceBuffer, kCVPixelBufferLock_ReadOnly);
                            copyRegion(canvas, _userPieceBuffer, (size_t)dx0, (size_t)dy0, 0, 0, dw, dh);
                            CVPixelBufferUnlockBaseAddress(_userPieceBuffer, kCVPixelBufferLock_ReadOnly);
                        } else {
                            copyRegion(canvas, _userShrinkBuffer, 0, 0, 0, 0, MIN(sw, W), MIN(sh, H));
                        }
                    } else {
                        copyRegion(canvas, _userShrinkBuffer, 0, 0, 0, 0, MIN(sw, W), MIN(sh, H));
                    }
                }
            }
        } else {
            clearBlack(canvas);
        }
    }

    CVPixelBufferUnlockBaseAddress(canvas, 0);
    CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    return (CVPixelBufferRef)CVPixelBufferRetain(canvas);
}

#pragma mark - CI 回退

- (CVPixelBufferRef)convertWithCoreImage:(CVPixelBufferRef)input
                                toFormat:(OSType)format
                                  width:(size_t)width
                                 height:(size_t)height CF_RETURNS_RETAINED {
    if (!input || !_preprocessContext) return NULL;
    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NULL;

    CVPixelBufferRef bgra = [self getOrCreateBGRABufferWithWidth:width height:height];
    if (!bgra) return NULL;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_preprocessContext render:image toCVPixelBuffer:bgra
                        bounds:CGRectMake(0, 0, (CGFloat)width, (CGFloat)height)
                    colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);

    if (format == kCVPixelFormatType_32BGRA) return bgra;

    CVPixelBufferRef output = [self createBufferWithWidth:width height:height format:format];
    if (!output) { CVPixelBufferRelease(bgra); return NULL; }
    if (!_prerenderTransferSession) [self setupPrerenderTransferSession];
    if (!_prerenderTransferSession ||
        VTPixelTransferSessionTransferImage(_prerenderTransferSession, bgra, output) != noErr) {
        CVPixelBufferRelease(output);
        CVPixelBufferRelease(bgra);
        return NULL;
    }
    CVPixelBufferRelease(bgra);
    return output;
}

- (CVPixelBufferRef)convertFormat:(CVPixelBufferRef)input toFormat:(OSType)format CF_RETURNS_RETAINED {
    if (!input) return NULL;
    if (CVPixelBufferGetPixelFormatType(input) == format) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }
    size_t w = CVPixelBufferGetWidth(input);
    size_t h = CVPixelBufferGetHeight(input);

    CVPixelBufferRef out = [self createBufferWithWidth:w height:h format:format];
    if (out) {
        if (!_prerenderTransferSession) [self setupPrerenderTransferSession];
        if (_prerenderTransferSession &&
            VTPixelTransferSessionTransferImage(_prerenderTransferSession, input, out) == noErr) {
            return out;
        }
        CVPixelBufferRelease(out);
    }
    return [self convertWithCoreImage:input toFormat:format width:w height:h];
}

- (BOOL)renderCropFill:(CVPixelBufferRef)input toPixelBuffer:(CVPixelBufferRef)dst {
    if (!input || !dst || !_renderContext) return NO;
    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    size_t w = CVPixelBufferGetWidth(dst);
    size_t h = CVPixelBufferGetHeight(dst);
    if (!inW || !inH || !w || !h) return NO;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NO;

    CGFloat scale = MAX((CGFloat)w / (CGFloat)inW, (CGFloat)h / (CGFloat)inH);
    CGFloat offsetX = ((CGFloat)w - (CGFloat)inW * scale) / 2.0;
    CGFloat offsetY = ((CGFloat)h - (CGFloat)inH * scale) / 2.0;
    CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
    t = CGAffineTransformTranslate(t, offsetX / scale, offsetY / scale);
    CIImage *scaled = [image imageByApplyingTransform:t];

    [_rotationRenderLock lock];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_renderContext render:scaled toCVPixelBuffer:dst
                    bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)
                colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);
    [_rotationRenderLock unlock];
    return YES;
}

#pragma mark - 核心入口

- (CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)input
                                toWidth:(size_t)width
                                height:(size_t)height
                                format:(OSType)format CF_RETURNS_RETAINED {
    if (!input) return NULL;
    @try {
        int total = (_sourceRotation + _rotationAngle) % 360;
        if (total < 0) total += 360;

        CVPixelBufferRef processed = NULL;
        if ((total != 0 || _mirrored) && _rotationApiAvailable && _pixelRotationSession) {
            processed = [self rotateAndMirrorIfNeeded:input];
        }
        if (!processed) {
            processed = (CVPixelBufferRef)CVPixelBufferRetain(input);
        }

        size_t curW = CVPixelBufferGetWidth(processed);
        size_t curH = CVPixelBufferGetHeight(processed);
        if (curW != width || curH != height) {
            CVPixelBufferRef scaled = [self scaleToBGRA:processed width:width height:height];
            CVPixelBufferRelease(processed);
            processed = scaled;
            if (!processed) return NULL;
        }

        CVPixelBufferRef output = NULL;
        if (format == kCVPixelFormatType_32BGRA) {
            output = processed;
        } else {
            output = [self createBufferWithWidth:width height:height format:format];
            if (output) {
                if (!_prerenderTransferSession) [self setupPrerenderTransferSession];
                OSStatus status = VTPixelTransferSessionTransferImage(_prerenderTransferSession,
                                                                      processed, output);
                if (status != noErr) {
                    CVPixelBufferRelease(output);
                    output = [self convertWithCoreImage:processed toFormat:format
                                                  width:width height:height];
                }
            }
            CVPixelBufferRelease(processed);
        }
        return output;
    } @catch (NSException *e) {
        return NULL;
    }
}

#pragma mark - LRU 淘汰

static const NSUInteger kVcamMaxStreamKeys = 6;

- (void)evictStreamKeyResourcesLocked:(NSString *)old {
    if (!old) return;
    NSLock *olock = _oneStepKeyLockPool[old];
    NSLock *tlock = _twoStepKeyLockPool[old];
    if (olock) [olock lock];
    if (tlock) [tlock lock];

    void (*invalidateSession)(VTPixelTransferSessionRef) =
        (void (*)(VTPixelTransferSessionRef))dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");

    NSValue *osv = nil, *tsv = nil, *stv = nil, *rcv = nil, *rbsv = nil;
    id poolObj = nil;
    [_poolDictLock lock];
    osv = _oneStepSessionPool[old];
    if (osv) [_oneStepSessionPool removeObjectForKey:old];
    tsv = _twoStepSessionPool[old];
    if (tsv) [_twoStepSessionPool removeObjectForKey:old];
    stv = _twoStepStagingPool[old];
    if (stv) [_twoStepStagingPool removeObjectForKey:old];
    [_twoStepTokenPool removeObjectForKey:old];
    [_twoStepFailCountPool removeObjectForKey:old];
    poolObj = _bgraBufferPoolMap[old];
    if (poolObj) [_bgraBufferPoolMap removeObjectForKey:old];
    if (![old hasPrefix:@"g:"]) {
        rcv = _resultCachePool[old];
        if (rcv) [_resultCachePool removeObjectForKey:old];
        [_resultCacheTokenPool removeObjectForKey:old];
        [_lastReqTokenPool removeObjectForKey:old];
        rbsv = _resultBlitSessionPool[old];
        if (rbsv) [_resultBlitSessionPool removeObjectForKey:old];
    }
    [_poolDictLock unlock];

    if (osv) {
        VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[osv pointerValue];
        if (s && invalidateSession) invalidateSession(s);
    }
    if (tsv) {
        VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[tsv pointerValue];
        if (s && invalidateSession) invalidateSession(s);
    }
    if (stv) {
        CVPixelBufferRef b = (CVPixelBufferRef)[stv pointerValue];
        if (b) CVPixelBufferRelease(b);
    }
    if (poolObj) {
        CVPixelBufferPoolRelease((__bridge CVPixelBufferPoolRef)poolObj);
    }

    if ([old hasPrefix:@"g:"]) {
        NSLock *gLock = _groupGlobalLock;
        if (gLock) [gLock lock];
        NSValue *gsv = nil, *gssv = nil;
        [_poolDictLock lock];
        gsv = _groupStagingPool[old];
        if (gsv) [_groupStagingPool removeObjectForKey:old];
        gssv = _groupSessionPool[old];
        if (gssv) [_groupSessionPool removeObjectForKey:old];
        [_groupTokenPool removeObjectForKey:old];
        [_groupSizePool removeObjectForKey:old];
        [_poolDictLock unlock];
        if (gsv) {
            CVPixelBufferRef b = (CVPixelBufferRef)[gsv pointerValue];
            if (b) CVPixelBufferRelease(b);
        }
        if (gssv) {
            VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[gssv pointerValue];
            if (s && invalidateSession) invalidateSession(s);
        }
        if (gLock) [gLock unlock];
    } else {
        if (rcv) {
            CVPixelBufferRef b = (CVPixelBufferRef)[rcv pointerValue];
            if (b) CVPixelBufferRelease(b);
        }
        if (rbsv) {
            VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[rbsv pointerValue];
            if (s && invalidateSession) invalidateSession(s);
        }
    }

    [_oneStepKeyLockPool removeObjectForKey:old];
    [_twoStepKeyLockPool removeObjectForKey:old];

    if (tlock) [tlock unlock];
    if (olock) [olock unlock];
}

- (void)touchStreamKeyLRU:(NSString *)key {
    if (!key) return;
    @synchronized(self) {
        NSUInteger idx = [_streamKeyOrder indexOfObject:key];
        if (idx != NSNotFound) [_streamKeyOrder removeObjectAtIndex:idx];
        [_streamKeyOrder addObject:key];

        while (_streamKeyOrder.count > kVcamMaxStreamKeys) {
            NSString *old = _streamKeyOrder.firstObject;
            [_streamKeyOrder removeObjectAtIndex:0];
            if (!old) break;
            [self evictStreamKeyResourcesLocked:old];
        }
    }
}

#pragma mark - 空闲释放

- (void)releaseIdleMemory {
    @synchronized(self) {
        while (_streamKeyOrder.count > 0) {
            NSString *old = _streamKeyOrder.firstObject;
            [_streamKeyOrder removeObjectAtIndex:0];
            if (!old) break;
            [self evictStreamKeyResourcesLocked:old];
        }
    }
}

- (void)releaseHeavyBuffersForIdle {
    @synchronized(self) {
        if (_adaptiveRotateCache) {
            CVPixelBufferRelease(_adaptiveRotateCache);
            _adaptiveRotateCache = NULL;
        }
        for (int i = 0; i < 3; i++) {
            CVPixelBufferRef b = [self prerenderRotateBufferAtSlot:i];
            if (b) { CVPixelBufferRelease(b); [self setPrerenderRotateBuffer:NULL atSlot:i]; }
        }
        for (int i = 0; i < 3; i++) {
            CVPixelBufferRef b = [self userCanvasAtSlot:i];
            if (b) { CVPixelBufferRelease(b); [self setUserCanvas:NULL atSlot:i]; }
        }
        if (_userShrinkBuffer) { CVPixelBufferRelease(_userShrinkBuffer); _userShrinkBuffer = NULL; }
        if (_userPieceBuffer) { CVPixelBufferRelease(_userPieceBuffer); _userPieceBuffer = NULL; }
        for (id key in _bgraBufferPoolMap) {
            CVPixelBufferPoolRelease((__bridge CVPixelBufferPoolRef)_bgraBufferPoolMap[key]);
        }
        [_bgraBufferPoolMap removeAllObjects];
    }
    [_laneLockPrivate lock];
    for (int i = 0; i < kVcamLaneStagingMax; i++) {
        if (gVcamLaneStaging[i].staging) {
            CVPixelBufferRelease(gVcamLaneStaging[i].staging);
            gVcamLaneStaging[i].staging = NULL;
            gVcamLaneStaging[i].w = gVcamLaneStaging[i].h = 0;
            gVcamLaneStaging[i].token = 0;
        }
    }
    for (int i = 0; i < kVcamCropStagingMax; i++) {
        if (gVcamCropStaging[i].staging) {
            CVPixelBufferRelease(gVcamCropStaging[i].staging);
            gVcamCropStaging[i].staging = NULL;
        }
    }
    for (int i = 0; i < kVcamYuvStagingMax; i++) {
        if (gVcamYuvStaging[i].staging) {
            CVPixelBufferRelease(gVcamYuvStaging[i].staging);
            gVcamYuvStaging[i].staging = NULL;
        }
    }
    [_laneLockPrivate unlock];
}

#pragma mark - 统计

- (NSUInteger)activeStreamKeyCount {
    @synchronized(self) {
        return _streamKeyOrder.count;
    }
}

- (NSString *)takeStreamStats {
    [_statsLock lock];
    NSString *out = @"";
    NSMutableArray *parts = [NSMutableArray array];
    for (int i = 0; i < kVcamStatSlots; i++) {
        VCamStatSlot *s = &gVcamStatSlots[i];
        if (s->fmt == 0 || s->renders == 0) continue;
        uint64_t mb = (s->pixels * 4ull) >> 20;
        double s1Avg = s->s1Cnt > 0 ? (s->s1TotalMs / s->s1Cnt) : -1.0;
        double s2Avg = s->s2Cnt > 0 ? (s->s2TotalMs / s->s2Cnt) : -1.0;
        [parts addObject:[NSString stringWithFormat:@"%ux%u_%u:%llu/%lluMB(%.1f,%.1fms)",
                          s->w, s->h, s->fmt, s->renders, mb, s1Avg, s2Avg]];
    }
    if (parts.count > 0) out = [parts componentsJoinedByString:@" "];
    memset(gVcamStatSlots, 0, sizeof(gVcamStatSlots));
    [_statsLock unlock];
    return out;
}

- (void)noteStreamRenderFmt:(uint32_t)fmt w:(uint32_t)w h:(uint32_t)h pixels:(uint64_t)px {
    [_statsLock lock];
    for (int i = 0; i < kVcamStatSlots; i++) {
        VCamStatSlot *s = &gVcamStatSlots[i];
        if (s->fmt == fmt && s->w == w && s->h == h) {
            s->renders++; s->pixels += px;
            break;
        }
        if (s->fmt == 0 && s->renders == 0) {
            s->fmt = fmt; s->w = w; s->h = h;
            s->renders = 1; s->pixels = px;
            break;
        }
    }
    [_statsLock unlock];
}

- (void)noteStageTimingFmt:(uint32_t)fmt w:(uint32_t)w h:(uint32_t)h stage:(int)stage ms:(double)ms {
    [_statsLock lock];
    for (int i = 0; i < kVcamStatSlots; i++) {
        VCamStatSlot *s = &gVcamStatSlots[i];
        if (s->fmt == fmt && s->w == w && s->h == h) {
            if (stage == 1) { s->s1TotalMs += ms; s->s1Cnt++; }
            else            { s->s2TotalMs += ms; s->s2Cnt++; }
            break;
        }
    }
    [_statsLock unlock];
}

@end
