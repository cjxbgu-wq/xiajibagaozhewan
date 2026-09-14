//
//  NSQueue.h
//  线程安全帧队列（PixelBuffer / SampleBuffer 双模式）
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

@interface NSQueue : NSObject

@property (nonatomic, assign) BOOL isPixelBufferMode;
@property (nonatomic, readonly) NSUInteger count;
@property (nonatomic, readonly) NSUInteger capacity;

- (instancetype)initWithCapacity:(NSUInteger)capacity pixelBufferMode:(BOOL)pixelBufferMode;

- (void)enqueuePixelBuffer:(CVPixelBufferRef)buffer;
- (CVPixelBufferRef)dequeuePixelBuffer CF_RETURNS_RETAINED;
- (CVPixelBufferRef)peekPixelBuffer;
- (CVPixelBufferRef)copyCurrentFrame CF_RETURNS_RETAINED;
- (CVPixelBufferRef)getCurrentFrame;

- (void)enqueueSampleBuffer:(CMSampleBufferRef)buffer;
- (CMSampleBufferRef)dequeueSampleBuffer CF_RETURNS_RETAINED;

- (void)clearFrameQueue;

@end
