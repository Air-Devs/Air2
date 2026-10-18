//
//  LanPortDetector.m
//  Amethyst
//
//  Minecraft "对局域网开放"端口检测器（手动输入版）实现
//

#import "LanPortDetector.h"

/// 通知名：手动设置端口时发送
NSString *const LanPortDetectorDidDetectPortNotification = @"LanPortDetectorDidDetectPort";

@interface LanPortDetector ()
/// 当前已设置的端口（0 表示未设置）
@property (nonatomic, assign, readwrite) uint16_t detectedPort;
@end

@implementation LanPortDetector

#pragma mark - 单例

+ (instancetype)sharedInstance {
    static LanPortDetector *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

#pragma mark - 手动设置端口

/// 手动设置 MC LAN 端口
- (void)setManualPort:(uint16_t)port {
    self.detectedPort = port;

    NSLog(@"[LanPortDetector] Manually set LAN port: %u", port);

    // 发送通知，userInfo 包含端口号
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:LanPortDetectorDidDetectPortNotification
                                                            object:self
                                                          userInfo:@{ @"port": @(port) }];
    });
}

@end
