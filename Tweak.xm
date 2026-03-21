// RemoteCamTweak - SE2 远程摄像头注入

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>

#define LOG(fmt, ...) NSLog(@"[RemoteCam] " fmt, ##__VA_ARGS__)
#define SERVER_URL @"http://103.140.229.54:3000"

static UIImage *g_remoteFrame = nil;
static NSURLSession *g_session = nil;
static NSTimer *g_pollTimer = nil;
static BOOL g_isActive = NO;

static void fetchRemoteFrame() {
    if (!g_isActive) return;
    NSString *urlString = [NSString stringWithFormat:@"%@/frame", SERVER_URL];
    NSURL *url = [NSURL URLWithString:urlString];
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    NSURLSessionDataTask *task = [g_session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error || !data) return;
            UIImage *image = [UIImage imageWithData:data];
            if (image) g_remoteFrame = image;
        }];
    [task resume];
}

static void startRemoteReceiving() {
    if (g_isActive) return;
    LOG("启动远程视频接收");
    g_isActive = YES;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    g_session = [NSURLSession sessionWithConfiguration:config];
    g_pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
        target:[NSBlockOperation blockOperationWithBlock:^{ fetchRemoteFrame(); }]
        selector:@selector(main) userInfo:nil repeats:YES];
}

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    LOG("设置视频代理");
    startRemoteReceiving();
    %orig(delegate, queue);
}

%end

%ctor {
    LOG("========================================");
    LOG("RemoteCamTweak 已加载 - 服务器: %@", SERVER_URL);
    LOG("========================================");
}
