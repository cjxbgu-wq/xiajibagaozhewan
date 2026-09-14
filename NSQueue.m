//
//  NSQueue.m
//  帧队列（NSRecursiveLock 保护 + currentFrame 缓存）
//

#import "NSQueue.h"

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

static volatile int32_t vcamQueueLogCount = 0;
static void vcam_queue_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    if (!vcam_log_budget_take()) return;
    int32_t n = __sync_add_and_fetch(&vcamQueueLogCount, 1);
    if (n > 50) return;
    @try {
        NSString *logPath = @"/tmp/vcam_queue_log.txt";
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

@interface NSQueue ()
@property (nonatomic, strong) NSRecursiveLock *bufferLock;
@property (nonatomic, strong) NSMutableArray *pixelBuffers;
@property (nonatomic, strong) NSMutableArray *sampleBuffers;
@property (nonatomic, assign) NSUInteger capacity;
@property (nonatomic, assign) CVPixelBufferRef currentPixelBuffer;
@property (nonatomic, assign) CMSampleBufferRef currentSampleBuffer;
@end

@implementation NSQueue

- (instancetype)initWithCapacity:(NSUInteger)capacity pixelBufferMode:(BOOL)pixelBufferMode {
    self = [super init];
    if (self) {
        _capacity = capacity;
        _isPixelBufferMode = pixelBufferMode;
        _bufferLock = [[NSRecursiveLock alloc] init];
        _pixelBuffers = [[NSMutableArray alloc] init];
        _sampleBuffers = [[NSMutableArray alloc] init];
        _currentPixelBuffer = NULL;
        _currentSampleBuffer = NULL;
    }
    return self;
}

- (void)dealloc {
    [self clearFrameQueue];
}

- (NSUInteger)count {
    [_bufferLock lock];
    NSUInteger c = _isPixelBufferMode ? _pixelBuffers.count : _sampleBuffers.count;
    [_bufferLock unlock];
    return c;
}

- (void)enqueuePixelBuffer:(CVPixelBufferRef)buffer {
    if (!buffer) return;
    [_bufferLock lock];
    [_pixelBuffers addObject:(__bridge id)buffer];
    while (_pixelBuffers.count > _capacity) {
        [_pixelBuffers removeObjectAtIndex:0];
    }
    if (_currentPixelBuffer) CVPixelBufferRelease(_currentPixelBuffer);
    _currentPixelBuffer = buffer;
    CVPixelBufferRetain(_currentPixelBuffer);
    [_bufferLock unlock];
}

- (CVPixelBufferRef)dequeuePixelBuffer CF_RETURNS_RETAINED {
    [_bufferLock lock];
    CVPixelBufferRef buffer = NULL;
    if (_pixelBuffers.count > 0) {
        buffer = (__bridge CVPixelBufferRef)_pixelBuffers[0];
        CVPixelBufferRetain(buffer);
        [_pixelBuffers removeObjectAtIndex:0];
    }
    [_bufferLock unlock];
    return buffer;
}

- (CVPixelBufferRef)peekPixelBuffer {
    [_bufferLock lock];
    CVPixelBufferRef buffer = NULL;
    if (_pixelBuffers.count > 0) buffer = (__bridge CVPixelBufferRef)_pixelBuffers[0];
    [_bufferLock unlock];
    return buffer;
}

- (CVPixelBufferRef)copyCurrentFrame CF_RETURNS_RETAINED {
    [_bufferLock lock];
    CVPixelBufferRef buffer = NULL;
    if (_currentPixelBuffer) {
        buffer = _currentPixelBuffer;
        CVPixelBufferRetain(buffer);
    }
    [_bufferLock unlock];
    return buffer;
}

- (CVPixelBufferRef)getCurrentFrame {
    return _currentPixelBuffer;
}

- (void)enqueueSampleBuffer:(CMSampleBufferRef)buffer {
    if (!buffer) return;
    [_bufferLock lock];
    [_sampleBuffers addObject:(__bridge id)buffer];
    while (_sampleBuffers.count > _capacity) {
        [_sampleBuffers removeObjectAtIndex:0];
    }
    if (_currentSampleBuffer) CFRelease(_currentSampleBuffer);
    _currentSampleBuffer = buffer;
    CFRetain(_currentSampleBuffer);
    [_bufferLock unlock];
}

- (CMSampleBufferRef)dequeueSampleBuffer CF_RETURNS_RETAINED {
    [_bufferLock lock];
    CMSampleBufferRef buffer = NULL;
    if (_sampleBuffers.count > 0) {
        buffer = (__bridge CMSampleBufferRef)_sampleBuffers[0];
        CFRetain(buffer);
        [_sampleBuffers removeObjectAtIndex:0];
    }
    [_bufferLock unlock];
    return buffer;
}

- (void)clearFrameQueue {
    [_bufferLock lock];
    [_pixelBuffers removeAllObjects];
    [_sampleBuffers removeAllObjects];
    if (_currentPixelBuffer) {
        CVPixelBufferRelease(_currentPixelBuffer);
        _currentPixelBuffer = NULL;
    }
    if (_currentSampleBuffer) {
        CFRelease(_currentSampleBuffer);
        _currentSampleBuffer = NULL;
    }
    [_bufferLock unlock];
}

@end
