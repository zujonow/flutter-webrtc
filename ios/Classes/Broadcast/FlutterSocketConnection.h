//
//  FlutterSocketConnection.h
//  RCTWebRTC
//
//  Created by Alex-Dan Bumbu on 08/01/2021.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FlutterSocketConnection : NSObject

@property(nonatomic, readonly) NSInputStream *inputStream;
@property(nonatomic, readonly) NSOutputStream *outputStream;

- (instancetype)initWithFilePath:(nonnull NSString*)filePath;
- (void)openWithStreamDelegate:(id<NSStreamDelegate>)streamDelegate;
- (void)close;

@end

NS_ASSUME_NONNULL_END
