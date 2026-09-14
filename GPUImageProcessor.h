//
//  GPUImageProcessor.h
//  图像处理器（旋转/镜像/格式转换/用户变换）
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@interface GPUImageProcessor : NSObject

// 旋转/镜像状态
@property (nonatomic, assign) int rotationAngle;   // 0/90/180/270 用户手动
@property (nonatomic, assign) int sourceRotation;  // 视频自带旋转
@property (nonatomic, assign) BOOL mirrored;
@property (nonatomic, readonly) BOOL rotationApiAvailable;

// 用户画面变换（缩放/平移）
@property (nonatomic, assign) double userPanX;
@property (nonatomic, assign) double userPanY;
@property (nonatomic, assign) double userZoom;

// 帧代数
@property (nonatomic, assign) uint64_t frameToken;

// 核心处理
- (CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)input
                                toWidth:(size_t)width
                                height:(size_t)height
                                format:(OSType)format CF_RETURNS_RETAINED;

- (CVPixelBufferRef)scaleToBGRA:(CVPixelBufferRef)input
                          width:(size_t)width
                         height:(size_t)height CF_RETURNS_RETAINED;

- (CVPixelBufferRef)rotateAndMirrorIfNeeded:(CVPixelBufferRef)input CF_RETURNS_RETAINED;

- (CVPixelBufferRef)bakeUserTransformIntoCanvas:(CVPixelBufferRef)input CF_RETURNS_RETAINED;

- (CVPixelBufferRef)convertFormat:(CVPixelBufferRef)input toFormat:(OSType)format CF_RETURNS_RETAINED;

- (BOOL)renderCropFill:(CVPixelBufferRef)input toPixelBuffer:(CVPixelBufferRef)dst;

- (CVPixelBufferRef)adaptiveRotateIfNeeded:(CVPixelBufferRef)src
                               targetWidth:(size_t)targetW
                              targetHeight:(size_t)targetH
                                     token:(uint64_t)token CF_RETURNS_RETAINED;

- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst;
- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst token:(uint64_t)token;

- (CVPixelBufferRef)getOrCreateBGRABufferWithWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED;

- (void)configureWithWidth:(size_t)width height:(size_t)height format:(OSType)format;

- (NSUInteger)activeStreamKeyCount;
- (NSString *)takeStreamStats;

- (void)releaseIdleMemory;
- (void)releaseHeavyBuffersForIdle;

@end
