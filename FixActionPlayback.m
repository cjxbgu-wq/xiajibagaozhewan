//
//  FixActionPlayback.m — 动作切片（抢占式三状态机 + 微秒精度）
//
//  【三状态机】
//   LOOP_FULL    全片循环 (默认)
//   PLAY_ACTION  单次播放动作段
//   FROZEN       冻结在动作段末帧
//
//  【抢占式】
//   点任意动作键 → 直接跳 PLAY_ACTION (无需先退出)
//   播完 → FROZEN
//   点"退出动作"按钮 → 回 LOOP_FULL
//   LOOP_FULL 下点"播" = 暂停/继续 (不进动作模式)
//
//  【微秒精度】
//   plist 存 int64_t 微秒 (action*StartUs / action*EndUs)
//   CMTimeMake(us, 1000000) → 精度 1μs
//   兼容旧秒键 (action*Start × 1000000)
//
//  【性能优化】
//   · seek 300ms 防抖 + 异步队列
//   · prefetch 5 帧 → 1 帧 (hook readNextFrame)
//   · poller 1.0s + mtime 缓存
//   · OVERRIDE 日志 30s 限流
//   · notify 事件驱动 (零延迟响应)
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>
#include <math.h>
#include <notify.h>

// ============================================================
//  Darwin 通知名（XOR 编码 "com.gouchun.action"）
// ============================================================
static const char *fxActionNotifyName(void) {
    static char buf[64] = {0};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const unsigned char enc[] = {
            'c' ^ 0x5E, 'o' ^ 0x5E, 'm' ^ 0x5E, '.' ^ 0x5E,
            'g' ^ 0x5E, 'o' ^ 0x5E, 'u' ^ 0x5E, 'c' ^ 0x5E,
            'h' ^ 0x5E, 'u' ^ 0x5E, 'n' ^ 0x5E, '.' ^ 0x5E,
            'a' ^ 0x5E, 'c' ^ 0x5E, 't' ^ 0x5E, 'i' ^ 0x5E,
            'o' ^ 0x5E, 'n' ^ 0x5E, 0
        };
        size_t n = 0;
        while (enc[n] && n < 63) { buf[n] = enc[n] ^ 0x5E; n++; }
        buf[n] = 0;
    });
    return buf;
}

static void fxPostActionNotify(void) {
    notify_post(fxActionNotifyName());
}

// ============================================================
//  日志
// ============================================================
static const char *fxPickLogPath(void) {
    static const char *cached = NULL;
    if (cached) return cached;
    static const char *cands[] = {
        "/var/mobile/Media/DCIM/vcam_md.txt",
        "/var/mobile/Media/vcam_md.txt",
        "/private/var/tmp/vcam_md.txt",
        "/tmp/vcam_md.txt",
        NULL
    };
    for (int i = 0; cands[i]; i++) {
        FILE *f = fopen(cands[i], "a");
        if (f) { fclose(f); cached = cands[i]; return cached; }
    }
    return NULL;
}

static void fxLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        struct tm tm;
        localtime_r(&ts.tv_sec, &tm);
        char tbuf[24];
        snprintf(tbuf, sizeof(tbuf), "%02d:%02d:%02d.%03ld",
                 tm.tm_hour, tm.tm_min, tm.tm_sec, ts.tv_nsec / 1000000);
        NSString *line = [NSString stringWithFormat:@"[%s][md] %@\n", tbuf, m];
        const char *p = fxPickLogPath();
        if (!p) return;
        FILE *f = fopen(p, "a");
        if (f) { fprintf(f, "%s", [line UTF8String]); fclose(f); }
    }
}

// ============================================================
//  XOR 解码 + 进程判定
// ============================================================
static NSString *fxXor(const unsigned char *e, int n) {
    volatile unsigned char k = 0x5A;
    char b[64];
    for (int i = 0; i < n; i++) b[i] = (char)(e[i] ^ k);
    b[n] = 0;
    return [NSString stringWithUTF8String:b];
}

static BOOL fxIsMd(void) {
    const char *n = getprogname(); if (!n) return NO;
    static const unsigned char e[] = {
        0x37,0x3F,0x3E,0x33,0x3B,0x29,0x3F,0x28,0x2C,0x3F,0x28,0x3E
    };
    volatile unsigned char k = 0x5A; char b[16];
    for (int i = 0; i < 12; i++) b[i] = (char)(e[i] ^ k);
    b[12] = 0;
    return strcmp(n, b) == 0;
}

static BOOL fxIsSb(void) {
    const char *n = getprogname(); if (!n) return NO;
    static const unsigned char e[] = {
        0x09,0x2A,0x28,0x33,0x34,0x3D,0x18,0x35,0x3B,0x28,0x3E
    };
    volatile unsigned char k = 0x5A; char b[16];
    for (int i = 0; i < 11; i++) b[i] = (char)(e[i] ^ k);
    b[11] = 0;
    return strcmp(n, b) == 0;
}

static NSString *fxPlist(void) {
    static NSString *s = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const unsigned char t[] = {0x2C,0x39,0x74,0x2A,0x36,0x33,0x29,0x2E};
        s = [@"/var/mobile/Media/DCIM/" stringByAppendingString:fxXor(t, 8)];
    });
    return s;
}

// ============================================================
//  状态机
// ============================================================
typedef enum {
    FX_STATE_LOOP_FULL = 0,
    FX_STATE_PLAY_ACTION,
    FX_STATE_FROZEN
} FxState;

static FxState   gState = FX_STATE_LOOP_FULL;
static int64_t   gStartUs = 0;
static int64_t   gEndUs   = 0;
static int       gCurAction = 0;

static int64_t   gLastTok = -1;
static int64_t   gLastRt  = 0;
static int       gLastAct = 0;
static NSString *gLastPath = nil;
static NSString *gVideoPath = nil;
static BOOL      gInitDone = NO;

// ============================================================
//  plist 键名
// ============================================================
static NSString *const kTok       = @"actionToken";
static NSString *const kAct       = @"actionActive";
static NSString *const kPausedStr = @"paused";

static NSString *const kBS_Us = @"actionBlinkStartUs";
static NSString *const kBE_Us = @"actionBlinkEndUs";
static NSString *const kMS_Us = @"actionMouthStartUs";
static NSString *const kME_Us = @"actionMouthEndUs";
static NSString *const kHS_Us = @"actionHeadStartUs";
static NSString *const kHE_Us = @"actionHeadEndUs";
static NSString *const kBS_Legacy = @"actionBlinkStart";
static NSString *const kBE_Legacy = @"actionBlinkEnd";
static NSString *const kMS_Legacy = @"actionMouthStart";
static NSString *const kME_Legacy = @"actionMouthEnd";
static NSString *const kHS_Legacy = @"actionHeadStart";
static NSString *const kHE_Legacy = @"actionHeadEnd";

static const int64_t kBlinkStartDefUs = 1000000LL;
static const int64_t kBlinkEndDefUs   = 2000000LL;
static const int64_t kMouthStartDefUs = 2500000LL;
static const int64_t kMouthEndDefUs   = 3500000LL;
static const int64_t kHeadStartDefUs  = 4000000LL;
static const int64_t kHeadEndDefUs    = 5500000LL;

static int64_t fxReadUsFromDict(NSDictionary *pl, NSString *usKey, NSString *legacyKey) {
    NSNumber *n = pl[usKey];
    if (n) return [n longLongValue];
    n = pl[legacyKey];
    if (n) {
        double sec = [n doubleValue];
        return (int64_t)llround(sec * 1000000.0);
    }
    return 0;
}

static NSString *fxNormPath(NSString *p) {
    if (!p) return nil;
    NSString *r = [p stringByResolvingSymlinksInPath];
    if ([r hasPrefix:@"/private/var"]) r = [r substringFromIndex:8];
    return r ?: p;
}

static NSString *kPathKey(void) {
    static NSString *s = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const unsigned char e[] = {
            0x3B,0x39,0x2E,0x33,0x2C,0x3F,0x0A,0x36,0x3B,0x23,
            0x38,0x3B,0x39,0x31,0x0A,0x3B,0x2E,0x32
        };
        s = fxXor(e, 18);
    });
    return s;
}

static NSString *kRtKey(void) {
    static NSString *s = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const unsigned char e[] = {
            0x28,0x3F,0x29,0x2E,0x3B,0x28,0x2E,0x0E,0x35,0x31,0x3F,0x34
        };
        s = fxXor(e, 12);
    });
    return s;
}

static BOOL fxIsOurReader(AVAssetReader *r) {
    if (gVideoPath.length == 0) return NO;
    @try {
        AVAsset *a = r.asset;
        if (![a isKindOfClass:[AVURLAsset class]]) return NO;
        NSString *p = fxNormPath(((AVURLAsset *)a).URL.path);
        NSString *g = fxNormPath(gVideoPath);
        if (p.length == 0 || g.length == 0) return NO;
        if ([p isEqualToString:g]) return YES;
        if ([p hasSuffix:g]) return YES;
        if ([g hasSuffix:p]) return YES;
        NSString *n1 = [p lastPathComponent];
        NSString *n2 = [g lastPathComponent];
        if (n1.length && [n1 isEqualToString:n2]) return YES;
    } @catch (NSException *e) {}
    return NO;
}

// ============================================================
//  Prefetch 限制 (1 帧)
//
//  LocalVideoPlayer.rebuildReaderOnDecodeThread 内的 prefetch 循环
//  调用 readNextFrame 5 次。这里让第 2 次起返回 NULL, 循环立即 break。
// ============================================================
static __thread BOOL tInPrefetch = NO;
static __thread int  tPrefetchCalls = 0;

static CVPixelBufferRef (*orig_readNextFrame)(id, SEL) = NULL;
static CVPixelBufferRef fx_readNextFrame(id self, SEL _cmd) {
    if (tInPrefetch) {
        tPrefetchCalls++;
        if (tPrefetchCalls > 1) {
            return NULL;  // 第 2 次起返回 NULL, prefetch 循环 break
        }
    }
    return orig_readNextFrame ? orig_readNextFrame(self, _cmd) : NULL;
}

static void (*orig_rebuildReader)(id, SEL) = NULL;
static void fx_rebuildReader(id self, SEL _cmd) {
    tInPrefetch = YES;
    tPrefetchCalls = 0;
    if (orig_rebuildReader) orig_rebuildReader(self, _cmd);
    tInPrefetch = NO;
    tPrefetchCalls = 0;
}

// ============================================================
//  Hook #1: -[AVAssetReader startReading]
//  仅 PLAY_ACTION 状态下改写 timeRange 为 [gStartUs, gEndUs]
// ============================================================
static BOOL (*orig_startReading)(id, SEL) = NULL;
static BOOL fx_startReading(id self, SEL _cmd) {
    if (gState != FX_STATE_PLAY_ACTION) {
        return orig_startReading ? orig_startReading(self, _cmd) : NO;
    }
    @try {
        if (fxIsOurReader((AVAssetReader *)self)) {
            AVAsset *a = [(AVAssetReader *)self asset];
            CMTime assetDur = a.duration;
            int64_t durUs = (int64_t)((double)assetDur.value * 1000000.0 / (double)assetDur.timescale);

            int64_t sUs = gStartUs;
            int64_t eUs = gEndUs;

            if (durUs > 0) {
                if (sUs < 0) sUs = 0;
                if (sUs > durUs) sUs = 0;
                if (eUs <= sUs + 50000LL) eUs = durUs;
                if (eUs > durUs) eUs = durUs;
            }
            if (eUs - sUs >= 100000LL) {
                CMTimeRange range = CMTimeRangeMake(
                    CMTimeMake(sUs, 1000000),
                    CMTimeMake(eUs - sUs, 1000000));
                [(AVAssetReader *)self setTimeRange:range];

                static CFAbsoluteTime lastLog = 0;
                CFAbsoluteTime nowT = CFAbsoluteTimeGetCurrent();
                if (nowT - lastLog > 30.0) {
                    lastLog = nowT;
                    fxLog(@"OVERRIDE [%lldus-%lldus] = [%.6fs-%.6fs]",
                          sUs, eUs, sUs / 1e6, eUs / 1e6);
                }
            }
        }
    } @catch (NSException *e) { fxLog(@"startReading EXC %@", e); }
    return orig_startReading ? orig_startReading(self, _cmd) : NO;
}

// ============================================================
//  Hook #2: -[LocalVideoPlayer resetReaderForLoop]
//  PLAY_ACTION 播完 → 冻结
// ============================================================
static void (*orig_resetReaderForLoop)(id, SEL) = NULL;
static void fx_resetReaderForLoop(id self, SEL _cmd) {
    if (gState == FX_STATE_PLAY_ACTION) {
        gState = FX_STATE_FROZEN;
        fxLog(@"FROZEN");
        SEL stopSel = NSSelectorFromString(@"stopDecodingThread");
        if ([self respondsToSelector:stopSel]) {
            ((void (*)(id, SEL))objc_msgSend)(self, stopSel);
        }
        return;
    }
    if (orig_resetReaderForLoop) orig_resetReaderForLoop(self, _cmd);
}

// ============================================================
//  取 player（通过混淆类名 Qz1）
// ============================================================
static id fxPlayer(void) {
    Class c = NSClassFromString(@"Qz1");
    if (!c) return nil;
    SEL s = NSSelectorFromString(@"sharedInstance");
    if (![c respondsToSelector:s]) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))[c methodForSelector:s];
    id core = fn(c, s);
    if (!core) return nil;
    id p = nil;
    @try { p = [core valueForKey:@"videoPlayer"]; } @catch (NSException *e) {}
    return p;
}

// ============================================================
//  Seek 防抖 + 异步队列
// ============================================================
static dispatch_queue_t gSeekQueue = NULL;
static int64_t   gPendingSeekUs = -1;
static NSString *gPendingSeekPath = nil;
static CFAbsoluteTime gPendingSeekAt = 0;

static void fxExecSeek(int64_t us, NSString *path) {
    id p = fxPlayer();
    if (!p) return;

    // SEL/IMP 缓存
    static SEL selSetResume = NULL;
    static IMP impSetResume = NULL;
    static SEL selLoad = NULL;
    static IMP impLoad = NULL;

    if (!selSetResume) {
        selSetResume = NSSelectorFromString(@"setResumeAtSeconds:");
        if ([p respondsToSelector:selSetResume]) {
            impSetResume = [p methodForSelector:selSetResume];
        }
        selLoad = NSSelectorFromString(@"loadVideoAtPath:completion:");
        if ([p respondsToSelector:selLoad]) {
            impLoad = [p methodForSelector:selLoad];
        }
    }
    if (!impSetResume || !impLoad) return;

    double sec = (double)us / 1000000.0;
    ((void (*)(id, SEL, double))impSetResume)(p, selSetResume, sec);
    ((void (*)(id, SEL, NSString *, id))impLoad)(p, selLoad, path, nil);
    fxLog(@"seek %lldus (%.3fs)", us, sec);
}

static void fxSeekUs(int64_t us, NSString *path) {
    if (path.length == 0) return;

    if (!gSeekQueue) {
        gSeekQueue = dispatch_queue_create("fx.seek", DISPATCH_QUEUE_SERIAL);
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    // 同目标 300ms 内合并
    if (gPendingSeekUs == us && (now - gPendingSeekAt) < 0.3) {
        return;
    }

    gPendingSeekUs = us;
    gPendingSeekPath = [path copy];
    gPendingSeekAt = now;

    int64_t capturedUs = us;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   gSeekQueue, ^{
        @autoreleasepool {
            if (gPendingSeekUs != capturedUs) return;
            int64_t execUs = gPendingSeekUs;
            NSString *execPath = gPendingSeekPath;
            gPendingSeekUs = -1;
            gPendingSeekPath = nil;
            fxExecSeek(execUs, execPath);
        }
    });
}

// ============================================================
//  启动动作（抢占）
// ============================================================
static void fxStartAction(int act, NSDictionary *pl) {
    int64_t sUs = 0, eUs = 0;
    if (act == 1) {
        sUs = fxReadUsFromDict(pl, kBS_Us, kBS_Legacy);
        eUs = fxReadUsFromDict(pl, kBE_Us, kBE_Legacy);
        if (sUs <= 0 && eUs <= 0) { sUs = kBlinkStartDefUs; eUs = kBlinkEndDefUs; }
    } else if (act == 2) {
        sUs = fxReadUsFromDict(pl, kMS_Us, kMS_Legacy);
        eUs = fxReadUsFromDict(pl, kME_Us, kME_Legacy);
        if (sUs <= 0 && eUs <= 0) { sUs = kMouthStartDefUs; eUs = kMouthEndDefUs; }
    } else if (act == 3) {
        sUs = fxReadUsFromDict(pl, kHS_Us, kHS_Legacy);
        eUs = fxReadUsFromDict(pl, kHE_Us, kHE_Legacy);
        if (sUs <= 0 && eUs <= 0) { sUs = kHeadStartDefUs; eUs = kHeadEndDefUs; }
    } else return;

    if (sUs < 0) sUs = 0;
    if (eUs <= sUs) eUs = sUs + 1000000LL;

    gState = FX_STATE_PLAY_ACTION;
    gCurAction = act;
    gStartUs = sUs;
    gEndUs   = eUs;

    fxLog(@"START act=%d [%.3fs-%.3fs]", act, sUs / 1e6, eUs / 1e6);
    fxSeekUs(sUs, gVideoPath.length ? gVideoPath : gLastPath);
}

// ============================================================
//  退出动作模式
// ============================================================
static void fxExitAction(void) {
    if (gState == FX_STATE_LOOP_FULL) return;
    gState = FX_STATE_LOOP_FULL;
    gCurAction = 0;
    gStartUs = 0;
    gEndUs = 0;
    fxLog(@"EXIT");
    fxSeekUs(0, gVideoPath.length ? gVideoPath : gLastPath);
}

// ============================================================
//  plist 读取（mtime 缓存）
// ============================================================
static NSDictionary *fxLoadPlist(void) {
    static time_t lastMtime = 0;
    static NSDictionary *cached = nil;
    NSString *path = fxPlist();
    struct stat st;
    if (stat(path.UTF8String, &st) != 0) return nil;
    if (st.st_mtime == lastMtime && cached) return cached;
    lastMtime = st.st_mtime;
    cached = [NSDictionary dictionaryWithContentsOfFile:path];
    return cached;
}

// ============================================================
//  paused 同步
// ============================================================
static void fxSyncPaused(NSDictionary *pl) {
    static BOOL lastP = NO;
    static BOOL first = YES;
    BOOL p = [pl[kPausedStr] boolValue];
    if (first) { first = NO; lastP = p; return; }
    if (p == lastP) return;
    lastP = p;
    id player = fxPlayer();
    if (!player) return;
    SEL s = NSSelectorFromString(@"setPaused:");
    if ([player respondsToSelector:s]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(player, s, p);
        fxLog(@"paused synced: %d", p);
    }
}

// ============================================================
//  状态机主循环 — 双条件检测
// ============================================================
static void fxCheck(void) {
    NSDictionary *pl = fxLoadPlist();
    if (!pl) return;

    fxSyncPaused(pl);

    NSString *path = pl[kPathKey()];
    int64_t tok = [pl[kTok] longLongValue];
    int64_t rtok = [pl[kRtKey()] longLongValue];
    int act = [pl[kAct] intValue];

    if (!gInitDone) {
        gInitDone = YES;
        gLastPath = [path copy];
        gVideoPath = [path copy];
        gLastTok = tok; gLastRt = rtok; gLastAct = act;
        gState = FX_STATE_LOOP_FULL;
        fxLog(@"init path=%@ tok=%lld rtok=%lld act=%d",
              path ? [path lastPathComponent] : @"(nil)", tok, rtok, act);
        return;
    }
    if (![path isEqualToString:gLastPath]) {
        fxLog(@"path change -> %@", path ? [path lastPathComponent] : @"(nil)");
        gLastPath = [path copy]; gVideoPath = [path copy];
        gLastTok = tok; gLastRt = rtok; gLastAct = act;
        gState = FX_STATE_LOOP_FULL;
        gCurAction = 0;
        return;
    }
    if (rtok != gLastRt) {
        fxLog(@"restart");
        gLastRt = rtok;
        if (gState != FX_STATE_LOOP_FULL) {
            gState = FX_STATE_LOOP_FULL;
            gCurAction = 0;
        }
        return;
    }

    BOOL tokChanged = (tok != gLastTok);
    BOOL actToZero = (act == 0 && gLastAct > 0);

    if (tokChanged || actToZero) {
        gLastTok = tok;
        if (act >= 1 && act <= 3) {
            gLastAct = act;
            fxStartAction(act, pl);
        } else {
            gLastAct = act;
            fxExitAction();
        }
    }
}

// ============================================================
//  notify 监听 + poller 兜底
// ============================================================
static void fxRegisterNotify(void) {
    static int token = -1;
    notify_register_dispatch(fxActionNotifyName(), &token,
                             dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                             ^(int t) {
        @autoreleasepool {
            @try { fxCheck(); } @catch (NSException *e) {}
        }
    });
    fxLog(@"notify listener registered");
}

static dispatch_source_t gPoller = nil;

static void fxStartPoller(void) {
    dispatch_queue_t q = dispatch_queue_create("fx.poll", DISPATCH_QUEUE_SERIAL);
    gPoller = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!gPoller) return;

    // 1.0s 兜底
    dispatch_source_set_timer(gPoller,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        (uint64_t)(1.0 * NSEC_PER_SEC),
        (uint64_t)(0.2 * NSEC_PER_SEC));

    __block int beat = 0;
    dispatch_source_set_event_handler(gPoller, ^{
        @autoreleasepool {
            if (++beat % 30 == 0) {
                NSDictionary *p = fxLoadPlist();
                fxLog(@"beat tok=%@ act=%@ state=%d",
                      p[kTok] ?: @"-", p[kAct] ?: @"-", gState);
            }
            @try { fxCheck(); }
            @catch (NSException *e) {}
        }
    });
    dispatch_resume(gPoller);
    fxLog(@"poller started (1.0s)");
}

// ============================================================
//  Hook #3: -[LocalVideoPlayer loadVideoAtPath:completion:]
//  回写 videoDuration
// ============================================================
static void (*orig_loadVideo)(id, SEL, NSString *, id) = NULL;
static void fx_loadVideo(id self, SEL _cmd, NSString *path, id completion) {
    if (orig_loadVideo) orig_loadVideo(self, _cmd, path, completion);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            double dur = [[self valueForKey:@"videoDuration"] doubleValue];
            if (dur > 0.05) {
                NSString *p = fxPlist();
                NSDictionary *cur = [NSDictionary dictionaryWithContentsOfFile:p];
                if ([cur[@"videoDuration"] doubleValue] < 0.05) {
                    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:cur ?: @{}];
                    m[@"videoDuration"] = @(dur);
                    [m writeToFile:p atomically:YES];
                }
            }
        } @catch (NSException *e) {}
    });
}

// ============================================================
//  SpringBoard 侧：退出按钮注入
// ============================================================
static void fx_exitTapped(id self, SEL _cmd) {
    NSString *p = fxPlist();
    NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:p];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:pl ?: @{}];
    d[@"actionActive"] = @0;
    d[@"actionToken"]  = @([d[@"actionToken"] integerValue] + 1);
    [d writeToFile:p atomically:YES];
    fxPostActionNotify();
}

static void (*orig_injectIntoBall)(id, SEL, id, UIView *) = NULL;
static void fx_injectIntoBall(id self, SEL _cmd, id ball, UIView *panelView) {
    if (orig_injectIntoBall) orig_injectIntoBall(self, _cmd, ball, panelView);

    UIView *page = [panelView viewWithTag:0x56435042];
    if (!page || [page viewWithTag:0x46455849]) return;

    CGRect f = page.frame;
    f.size.height += 46;
    page.frame = f;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = 0x46455849;
    btn.frame = CGRectMake(10, f.size.height - 42, f.size.width - 20, 36);
    [btn setTitle:@"退出动作" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    btn.backgroundColor = [UIColor colorWithRed:0.36 green:0.42 blue:0.58 alpha:1.0];
    btn.layer.cornerRadius = 6;
    btn.layer.masksToBounds = YES;
    [btn addTarget:self action:@selector(fx_exitTapped_internal)
  forControlEvents:UIControlEventTouchUpInside];
    [page addSubview:btn];
}

static void (*orig_doAction)(id, SEL, int) = NULL;
static void fx_doAction(id self, SEL _cmd, int action) {
    if (orig_doAction) orig_doAction(self, _cmd, action);
    fxPostActionNotify();
}

static void fxInstallSBHooks(void) {
    Class cls = NSClassFromString(@"VCamActionPatch");
    if (!cls) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            fxInstallSBHooks();
        });
        return;
    }

    // 注册 fx_exitTapped_internal 方法
    SEL sExit = NSSelectorFromString(@"fx_exitTapped_internal");
    class_addMethod(cls, sExit, (IMP)fx_exitTapped, "v@:");

    // hook doAction:
    SEL s2 = NSSelectorFromString(@"doAction:");
    Method m2 = class_getInstanceMethod(cls, s2);
    if (m2) {
        orig_doAction = (void (*)(id, SEL, int))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)fx_doAction);
        fxLog(@"hook doAction: OK");
    }

    // hook injectIntoBall:panelView:
    SEL s3 = NSSelectorFromString(@"injectIntoBall:panelView:");
    Method m3 = class_getInstanceMethod(cls, s3);
    if (m3) {
        orig_injectIntoBall = (void (*)(id, SEL, id, UIView *))method_getImplementation(m3);
        method_setImplementation(m3, (IMP)fx_injectIntoBall);
        fxLog(@"hook injectIntoBall:panelView: OK");
    } else {
        fxLog(@"injectIntoBall:panelView: not found");
    }
}

// ============================================================
//  安装
// ============================================================
__attribute__((constructor, used))
static void fxInstall(void) {
    @autoreleasepool {
        fxLog(@"===== install (proc=%s pid=%d) =====",
              getprogname() ?: "?", (int)getpid());
        fxLog(@"log path: %s", fxPickLogPath() ?: "(none)");

        if (fxIsMd()) {
            // ========== mediaserverd ==========
            fxLog(@"role=md");

            Class r = [AVAssetReader class];
            Method m1 = class_getInstanceMethod(r, @selector(startReading));
            if (m1) {
                orig_startReading = (BOOL (*)(id, SEL))method_getImplementation(m1);
                method_setImplementation(m1, (IMP)fx_startReading);
                fxLog(@"hook startReading OK");
            }

            Class lp = NSClassFromString(@"Wv2");
            if (lp) {
                SEL sReset = NSSelectorFromString(@"resetReaderForLoop");
                Method m2 = class_getInstanceMethod(lp, sReset);
                if (m2) {
                    orig_resetReaderForLoop = (void (*)(id, SEL))method_getImplementation(m2);
                    method_setImplementation(m2, (IMP)fx_resetReaderForLoop);
                    fxLog(@"hook resetReaderForLoop OK");
                }

                SEL sLoad = NSSelectorFromString(@"loadVideoAtPath:completion:");
                Method m3 = class_getInstanceMethod(lp, sLoad);
                if (m3) {
                    orig_loadVideo = (void (*)(id, SEL, NSString *, id))method_getImplementation(m3);
                    method_setImplementation(m3, (IMP)fx_loadVideo);
                    fxLog(@"hook loadVideoAtPath OK");
                }

                // rebuildReaderOnDecodeThread (prefetch 1 帧)
                SEL sRebuild = NSSelectorFromString(@"rebuildReaderOnDecodeThread");
                Method m4 = class_getInstanceMethod(lp, sRebuild);
                if (m4) {
                    orig_rebuildReader = (void (*)(id, SEL))method_getImplementation(m4);
                    method_setImplementation(m4, (IMP)fx_rebuildReader);
                }

                // readNextFrame (prefetch 限制)
                SEL sRead = NSSelectorFromString(@"readNextFrame");
                Method m5 = class_getInstanceMethod(lp, sRead);
                if (m5) {
                    orig_readNextFrame = (CVPixelBufferRef (*)(id, SEL))method_getImplementation(m5);
                    method_setImplementation(m5, (IMP)fx_readNextFrame);
                }
            }

            fxRegisterNotify();
            fxStartPoller();
            fxLog(@"===== md install done =====");

        } else if (fxIsSb()) {
            // ========== SpringBoard ==========
            fxLog(@"role=sb");
            fxInstallSBHooks();
            fxLog(@"===== sb install done =====");

        } else {
            fxLog(@"skip (not target process)");
        }
    }
}
