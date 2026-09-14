//
//  LocalVideoPlayer.m
//  AVAssetReader 解码 + 帧队列 + 循环播放 + 文件监听
//

#import "LocalVideoPlayer.h"
#import "VCamNotify.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <AVFoundation/AVFoundation.h>

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

static void vcam_player_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    if (!vcam_log_budget_take()) return;
    @try {
        NSString *logPath = @"/tmp/vcam_player_log.txt";
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
//  类扩展
// ============================================================
@interface LocalVideoPlayer ()
@property (nonatomic, strong) AVURLAsset *urlAsset;
@property (nonatomic, strong) NSMutableArray *preloadCache;
@property (nonatomic, strong) NSMutableDictionary *preloadInfo;

@property (nonatomic, strong) dispatch_source_t watchTimer;
@property (nonatomic, copy) NSString *watchPath;
@property (nonatomic, assign) unsigned long long lastFileSize;
@property (nonatomic, assign) unsigned long long lastInode;
@property (nonatomic, assign) double lastMtime;

@property (nonatomic, assign) int64_t reloadGeneration;
@property (nonatomic, assign) int64_t currentGeneration;

@property (nonatomic, assign) CGFloat effectiveFpsInternal;
@property (nonatomic, assign) BOOL hasLastPTS;
@property (nonatomic, assign) double lastPTS;

@property (nonatomic, copy) NSString *assetPath;
@property (nonatomic, strong) AVURLAsset *reusableAsset;
@property (nonatomic, strong) AVAssetTrack *reusableTrack;

@property (nonatomic, assign) volatile int64_t requestedLoadGen;
@property (nonatomic, assign) volatile int64_t appliedLoadGen;
@property (nonatomic, copy) NSString *pendingPath;
@property (nonatomic, assign) volatile BOOL pendingUnload;

@property (nonatomic, assign) double lastDecodedPosSec;
@property (nonatomic, assign) double resumeAtSeconds;

@property (nonatomic, assign) BOOL shouldDecode;
@property (nonatomic, strong) NSThread *decodeThread;
@property (nonatomic, strong) NSLock *stateLock;
@end

// ============================================================
//  @implementation
// ============================================================
@implementation LocalVideoPlayer

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    self = [super init];
    if (self) {
        _frameQueue = [[NSQueue alloc] initWithCapacity:capacity pixelBufferMode:YES];
        _decodeQueue = dispatch_queue_create("com.vcam.videoreader", DISPATCH_QUEUE_SERIAL);
        _processingQueue = dispatch_queue_create("com.vcam.decoder", DISPATCH_QUEUE_SERIAL);
        _preloadCache = [[NSMutableArray alloc] init];
        _preloadInfo = [[NSMutableDictionary alloc] init];
        _stateLock = [[NSLock alloc] init];
        _reloadGeneration = 0;
        _currentGeneration = 0;
        _effectiveFpsInternal = 0;
        _hasLastPTS = NO;
        _lastPTS = 0;
        _shouldDecode = NO;
        _enabled = NO;
        _isEnabled = NO;
        _preprocessEnabled = YES;
        _mediaType = VCamMediaTypeUnknown;
        _cachedImageBuffer = NULL;
        vcam_player_log(@"[vcam] LocalVideoPlayer initialized");
    }
    return self;
}

- (void)dealloc {
    [self stopDecodingThread];
    [self stopWatchingFile];
    [self clearFrameQueue];
    if (_cachedImageBuffer) {
        CVPixelBufferRelease(_cachedImageBuffer);
        _cachedImageBuffer = NULL;
    }
    vcam_player_log(@"[vcam] LocalVideoPlayer deallocated");
}

#pragma mark - 媒体类型检测

+ (VCamMediaType)detectMediaType:(NSString *)path {
    if (!path || path.length == 0) return VCamMediaTypeUnknown;
    NSString *ext = path.pathExtension.lowercaseString;
    NSArray *videoExts = @[@"mp4", @"mov", @"m4v", @"3gp", @"avi", @"mkv"];
    if ([videoExts containsObject:ext]) return VCamMediaTypeVideo;
    NSArray *imageExts = @[@"jpg", @"jpeg", @"png", @"heic", @"heif", @"bmp", @"gif"];
    if ([imageExts containsObject:ext]) return VCamMediaTypeImage;
    return VCamMediaTypeUnknown;
}

#pragma mark - 有效帧率

- (CGFloat)effectiveFps {
    if (_effectiveFpsInternal > 1.0) return _effectiveFpsInternal;
    if (_videoFps > 1.0) return _videoFps;
    return 30.0;
}

static size_t vcam_decode_max_edge(void) {
    static int cached = -1;
    if (cached < 0) {
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
            if (d && d[@"decodeMaxEdge"]) {
                NSInteger v = [d[@"decodeMaxEdge"] integerValue];
                cached = (int)(v >= 0 ? v : 720);
            } else {
                cached = 720;
            }
        } @catch (NSException *e) { cached = 720; }
    }
    return (size_t)cached;
}

#pragma mark - 视频加载

- (void)loadVideoAtPath:(NSString *)path completion:(void(^)(BOOL success, NSError *error))completion {
    if (!path || path.length == 0) {
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:1 userInfo:@{NSLocalizedDescriptionKey:@"No path"}]);
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:2 userInfo:@{NSLocalizedDescriptionKey:@"File not found"}]);
        return;
    }

    VCamMediaType type = [LocalVideoPlayer detectMediaType:path];
    if (type == VCamMediaTypeVideo) {
        [self loadVideoFile:path completion:completion];
    } else if (type == VCamMediaTypeImage) {
        [self loadImageFile:path completion:completion];
    } else {
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Unsupported"}]);
    }
}

- (void)loadVideoFile:(NSString *)path completion:(void(^)(BOOL success, NSError *error))completion {
    NSURL *url = [NSURL fileURLWithPath:path];
    _currentVideoPath = path;
    _mediaType = VCamMediaTypeVideo;
    _hasLastPTS = NO;
    _lastPTS = 0;
    _effectiveFpsInternal = 0;

    // asset/track 复用（同路径重载不重建）
    if (![_assetPath isEqualToString:path] || !_reusableAsset) {
        NSDictionary *opts = @{AVURLAssetPreferPreciseDurationAndTimingKey: @NO};
        _reusableAsset = [AVURLAsset URLAssetWithURL:url options:opts];
        _reusableTrack = nil;
        _assetPath = [path copy];
        _resumeAtSeconds = 0;
        _lastDecodedPosSec = 0;
    }
    _urlAsset = _reusableAsset;

    if (!_reusableTrack) {
        NSArray *tracks = [_urlAsset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count == 0) {
            if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:4 userInfo:@{NSLocalizedDescriptionKey:@"No video track"}]);
            return;
        }
        _reusableTrack = tracks[0];
    }
    _videoTrack = _reusableTrack;

    _videoWidth = (size_t)_videoTrack.naturalSize.width;
    _videoHeight = (size_t)_videoTrack.naturalSize.height;
    _videoFps = _videoTrack.nominalFrameRate;
    _videoDuration = CMTimeGetSeconds(_urlAsset.duration);

    // 解码降采样
    size_t plistEdge = vcam_decode_max_edge();
    size_t maxEdge = (_dynamicMaxEdge > 0)
        ? ((plistEdge > 0) ? MIN(_dynamicMaxEdge, plistEdge) : _dynamicMaxEdge)
        : plistEdge;
    if (maxEdge > 0) {
        size_t longEdge = MAX(_videoWidth, _videoHeight);
        if (longEdge > maxEdge) {
            double scale = (double)maxEdge / (double)longEdge;
            size_t nw = ((size_t)((double)_videoWidth * scale)) & ~1u;
            size_t nh = ((size_t)((double)_videoHeight * scale)) & ~1u;
            if (nw >= 2 && nh >= 2) {
                _videoWidth = nw;
                _videoHeight = nh;
            }
        }
    }

    // preferredTransform 解析
    CGAffineTransform pt = _videoTrack.preferredTransform;
    if (pt.a == 0 && pt.b == 1 && pt.c == -1 && pt.d == 0) {
        _preferredRotation = 90;
    } else if (pt.a == -1 && pt.b == 0 && pt.c == 0 && pt.d == -1) {
        _preferredRotation = 180;
    } else if (pt.a == 0 && pt.b == -1 && pt.c == 1 && pt.d == 0) {
        _preferredRotation = 270;
    } else {
        _preferredRotation = 0;
    }

    _pendingPath = [path copy];
    __sync_add_and_fetch(&_requestedLoadGen, 1);
    [self startDecodingThread];

    if (completion) completion(YES, nil);
}

// 解码线程内重建 reader（reader 生命周期单线程持有）
- (void)rebuildReaderOnDecodeThread {
    if (!_urlAsset || !_videoTrack) return;

    if (_assetReader) {
        [_assetReader cancelReading];
        _assetReader = nil;
    }
    _videoOutput = nil;
    [self clearFrameQueue];

    NSError *readerErr = nil;
    _assetReader = [[AVAssetReader alloc] initWithAsset:_urlAsset error:&readerErr];
    if (readerErr || !_assetReader) return;

    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @((OSType)'420f'),
        (id)kCVPixelBufferWidthKey:  @(_videoWidth),
        (id)kCVPixelBufferHeightKey: @(_videoHeight),
    };
    _videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:_videoTrack outputSettings:outputSettings];
    _videoOutput.alwaysCopiesSampleData = NO;

    if (![_assetReader canAddOutput:_videoOutput]) {
        _assetReader = nil;
        _videoOutput = nil;
        return;
    }
    [_assetReader addOutput:_videoOutput];

    // 空闲恢复续播
    if (_resumeAtSeconds > 0.05 && _videoDuration > 0.3 &&
        _resumeAtSeconds < _videoDuration - 0.15) {
        CMTime start = CMTimeMakeWithSeconds(_resumeAtSeconds, 600);
        _assetReader.timeRange = CMTimeRangeFromTimeToTime(start, _urlAsset.duration);
    }
    _resumeAtSeconds = 0;

    if (![_assetReader startReading]) {
        [_assetReader cancelReading];
        _assetReader = nil;
        _videoOutput = nil;
        return;
    }

    // 预填 5 帧
    NSUInteger prefilled = 0;
    while (prefilled < 5 && prefilled < _frameQueue.capacity) {
        CVPixelBufferRef b = [self readNextFrame];
        if (!b) break;
        [_frameQueue enqueuePixelBuffer:b];
        CVPixelBufferRelease(b);
        prefilled++;
    }
}

- (void)loadImageFile:(NSString *)path completion:(void(^)(BOOL success, NSError *error))completion {
    [self stopDecodingThread];
    [self clearFrameQueue];

    _currentVideoPath = path;
    _mediaType = VCamMediaTypeImage;

    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nil);
    if (!source) {
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:6 userInfo:@{NSLocalizedDescriptionKey:@"Image not found"}]);
        return;
    }

    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil);
    CFRelease(source);
    if (!cgImage) {
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:7 userInfo:@{NSLocalizedDescriptionKey:@"Decode failed"}]);
        return;
    }

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);

    CVPixelBufferRef pixelBuffer = NULL;
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA, NULL, &pixelBuffer);
    if (status != noErr || !pixelBuffer) {
        CGImageRelease(cgImage);
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:8 userInfo:@{NSLocalizedDescriptionKey:@"Buffer create failed"}]);
        return;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    CGContextRef ctx = CGBitmapContextCreate(
        CVPixelBufferGetBaseAddress(pixelBuffer),
        width, height, 8, CVPixelBufferGetBytesPerRow(pixelBuffer),
        CGColorSpaceCreateDeviceRGB(),
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
    );
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    CGImageRelease(cgImage);

    if (_cachedImageBuffer) CVPixelBufferRelease(_cachedImageBuffer);
    _cachedImageBuffer = pixelBuffer;
    CVPixelBufferRetain(_cachedImageBuffer);

    [_frameQueue enqueuePixelBuffer:pixelBuffer];

    _videoWidth = width;
    _videoHeight = height;

    if (completion) completion(YES, nil);
}

#pragma mark - 帧读取（仅解码线程调用）

- (CVPixelBufferRef)readNextFrame CF_RETURNS_RETAINED {
    if (!_videoOutput || _assetReader.status != AVAssetReaderStatusReading) {
        return NULL;
    }

    CMSampleBufferRef sampleBuffer = [_videoOutput copyNextSampleBuffer];
    if (!sampleBuffer) {
        if (_assetReader.status == AVAssetReaderStatusCompleted) {
            [self resetReaderForLoop];
        }
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer) {
        CVPixelBufferRetain(pixelBuffer);
        // PTS 实测帧率（EMA 平滑）
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        double ptsSec = CMTimeGetSeconds(pts);
        if (CMTIME_IS_VALID(pts) && !isnan(ptsSec)) {
            if (_hasLastPTS && ptsSec > _lastPTS) {
                double interval = ptsSec - _lastPTS;
                if (interval >= 0.005 && interval <= 0.2) {
                    double inst = 1.0 / interval;
                    _effectiveFpsInternal = (_effectiveFpsInternal > 1.0)
                        ? (_effectiveFpsInternal * 0.8 + inst * 0.2) : inst;
                }
            }
            _lastPTS = ptsSec;
            _hasLastPTS = YES;
            _lastDecodedPosSec = ptsSec;
        }
    }
    CFRelease(sampleBuffer);
    return pixelBuffer;
}

- (void)resetReaderForLoop {
    [_assetReader cancelReading];
    _assetReader = nil;
    _videoOutput = nil;

    NSError *err = nil;
    _assetReader = [[AVAssetReader alloc] initWithAsset:_urlAsset error:&err];
    if (err || !_assetReader) return;

    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @((OSType)'420f'),
        (id)kCVPixelBufferWidthKey:  @(_videoWidth),
        (id)kCVPixelBufferHeightKey: @(_videoHeight),
    };
    _videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:_videoTrack outputSettings:outputSettings];
    _videoOutput.alwaysCopiesSampleData = NO;
    [_assetReader addOutput:_videoOutput];
    [_assetReader startReading];
}

#pragma mark - 解码线程

- (void)startDecodingThread {
    // 常驻线程（只创建一次，stop/start 只翻标志）
    if (_decodeThread && _isDecoding) {
        _shouldDecode = YES;
        return;
    }
    _shouldDecode = YES;
    _isDecoding = YES;

    _decodeThread = [[NSThread alloc] initWithTarget:self selector:@selector(decodeLoop) object:nil];
    _decodeThread.name = @"vcam.decoder";
    _decodeThread.qualityOfService = NSQualityOfServiceDefault;
    [_decodeThread start];
}

- (void)stopDecodingThread {
    _shouldDecode = NO;
}

- (void)unloadForIdle {
    _pendingUnload = YES;
    __sync_add_and_fetch(&_requestedLoadGen, 1);
    _resumeAtSeconds = 0;
    [self clearFrameQueue];
}

- (void)resetPlaybackPosition {
    _resumeAtSeconds = 0;
    _lastDecodedPosSec = 0;
}

- (void)releaseMediaOnDecodeThread {
    if (_assetReader) {
        [_assetReader cancelReading];
        _assetReader = nil;
    }
    _videoOutput = nil;
    _urlAsset = nil;
    _videoTrack = nil;
    [self clearFrameQueue];
    if (_cachedImageBuffer) {
        CVPixelBufferRelease(_cachedImageBuffer);
        _cachedImageBuffer = NULL;
    }
}

- (void)decodeLoop {
    @autoreleasepool {
        CFAbsoluteTime nextTick = CFAbsoluteTimeGetCurrent();
        while (YES) {
            @autoreleasepool {
                if (!_shouldDecode) {
                    // 暂停态也要处理代数（idle unload 用）
                    if (_requestedLoadGen != _appliedLoadGen) {
                        _appliedLoadGen = _requestedLoadGen;
                        if (_pendingUnload) {
                            _pendingUnload = NO;
                            [self releaseMediaOnDecodeThread];
                        }
                    }
                    [NSThread sleepForTimeInterval:0.1];
                    continue;
                }

                // 加载代数变化 → 解码线程自行重建 reader
                if (_requestedLoadGen != _appliedLoadGen) {
                    _appliedLoadGen = _requestedLoadGen;
                    if (_pendingUnload) {
                        _pendingUnload = NO;
                        [self releaseMediaOnDecodeThread];
                        continue;
                    }
                    if (_mediaType == VCamMediaTypeVideo) {
                        [self rebuildReaderOnDecodeThread];
                    }
                }

                if (_mediaType == VCamMediaTypeImage) {
                    [NSThread sleepForTimeInterval:0.1];
                    continue;
                }

                // 暂停态：停止取新帧
                if (_paused) {
                    [NSThread sleepForTimeInterval:0.05];
                    nextTick = CFAbsoluteTimeGetCurrent();
                    continue;
                }

                CVPixelBufferRef buffer = [self readNextFrame];
                if (buffer) {
                    [_frameQueue enqueuePixelBuffer:buffer];
                    CVPixelBufferRelease(buffer);
                    _frameCount++;

                    double effFps = [self effectiveFps];
                    double frameInterval = 1.0 / effFps;
                    nextTick += frameInterval;
                    double wait = nextTick - CFAbsoluteTimeGetCurrent();
                    if (wait > 0.001) {
                        [NSThread sleepForTimeInterval:wait];
                    } else {
                        nextTick = CFAbsoluteTimeGetCurrent();
                    }
                } else {
                    [NSThread sleepForTimeInterval:0.005];
                    nextTick = CFAbsoluteTimeGetCurrent();
                }

                if (_frameQueue.count > _frameQueue.capacity) {
                    [NSThread sleepForTimeInterval:0.01];
                    nextTick = CFAbsoluteTimeGetCurrent();
                }
            }
        }
    }
}

#pragma mark - 帧获取

- (CVPixelBufferRef)getCurrentFrame {
    return [_frameQueue getCurrentFrame];
}

- (CVPixelBufferRef)copyCurrentFrame CF_RETURNS_RETAINED {
    return [_frameQueue copyCurrentFrame];
}

#pragma mark - 帧队列管理

- (void)clearFrameQueue {
    [_frameQueue clearFrameQueue];
}

#pragma mark - 文件监听

- (void)startWatchingFile:(NSString *)path {
    if (!path || path.length == 0) return;
    [self stopWatchingFile];
    _watchPath = [path copy];
    [self updateFileInfo];

    __weak typeof(self) weakSelf = self;
    static BOOL reloadListenerRegistered = NO;
    if (!reloadListenerRegistered) {
        reloadListenerRegistered = YES;
        [[VCamNotify sharedInstance] registerForNotification:VCamNotifyReloadMedia callback:^(NSString *name) {
            [weakSelf reloadMedia];
        }];
    }

    dispatch_queue_t watchQueue = dispatch_queue_create("com.vcam.filewatch", DISPATCH_QUEUE_SERIAL);
    _watchTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, watchQueue);
    dispatch_source_set_timer(_watchTimer,
        dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
        2 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(_watchTimer, ^{
        [weakSelf checkFileChanges];
    });
    dispatch_resume(_watchTimer);
}

- (void)stopWatchingFile {
    if (_watchTimer) {
        dispatch_source_cancel(_watchTimer);
        _watchTimer = nil;
    }
    _watchPath = nil;
}

- (void)updateFileInfo {
    if (!_watchPath) return;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:_watchPath error:nil];
    if (attrs) {
        _lastFileSize = [attrs fileSize];
        _lastMtime = [attrs.fileModificationDate timeIntervalSince1970];
        NSNumber *inode = attrs[NSFileSystemFileNumber];
        _lastInode = inode ? [inode unsignedLongLongValue] : 0;
    }
}

- (void)checkFileChanges {
    if (!_watchPath) return;

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:_watchPath error:nil];
    if (!attrs) {
        // 文件被删除
        [self stopDecodingThread];
        [self clearFrameQueue];
        return;
    }

    unsigned long long newSize = [attrs fileSize];
    double newMtime = [attrs.fileModificationDate timeIntervalSince1970];
    NSNumber *inode = attrs[NSFileSystemFileNumber];
    unsigned long long newInode = inode ? [inode unsignedLongLongValue] : 0;

    BOOL changed = NO;
    if (newInode != _lastInode) changed = YES;
    if (newSize != _lastFileSize) changed = YES;
    if (fabs(newMtime - _lastMtime) > 1.0) changed = YES;

    if (changed) {
        _lastFileSize = newSize;
        _lastInode = newInode;
        _lastMtime = newMtime;
        [self reloadMedia];
    }
}

- (void)reloadMedia {
    int64_t gen = __sync_add_and_fetch(&_reloadGeneration, 1);
    __weak typeof(self) weakSelf = self;
    NSString *path = _currentVideoPath;

    // 文件内容变化：asset/track 必须丢弃重建
    _reusableAsset = nil;
    _reusableTrack = nil;
    _assetPath = nil;

    dispatch_async(_processingQueue, ^{
        LocalVideoPlayer *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (gen != strongSelf.reloadGeneration) return;
        [strongSelf loadVideoAtPath:path completion:nil];
    });
}

@end
