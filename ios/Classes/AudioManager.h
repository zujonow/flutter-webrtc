#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
#import "AudioProcessingAdapter.h"

@protocol ExternalAudioProcessingDelegate;

@interface AudioManager : NSObject

@property(nonatomic, strong) RTCDefaultAudioProcessingModule* _Nonnull audioProcessingModule;

@property(nonatomic, strong) AudioProcessingAdapter* _Nonnull capturePostProcessingAdapter;

@property(nonatomic, strong) AudioProcessingAdapter* _Nonnull renderPreProcessingAdapter;

/// When YES, the registered external processor will process mic audio.
@property(nonatomic, assign) BOOL noiseCancellationEnabled;

/// Register an external audio processor (e.g. from noise_cancellation_plugin).
- (void)setExternalAudioProcessor:(nullable id<ExternalAudioProcessingDelegate>)processor;

+ (_Nonnull instancetype)sharedInstance;

- (void)addLocalAudioRenderer:(nonnull id<RTCAudioRenderer>)renderer;

- (void)removeLocalAudioRenderer:(nonnull id<RTCAudioRenderer>)renderer;

- (void)addRemoteAudioSink:(nonnull id<RTCAudioRenderer>)sink;

- (void)removeRemoteAudioSink:(nonnull id<RTCAudioRenderer>)sink;

@end

