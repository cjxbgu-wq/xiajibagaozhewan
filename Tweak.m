//
//  Tweak.m
//  Hook 入口（进程分派 + 3 个相机 Hook 安装）
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <signal.h>
#import <execinfo.h>
#import <fcntl.h>
#import <unistd.h>
#import <time.h>
#import <string.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

#import "VCamCore.h"
#import "VCamFloatingBall.h"
#import "VCamNotify.h"

// 补丁初始化（VCamHidePatch.m / VCamActionPatch.m 定义）
extern void vchp_init(void);
extern void vcap_init(void);

// MSHookMessageEx 自包含（不依赖 Substrate）
static void MSHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *origPtr) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        if (origPtr) *origPtr = NULL;
        return;
    }
    if (origPtr) *origPtr = method_getImplementation(method);
    method_setImplementation(method, newImp);
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

extern BOOL vcam_log_budget_take(void);

static volatile int32_t vcamTweakLogCount = 0;
static void vcam_tweak_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    if (!vcam_log_budget_take()) return;
    int32_t n = __sync_add_and_fetch(&vcamTweakLogCount, 1);
    if (n > 2000) return;
    @try {
        NSString *logPath = @"/tmp/vcam_tweak_log.txt";
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

#pragma mark - Hook 函数原始指针

static void (*orig_BWNodeOutput_emitSampleBuffer)(id self, SEL _cmd, CMSampleBufferRef sampleBuffer);
static void (*orig_BWStillImageScalerNode_renderSampleBuffer)(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input);
static void (*orig_BWPhotoEncoderNode_renderSampleBuffer)(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input);

#pragma mark - Hook 1: BWNodeOutput emitSampleBuffer:

static void hook_BWNodeOutput_emitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer) {
    static int vcamEmitCount = 0;
    vcamEmitCount++;
    if (vcamEmitCount % 1800 == 1) {
        CVPixelBufferRef pb = sampleBuffer ? CMSampleBufferGetImageBuffer(sampleBuffer) : NULL;
        OSType fmt = pb ? CVPixelBufferGetPixelFormatType(pb) : 0;
        vcam_tweak_log([NSString stringWithFormat:@"[vcam] emit#%d fmt=0x%x cls=%@",
                        vcamEmitCount, (unsigned)fmt, NSStringFromClass([self class])]);
    }
    if (sampleBuffer) {
        @autoreleasepool {
            @try {
                SEL mediaTypeSel = sel_registerName("mediaType");
                if ([self respondsToSelector:mediaTypeSel]) {
                    uint32_t mt = ((uint32_t(*)(id, SEL))objc_msgSend)(self, mediaTypeSel);
                    if (mt != 'vide') {
                        if (orig_BWNodeOutput_emitSampleBuffer) {
                            orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
                        }
                        return;
                    }
                }
            } @catch (NSException *e) {}
            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (pixelBuffer) {
                @try {
                    [[VCamCore sharedInstance] renderReplacementToPixelBuffer:pixelBuffer
                                                                         pts:CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))];
                } @catch (NSException *e) {
                    vcam_tweak_log([NSString stringWithFormat:@"[vcam] emit hook exception: %@", e]);
                }
            }
        }
    }
    if (orig_BWNodeOutput_emitSampleBuffer) {
        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
    }
}

#pragma mark - Hook 2: BWStillImageScalerNode renderSampleBuffer:forInput:

static void hook_BWStillImageScalerNode_renderSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
    if (sampleBuffer) {
        @autoreleasepool {
            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (pixelBuffer) {
                @try {
                    [[VCamCore sharedInstance] renderReplacementToPixelBuffer:pixelBuffer
                                                                         pts:CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))];
                } @catch (NSException *e) {
                    vcam_tweak_log([NSString stringWithFormat:@"[vcam] Scaler hook exception: %@", e]);
                }
            }
        }
    }
    if (orig_BWStillImageScalerNode_renderSampleBuffer) {
        orig_BWStillImageScalerNode_renderSampleBuffer(self, _cmd, sampleBuffer, input);
    }
}

#pragma mark - Hook 3: BWPhotoEncoderNode renderSampleBuffer:forInput:

static void hook_BWPhotoEncoderNode_renderSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
    if (sampleBuffer) {
        @autoreleasepool {
            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (pixelBuffer) {
                @try {
                    [[VCamCore sharedInstance] renderReplacementToPixelBuffer:pixelBuffer
                                                                         pts:CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))];
                } @catch (NSException *e) {
                    vcam_tweak_log([NSString stringWithFormat:@"[vcam] PhotoEncoder hook exception: %@", e]);
                }
            }
        }
    }
    if (orig_BWPhotoEncoderNode_renderSampleBuffer) {
        orig_BWPhotoEncoderNode_renderSampleBuffer(self, _cmd, sampleBuffer, input);
    }
}

#pragma mark - Hook 安装

static void installMediaserverdHooks(void) {
    Class bwNodeOutput = objc_getClass("BWNodeOutput");
    if (bwNodeOutput) {
        MSHookMessageEx(bwNodeOutput,
                        @selector(emitSampleBuffer:),
                        (IMP)hook_BWNodeOutput_emitSampleBuffer,
                        (IMP *)&orig_BWNodeOutput_emitSampleBuffer);
        vcam_tweak_log(@"[vcam] Hooked BWNodeOutput emitSampleBuffer:");
    } else {
        vcam_tweak_log(@"[vcam] BWNodeOutput class not found");
    }

    Class bwStillImageScaler = objc_getClass("BWStillImageScalerNode");
    if (bwStillImageScaler) {
        MSHookMessageEx(bwStillImageScaler,
                        @selector(renderSampleBuffer:forInput:),
                        (IMP)hook_BWStillImageScalerNode_renderSampleBuffer,
                        (IMP *)&orig_BWStillImageScalerNode_renderSampleBuffer);
        vcam_tweak_log(@"[vcam] Hooked BWStillImageScalerNode");
    } else {
        vcam_tweak_log(@"[vcam] BWStillImageScalerNode class not found");
    }

    Class bwPhotoEncoder = objc_getClass("BWPhotoEncoderNode");
    if (bwPhotoEncoder) {
        MSHookMessageEx(bwPhotoEncoder,
                        @selector(renderSampleBuffer:forInput:),
                        (IMP)hook_BWPhotoEncoderNode_renderSampleBuffer,
                        (IMP *)&orig_BWPhotoEncoderNode_renderSampleBuffer);
        vcam_tweak_log(@"[vcam] Hooked BWPhotoEncoderNode");
    } else {
        vcam_tweak_log(@"[vcam] BWPhotoEncoderNode class not found");
    }
}

#pragma mark - 进程初始化

static void initializeInMediaserverd(void) {
    vcam_tweak_log(@"[vcam] Initializing in mediaserverd...");
    [[VCamCore sharedInstance] initializeInMediaserverd];
    installMediaserverdHooks();
}

static void initializeInSpringBoard(void) {
    vcam_tweak_log(@"[vcam] Initializing in SpringBoard...");
    [[VCamCore sharedInstance] initializeInSpringBoard];
    [[VCamFloatingBall sharedInstance] showFloatingBall];
    vchp_init();
    vcap_init();
}

#pragma mark - SIGSEGV 崩溃捕获

static void vcam_crash_handler(int sig, siginfo_t *info, void *ucontext) {
    (void)ucontext;
    int fd = open("/tmp/vcam_crash.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        dprintf(fd, "[vcam] ===== SIG%d addr=%p ", sig, info ? info->si_addr : NULL);
        char ts[32] = {0};
        time_t now = time(NULL);
        struct tm tmv;
        localtime_r(&now, &tmv);
        strftime(ts, sizeof(ts), "%H:%M:%S", &tmv);
        dprintf(fd, "%s backtrace:\n", ts);
        void *frames[64];
        int n = backtrace(frames, 64);
        backtrace_symbols_fd(frames, n, fd);
        close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void vcam_install_crash_handler(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = vcam_crash_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
}

#pragma mark - 入口

static void vcamInit(void);

static BOOL vcam_loaded_via_other_path(void) {
    Dl_info info;
    if (!dladdr((void *)&vcamInit, &info) || !info.dli_fname) return NO;
    const char *selfPath = info.dli_fname;
    const char *selfBase = strrchr(selfPath, '/');
    selfBase = selfBase ? selfBase + 1 : selfPath;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        if (!p || strcmp(p, selfPath) == 0) continue;
        const char *base = strrchr(p, '/');
        base = base ? base + 1 : p;
        if (strcmp(base, selfBase) == 0) return YES;
    }
    return NO;
}

static void vcam_load_beacon(NSString *processName) {
    NSString *line = [NSString stringWithFormat:@"[%@] loaded in %@ (pid %d)\n",
                      [NSDate date], processName, getpid()];
    NSArray *paths = @[@"/var/mobile/Media/DCIM/vcam_load.txt",
                       @"/tmp/vcam_load.txt",
                       @"/private/tmp/vcam_load.txt",
                       @"/var/tmp/vcam_load.txt"];
    for (NSString *p in paths) {
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (!fh) {
                [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            } else {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        } @catch (NSException *e) {}
    }
}

__attribute__((constructor))
static void vcamInit(void) {
    @autoreleasepool {
        if (vcam_loaded_via_other_path()) return;
        NSString *processName = [[NSProcessInfo processInfo] processName];
        BOOL isMd = [processName isEqualToString:@"mediaserverd"];
        BOOL isSB = [processName isEqualToString:@"SpringBoard"];
        BOOL isLskdd = [processName isEqualToString:@"lskdd"];

        if (isMd) {
            vcam_load_beacon(processName);
            vcam_install_crash_handler();
            initializeInMediaserverd();
        } else if (isSB) {
            vcam_load_beacon(processName);
            initializeInSpringBoard();
        } else if (isLskdd) {
            [[VCamCore sharedInstance] initializeInMediaserverd];
        }
    }
}

__attribute__((destructor))
static void vcamDeinit(void) {
    [[VCamCore sharedInstance] stopStatePolling];
}
