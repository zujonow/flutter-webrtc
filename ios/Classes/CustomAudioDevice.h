//
//  CustomAudioDevice.h
//  Pods
//
//  Created by Pavan Faldu on 04/08/25.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WebRTC/RTCAudioDevice.h"

NS_ASSUME_NONNULL_BEGIN

@interface CustomAudioDevice : NSObject <RTCAudioDevice>

+ (instancetype)sharedInstance;

- (void)handleBroadcastAudioData:(NSData *)audioData withDescription:(AudioStreamBasicDescription)description;
- (void)setScreenShareAudioEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
