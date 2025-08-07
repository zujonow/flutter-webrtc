//
//  FlutterBroadcastScreenCapturer.m
//  RCTWebRTC
//
//  Created by Alex-Dan Bumbu on 06/01/2021.
//

#import "FlutterBroadcastScreenCapturer.h"
#import "FlutterSocketConnection.h"
#import "FlutterSocketConnectionFrameReader.h"

NSString* const kRTCAppGroupIdentifier = @"RTCAppGroupIdentifier";
NSString* const kRTCScreenSharingExtension = @"RTCScreenSharingExtension";
NSString *const kRTCScreensharingVideoSocketFD = @"rtc_SSFD_video";
NSString *const kRTCScreensharingAudioSocketFD = @"rtc_SSFD_audio";

@interface FlutterBroadcastScreenCapturer ()

@property(nonatomic, retain) FlutterSocketConnectionFrameReader* capturer;

@end

@interface FlutterBroadcastScreenCapturer (Private)

@property(nonatomic, readonly) NSString* appGroupIdentifier;

@end

@implementation FlutterBroadcastScreenCapturer

- (void)startCapture {
    if (!self.appGroupIdentifier) {
        return;
    }
    
    NSString *videoSocketFilePath = [self filePathForApplicationGroupIdentifier:self.appGroupIdentifier
                                                                     socketType:@"video"];
    FlutterSocketConnection *videoConnection = [[FlutterSocketConnection alloc] initWithFilePath:videoSocketFilePath];
    
    NSString *audioSocketFilePath = [self filePathForApplicationGroupIdentifier:self.appGroupIdentifier
                                              
                                                                     socketType:@"audio"];
    
    FlutterSocketConnectionFrameReader* frameReader =
        [[FlutterSocketConnectionFrameReader alloc] initWithDelegate:self.delegate];

    
    FlutterSocketConnection *audioConnection = [[FlutterSocketConnection alloc] initWithFilePath:audioSocketFilePath];
    self.capturer = frameReader;
    
    [self.capturer startCaptureWithVideoConnection:videoConnection
                                     audioConnection:audioConnection];
    
}

- (void)stopCapture {
  [self.capturer stopCapture];
}
- (void)stopCaptureWithCompletionHandler:(nullable void (^)(void))completionHandler {
  [self stopCapture];
  if (completionHandler != nil) {
    completionHandler();
  }
}
// MARK: Private Methods

- (NSString *)appGroupIdentifier {
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    return infoDictionary[kRTCAppGroupIdentifier];
}


- (NSString *)filePathForApplicationGroupIdentifier:(nonnull NSString *)identifier
                                        socketType:(NSString *)socketType {
    NSURL *sharedContainer =
        [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:identifier];
    
    NSString *socketSuffix = [socketType isEqualToString:@"video"] ?
                            kRTCScreensharingVideoSocketFD :
                            kRTCScreensharingAudioSocketFD;
    
    NSString *socketFilePath = [[sharedContainer URLByAppendingPathComponent:socketSuffix] path];
    
    return socketFilePath;
}

@end
