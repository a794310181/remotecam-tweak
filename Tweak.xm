// RemoteCamTweak - 修复版
// 关键：Hook didOutputSampleBuffer 并替换帧

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>

#define LOG(fmt, ...) NSLog(@"[RemoteCam] " fmt, ##__VA_ARGS__)

static NSString *const kServerURL = @"http://103.140.229.54:3000";
static UIImage *g_remoteFrame = nil;
static NSDate *g_lastFrameTime = nil;
static NSURLSession *g_session = nil;
static NSTimer *g_pollTimer = nil;

// 原始代理
static id<AVCaptureVideoDataOutputSampleBufferDelegate> g_origDelegate = nil;
static dispatch_queue_t g_origQueue = NULL;

// ============ 获取远程帧 ============
static void fetchRemoteFrame() {
NSString *url = [NSString stringWithFormat:@"%@/frame", kServerURL];
NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:url]
cachePolicy:NSURLRequestReloadIgnoringCacheData
timeoutInterval:2.0];

NSURLSessionDataTask *task = [g_session dataTaskWithRequest:req
completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
if (!error && data && data.length > 100) {
UIImage *img = [UIImage imageWithData:data];
if (img) {
@synchronized(g_remoteFrame) {
g_remoteFrame = img;
g_lastFrameTime = [NSDate date];
}
LOG(@"收到帧: %.0fx%.0f", img.size.width, img.size.height);
}
}
}];
[task resume];
}

// ============ 启动远程接收 ============
static void startRemoteReceiving() {
if (g_pollTimer) return;

LOG(@"*** 启动远程视频接收 ***");

NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
cfg.timeoutIntervalForRequest = 3.0;
g_session = [NSURLSession sessionWithConfiguration:cfg];

fetchRemoteFrame();

g_pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
target:[NSBlockOperation blockOperationWithBlock:^{
fetchRemoteFrame();
}]
selector:@selector(main)
userInfo:nil
repeats:YES];
}

// ============ 图片转 SampleBuffer ============
static CMSampleBufferRef CreateSampleBufferFromImage(UIImage *image) {
if (!image) return NULL;

CGSize size = CGSizeMake(640, 480);
UIGraphicsBeginImageContext(size);
[image drawInRect:CGRectMake(0, 0, size.width, size.height)];
UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
UIGraphicsEndImageContext();

if (!resized) return NULL;

CGImageRef cgImage = resized.CGImage;
if (!cgImage) return NULL;

size_t w = CGImageGetWidth(cgImage);
size_t h = CGImageGetHeight(cgImage);

CVPixelBufferRef pb = NULL;
CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, NULL, &pb);
if (!pb) return NULL;

CVPixelBufferLockBaseAddress(pb, 0);
void *pxdata = CVPixelBufferGetBaseAddress(pb);

CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
CGContextRef ctx = CGBitmapContextCreate(pxdata, w, h, 8,
CVPixelBufferGetBytesPerRow(pb),
cs,
kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImage);
CGContextRelease(ctx);
CGColorSpaceRelease(cs);
CVPixelBufferUnlockBaseAddress(pb, 0);

CMSampleBufferRef sb = NULL;
CMFormatDescriptionRef fd = NULL;
CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fd);

CMSampleTimingInfo timing = {
.duration = CMTimeMake(1, 30),
.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000),
.decodeTimeStamp = kCMTimeInvalid
};

OSStatus err = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fd, &timing, &sb);

CVPixelBufferRelease(pb);
if (fd) CFRelease(fd);

return (err == noErr) ? sb : NULL;
}

// ============ 代理对象（关键！） ============
@interface RemoteCamProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation RemoteCamProxy

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
fromConnection:(AVCaptureConnection *)connection {

CMSampleBufferRef outputBuffer = sampleBuffer;
BOOL needRelease = NO;

// 获取远程帧
UIImage *remoteImg = nil;
@synchronized(g_remoteFrame) {
remoteImg = g_remoteFrame;
// 检查是否过期（3秒）
if (g_lastFrameTime && -[g_lastFrameTime timeIntervalSinceNow] > 3.0) {
remoteImg = nil;
}
}

// 有远程帧就替换
if (remoteImg) {
CMSampleBufferRef remoteSB = CreateSampleBufferFromImage(remoteImg);
if (remoteSB) {
outputBuffer = remoteSB;
needRelease = YES;
LOG(@"✓ 替换为远程帧");
}
} else {
LOG(@"✗ 无远程帧，用原帧");
}

// 调用原始代理
if (g_origDelegate && [g_origDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
[g_origDelegate captureOutput:output didOutputSampleBuffer:outputBuffer fromConnection:connection];
}

if (needRelease && outputBuffer) {
CFRelease(outputBuffer);
}
}

- (void)captureOutput:(AVCaptureOutput *)output
didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
fromConnection:(AVCaptureConnection *)connection {
if (g_origDelegate && [g_origDelegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
[g_origDelegate captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
}
}

@end

static RemoteCamProxy *g_proxy = nil;

// ============ HOOK ============
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
queue:(dispatch_queue_t)queue {

LOG(@"========================================");
LOG(@"Hook setSampleBufferDelegate");
LOG(@"原始代理: %@", NSStringFromClass([delegate class]));
LOG(@"========================================");

g_origDelegate = delegate;
g_origQueue = queue;

if (!g_proxy) {
g_proxy = [[RemoteCamProxy alloc] init];
}

// 启动远程接收
startRemoteReceiving();

// 用自己的代理替换
%orig(g_proxy, queue);

LOG(@"代理替换完成");
}

%end

%ctor {
LOG(@"========================================");
LOG(@"RemoteCamTweak 已加载");
LOG(@"服务器: %@", kServerURL);
LOG(@"========================================");
}

%dtor {
LOG(@"RemoteCamTweak 卸载");
[g_pollTimer invalidate];
}
