#import "AudioManager.h"
#import "AudioProcessingAdapter.h"

@implementation AudioManager {
  RTCDefaultAudioProcessingModule* _audioProcessingModule;
  AudioProcessingAdapter* _capturePostProcessingAdapter;
  AudioProcessingAdapter* _renderPreProcessingAdapter;
  id<ExternalAudioProcessingDelegate> _externalAudioProcessor;
  BOOL _noiseCancellationEnabled;
}

@synthesize capturePostProcessingAdapter = _capturePostProcessingAdapter;
@synthesize renderPreProcessingAdapter = _renderPreProcessingAdapter;
@synthesize audioProcessingModule = _audioProcessingModule;

+ (instancetype)sharedInstance {
  static dispatch_once_t onceToken;
  static AudioManager* sharedInstance = nil;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });
  return sharedInstance;
}

- (instancetype)init {
  if (self = [super init]) {
    _audioProcessingModule = [[RTCDefaultAudioProcessingModule alloc] init];
    _capturePostProcessingAdapter = [[AudioProcessingAdapter alloc] init];
    _renderPreProcessingAdapter = [[AudioProcessingAdapter alloc] init];
    _audioProcessingModule.capturePostProcessingDelegate = _capturePostProcessingAdapter;
    _audioProcessingModule.renderPreProcessingDelegate = _renderPreProcessingAdapter;
  }
  return self;
}

- (void)setExternalAudioProcessor:(nullable id<ExternalAudioProcessingDelegate>)processor {
  // Remove old processor if one was previously registered
  if (_externalAudioProcessor) {
    [_capturePostProcessingAdapter removeProcessing:_externalAudioProcessor];
  }

  _externalAudioProcessor = processor;

  // If currently enabled, register the new processor immediately
  if (_externalAudioProcessor && _noiseCancellationEnabled) {
    [_capturePostProcessingAdapter addProcessing:_externalAudioProcessor];
  }
}

- (void)setNoiseCancellationEnabled:(BOOL)noiseCancellationEnabled {
  _noiseCancellationEnabled = noiseCancellationEnabled;
  if (_externalAudioProcessor) {
    if (noiseCancellationEnabled) {
      [_capturePostProcessingAdapter addProcessing:_externalAudioProcessor];
    } else {
      [_capturePostProcessingAdapter removeProcessing:_externalAudioProcessor];
    }
  }
}

- (BOOL)noiseCancellationEnabled {
  return _noiseCancellationEnabled;
}

- (void)addLocalAudioRenderer:(nonnull id<RTCAudioRenderer>)renderer {
  [_capturePostProcessingAdapter addAudioRenderer:renderer];
}

- (void)removeLocalAudioRenderer:(nonnull id<RTCAudioRenderer>)renderer {
  [_capturePostProcessingAdapter removeAudioRenderer:renderer];
}

- (void)addRemoteAudioSink:(nonnull id<RTCAudioRenderer>)sink {
  [_renderPreProcessingAdapter addAudioRenderer:sink];
}

- (void)removeRemoteAudioSink:(nonnull id<RTCAudioRenderer>)sink {
  [_renderPreProcessingAdapter removeAudioRenderer:sink];
}

@end