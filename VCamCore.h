//
//  VCamCore.h
//  核心渲染逻辑（视频替换相机画面的总指挥）
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "LocalVideoPlayer.h"
#import "GPUImageProcessor.h"
#import "VCamNotify.h"

@interface VCamCore : NSObject

// 组件
@property (nonatomic, strong) LocalVideoPlayer *videoPlayer;
@property (nonatomic, strong) GPUImageProcessor *gpuProcessor;
@property (nonatomic, strong) NSQueue *frameQueue;

// 双格式预渲染缓冲
@property (nonatomic, assign) CVPixelBufferRef liveBGRAPixelBuffer;
@property (nonatomic, assign) CVPixelBufferRef liveYUVPixelBuffer;

// 格式状态（诊断用）
@property (nonatomic, assign) BOOL targetSizeKnown;
@property (nonatomic, assign) size_t targetWidth;
@property (nonatomic, assign) size_t targetHeight;
@property (nonatomic, assign) OSType targetFormat;

// 缓存
@property (nonatomic, assign) size_t lastRenderedWidth;
@property (nonatomic, assign) size_t lastRenderedHeight;
@property (nonatomic, assign) uint64_t frameCount;

// 状态
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, strong) dispatch_queue_t prerenderQueue;
@property (nonatomic, strong) dispatch_queue_t processingQueue;
@property (nonatomic, strong) NSLock *processLock;
@property (nonatomic, strong) CIContext *ciContext;

// 预处理
@property (nonatomic, assign) BOOL isPixelBufferMode;
@property (nonatomic, assign) BOOL preprocessEnabled;

+ (instancetype)sharedInstance;

#pragma mark - 核心方法（Hook 函数调用）
- (void)renderReplacementToPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)renderReplacementToPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(double)pts;
- (BOOL)hasReplacementFrame;
- (void)clearReplacementFrame;
- (void)cacheLastRenderedFrame:(CVPixelBufferRef)buffer width:(size_t)width height:(size_t)height;
- (BOOL)isPrivateFormat:(OSType)format;

#pragma mark - 状态控制
- (void)setEnabled:(BOOL)enabled;
- (void)startStatePolling;
- (void)stopStatePolling;

#pragma mark - 初始化
- (void)initializeInMediaserverd;
- (void)initializeInSpringBoard;

#pragma mark - 预渲染线程
- (void)startPrerenderThread;
- (void)stopPrerenderThread;

@end
