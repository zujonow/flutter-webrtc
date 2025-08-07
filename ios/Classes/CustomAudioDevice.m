//
//  CustomAudioDevice.m
//  videosdk_webrtc
//
//  Created by Pavan Faldu on 04/08/25.
//

#import "CustomAudioDevice.h"
#import <AVFoundation/AVFoundation.h>
#import "WebRTC/WebRTC.h"
#import "AudioConfig.h"


const int kMaxRingBufferSize = 16384;

@interface CustomAudioDevice () {
    id<RTCAudioDeviceDelegate> _Nullable _deviceDelegate;

    AVAudioEngine *_engine;
    AVAudioSourceNode *_screenShareAudioSourceNode;
    AVAudioSourceNode *_playoutSourceNode;
    AVAudioSinkNode *_recordingSinkNode;
    AVAudioMixerNode *_recordingMixerNode;
    
    AVAudioFormat *_clientFormat;
    AVAudioFormat *_webRTCRecordingFormat;
    AVAudioConverter *_recordingConverter;

    AVAudioPCMBuffer *_recordingFloatBuffer;
    AVAudioPCMBuffer *_recordingInt16Buffer;

    float *_ringBuffer;
    size_t _ringBufferWritePos;
    size_t _ringBufferReadPos;
    
    float *_smoothingBuffer;
    size_t _smoothingBufferSize;
    size_t _smoothingWritePos;
    size_t _smoothingReadPos;
    float _lastValidSample;
    int _silenceCounter;
    
    BOOL _isRecording;
    BOOL _isPlaying;
    BOOL _isInterrupted;
    
    dispatch_queue_t _audioQueue;
    dispatch_queue_t _conversionQueue;

    AVAudioUnitEQ *_screenShareGainNode;
    AVAudioUnitEQ *_playoutGainNode;
    NSLock *_ringBufferLock;
    NSLock *_smoothingLock;
    
    BOOL _shouldStopBackgroundMaintenance;
    dispatch_source_t _backgroundMaintenanceTimer;
    NSLock *_backgroundMaintenanceLock;
    BOOL _isPlayoutGraphConnected;
}
@end

@implementation CustomAudioDevice

+ (instancetype)sharedInstance {
    static CustomAudioDevice *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[CustomAudioDevice alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _audioQueue = dispatch_queue_create("com.videosdk.customaudiodevice.queue", DISPATCH_QUEUE_SERIAL);
        
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _conversionQueue = dispatch_queue_create("com.videosdk.audioconversion.queue", attr);
        
        _ringBuffer = (float *)calloc(kMaxRingBufferSize, sizeof(float));
        _ringBufferLock = [[NSLock alloc] init];
        
        _smoothingBufferSize = 4096;
        _smoothingBuffer = (float *)calloc(_smoothingBufferSize, sizeof(float));
        _smoothingLock = [[NSLock alloc] init];
        _smoothingWritePos = 0;
        _smoothingReadPos = 0;
        _lastValidSample = 0.0f;
        _silenceCounter = 0;
        
        _backgroundMaintenanceLock = [[NSLock alloc] init];
        _shouldStopBackgroundMaintenance = NO;
        _isPlayoutGraphConnected = NO;
        
        [self subscribeToNotifications];
    }
    return self;
}

- (void)dealloc {
    [self stopBackgroundBufferMaintenance];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_ringBuffer) {
        free(_ringBuffer);
        _ringBuffer = NULL;
    }
    if (_smoothingBuffer) {
        free(_smoothingBuffer);
        _smoothingBuffer = NULL;
    }
}

#pragma mark - Public: Screen Share Audio Ingestion

- (void)handleBroadcastAudioData:(NSData *)audioData withDescription:(AudioStreamBasicDescription)description {
    if (!_clientFormat || !audioData) return;

    static int queueWorkItems = 0;
    if (queueWorkItems > 10) {
        return;
    }
    
    __sync_fetch_and_add(&queueWorkItems, 1);
    
    dispatch_async(_conversionQueue, ^{
        @autoreleasepool {
            AVAudioFormat *sourceFormat = [[AVAudioFormat alloc] initWithStreamDescription:&description];
            AVAudioFrameCount sourceFrameCount = (AVAudioFrameCount)(audioData.length / description.mBytesPerFrame);
            
            if (sourceFrameCount == 0 || sourceFrameCount > 16384) {
                return;
            }
            
            AVAudioPCMBuffer *sourceBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:sourceFormat frameCapacity:sourceFrameCount];
            if (!sourceBuffer) return;
            
            sourceBuffer.frameLength = sourceFrameCount;
            memcpy(sourceBuffer.mutableAudioBufferList->mBuffers[0].mData, audioData.bytes, audioData.length);
            
            AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:sourceFormat toFormat:self->_clientFormat];
            if (!converter) return;
            
            converter.downmix = YES;
            
            AVAudioFrameCount outputCapacity = (AVAudioFrameCount)ceil(((double)self->_clientFormat.sampleRate / sourceFormat.sampleRate) * sourceFrameCount);
            AVAudioPCMBuffer *outputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self->_clientFormat frameCapacity:outputCapacity];
            if (!outputBuffer) return;
            
            NSError *error;
            __block BOOL inputProvided = NO;
            [converter convertToBuffer:outputBuffer error:&error withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus * _Nonnull outStatus) {
                if (inputProvided) {
                    *outStatus = AVAudioConverterInputStatus_EndOfStream;
                    return nil;
                }
                *outStatus = AVAudioConverterInputStatus_HaveData;
                inputProvided = YES;
                return sourceBuffer;
            }];
            
            if (!error && outputBuffer.frameLength > 0) {
                [self->_smoothingLock lock];
                
                float *buffer = outputBuffer.floatChannelData[0];
                const float STABLE_VOLUME = 0.85f;
                
                for (AVAudioFrameCount i = 0; i < outputBuffer.frameLength; i++) {
                    float sample = buffer[i] * STABLE_VOLUME;
                    
                    if (self->_lastValidSample != 0.0f) {
                        float diff = fabsf(sample - self->_lastValidSample);
                        if (diff > 0.5f) {
                            sample = self->_lastValidSample + (sample - self->_lastValidSample) * 0.3f;
                        }
                    }
                    
                    sample = fmaxf(-1.0f, fminf(1.0f, sample));
                    self->_lastValidSample = sample;
                    
                    self->_smoothingBuffer[self->_smoothingWritePos] = sample;
                    self->_smoothingWritePos = (self->_smoothingWritePos + 1) % self->_smoothingBufferSize;
                }
                
                [self->_smoothingLock unlock];
                
                [self transferSmoothedDataToRingBuffer];
            }
            
            __sync_fetch_and_sub(&queueWorkItems, 1);
        }
    });
}

- (void)transferSmoothedDataToRingBuffer {
    [_smoothingLock lock];
    [_ringBufferLock lock];
    
    size_t availableSmoothed;
    if (_smoothingWritePos >= _smoothingReadPos) {
        availableSmoothed = _smoothingWritePos - _smoothingReadPos;
    } else {
        availableSmoothed = (_smoothingBufferSize - _smoothingReadPos) + _smoothingWritePos;
    }
    
    size_t samplesToTransfer = MIN(availableSmoothed, 1024);
    
    for (size_t i = 0; i < samplesToTransfer; i++) {
        _ringBuffer[_ringBufferWritePos] = _smoothingBuffer[_smoothingReadPos];
        _ringBufferWritePos = (_ringBufferWritePos + 1) % kMaxRingBufferSize;
        _smoothingReadPos = (_smoothingReadPos + 1) % _smoothingBufferSize;
    }
    
    [_ringBufferLock unlock];
    [_smoothingLock unlock];
}

#pragma mark - Engine Lifecycle

- (void)updateAudioEngine {
    dispatch_async(_audioQueue, ^{
        if (self->_isInterrupted || (!self->_isRecording && !self->_isPlaying)) {
            if (self->_engine) {
                [self shutdownEngine];
            }
            return;
        }
        [self setupAudioSession];

        BOOL shouldRebuildEngine = NO;
        if (self->_engine == nil) {
            shouldRebuildEngine = YES;
        } else {
            double hardwareSampleRate = [AVAudioSession sharedInstance].sampleRate;
            if (fabs([self->_engine.inputNode outputFormatForBus:0].sampleRate - hardwareSampleRate) > 1.0) {
                shouldRebuildEngine = YES;
            }
            
            if (self->_isRecording && self->_recordingSinkNode == nil && self->_engine.isRunning) {
                shouldRebuildEngine = YES;
            }

            if (self->_isPlaying && !self->_isPlayoutGraphConnected) {
                shouldRebuildEngine = YES;
            }
        }
        
        if (shouldRebuildEngine) {
            [self shutdownEngine];
            [self updateAudioFormats];
            [self createEngineAndAttachNodes];
        }

        [self connectNodesForRecording];
        [self connectNodesForPlayout];

        if (!self->_engine.isRunning) {
            NSError *error = nil;
            if (![self->_engine startAndReturnError:&error]) {
                [self shutdownEngine];
            } else {
                [self startBackgroundBufferMaintenance];
            }
        } else {
            if (self->_isRecording && self->_recordingSinkNode == nil) {
                [self shutdownEngine];
                [self updateAudioFormats];
                [self createEngineAndAttachNodes];
                [self connectNodesForRecording];
                [self connectNodesForPlayout];
                
                NSError *error = nil;
                if (![self->_engine startAndReturnError:&error]) {
                    [self shutdownEngine];
                } else {
                    [self startBackgroundBufferMaintenance];
                }
            }
        }
    });
}

- (void)shutdownEngine {
    if (!_engine) return;
    
    [self stopBackgroundBufferMaintenance];
    
    if (_engine.isRunning) {
        [_engine stop];
    }
    
    if (_recordingSinkNode) [_engine detachNode:_recordingSinkNode];
    if (_playoutSourceNode) [_engine detachNode:_playoutSourceNode];
    if (_screenShareAudioSourceNode) [_engine detachNode:_screenShareAudioSourceNode];
    if (_screenShareGainNode) [_engine detachNode:_screenShareGainNode];
    if (_playoutGainNode) [_engine detachNode:_playoutGainNode];
    if (_recordingMixerNode) [_engine detachNode:_recordingMixerNode];
    
    _recordingSinkNode = nil;
    _playoutSourceNode = nil;
    _screenShareAudioSourceNode = nil;
    _screenShareGainNode = nil;
    _playoutGainNode = nil;
    _recordingMixerNode = nil;
    _engine = nil;
    _isPlayoutGraphConnected = NO;
}

#pragma mark - Configuration

- (void)setupAudioSession {
    RTCAudioSession *rtcSession = [RTCAudioSession sharedInstance];
    
    [rtcSession lockForConfiguration];
    @try {
        RTCAudioSessionConfiguration *config = [[RTCAudioSessionConfiguration alloc] init];
        config.category = AVAudioSessionCategoryPlayAndRecord;
        
        config.categoryOptions = AVAudioSessionCategoryOptionMixWithOthers |
                               AVAudioSessionCategoryOptionDefaultToSpeaker |
                               AVAudioSessionCategoryOptionAllowBluetooth |
                               AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                               AVAudioSessionCategoryOptionInterruptSpokenAudioAndMixWithOthers;
        
        config.mode = AVAudioSessionModeVideoChat;
        
        NSError *error;
        [rtcSession setConfiguration:config error:&error];
        [rtcSession setActive:YES error:&error];
        
        if (error) {
            
            config.categoryOptions = AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker;
            [rtcSession setConfiguration:config error:nil];
            [rtcSession setActive:YES error:nil];
        } else {
            AVAudioSession *session = rtcSession.session;
        }
        
    } @finally {
        [rtcSession unlockForConfiguration];
    }
}

- (void)createEngineAndAttachNodes {
    _engine = [[AVAudioEngine alloc] init];
    
    _recordingMixerNode = [[AVAudioMixerNode alloc] init];
    [_engine attachNode:_recordingMixerNode];

    // Conditionally create and attach screen share audio nodes
    if (gEnableScreenAudio) {
        _screenShareGainNode = [[AVAudioUnitEQ alloc] initWithNumberOfBands:1];
        _screenShareAudioSourceNode = [[AVAudioSourceNode alloc] initWithFormat:_clientFormat
                                                                    renderBlock:[self screenShareRenderBlock]];
        
        [_engine attachNode:_screenShareAudioSourceNode];
        [_engine attachNode:_screenShareGainNode];
    } else {
        _screenShareGainNode = nil;
        _screenShareAudioSourceNode = nil;
    }

    // Always create and attach playout nodes
    AVAudioFormat *playoutFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                                    sampleRate:self.deviceOutputSampleRate
                                                                      channels:self.outputNumberOfChannels
                                                                   interleaved:YES];
    
    _playoutSourceNode = [[AVAudioSourceNode alloc] initWithFormat:playoutFormat
                                                       renderBlock:[self playoutRenderBlock]];
    
    _playoutGainNode = [[AVAudioUnitEQ alloc] initWithNumberOfBands:1];
    _playoutGainNode.globalGain = 5.0;

    [_engine attachNode:_playoutSourceNode];
    [_engine attachNode:_playoutGainNode];
}

- (void)connectNodesForRecording {
    if (_isRecording && _recordingSinkNode == nil) {
        
        @try {
            [_engine disconnectNodeInput:_recordingMixerNode];
            [_engine disconnectNodeOutput:_recordingMixerNode];
        } @catch (NSException *exception) {
        }
        
        _recordingSinkNode = [[AVAudioSinkNode alloc] initWithReceiverBlock:[self recordingReceiverBlock]];
        [_engine attachNode:_recordingSinkNode];

        AVAudioInputNode *micNode = _engine.inputNode;
        AVAudioFormat *micFormat = [micNode outputFormatForBus:0];

        @try {
            [_engine connect:micNode to:_recordingMixerNode format:micFormat];
            if (gEnableScreenAudio && _screenShareAudioSourceNode && _screenShareGainNode) {
                [_engine connect:_screenShareAudioSourceNode to:_screenShareGainNode format:_clientFormat];
                [_engine connect:_screenShareGainNode to:_recordingMixerNode format:_clientFormat];
            }
            [_engine connect:_recordingMixerNode to:_recordingSinkNode format:_clientFormat];
        } @catch (NSException *exception) {
            if (_recordingSinkNode) {
                [_engine detachNode:_recordingSinkNode];
                _recordingSinkNode = nil;
            }
        }
        
    } else if (!_isRecording && _recordingSinkNode != nil) {
        
        @try {
            [_engine disconnectNodeOutput:_recordingMixerNode];
            [_engine disconnectNodeInput:_recordingMixerNode];
            [_engine disconnectNodeOutput:_screenShareGainNode];
            [_engine disconnectNodeOutput:_screenShareAudioSourceNode];
        } @catch (NSException *exception) {
        }
        
        [_engine detachNode:_recordingSinkNode];
        _recordingSinkNode = nil;
        
        _recordingFloatBuffer = nil;
        _recordingInt16Buffer = nil;
        
    }
}

- (void)connectNodesForPlayout {
    [_engine disconnectNodeOutput:_playoutSourceNode];
    if (_playoutGainNode) {
        [_engine disconnectNodeOutput:_playoutGainNode];
    }
    
    if (_isPlaying) {
        AVAudioFormat *playoutFormat = [_playoutSourceNode outputFormatForBus:0];
        [_engine connect:_playoutSourceNode to:_playoutGainNode format:playoutFormat];
        [_engine connect:_playoutGainNode to:_engine.mainMixerNode format:playoutFormat];
        _isPlayoutGraphConnected = YES;
    } else {
        _isPlayoutGraphConnected = NO;
    }
}

#pragma mark - Render/Receiver Blocks

- (AVAudioSourceNodeRenderBlock)screenShareRenderBlock {
    return ^OSStatus(BOOL * _Nonnull isSilence, const AudioTimeStamp * _Nonnull timestamp, AVAudioFrameCount frameCount, AudioBufferList * _Nonnull outputData) {
        
        for (UInt32 i = 0; i < outputData->mNumberBuffers; i++) {
            memset(outputData->mBuffers[i].mData, 0, outputData->mBuffers[i].mDataByteSize);
        }
        
        float *outputBuffer = (float *)outputData->mBuffers[0].mData;
        
        if (![self->_ringBufferLock tryLock]) {
            *isSilence = YES;
            return noErr;
        }
        
        size_t availableFrames;
        if (self->_ringBufferWritePos >= self->_ringBufferReadPos) {
            availableFrames = self->_ringBufferWritePos - self->_ringBufferReadPos;
        } else {
            availableFrames = (kMaxRingBufferSize - self->_ringBufferReadPos) + self->_ringBufferWritePos;
        }
        
        if (availableFrames >= frameCount) {
            for (AVAudioFrameCount i = 0; i < frameCount; i++) {
                outputBuffer[i] = self->_ringBuffer[self->_ringBufferReadPos];
                self->_ringBufferReadPos = (self->_ringBufferReadPos + 1) % kMaxRingBufferSize;
            }
            self->_silenceCounter = 0;
            *isSilence = NO;
            
        } else if (availableFrames > 0) {
            float samples[frameCount];
            
            for (size_t i = 0; i < availableFrames; i++) {
                samples[i] = self->_ringBuffer[self->_ringBufferReadPos];
                self->_ringBufferReadPos = (self->_ringBufferReadPos + 1) % kMaxRingBufferSize;
            }
            
            if (availableFrames >= frameCount / 2) {
                for (AVAudioFrameCount i = 0; i < frameCount; i++) {
                    if (i < availableFrames) {
                        outputBuffer[i] = samples[i];
                    } else {
                        if (availableFrames >= 3) {
                            float s2 = samples[availableFrames - 2];
                            float s3 = samples[availableFrames - 1];
                            
                            float t = (float)(i - availableFrames + 1) / (float)(frameCount - availableFrames);
                            float extrapolated = s3 + (s3 - s2) * t * 0.7f;
                            outputBuffer[i] = extrapolated * (1.0f - t * 0.3f);
                        } else {
                            float fadeMultiplier = 1.0f - (float)(i - availableFrames) / (float)(frameCount - availableFrames);
                            outputBuffer[i] = samples[availableFrames - 1] * fadeMultiplier * 0.5f;
                        }
                    }
                }
            } else {
                float lastSample = availableFrames > 0 ? samples[availableFrames - 1] : self->_lastValidSample;
                for (AVAudioFrameCount i = 0; i < frameCount; i++) {
                    if (i < availableFrames) {
                        outputBuffer[i] = samples[i];
                    } else {
                        float fadeOut = 1.0f - (float)(i - availableFrames) / (float)(frameCount - availableFrames);
                        outputBuffer[i] = lastSample * fadeOut * 0.3f;
                    }
                }
            }
            
            *isSilence = NO;
            
        } else {
            self->_silenceCounter++;
            if (self->_silenceCounter < 5) {
                float fadeValue = self->_lastValidSample * (1.0f - (float)self->_silenceCounter / 5.0f) * 0.1f;
                for (AVAudioFrameCount i = 0; i < frameCount; i++) {
                    outputBuffer[i] = fadeValue * (1.0f - (float)i / (float)frameCount);
                }
                *isSilence = NO;
            } else {
                *isSilence = YES;
            }
        }
        
        [self->_ringBufferLock unlock];
        
        return noErr;
    };
}

- (AVAudioSinkNodeReceiverBlock)recordingReceiverBlock {
    return ^OSStatus(const AudioTimeStamp * timeStamp, AVAudioFrameCount frameCount, const AudioBufferList * inputData) {
        @autoreleasepool {
            
            if (!self->_deviceDelegate) return noErr;
            
            if (!self->_recordingFloatBuffer || self->_recordingFloatBuffer.frameCapacity < frameCount) {
                self->_recordingFloatBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self->_clientFormat frameCapacity:frameCount];
            }
            AVAudioPCMBuffer *floatBuffer = self->_recordingFloatBuffer;
            floatBuffer.frameLength = frameCount;

            const AudioBuffer *sourceBuffer = &inputData->mBuffers[0];
            AudioBuffer *destBuffer = &floatBuffer.mutableAudioBufferList->mBuffers[0];
            memcpy(destBuffer->mData, sourceBuffer->mData, sourceBuffer->mDataByteSize);
            
            if (!self->_recordingConverter) return noErr;
            
            AVAudioConverter *converter = self->_recordingConverter;

            [converter reset];

            double outputSampleRate = self->_webRTCRecordingFormat.sampleRate;
            double inputSampleRate = self->_clientFormat.sampleRate;
            AVAudioFrameCount outputCapacity = (AVAudioFrameCount)ceil(frameCount * (outputSampleRate / inputSampleRate));

            if (!self->_recordingInt16Buffer || self->_recordingInt16Buffer.frameCapacity < outputCapacity) {
                self->_recordingInt16Buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self->_webRTCRecordingFormat frameCapacity:outputCapacity];
            }
            AVAudioPCMBuffer *int16Buffer = self->_recordingInt16Buffer;
            
            NSError *error;
            __block BOOL inputProvided = NO;
            AVAudioConverterOutputStatus status = [converter convertToBuffer:int16Buffer error:&error withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus * _Nonnull outStatus) {
                if (inputProvided) { *outStatus = AVAudioConverterInputStatus_EndOfStream; return nil; }
                *outStatus = AVAudioConverterInputStatus_HaveData;
                inputProvided = YES;
                return floatBuffer;
            }];
            
            if (status == AVAudioConverterOutputStatus_Error) {
                return noErr;
            }
            
            AudioUnitRenderActionFlags flags = 0;
            self->_deviceDelegate.deliverRecordedData(&flags, timeStamp, 0, int16Buffer.frameLength, int16Buffer.audioBufferList, NULL, NULL);
            return noErr;
        }
    };
}

- (AVAudioSourceNodeRenderBlock)playoutRenderBlock {
    return ^OSStatus(BOOL * _Nonnull isSilence, const AudioTimeStamp * _Nonnull timestamp, AVAudioFrameCount frameCount, AudioBufferList * _Nonnull outputData) {
        if (self->_deviceDelegate) {
            AudioUnitRenderActionFlags flags = 0;
            self->_deviceDelegate.getPlayoutData(&flags, timestamp, 0, frameCount, outputData);
        }
        return noErr;
    };
}

#pragma mark - Notification Handling

- (void)subscribeToNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleRouteChange:) name:AVAudioSessionRouteChangeNotification object:nil];
}

- (void)handleInterruption:(NSNotification*)notification {
    NSNumber *typeNumber = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    AVAudioSessionInterruptionType type = [typeNumber intValue];
    
    if (type == AVAudioSessionInterruptionTypeBegan) {
        _isInterrupted = YES;
    } else if (type == AVAudioSessionInterruptionTypeEnded) {
        _isInterrupted = NO;
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), _audioQueue, ^{
            [self beginGracefulRecovery];
        });
    }
}

- (void)beginGracefulRecovery {
    
    [self setupAudioSession];
    [self checkEngineHealth];
    
}

- (void)handleRouteChange:(NSNotification*)notification {
    NSNumber *reasonNumber = notification.userInfo[AVAudioSessionRouteChangeReasonKey];
    AVAudioSessionRouteChangeReason reason = [reasonNumber unsignedIntegerValue];
    
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSString *currentRoute = session.currentRoute.outputs.firstObject.portName ?: @"Unknown";
    
    switch (reason) {
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable: {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), _audioQueue, ^{
                [self updateAudioEngine];
            });
            break;
        }
        case AVAudioSessionRouteChangeReasonCategoryChange: {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), _audioQueue, ^{
                [self setupAudioSession];
                [self checkEngineHealth];
            });
            break;
        }
        case AVAudioSessionRouteChangeReasonOverride: {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), _audioQueue, ^{
                [self checkEngineHealth];
            });
            break;
        }
        default:
            break;
    }
}

- (void)checkEngineHealth {
    if (!_engine || !_engine.isRunning) {
        [self updateAudioEngine];
        return;
    }
    
    AVAudioSession *session = [AVAudioSession sharedInstance];
    double sessionSampleRate = session.sampleRate;
    double engineSampleRate = [_engine.inputNode outputFormatForBus:0].sampleRate;
    
    if (fabs(sessionSampleRate - engineSampleRate) > 1.0) {
        [self updateAudioEngine];
    }
}

#pragma mark - RTCAudioDevice Protocol Implementation

- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    _deviceDelegate = delegate;
    [self updateAudioFormats];
    return YES;
}

- (BOOL)terminateDevice {
    _deviceDelegate = nil;
    _isRecording = NO;
    _isPlaying = NO;
    _recordingConverter = nil;
    _recordingFloatBuffer = nil;
    _recordingInt16Buffer = nil;
    [self updateAudioEngine];
    return YES;
}

- (BOOL)startRecording {
    if (_isRecording) return YES;
    _isRecording = YES;
    [self updateAudioEngine];
    return YES;
}

- (BOOL)stopRecording {
    if (!_isRecording) return YES;
    _isRecording = NO;
    [self updateAudioEngine];
    return YES;
}

- (BOOL)startPlayout {
    if (_isPlaying) return YES;
    _isPlaying = YES;
    [self updateAudioEngine];
    return YES;
}

- (BOOL)stopPlayout {
    if (!_isPlaying) return YES;
    _isPlaying = NO;
    [self updateAudioEngine];
    return YES;
}

- (BOOL)initializeRecording { return YES; }
- (BOOL)initializePlayout { return YES; }
- (BOOL)isRecordingInitialized { return YES; }
- (BOOL)isPlayoutInitialized { return YES; }
- (BOOL)isRecording { return _isRecording; }
- (BOOL)isPlaying { return _isPlaying; }

- (double)deviceInputSampleRate { return _deviceDelegate ? _deviceDelegate.preferredInputSampleRate : 48000; }
- (double)deviceOutputSampleRate { return _deviceDelegate ? _deviceDelegate.preferredOutputSampleRate : 48000; }

- (NSInteger)inputNumberOfChannels { return 1; }
- (NSInteger)outputNumberOfChannels { return 1; }

- (NSTimeInterval)inputLatency { return [AVAudioSession sharedInstance].inputLatency; }
- (NSTimeInterval)outputLatency { return [AVAudioSession sharedInstance].outputLatency; }
- (NSTimeInterval)inputIOBufferDuration { return [AVAudioSession sharedInstance].IOBufferDuration; }
- (NSTimeInterval)outputIOBufferDuration { return [AVAudioSession sharedInstance].IOBufferDuration; }
- (BOOL)isInitialized { return _deviceDelegate != nil; }

- (void)startBackgroundBufferMaintenance {
    [_backgroundMaintenanceLock lock];
    
    if (_backgroundMaintenanceTimer) {
        [_backgroundMaintenanceLock unlock];
        return;
    }
    
    _shouldStopBackgroundMaintenance = NO;
    
    _backgroundMaintenanceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    
    dispatch_source_set_timer(_backgroundMaintenanceTimer,
                             dispatch_time(DISPATCH_TIME_NOW, 0),
                             5 * NSEC_PER_MSEC,
                             1 * NSEC_PER_MSEC);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_backgroundMaintenanceTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_shouldStopBackgroundMaintenance) {
            return;
        }
        
        if (strongSelf->_engine && strongSelf->_engine.isRunning && !strongSelf->_isInterrupted) {
            [strongSelf transferSmoothedDataToRingBuffer];
        }
    });
    
    dispatch_resume(_backgroundMaintenanceTimer);
    [_backgroundMaintenanceLock unlock];
    
}

- (void)stopBackgroundBufferMaintenance {
    [_backgroundMaintenanceLock lock];
    
    _shouldStopBackgroundMaintenance = YES;
    
    if (_backgroundMaintenanceTimer) {
        dispatch_source_cancel(_backgroundMaintenanceTimer);
        _backgroundMaintenanceTimer = nil;
    }
    
    [_backgroundMaintenanceLock unlock];
    
}

#pragma mark - Private Methods

- (void)updateAudioFormats {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    double hardwareSampleRate = session.sampleRate;

    if (!_deviceDelegate) {
        return;
    }


    _clientFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                     sampleRate:hardwareSampleRate
                                                       channels:1
                                                    interleaved:NO];

    _webRTCRecordingFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                              sampleRate:[self deviceInputSampleRate]
                                                                channels:1
                                                             interleaved:YES];

    _recordingConverter = [[AVAudioConverter alloc] initFromFormat:_clientFormat toFormat:_webRTCRecordingFormat];

    _recordingFloatBuffer = nil;
    _recordingInt16Buffer = nil;

}

@end
