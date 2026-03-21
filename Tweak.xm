// RemoteCamTweak - SE2 远程摄像头注入
// HTTP 轮询方案

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>

#define LOG(fmt, ...) NSLog(@"[RemoteCam] " fmt, ##__VA_ARGS__)
#define SERVER_URL @"http://103.140.229.54:3000"

@interface RemoteVideoSource : NSObject
@property (nonatomic, strong) NSMutableData *frameBuffer;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) UIImage *currentFrame;
+ (instancetype)sharedInstance;
- (void)startReceiving;
- (void)stopReceiving;
@end

@implementation RemoteVideoSource

+ (instancetype)sharedInstance {
static RemoteVideoSource *instance = nil;
static dispatch_once_t onceToken;
dispatch_once(&onceToken, ^{
instance = [[self alloc] init];
});
return instance;
}

- (instancetype)init {
self = [super init];
if (self) {
_frameBuffer = [NSMutableData data];
_isActive = NO;
NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
config.timeoutIntervalForRequest = 10;
_session = [NSURLSession sessionWithConfiguration:config];
}
return self;
}

- (void)startReceiving {
if (self.isActive) return;
LOG("启动远程视频接收");
self.isActive = YES;
self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
target:self
selector:@selector(fetchFrame)
userInfo:nil
repeats:YES];
}

- (void)stopReceiving {
LOG("停止远程视频接收");
self.isActive = NO;
[self.pollTimer invalidate];
self.pollTimer = nil;
}

- (void)fetchFrame {
if (!self.isActive) return;
NSString *urlString = [NSString stringWithFormat:@"%@/frame", SERVER_URL];
NSURL *url = [NSURL URLWithString:urlString];
NSURLRequest *request = [NSURLRequest requestWithURL:url];
NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
if (error) return;
if (data.length > 0) {
UIImage *image = [UIImage imageWithData:data];
if (image) self.currentFrame = image;
}
}];
[task resume];
}

- (CMSampleBufferRef)createSampleBufferFromImage:(UIImage *)image {
if (!image) return NULL;
CGSize size = image.size;
NSDictionary *options = @{
(NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
(NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
};
CVPixelBufferRef pixelBuffer = NULL;
CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height,
kCVPixelFormatType_32BGRA,
(__bridge CFDictionaryRef)options, &pixelBuffer);
if (status != kCVReturnSuccess || !pixelBuffer) return NULL;

CVPixelBufferLockBaseAddress(pixelBuffer, 0);
void *pixelData = CVPixelBufferGetBaseAddress(pixelBuffer);
CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
CGContextRef context = CGBitmapContextCreate(pixelData, size.width, size.height, 8,
CVPixelBufferGetBytesPerRow(pixelBuffer),
rgbColorSpace,
kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), image.CGImage);
CGContextRelease(context);
CGColorSpaceRelease(rgbColorSpace);
CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

CMSampleBufferRef sampleBuffer = NULL;
CMFormatDescriptionRef formatDescription = NULL;
CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
CMSampleTimingInfo timingInfo = {
.duration = CMTimeMake(1, 30),
.presentationTimeStamp = CMTimeMake(CACurrentMediaTime() * 30, 30),
.decodeTimeStamp = kCMTimeInvalid
};
CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, formatDescription, &timingInfo, &sampleBuffer);
CVPixelBufferRelease(pixelBuffer);
if (formatDescription) CFRelease(formatDescription);
return sampleBuffer;
}

@end

static BOOL g_isRemoteMode = YES;

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
LOG("设置视频缓冲区代理");
objc_setAssociatedObject(self, @selector(originalDelegate), delegate, OBJC_ASSOCIATION_RETAIN);
objc_setAssociatedObject(self, @selector(callbackQueue), queue, OBJC_ASSOCIATION_RETAIN);
[[RemoteVideoSource sharedInstance] startReceiving];
%orig(delegate, queue);
}

%end

%hookf(void, "captureOutput:didOutputSampleBuffer:fromConnection:", id self, SEL _cmd, id output, CMSampleBufferRef sampleBuffer, id connection) {
id originalDelegate = objc_getAssociatedObject(output, @selector(originalDelegate));
if (g_isRemoteMode) {
UIImage *remoteFrame = [RemoteVideoSource sharedInstance].currentFrame;
if (remoteFrame) {
CMSampleBufferRef remoteBuffer = [[RemoteVideoSource sharedInstance] createSampleBufferFromImage:remoteFrame];
if (remoteBuffer) {
if (originalDelegate) {
[originalDelegate captureOutput:output didOutputSampleBuffer:remoteBuffer fromConnection:connection];
}
CFRelease(remoteBuffer);
return;
}
}
}
if (originalDelegate) {
[originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
}
}

%hook AVCaptureDevice

+ (NSArray *)devicesWithMediaType:(NSString *)mediaType {
NSArray *devices = %orig(mediaType);
LOG("查询视频设备，返回 %lu 个", (unsigned long)devices.count);
return devices;
}

%end

static void checkForKuaishou() {
NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
if ([bundleID containsString:@"kuaishou"] || [bundleID containsString:@"Kwai"]) {
LOG("*** 检测到快手 APP: %@ ***", bundleID);
g_isRemoteMode = YES;
}
}

%ctor {
LOG("========================================");
LOG("RemoteCamTweak 已加载 - 服务器: %@", SERVER_URL);
LOG("========================================");
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
dispatch_get_main_queue(), ^{ checkForKuaishou(); });
[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
object:nil queue:nil
usingBlock:^(NSNotification *note) { checkForKuaishou(); }];
}

%dtor {
LOG("RemoteCamTweak 已卸载");
[[RemoteVideoSource sharedInstance] stopReceiving];
}