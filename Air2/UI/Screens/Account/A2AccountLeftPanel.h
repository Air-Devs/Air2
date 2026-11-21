//
//  A2AccountLeftPanel.h
//  Air2
//
//  账号管理左栏 —— 对照 ZL2 的 ActionsLayout。
//
//  ## ZL2 左栏的结构
//
//    ┌──────────────┐
//    │              │
//    │   3D 皮肤     │  ← PetModelView（Rust 实现的 3D 预览）
//    │   立绘预览    │
//    │              │
//    ├──────────────┤
//    │ [添加新账号]  │
//    └──────────────┘
//
//  ## 我们的做法
//
//  ZL2 的 3D 预览是 Rust + Android JNI 实现的（PetLib 模块），
//  iOS 上无法直接用。按用户的选择（「要么 3D 要么不用」），
//  这里先用「大号皮肤头像 + 账号信息」占位，不做半吊子的 2D 全身预览。
//
//  结构与 ZL2 一致（左栏 = 当前账号展示 + 添加按钮），
//  将来接入 3D 时只需把 avatarView 换掉。
//

#import <UIKit/UIKit.h>
#import "A2Account.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2AccountLeftPanel : UIView

@property (nonatomic, copy, nullable) void (^onAddAccount)(void);

/// 当前账号变化时刷新
- (void)updateWithAccount:(nullable A2Account *)account;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
