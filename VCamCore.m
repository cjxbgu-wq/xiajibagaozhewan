//
//  VCamCore.m
//  核心渲染逻辑（视频替换 + 预渲染 + plist 轮询 + CPU 闭环）
//
//  2026-09-15 换视频残留修复: path 变化时先清 live + fallback 缓存
//

#import "VCamCore.h"
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <mach/mach.h>
#include <dlfcn.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach-o/loader.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>
#import "VCamTextSig.h"

BOOL vcam_log_budget_take(void);

extern void vcamLaneResetAllMemos(void);

// ============================================================
//  CPU 采样
// ============================================================
static NSString *vcam_process_cpu_seconds(void) {
    thread_array_t threads;
    mach_msg_type_number_t tcount = 0;
    double total = 0;
    if (task_threads(mach_task_self(), &threads, &tcount) == KERN_SUCCESS) {
        for (mach_msg_type_number_t i = 0; i < tcount; i++) {
            thread_basic_info_data_t bi;
            mach_msg_type_number_t bc = THREAD_BASIC_INFO_COUNT;
            if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &bc) == KERN_SUCCESS) {
                total += bi.user_time.seconds + bi.user_time.microseconds / 1e6;
                total += bi.system_time.seconds + bi.system_time.microseconds / 1e6;
            }
            mach_port_deallocate(mach_task_self(), threads[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threads, tcount * sizeof(thread_t));
    }
    return [NSString stringWithFormat:@"%.1f", total];
}

static void vcam_telemetry_sample(uint64_t renderedFrames, NSString *streamStats) {
    (void)renderedFrames;
    (void)streamStats;

    static CFAbsoluteTime lastTel = 0;
    static double lastCpu = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastTel > 0 && (now - lastTel) < 30.0) return;

    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
    uint64_t footprint = 0;
    uint64_t resident = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &vmCount) == KERN_SUCCESS) {
        footprint = vmInfo.phys_footprint;
        resident = vmInfo.resident_size;
    }
    (void)footprint;
    (void)resident;

    double cpuSec = [vcam_process_cpu_seconds() doubleValue];
    double cpuPct = (lastTel > 0 && now > lastTel) ? ((cpuSec - lastCpu) / (now - lastTel) * 100.0) : 0;
    (void)cpuPct;
    lastTel = now;
    lastCpu = cpuSec;
}

// ============================================================
//  日志
// ============================================================
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

BOOL vcam_log_budget_take(void) {
    static NSLock *lk = nil;
    static double tokens = 24.0;
    static double lastRefill = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lk = [[NSLock alloc] init];
        lastRefill = CFAbsoluteTimeGetCurrent();
    });
    [lk lock];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastRefill < now) {
        double refilled = tokens + (now - lastRefill) * 3.0;
        tokens = refilled > 24.0 ? 24.0 : refilled;
        lastRefill = now;
    }
    BOOL ok = NO;
    if (tokens >= 1.0) { tokens -= 1.0; ok = YES; }
    [lk unlock];
    return ok;
}

static void vcam_core_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    if (!vcam_log_budget_take()) return;
    @try {
        NSString *logPath = @"/tmp/vcam_core_log.txt";
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
//  自身 IMP 范围自检
// ============================================================
static BOOL vcamSelfIntegrityOK(void) {
    static uintptr_t textStart = 0, textEnd = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Dl_info info;
        if (dladdr((void *)&vcamSelfIntegrityOK, &info) == 0 || !info.dli_fbase) return;
        struct mach_header_64 *hdr = (struct mach_header_64 *)info.dli_fbase;
        if (hdr->magic != MH_MAGIC_64) return;
        uint8_t *p = (uint8_t *)hdr + sizeof(struct mach_header_64);
        for (uint32_t c = 0; c < hdr->ncmds; c++) {
            struct load_command *lc = (struct load_command *)p;
            if (lc->cmd == LC_SEGMENT_64) {
                struct segment_command_64 *seg = (struct segment_command_64 *)p;
                if (strncmp(seg->segname, "__TEXT", 6) == 0) {
                    textStart = (uintptr_t)info.dli_fbase;
                    textEnd = textStart + (uintptr_t)seg->vmsize;
                    break;
                }
            }
            p += lc->cmdsize;
        }
    });
    if (textStart == 0 || textEnd == 0) return NO;

    uintptr_t vaMask = 1;
    while (vaMask <= textEnd) vaMask <<= 1;
    vaMask -= 1;

    Class clsA = [VCamCore class];
    SEL selsA[3] = {
        @selector(setEnabled:),
        @selector(renderReplacementToPixelBuffer:pts:),
        @selector(hasReplacementFrame),
    };
    Class clsB = object_getClass([VCamNotify class]);
    SEL selsB[2] = {
        @selector(vcamLicenseValid),
        @selector(vcamCrossDeviceCodeOK),
    };
    BOOL res = YES;
    for (int i = 0; i < 3; i++) {
        IMP imp = class_getMethodImplementation(clsA, selsA[i]);
        uintptr_t a = ((uintptr_t)imp) & vaMask;
        if (a < textStart || a >= textEnd) res = NO;
    }
    for (int i = 0; i < 2; i++) {
        IMP imp = class_getMethodImplementation(clsB, selsB[i]);
        uintptr_t a = ((uintptr_t)imp) & vaMask;
        if (a < textStart || a >= textEnd) res = NO;
    }
    return res;
}

// ============================================================
//  延迟注入检测
// ============================================================
static BOOL vcamNoLateHookLibs(void) {
    static NSArray<NSString *> *snapshot = nil;
    static double lastScan = 0;
    static BOOL lastRes = YES;
    double now = CFAbsoluteTimeGetCurrent();
    if (snapshot && now - lastScan < 30.0) return lastRes;
    lastScan = now;

    uint32_t n = _dyld_image_count();
    if (!snapshot) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
        for (uint32_t i = 0; i < n; i++) {
            const char *nm = _dyld_get_image_name(i);
            if (nm) [a addObject:[NSString stringWithUTF8String:nm]];
        }
        snapshot = [a copy];
        return YES;
    }
    static NSArray<NSString *> *kw = nil;
    if (!kw) kw = @[@"frida", @"substrate", @"substitute", @"libhooker",
                    @"ellekit", @"elup", @"psunday", @"cynject", @"dobby"];
    BOOL res = YES;
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        NSString *s = [NSString stringWithUTF8String:nm];
        if ([snapshot containsObject:s]) continue;
        NSString *low = [s lowercaseString];
        for (NSString *k in kw) {
            if ([low containsString:k]) { res = NO; break; }
        }
    }
    lastRes = res;
    return res;
}

// ============================================================
//  类扩展
// ============================================================
@interface VCamCore ()
@property (nonatomic, strong) dispatch_source_t pollingTimer;
@property (nonatomic, assign) BOOL pollingActive;
@property (nonatomic, assign) BOOL lastEnabledState;

@property (nonatomic, assign) BOOL licGate;
@property (nonatomic, assign) BOOL licMark;

@property (nonatomic, assign) CVPixelBufferRef cachedProcessedFrame;
@property (nonatomic, assign) uint64_t lastProcessedFrameCount;
@property (nonatomic, assign) size_t lastProcessedWidth;
@property (nonatomic, assign) size_t lastProcessedHeight;
@property (nonatomic, assign) OSType lastProcessedFormat;
@property (nonatomic, assign) BOOL prerenderActive;

@property (nonatomic, strong) NSLock *renderLock;

@property (nonatomic, assign) CVPixelBufferRef fallbackFrame;
@property (nonatomic, assign) size_t fallbackWidth;
@property (nonatomic, assign) size_t fallbackHeight;

@property (nonatomic, assign) CVPixelBufferRef dedupLastBuffer;
@property (nonatomic, assign) CFAbsoluteTime dedupLastTime;
@property (nonatomic, assign) double dedupLastPts;
@property (nonatomic, assign) double lastAdvancePts;

@property (nonatomic, assign) BOOL isMediaserverdProcess;
@property (nonatomic, assign) uint64_t liveFrameGen;
@property (nonatomic, assign) uint64_t lastPrerenderSrcGen;
@property (nonatomic, assign) int lastPrerenderRot;
@property (nonatomic, assign) BOOL lastPrerenderMirror;
@property (nonatomic, assign) double lastPrerenderPanX;
@property (nonatomic, assign) double lastPrerenderPanY;
@property (nonatomic, assign) double lastPrerenderZoom;

@property (nonatomic, assign) CFAbsoluteTime lastRenderActivity;
@property (nonatomic, assign) BOOL pipelineIdle;
@property (nonatomic, assign) BOOL idleUnloaded;
@property (nonatomic, copy) NSString *idleResumePath;
@property (nonatomic, assign) CFAbsoluteTime lastIdleResumeTime;
@property (nonatomic, assign) BOOL lowPowerDecode;
@property (nonatomic, assign) CFAbsoluteTime camSessionStart;

@property (nonatomic, assign) CVPixelBufferRef syncDisplayFrame;
@property (nonatomic, assign) uint64_t syncDisplayGen;
@property (nonatomic, assign) CFAbsoluteTime lastGenAdvanceTime;

- (BOOL)writeFrame:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst token:(uint64_t)token;
@end

static CFAbsoluteTime gVcamProcInitTime = 0;

@implementation VCamCore

+ (instancetype)sharedInstance {
    static VCamCore *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamCore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _prerenderQueue = dispatch_queue_create("com.vcam.processing", DISPATCH_QUEUE_SERIAL);
        _processingQueue = dispatch_queue_create("com.vcam.processing.bg", DISPATCH_QUEUE_SERIAL);
        _processLock = [[NSLock alloc] init];
        _renderLock = [[NSLock alloc] init];
        _isPixelBufferMode = YES;
        _preprocessEnabled = YES;
        _enabled = NO;
        _targetSizeKnown = NO;
        _targetWidth = 0;
        _targetHeight = 0;
        _targetFormat = 0;
        _liveBGRAPixelBuffer = NULL;
        _liveYUVPixelBuffer = NULL;
        _lastRenderedWidth = 0;
        _lastRenderedHeight = 0;
        _frameCount = 0;
        _pollingActive = NO;
        _lastEnabledState = NO;
        _cachedProcessedFrame = NULL;
        _lastProcessedFrameCount = 0;
        _lastProcessedWidth = 0;
        _lastProcessedHeight = 0;
        _lastProcessedFormat = 0;
        _prerenderActive = NO;

        if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
            _gpuProcessor = nil;
            _videoPlayer = nil;
            _frameQueue = nil;
        } else {
            _gpuProcessor = [[GPUImageProcessor alloc] init];
            _videoPlayer = [[LocalVideoPlayer alloc] initWithCapacity:10];
            _videoPlayer.gpuProcessor = _gpuProcessor;
            _frameQueue = _videoPlayer.frameQueue;
        }

        @try {
            _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        } @catch (NSException *e) {
            _ciContext = nil;
        }

        if (gVcamProcInitTime == 0) gVcamProcInitTime = CFAbsoluteTimeGetCurrent();
    }
    return self;
}

- (void)dealloc {
    [self stopStatePolling];
    [self clearReplacementFrame];
}

#pragma mark - 初始化

- (void)initializeInMediaserverd {
    _isMediaserverdProcess = [[[NSProcessInfo processInfo] processName] isEqualToString:@"mediaserverd"];
    [self startStatePolling];
}

- (void)initializeInSpringBoard {
    [self startStatePolling];
}

#pragma mark - 核心方法

- (void)renderReplacementToPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    [self renderReplacementToPixelBuffer:pixelBuffer pts:0];
}

- (void)renderReplacementToPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(double)pts {
    if (!pixelBuffer || !_enabled) return;
    if (!_licGate || !_licMark) return;

    // 同帧去重 v2
    {
        static NSLock *dedupLock;
        static dispatch_once_t onceTok;
        dispatch_once(&onceTok, ^{ dedupLock = [[NSLock alloc] init]; });
        [dedupLock lock];
        CFAbsoluteTime nowDedup = CFAbsoluteTimeGetCurrent();
        BOOL samePtr = (self->_dedupLastBuffer == pixelBuffer);
        BOOL dup = samePtr && ((pts > 0 && self->_dedupLastPts == pts) ||
                               (nowDedup - self->_dedupLastTime < 0.005));
        if (pts > 0) self->_dedupLastPts = pts;
        self->_dedupLastBuffer = pixelBuffer;
        self->_dedupLastTime = nowDedup;
        [dedupLock unlock];
        if (dup) return;
    }

    OSType origFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    size_t targetW = CVPixelBufferGetWidth(pixelBuffer);
    size_t targetH = CVPixelBufferGetHeight(pixelBuffer);

    // 心跳 + 空闲即时唤醒
    CFAbsoluteTime prevActivity = self->_lastRenderActivity;
    self->_lastRenderActivity = CFAbsoluteTimeGetCurrent();
    if (prevActivity == 0 || self->_lastRenderActivity - prevActivity > 2.0) {
        self->_camSessionStart = self->_lastRenderActivity;
    }
    if (self->_pipelineIdle) {
        self->_pipelineIdle = NO;
        [self->_videoPlayer startDecodingThread];
        self->_lastIdleResumeTime = CFAbsoluteTimeGetCurrent();
        if (self->_idleUnloaded) {
            self->_idleUnloaded = NO;
            NSString *resumePath = self->_idleResumePath;
            if (resumePath.length > 0) {
                VCamCore *core = self;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                    [core->_videoPlayer loadVideoAtPath:resumePath completion:nil];
                });
            }
        }
    }

    // 显示快照 + 帧代数
    [_processLock lock];
    {
        uint64_t liveGen = _liveFrameGen;
        CFAbsoluteTime nowQ = CFAbsoluteTimeGetCurrent();
        double vfps = MAX(_videoPlayer.effectiveFps, 1.0);
        BOOL boundary;
        if (pts > 0) {
            boundary = (pts != self->_lastAdvancePts);
        } else {
            boundary = (nowQ - self->_lastGenAdvanceTime) >= (1.0 / vfps);
        }
        if (_liveYUVPixelBuffer &&
            (liveGen != self->_syncDisplayGen) && (liveGen < self->_syncDisplayGen || boundary)) {
            if (self->_syncDisplayFrame) CVPixelBufferRelease(self->_syncDisplayFrame);
            self->_syncDisplayFrame = CVPixelBufferRetain(_liveYUVPixelBuffer);
            self->_syncDisplayGen = liveGen;
            self->_lastGenAdvanceTime = nowQ;
            self->_lastAdvancePts = pts;
        }
    }
    CVPixelBufferRef yuv = self->_syncDisplayFrame;
    if (yuv) CVPixelBufferRetain(yuv);
    uint64_t gen = self->_syncDisplayGen;
    [_processLock unlock];
    CVPixelBufferRef bgra = NULL;

    // CPU 闭环降载
    {
        static CFAbsoluteTime lastCpuCheck = 0;
        static CFAbsoluteTime lastCpuSample = 0;
        static double lastCpuSec = 0;
        static double emaPct = 0;
        static BOOL emaInit = NO;
        static BOOL lowPower = NO;
        static CFAbsoluteTime lastModeSwitch = 0;
        CFAbsoluteTime nowT = CFAbsoluteTimeGetCurrent();

        if (nowT - lastCpuCheck > 0.8) {
            double cpuSec = [vcam_process_cpu_seconds() doubleValue];
            double delta = cpuSec - lastCpuSec;

            if (lastCpuSec > 0 && lastCpuSample > 0 && nowT > lastCpuSample && delta >= 0) {
                double pct = delta / (nowT - lastCpuSample) * 100.0;
                if (pct < 400.0) {
                    emaPct = emaInit ? (emaPct * 0.5 + pct * 0.5) : pct;
                    emaInit = YES;
                }
                BOOL minHoldOk = (nowT - lastModeSwitch) > (lowPower ? 5.0 : 2.0);
                BOOL sessionExempt = (self->_camSessionStart > 0 &&
                                      (nowT - self->_camSessionStart) < 8.0);
                BOOL hardTrip = (emaPct > (sessionExempt ? 170.0 : 110.0));
                if (hardTrip && !lowPower) {
                    lowPower = YES;
                    lastModeSwitch = nowT;
                    vcam_core_log([NSString stringWithFormat:@"[vcam] CPU %.0f%% hardTrip, throttle ON", emaPct]);
                } else if (emaPct < 62.0 && lowPower && minHoldOk) {
                    lowPower = NO;
                    lastModeSwitch = nowT;
                    vcam_core_log([NSString stringWithFormat:@"[vcam] CPU %.0f%% <62%%, throttle OFF", emaPct]);
                }
            }
            lastCpuSample = nowT;
            if (delta >= 0 || lastCpuSec == 0) lastCpuSec = cpuSec;
            lastCpuCheck = nowT;
            self.lowPowerDecode = lowPower;
        }

        // 不可见流节流
        {
            uint64_t px = (uint64_t)targetW * targetH;
            double window = px > 10000000ull ? 1.0 : (lowPower ? 0.05 : 0.0);
            if (window > 0.0) {
                static NSMutableDictionary<NSString *, NSDictionary *> *freezeState = nil;
                if (!freezeState) freezeState = [NSMutableDictionary dictionary];
                NSString *fk = [NSString stringWithFormat:@"%zu_%zu_%u", targetW, targetH, (unsigned)origFormat];
                @synchronized(freezeState) {
                    NSDictionary *st = freezeState[fk];
                    CFAbsoluteTime lastFull = st ? [st[@"t"] doubleValue] : 0;
                    uint64_t lastTok = st ? [st[@"tok"] unsignedLongLongValue] : 0;
                    if (lastFull > 0 && (nowT - lastFull) < window && lastTok != 0) {
                        gen = lastTok;
                    } else {
                        freezeState[fk] = @{@"t": @(nowT), @"tok": @(gen)};
                    }
                }
            }
        }
    }

    static int vcamRenderCount = 0;
    vcamRenderCount++;
    (void)vcamRenderCount;

    [_renderLock lock];

    if (!yuv) {
        CVPixelBufferRef fb = _fallbackFrame;
        if (fb) CVPixelBufferRetain(fb);
        if (fb) {
            [_gpuProcessor transferPixelBuffer:fb toPixelBuffer:pixelBuffer];
            CVPixelBufferRelease(fb);
        }
        [_renderLock unlock];
        return;
    }

    CVPixelBufferRef base = yuv;
    CVPixelBufferRef src = [_gpuProcessor adaptiveRotateIfNeeded:base
                                                     targetWidth:targetW
                                                    targetHeight:targetH
                                                           token:gen];

    BOOL ok = [self writeFrame:src toPixelBuffer:pixelBuffer token:gen];
    if (!ok && base == yuv) {
        if (src) CVPixelBufferRelease(src);
        src = NULL;
        CVPixelBufferRef lazyBGRA = [_gpuProcessor convertFormat:yuv toFormat:kCVPixelFormatType_32BGRA];
        if (lazyBGRA) {
            src = [_gpuProcessor adaptiveRotateIfNeeded:lazyBGRA
                                            targetWidth:targetW
                                           targetHeight:targetH
                                                  token:0];
            CVPixelBufferRelease(lazyBGRA);
        }
        ok = [self writeFrame:src toPixelBuffer:pixelBuffer token:0];
    }
    if (ok) {
        _frameCount++;
        if (_fallbackFrame) CVPixelBufferRelease(_fallbackFrame);
        _fallbackFrame = src;
        CVPixelBufferRetain(_fallbackFrame);
        _fallbackWidth = targetW;
        _fallbackHeight = targetH;
        _dedupLastBuffer = pixelBuffer;
        _dedupLastTime = CFAbsoluteTimeGetCurrent();
    }

    if (src) CVPixelBufferRelease(src);
    if (yuv) CVPixelBufferRelease(yuv);
    [_renderLock unlock];
}

- (BOOL)hasReplacementFrame {
    if (!_enabled || !_licGate || !_licMark) return NO;
    CVPixelBufferRef frame = [_videoPlayer getCurrentFrame];
    return frame != NULL;
}

- (void)clearReplacementFrame {
    [self stopPrerenderThread];
    [_processLock lock];
    if (_syncDisplayFrame) {
        CVPixelBufferRelease(_syncDisplayFrame);
        _syncDisplayFrame = NULL;
    }
    _syncDisplayGen = 0;
    _lastGenAdvanceTime = 0;
    if (_liveBGRAPixelBuffer) {
        CVPixelBufferRelease(_liveBGRAPixelBuffer);
        _liveBGRAPixelBuffer = NULL;
    }
    if (_liveYUVPixelBuffer) {
        CVPixelBufferRelease(_liveYUVPixelBuffer);
        _liveYUVPixelBuffer = NULL;
    }
    if (_cachedProcessedFrame) {
        CVPixelBufferRelease(_cachedProcessedFrame);
        _cachedProcessedFrame = NULL;
    }
    _lastProcessedFrameCount = 0;
    _lastProcessedWidth = 0;
    _lastProcessedHeight = 0;
    _lastProcessedFormat = 0;
    _targetSizeKnown = NO;
    _targetWidth = 0;
    _targetHeight = 0;
    _targetFormat = 0;
    [_processLock unlock];
    [_renderLock lock];
    if (_fallbackFrame) {
        CVPixelBufferRelease(_fallbackFrame);
        _fallbackFrame = NULL;
    }
    _fallbackWidth = 0;
    _fallbackHeight = 0;
    _dedupLastBuffer = NULL;
    _dedupLastTime = 0;
    _dedupLastPts = 0;
    _lastAdvancePts = 0;
    [_renderLock unlock];
}

- (void)cacheLastRenderedFrame:(CVPixelBufferRef)buffer width:(size_t)width height:(size_t)height {
    if (!buffer) return;
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    [_processLock lock];
    if (format == kCVPixelFormatType_32BGRA) {
        if (_liveBGRAPixelBuffer) CVPixelBufferRelease(_liveBGRAPixelBuffer);
        _liveBGRAPixelBuffer = buffer;
        CVPixelBufferRetain(_liveBGRAPixelBuffer);
    } else {
        if (_liveYUVPixelBuffer) CVPixelBufferRelease(_liveYUVPixelBuffer);
        _liveYUVPixelBuffer = buffer;
        CVPixelBufferRetain(_liveYUVPixelBuffer);
    }
    _lastRenderedWidth = width;
    _lastRenderedHeight = height;
    [_processLock unlock];
}

- (BOOL)isPrivateFormat:(OSType)format {
    return !(format == kCVPixelFormatType_32BGRA || format == '420v' || format == '420f');
}

#pragma mark - 帧写入

- (BOOL)writeFrame:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst token:(uint64_t)token {
    if (!src || !dst) return NO;
    BOOL done = NO;
    @try {
        if ([_gpuProcessor transferPixelBuffer:src toPixelBuffer:dst token:token]) {
            done = YES;
        }
    } @catch (NSException *e) {}
    return done;
}

#pragma mark - 预渲染线程

- (void)startPrerenderThread {
    if (_prerenderActive) return;
    _prerenderActive = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(_prerenderQueue, ^{
        VCamCore *strongSelf = weakSelf;
        if (!strongSelf) return;

        CFAbsoluteTime nextTick = CFAbsoluteTimeGetCurrent();

        while (strongSelf.prerenderActive && strongSelf.enabled) {
            @autoreleasepool {
                if (strongSelf.pipelineIdle) {
                    [NSThread sleepForTimeInterval:0.1];
                    nextTick = CFAbsoluteTimeGetCurrent();
                    continue;
                }

                double fps = strongSelf.videoPlayer.effectiveFps;
                nextTick += 1.0 / fps;
                double wait = nextTick - CFAbsoluteTimeGetCurrent();
                if (wait > 0.0005) {
                    [NSThread sleepForTimeInterval:wait];
                } else {
                    nextTick = CFAbsoluteTimeGetCurrent();
                }

                CVPixelBufferRef frame = [strongSelf.videoPlayer.frameQueue dequeuePixelBuffer];
                if (!frame) {
                    CFAbsoluteTime waitStart = CFAbsoluteTimeGetCurrent();
                    double waitBudget = (1.0 / fps) / 3.0;
                    while (!frame && CFAbsoluteTimeGetCurrent() - waitStart < waitBudget) {
                        [NSThread sleepForTimeInterval:0.002];
                        frame = [strongSelf.videoPlayer.frameQueue dequeuePixelBuffer];
                    }
                }
                if (frame) {
                    while ([strongSelf.videoPlayer.frameQueue count] > 1) {
                        CVPixelBufferRef excess = [strongSelf.videoPlayer.frameQueue dequeuePixelBuffer];
                        if (excess) CVPixelBufferRelease(excess);
                    }
                }
                if (!frame) frame = [strongSelf.videoPlayer copyCurrentFrame];
                if (!frame) continue;

                strongSelf.gpuProcessor.sourceRotation = strongSelf.videoPlayer.preferredRotation;
                int curRot = (strongSelf.gpuProcessor.sourceRotation + strongSelf.gpuProcessor.rotationAngle) % 360;
                BOOL curMirror = strongSelf.gpuProcessor.mirrored;
                double curPanX = strongSelf.gpuProcessor.userPanX;
                double curPanY = strongSelf.gpuProcessor.userPanY;
                double curZoom = strongSelf.gpuProcessor.userZoom;
                uint64_t curCount = strongSelf.videoPlayer.frameCount;
                if (curCount == strongSelf->_lastPrerenderSrcGen &&
                    curRot == strongSelf->_lastPrerenderRot &&
                    curMirror == strongSelf->_lastPrerenderMirror &&
                    curPanX == strongSelf->_lastPrerenderPanX &&
                    curPanY == strongSelf->_lastPrerenderPanY &&
                    curZoom == strongSelf->_lastPrerenderZoom) {
                    CVPixelBufferRelease(frame);
                    continue;
                }
                strongSelf->_lastPrerenderSrcGen = curCount;
                strongSelf->_lastPrerenderRot = curRot;
                strongSelf->_lastPrerenderMirror = curMirror;
                strongSelf->_lastPrerenderPanX = curPanX;
                strongSelf->_lastPrerenderPanY = curPanY;
                strongSelf->_lastPrerenderZoom = curZoom;

                CVPixelBufferRef rotated = [strongSelf.gpuProcessor rotateAndMirrorIfNeeded:frame];
                CVPixelBufferRelease(frame);
                if (!rotated) continue;

                CVPixelBufferRef baked = [strongSelf.gpuProcessor bakeUserTransformIntoCanvas:rotated];
                CVPixelBufferRelease(rotated);
                if (!baked) continue;

                [strongSelf.processLock lock];
                if (strongSelf->_liveYUVPixelBuffer) {
                    CVPixelBufferRelease(strongSelf->_liveYUVPixelBuffer);
                }
                strongSelf->_liveYUVPixelBuffer = baked;
                strongSelf->_liveFrameGen++;
                [strongSelf.processLock unlock];
            }
        }
    });
}

- (void)stopPrerenderThread {
    _prerenderActive = NO;
}

#pragma mark - 状态控制

- (void)setEnabled:(BOOL)enabled {
    if (!_isMediaserverdProcess) {
        _enabled = enabled;
        return;
    }

    [_processLock lock];
    if (_enabled == enabled) {
        [_processLock unlock];
        return;
    }
    [_processLock unlock];

    if (enabled) {
        NSString *path = [VCamNotify activePlaybackPath];
        if (!path || path.length == 0) {
            path = @"/var/mobile/Media/DCIM/vcam.mp4";
        }

        __weak typeof(self) weakSelf = self;
        dispatch_async(_processingQueue, ^{
            VCamCore *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf->_videoPlayer loadVideoAtPath:path completion:^(BOOL success, NSError *error) {
                if (success) {
                    [[VCamNotify sharedInstance] postNotification:VCamNotifyLiveChanged];
                }
            }];
            [strongSelf->_videoPlayer startWatchingFile:path];
        });

        [_processLock lock];
        _enabled = YES;
        [_processLock unlock];

        _pipelineIdle = NO;
        _lastRenderActivity = CFAbsoluteTimeGetCurrent();
        [self startPrerenderThread];
    } else {
        [self stopPrerenderThread];
        [_videoPlayer stopDecodingThread];
        [_videoPlayer stopWatchingFile];
        [_processLock lock];
        _enabled = NO;
        [_processLock unlock];
        _pipelineIdle = NO;
        [[VCamNotify sharedInstance] postNotification:VCamNotifyLiveChanged];
    }
}

#pragma mark - plist 轮询

- (void)startStatePolling {
    if (_pollingActive) return;
    _pollingActive = YES;

    __weak typeof(self) weakSelf = self;
    [[VCamNotify sharedInstance] startPollingWithInterval:0.15 callback:^(BOOL enabled) {
        VCamCore *strongSelf = weakSelf;
        if (!strongSelf) return;

        strongSelf->_licGate = [VCamNotify vcamLicenseValid];
        strongSelf->_licMark = vcamNoLateHookLibs() && [VCamNotify vcamCrossDeviceCodeOK]
            && vcamSelfIntegrityOK();

        BOOL effEnabled = enabled && strongSelf->_licGate && strongSelf->_licMark;
        if (effEnabled != strongSelf.lastEnabledState) {
            strongSelf.lastEnabledState = effEnabled;
            [strongSelf setEnabled:effEnabled];
        }

        if (strongSelf.isMediaserverdProcess && strongSelf.enabled && !strongSelf.pipelineIdle &&
            strongSelf->_lastRenderActivity > 0 &&
            (CFAbsoluteTimeGetCurrent() - strongSelf->_lastRenderActivity) > 2.0 &&
            (CFAbsoluteTimeGetCurrent() - strongSelf->_lastIdleResumeTime) > 5.0) {
            strongSelf->_pipelineIdle = YES;
            [strongSelf->_videoPlayer stopDecodingThread];
        }

        if (strongSelf.isMediaserverdProcess && strongSelf.enabled && strongSelf.pipelineIdle &&
            strongSelf->_lastRenderActivity > 0 &&
            (CFAbsoluteTimeGetCurrent() - strongSelf->_lastRenderActivity) > 60.0) {
            static CFAbsoluteTime lastIdleRelease = 0;
            CFAbsoluteTime nowIdle = CFAbsoluteTimeGetCurrent();
            if (nowIdle - lastIdleRelease > 30.0) {
                lastIdleRelease = nowIdle;
                if (!strongSelf->_idleUnloaded) {
                    strongSelf->_idleUnloaded = YES;
                    strongSelf->_idleResumePath = [strongSelf->_videoPlayer currentVideoPath];
                    [strongSelf->_videoPlayer unloadForIdle];
                    [strongSelf->_gpuProcessor releaseHeavyBuffersForIdle];
                    [strongSelf->_gpuProcessor releaseIdleMemory];
                    [strongSelf->_processLock lock];
                    if (strongSelf->_liveYUVPixelBuffer) {
                        CVPixelBufferRelease(strongSelf->_liveYUVPixelBuffer);
                        strongSelf->_liveYUVPixelBuffer = NULL;
                    }
                    [strongSelf->_processLock unlock];
                } else {
                    [strongSelf->_gpuProcessor releaseIdleMemory];
                }
            }
        }

        if (strongSelf.isMediaserverdProcess) {
            static CFAbsoluteTime lastStatsTake = 0;
            CFAbsoluteTime nowStats = CFAbsoluteTimeGetCurrent();
            if (nowStats - lastStatsTake >= 30.0) {
                lastStatsTake = nowStats;
                vcam_telemetry_sample(strongSelf->_frameCount,
                                      [strongSelf->_gpuProcessor takeStreamStats]);
            }
        }

        NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{};

        static NSInteger lastSyncedRotation = -1;
        static BOOL lastSyncedMirrored = NO;
        NSInteger plistRotation = [pl[@"manualRotation"] integerValue];
        BOOL plistMirrored = [pl[@"mirrored"] boolValue];
        if (plistRotation != lastSyncedRotation) {
            strongSelf.gpuProcessor.rotationAngle = (int)(plistRotation % 360);
            lastSyncedRotation = plistRotation;
        }
        if (plistMirrored != lastSyncedMirrored) {
            strongSelf.gpuProcessor.mirrored = plistMirrored;
            lastSyncedMirrored = plistMirrored;
        }

        static double lastSyncedPanX = 0.0;
        static double lastSyncedPanY = 0.0;
        static double lastSyncedZoom = -1.0;
        double plistPanX = [pl[@"userPanX"] doubleValue];
        double plistPanY = [pl[@"userPanY"] doubleValue];
        double plistZoom = [pl[@"userZoom"] doubleValue];
        if (plistZoom <= 0.0) plistZoom = 1.0;
        double panSgn = [pl[@"frontPanFix"] boolValue] ? -1.0 : 1.0;
        double applyPanX = plistPanX * panSgn;
        double applyPanY = plistPanY * panSgn;
        if (applyPanX != lastSyncedPanX || applyPanY != lastSyncedPanY || plistZoom != lastSyncedZoom) {
            strongSelf.gpuProcessor.userPanX = applyPanX;
            strongSelf.gpuProcessor.userPanY = applyPanY;
            strongSelf.gpuProcessor.userZoom = plistZoom;
            lastSyncedPanX = applyPanX;
            lastSyncedPanY = applyPanY;
            lastSyncedZoom = plistZoom;
        }

        // ============================================================
        // ★ 换视频检测 + 清缓存
        // ============================================================
        static NSString *lastSyncedPath = nil;
        static BOOL pathSyncInit = NO;
        NSString *activePath = pl[@"activePlaybackPath"];
        if (activePath.length > 0 && ![activePath isEqualToString:lastSyncedPath]) {
            if (pathSyncInit && strongSelf.enabled) {
                vcam_core_log([NSString stringWithFormat:
                    @"[vcam] activePlaybackPath changed: %@ -> %@, clearing buffers + reloading",
                    lastSyncedPath, activePath]);

                // ★ 清 live 帧缓存（_processLock 保护）
                [strongSelf->_processLock lock];
                if (strongSelf->_liveYUVPixelBuffer) {
                    CVPixelBufferRelease(strongSelf->_liveYUVPixelBuffer);
                    strongSelf->_liveYUVPixelBuffer = NULL;
                }
                if (strongSelf->_liveBGRAPixelBuffer) {
                    CVPixelBufferRelease(strongSelf->_liveBGRAPixelBuffer);
                    strongSelf->_liveBGRAPixelBuffer = NULL;
                }
                if (strongSelf->_syncDisplayFrame) {
                    CVPixelBufferRelease(strongSelf->_syncDisplayFrame);
                    strongSelf->_syncDisplayFrame = NULL;
                }
                strongSelf->_syncDisplayGen = 0;
                strongSelf->_lastGenAdvanceTime = 0;
                [strongSelf->_processLock unlock];

                // ★ 清 fallback 缓存（_renderLock 保护）
                [strongSelf->_renderLock lock];
                if (strongSelf->_fallbackFrame) {
                    CVPixelBufferRelease(strongSelf->_fallbackFrame);
                    strongSelf->_fallbackFrame = NULL;
                }
                strongSelf->_dedupLastBuffer = NULL;
                strongSelf->_dedupLastTime = 0;
                strongSelf->_dedupLastPts = 0;
                strongSelf->_lastAdvancePts = 0;
                [strongSelf->_renderLock unlock];

                // 重置旋转/镜像/pan/zoom
                strongSelf.gpuProcessor.rotationAngle = 0;
                strongSelf.gpuProcessor.mirrored = NO;
                strongSelf.gpuProcessor.userPanX = 0.0;
                strongSelf.gpuProcessor.userPanY = 0.0;
                strongSelf.gpuProcessor.userZoom = 1.0;
                [VCamNotify setPlistRotation:0];
                [VCamNotify setPlistMirrored:NO];
                [VCamNotify resetPlistTransform];
                lastSyncedRotation = 0;
                lastSyncedMirrored = NO;
                lastSyncedPanX = 0.0;
                lastSyncedPanY = 0.0;
                lastSyncedZoom = 1.0;
                vcamLaneResetAllMemos();

                __weak typeof(strongSelf) wSelf = strongSelf;
                dispatch_async(strongSelf.processingQueue, ^{
                    VCamCore *sSelf = wSelf;
                    if (!sSelf) return;
                    [sSelf.videoPlayer loadVideoAtPath:activePath completion:nil];
                    [sSelf.videoPlayer startWatchingFile:activePath];
                });
            }
            lastSyncedPath = [activePath copy];
            pathSyncInit = YES;
        }

        static BOOL lastSyncedPaused = NO;
        BOOL plistPaused = [pl[@"paused"] boolValue];
        if (plistPaused != lastSyncedPaused) {
            strongSelf.videoPlayer.paused = plistPaused;
            lastSyncedPaused = plistPaused;
        }

        static NSInteger lastRestartToken = -1;
        NSInteger restartToken = [pl[@"restartToken"] integerValue];
        if (restartToken != lastRestartToken) {
            if (lastRestartToken >= 0 && strongSelf.enabled && strongSelf.videoPlayer.currentVideoPath.length > 0) {
                [strongSelf.videoPlayer resetPlaybackPosition];
                NSString *replayPath = [[strongSelf.videoPlayer currentVideoPath] copy];
                __weak typeof(strongSelf) wSelf = strongSelf;
                dispatch_async(strongSelf.processingQueue, ^{
                    VCamCore *sSelf = wSelf;
                    if (!sSelf) return;
                    [sSelf.videoPlayer loadVideoAtPath:replayPath completion:nil];
                });
            }
            lastRestartToken = restartToken;
        }
    }];
}

- (void)stopStatePolling {
    [[VCamNotify sharedInstance] stopPolling];
    _pollingActive = NO;
}

@end
