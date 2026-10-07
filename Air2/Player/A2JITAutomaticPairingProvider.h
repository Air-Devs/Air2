//
//  A2JITAutomaticPairingProvider.h
//  Air2
//
//  Player —— 取得路径 ①：【设备内自动配对】（iOS 27+）。
//
//  语义（用户拍板 / ADR-008）：iOS 27 起，参考 SideInstaller 的「设备内 RPPairing」思路
//  【自研】在本机生成配对文件，不再需要 PC / 外部工具。
//  ★本单只落能力检测与占位★：真实实现第二阶段接入（需 vendor idevice(MIT) 做 RSD/TLS-PSK 隧道；
//  ★不得使用 SideInstaller 代码★——其许可为自定义、禁止再分发，只可参考协议思路）。
//

#import <Foundation/Foundation.h>
#import "A2JITProvider.h"

@class A2JITFacts;

NS_ASSUME_NONNULL_BEGIN

/// ① 设备内自动配对（iOS 27+）。
@interface A2JITAutomaticPairingProvider : NSObject <A2JITProvider>

/// 注入本机环境事实。
- (instancetype)initWithFacts:(A2JITFacts *)facts;

@end

NS_ASSUME_NONNULL_END
