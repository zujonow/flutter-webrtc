//
//  FlutterSocketConnectionFrameReader.m
//  RCTWebRTC
//
//  Created by Alex-Dan Bumbu on 06/01/2021.
//

#include <mach/mach_time.h>

#import <ReplayKit/ReplayKit.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrameBuffer.h>

#import "FlutterSocketConnection.h"
#import "FlutterSocketConnectionFrameReader.h"
#import "CustomAudioDevice.h"

const NSUInteger kMaxReadLength = 10 * 1024;

@class FrameParser;

@protocol FrameParserDelegate <NSObject>
- (void)parser:(FrameParser *)parser didReadFrame:(NSData *)frame withHeaders:(NSDictionary *)headers;
@end


@interface FrameParser : NSObject
@property(nonatomic, weak) id<FrameParserDelegate> delegate;
- (void)appendData:(NSData *)data;
@end

@interface FrameParser()
@property(nonatomic, strong) NSMutableData *buffer;
@end


@implementation FrameParser

- (instancetype)init {
    if (self = [super init]) {
        _buffer = [NSMutableData data];
    }
    return self;
}

- (void)appendData:(NSData *)data {
    [self.buffer appendData:data];
    [self processBuffer];
}

- (void)processBuffer {
    if (self.buffer.length == 0) {
        return;
    }
    
    NSRange separatorRange = [self.buffer rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, self.buffer.length)];
    
    if (separatorRange.location == NSNotFound) {
        return;
    }
    
    NSRange headerRange = NSMakeRange(0, separatorRange.location);
    NSData *headerData = [self.buffer subdataWithRange:headerRange];
    NSString *headerString = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    
    NSDictionary *headers = [self parseHeaders:headerString];
    NSInteger contentLength = [headers[@"Content-Length"] integerValue];
    
    if (contentLength == 0) {
        [self.buffer setData:[NSData data]];
        return;
    }
    
    NSInteger frameTotalLength = separatorRange.location + separatorRange.length + contentLength;
    
    if (self.buffer.length < frameTotalLength) {
        return;
    }
    
    NSInteger frameBodyLocation = separatorRange.location + separatorRange.length;
    NSRange frameBodyRange = NSMakeRange(frameBodyLocation, contentLength);
    NSData *frameData = [self.buffer subdataWithRange:frameBodyRange];
    
    [self.delegate parser:self didReadFrame:frameData withHeaders:headers];
    
    [self.buffer replaceBytesInRange:NSMakeRange(0, frameTotalLength) withBytes:NULL length:0];
    
    [self processBuffer];
}

- (NSDictionary *)parseHeaders:(NSString *)headerString {
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSArray *lines = [headerString componentsSeparatedByString:@"\r\n"];
    for (NSString *line in lines) {
        NSRange colonRange = [line rangeOfString:@": "];
        if (colonRange.location != NSNotFound) {
            NSString *key = [line substringToIndex:colonRange.location];
            NSString *value = [line substringFromIndex:colonRange.location + colonRange.length];
            headers[key] = value;
        }
    }
    return headers;
}
@end

// MARK: -

@interface FlutterSocketConnectionFrameReader () <NSStreamDelegate , FrameParserDelegate>

@property(nonatomic, strong) FlutterSocketConnection *videoConnection;
@property(nonatomic, strong) FlutterSocketConnection *audioConnection;
@property(nonatomic, strong) FrameParser *videoParser;
@property(nonatomic, strong) FrameParser *audioParser;
@property(nonatomic, strong) CIContext *imageContext;
@property(nonatomic, strong) NSDate *contextCreationTime;
@property(nonatomic, assign) NSTimeInterval contextLifetime;

@end

@implementation FlutterSocketConnectionFrameReader {
  mach_timebase_info_data_t _timebaseInfo;
  int64_t _startTimeStampNs;
}

- (instancetype)initWithDelegate:(__weak id<RTCVideoCapturerDelegate>)delegate {
  self = [super initWithDelegate:delegate];
  if (self) {
    mach_timebase_info(&_timebaseInfo);
    _contextLifetime = 120.0;
    [self createImageContext];
  }

  return self;
}

- (void)createImageContext {
    NSDictionary *options = @{
        kCIContextCacheIntermediates: @(NO),
        kCIContextUseSoftwareRenderer: @(NO)
    };
    _imageContext = [[CIContext alloc] initWithOptions:options];
    _contextCreationTime = [NSDate date];
}

- (CIContext *)getImageContext {
    if (_contextCreationTime &&
        [[NSDate date] timeIntervalSinceDate:_contextCreationTime] > _contextLifetime) {
        _imageContext = nil;
        _contextCreationTime = nil;
        [self createImageContext];
    }
    return _imageContext;
}

- (void)startCaptureWithVideoConnection:(FlutterSocketConnection *)videoConnection
                        audioConnection:(FlutterSocketConnection *)audioConnection {
    _startTimeStampNs = -1;
    
    self.videoConnection = videoConnection;
        self.videoParser = [[FrameParser alloc] init];
        self.videoParser.delegate = self;
        [self.videoConnection openWithStreamDelegate:self];

        self.audioConnection = audioConnection;
        self.audioParser = [[FrameParser alloc] init];
        self.audioParser.delegate = self;
        [self.audioConnection openWithStreamDelegate:self];
}

- (void)stopCapture {
    [self.videoConnection close];
    [self.audioConnection close];
    self.videoConnection = nil;
    self.audioConnection = nil;

    _imageContext = nil;
    _contextCreationTime = nil;
}

// MARK: FrameParserDelegate

- (void)parser:(FrameParser *)parser didReadFrame:(NSData *)frame withHeaders:(NSDictionary *)headers {
    NSString *contentType = headers[@"Content-Type"];

    if (parser == self.videoParser) {
        [self handleVideoFrame:frame withHeaders:headers];
    } else if (parser == self.audioParser) {
        [self handleAudioFrame:frame withHeaders:headers];
    }
}


// MARK: Private Methods

- (void)handleAudioFrame:(NSData *)frame withHeaders:(NSDictionary *)headers {
    NSString *metadataString = headers[@"Buffer-Metadata"];
    if (!metadataString) {
        return;
    }

    NSData *metadataJSON = [metadataString dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error;
    NSDictionary *metadata = [NSJSONSerialization JSONObjectWithData:metadataJSON options:0 error:&error];
    if (!metadata) {
        return;
    }

    NSArray *descArray = metadata[@"description"];

    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = [descArray[0] doubleValue];
    asbd.mFormatID = [descArray[1] unsignedIntValue];
    asbd.mFormatFlags = [descArray[2] unsignedIntValue];
    asbd.mBytesPerPacket = [descArray[3] unsignedIntValue];
    asbd.mFramesPerPacket = [descArray[4] unsignedIntValue];
    asbd.mBytesPerFrame = [descArray[5] unsignedIntValue];
    asbd.mChannelsPerFrame = [descArray[6] unsignedIntValue];
    asbd.mBitsPerChannel = [descArray[7] unsignedIntValue];
    
    [[CustomAudioDevice sharedInstance] handleBroadcastAudioData:frame withDescription:asbd];
}

- (void)handleVideoFrame:(NSData *)frame withHeaders:(NSDictionary *)headers {
    if (!frame || frame.length == 0) {
        return;
    }
    
    if (!headers || !headers[@"Buffer-Width"] || !headers[@"Buffer-Height"]) {
        return;
    }
    
    size_t width = [headers[@"Buffer-Width"] integerValue];
    size_t height = [headers[@"Buffer-Height"] integerValue];
    int imageOrientation = [headers[@"Buffer-Orientation"] intValue];

    if (width == 0 || height == 0 || width > 4096 || height > 4096) {
        return;
    }

    CVImageBufferRef imageBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, NULL, &imageBuffer);
    if (status != kCVReturnSuccess) {
        return;
    }

    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    
    @try {
        CIImage *image = [CIImage imageWithData:frame];
        if (!image) {
            CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
            CVPixelBufferRelease(imageBuffer);
            return;
        }
        
        CIContext *context = [self getImageContext];
        if (!context) {
            CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
            CVPixelBufferRelease(imageBuffer);
            return;
        }
        
        [context render:image toCVPixelBuffer:imageBuffer];
    } @catch (NSException *exception) {
        CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
        CVPixelBufferRelease(imageBuffer);
        return;
    }
    
    CVPixelBufferUnlockBaseAddress(imageBuffer, 0);

    [self didCaptureVideoFrame:imageBuffer withOrientation:imageOrientation];

    CVPixelBufferRelease(imageBuffer);
}

- (void)readBytesFromStream:(NSInputStream *)stream toParser:(FrameParser *)parser {
    if (!stream.hasBytesAvailable) {
        return;
    }

    uint8_t buffer[kMaxReadLength];
    NSInteger numberOfBytesRead = [stream read:buffer maxLength:kMaxReadLength];
    
    if (numberOfBytesRead < 0) {
        return;
    }
    
    if (numberOfBytesRead > 0) {
        NSData *data = [NSData dataWithBytes:buffer length:numberOfBytesRead];
        [parser appendData:data];
    }
}

- (void)didCaptureVideoFrame:(CVPixelBufferRef)pixelBuffer
             withOrientation:(CGImagePropertyOrientation)orientation {
  int64_t currentTime = mach_absolute_time();
  int64_t currentTimeStampNs = currentTime * _timebaseInfo.numer / _timebaseInfo.denom;

  if (_startTimeStampNs < 0) {
    _startTimeStampNs = currentTimeStampNs;
  }

  RTCCVPixelBuffer* rtcPixelBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
  int64_t frameTimeStampNs = currentTimeStampNs - _startTimeStampNs;

  RTCVideoRotation rotation;
  switch (orientation) {
    case kCGImagePropertyOrientationLeft:
      rotation = RTCVideoRotation_90;
      break;
    case kCGImagePropertyOrientationDown:
      rotation = RTCVideoRotation_180;
      break;
    case kCGImagePropertyOrientationRight:
      rotation = RTCVideoRotation_270;
      break;
    default:
      rotation = RTCVideoRotation_0;
      break;
  }

  RTCVideoFrame* videoFrame = [[RTCVideoFrame alloc] initWithBuffer:[rtcPixelBuffer toI420]
                                                           rotation:rotation
                                                        timeStampNs:frameTimeStampNs];

  [self.delegate capturer:self didCaptureVideoFrame:videoFrame];
}

@end

@implementation FlutterSocketConnectionFrameReader (NSStreamDelegate)

- (void)stream:(NSStream*)aStream handleEvent:(NSStreamEvent)eventCode {
  switch (eventCode) {
    case NSStreamEventOpenCompleted:
      break;
      case NSStreamEventHasBytesAvailable: {
          NSInputStream *inputStream = (NSInputStream *)aStream;
          if (inputStream == [self.videoConnection inputStream]) {
              [self readBytesFromStream:inputStream toParser:self.videoParser];
          } else if (inputStream == [self.audioConnection inputStream]) {
              [self readBytesFromStream:inputStream toParser:self.audioParser];
          }
          break;
      }
      case NSStreamEventEndEncountered:
         if (aStream == [self.videoConnection inputStream] ||
             aStream == [self.videoConnection outputStream]) {
             [self stopCapture];
             [self.eventsDelegate capturerDidEnd:self];
         }
         break;
    case NSStreamEventErrorOccurred:
      NSLog(@"server stream error encountered: %@", aStream.streamError.localizedDescription);
      break;

    default:
      break;
  }
}

@end

