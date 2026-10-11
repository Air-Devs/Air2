//
//  A2JITExternalToolLauncher.h
//  Air2
//
//  Player —— 外部工具【拉起】的注入缝（真实实现用 UIApplication 的 URL scheme）。
//
//  ★为什么要这层缝★：Player 只编排、不跨界（ADR-002）。`canOpenURL:` / `openURL:`
//  属 UIKit，不能写进 Player（否则纯逻辑单测要拖上 UIKit，且分层被破坏）。
//  真实实现落在 UI（Air2/UI/Components/A2JITSystemToolLauncher），单测注入假拉起器
//  ——于是「拉起 → 有界等待 → 轮询判据」这套编排逻辑可以脱离真机单测。
//
//  ★合规★：只走外部 App 的 URL scheme（零 vendor），不派生其代码
//  （StikDebug 本体为 AGPL-3.0，只可当外部依赖）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 【注入点】按 URL scheme 拉起外部使能器。
@protocol A2JITExternalToolLauncher <NSObject>

@required

/// 能否拉起该 URL（对应 UIApplication canOpenURL:；需 Info.plist
/// LSApplicationQueriesSchemes 白名单，见 Air2/Info.plist）。
- (BOOL)canOpenToolURL:(NSURL *)url;

/// 拉起该 URL（对应 UIApplication openURL:options:completionHandler:）。
/// @return 是否已发出拉起请求（异步完成，不代表对方已处理）。
- (BOOL)openToolURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
