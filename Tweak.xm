// RemoteCamTweak v4.1 - 修复编译错误
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
static BOOL g_isRunning = NO;

static void fetchRemoteFrame() {
    if (!g_isRunning) return;
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
                }
            }
        }];
    [task resume];
}

static void startRemoteReceiving() {
    if (g_isRunning) return;
    g_isRunning = YES;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    g_session = [NSURLSession sessionWithConfiguration:cfg];
    fetchRemoteFrame();
    g_pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        fetchRemoteFrame();
    }];
}

static CMSampleBufferRef CreateSampleBuffer(UIImage *image) {
    if (!image) return NULL;
    CGSize size = CGSizeMake(640, 480);
    UIGraphicsBeginImageContext(size);
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!resized) resized = image;
    CGImageRef cgImage = resized.CGImage;
    if (!cgImage) return NULL;
    size_t w = CGImageGetWidth(cgImage);
    size_t h = CGImageGetHeight(cgImage);
    CVPixelBufferRef pb = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, w, h, 
                                          kCVPixelFormatType_32BGRA, NULL, &pb);
    if (status != kCVReturnSuccess || !pb) return NULL;
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
    CMSampleTimingInfo timing = {.duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 600),
        .decodeTimeStamp = kCMTimeInvalid};
    OSStatus err = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fd, &timing, &sb);
    CVPixelBufferRelease(pb);
    if (fd) CFRelease(fd);
    return (err == noErr) ? sb : NULL;
}

// 正确的函数指针类型
static void (*orig_didOutputSampleBuffer)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) = NULL;
static void (*orig_setDelegate)(id, SEL, id, dispatch_queue_t) = NULL;

static void my_didOutputSampleBuffer(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
    UIImage *remoteImg = nil;
    BOOL hasRemote = NO;
    @synchronized(g_remoteFrame) {
        remoteImg = g_remoteFrame;
        if (remoteImg && g_lastFrameTime && -[g_lastFrameTime timeIntervalSinceNow] < 3.0) {
            hasRemote = YES;
        }
    }
    if (hasRemote) {
        CMSampleBufferRef remoteSB = CreateSampleBuffer(remoteImg);
        if (remoteSB) {
            LOG(@"替换帧");
            orig_didOutputSampleBuffer(self, _cmd, output, remoteSB, connection);
            CFRelease(remoteSB);
            return;
        }
    }
    orig_didOutputSampleBuffer(self, _cmd, output, sampleBuffer, connection);
}

static void my_setDelegate(id self, SEL _cmd, id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate, dispatch_queue_t queue) {
    LOG(@"Hook setSampleBufferDelegate: %@", NSStringFromClass([delegate class]));
    startRemoteReceiving();
    if (delegate) {
        Class delegateClass = [delegate class];
        SEL selector = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        Method origMethod = class_getInstanceMethod(delegateClass, selector);
        if (origMethod) {
            // 修复：使用正确的类型转换
            orig_didOutputSampleBuffer = (void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))method_getImplementation(origMethod);
            method_setImplementation(origMethod, (IMP)my_didOutputSampleBuffer);
            LOG(@"已Hook delegate");
        }
    }
    orig_setDelegate(self, _cmd, delegate, queue);
}

%ctor {
    LOG(@"RemoteCamTweak v4.1 加载");
    Class cls = objc_getClass("AVCaptureVideoDataOutput");
    if (cls) {
        SEL selector = @selector(setSampleBufferDelegate:queue:);
        Method origMethod = class_getInstanceMethod(cls, selector);
        if (origMethod) {
            // 修复：使用正确的类型转换
            orig_setDelegate = (void (*)(id, SEL, id, dispatch_queue_t))method_getImplementation(origMethod);
            method_setImplementation(origMethod, (IMP)my_setDelegate);
            LOG(@"已Hook AVCaptureVideoDataOutput");
        }
    }
}

%dtor {
    g_isRunning = NO;
    [g_pollTimer invalidate];
}
