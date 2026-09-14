//
//  LocalVideoPlayer.h
//  视频播放器（AVAssetReader 解码 + 帧队列 + 循环播放）
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import "NSQueue.h"
#import "GPUImageProcessor.h"

typedef NS_ENUM(NSInteger, VCamMediaType) {
    VCamMediaTypeUnknown = 0,
    VCamMediaTypeVideo   = 1,
    VCamMediaTypeImage   = 2,
};

@interface LocalVideoPlayer : NSObject

// AVAssetReader 相关
@property (nonatomic, strong) AVAssetReaderTrackOutput *videoOutput;
@property (nonatomic, strong) AVAssetTrack *videoTrack;
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, copy) NSString *currentVideoPath;

// 帧队列
@property (nonatomic, strong) NSQueue *frameQueue;

// dispatch_queue
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, strong) dispatch_queue_t processingQueue;

// 状态
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) BOOL preprocessEnabled;
@property (nonatomic, assign) BOOL isDecoding;
@property (nonatomic, assign) BOOL paused;
@property (nonatomic, assign) BOOL lowPowerDecode;
@property (nonatomic, assign) size_t dynamicMaxEdge;

// 输出尺寸/格式
@property (nonatomic, assign) size_t outputWidth;
@property (nonatomic, assign) size_t outputHeight;
@property (nonatomic, assign) OSType outputFormat;

// 缓存
@property (nonatomic, assign) size_t cachedBGRAWidth;
@property (nonatomic, assign) size_t cachedBGRAHeight;
@property (nonatomic, assign) size_t lastRenderedWidth;
@property (nonatomic, assign) size_t lastRenderedHeight;
@property (nonatomic, assign) uint64_t lastProcessedBufferID;
@property (nonatomic, assign) uint64_t lastProcessTime;
@property (nonatomic, assign) uint64_t frameCount;

// 帧定时器
@property (nonatomic, strong) dispatch_source_t frameTimer;

// 预处理
@property (nonatomic, strong) CIContext *preprocessContext;
@property (nonatomic, strong) GPUImageProcessor *gpuProcessor;

// 视频信息
@property (nonatomic, assign) CGFloat videoFps;
@property (nonatomic, readonly) CGFloat effectiveFps;
@property (nonatomic, assign) CGFloat videoDuration;
@property (nonatomic, assign) size_t videoWidth;
@property (nonatomic, assign) size_t videoHeight;
@property (nonatomic, assign) VCamMediaType mediaType;
@property (nonatomic, assign) int preferredRotation;

// 图片缓存
@property (nonatomic, assign) CVPixelBufferRef cachedImageBuffer;

// 初始化
- (instancetype)initWithCapacity:(NSUInteger)capacity;

// 视频加载
- (void)loadVideoAtPath:(NSString *)path completion:(void(^)(BOOL success, NSError *error))completion;

// 解码控制
- (void)startDecodingThread;
- (void)stopDecodingThread;

// 空闲卸载
- (void)unloadForIdle;
- (void)resetPlaybackPosition;

// 帧获取
- (CVPixelBufferRef)getCurrentFrame;
- (CVPixelBufferRef)copyCurrentFrame CF_RETURNS_RETAINED;

// 帧队列管理
- (void)clearFrameQueue;

// 文件监听
- (void)startWatchingFile:(NSString *)path;
- (void)stopWatchingFile;

// 媒体类型检测
+ (VCamMediaType)detectMediaType:(NSString *)path;

@end
