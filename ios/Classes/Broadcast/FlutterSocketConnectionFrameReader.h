//
//  FlutterSocketConnectionFrameReader.h
//  RCTWebRTC
//
//  Created by Alex-Dan Bumbu on 06/01/2021.
//

#import <AVFoundation/AVFoundation.h>
#import <WebRTC/RTCVideoCapturer.h>
#import "FlutterSocketConnection.h"

NS_ASSUME_NONNULL_BEGIN

@class FlutterSocketConnection;

@protocol ScreenCapturerDelegate <NSObject>
- (void)capturerDidEnd:(RTCVideoCapturer *)capturer;
@end

@interface FlutterSocketConnectionFrameReader : RTCVideoCapturer

@property(nonatomic, weak) id<ScreenCapturerDelegate> eventsDelegate;

- (instancetype)initWithDelegate:(__weak id<RTCVideoCapturerDelegate>)delegate;
- (void)startCaptureWithVideoConnection:(FlutterSocketConnection *)videoConnection
                        audioConnection:(FlutterSocketConnection *)audioConnection;
- (void)stopCapture;

@end

NS_ASSUME_NONNULL_END
