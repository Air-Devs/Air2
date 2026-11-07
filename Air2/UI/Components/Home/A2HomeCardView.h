//
//  A2HomeCardView.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  主页单张卡片。
//
//  一条纪律：**版式按档位切换，不是等比缩放**（docs/HOME-DESIGN.md §2.2.3）——
//  1x1 只留「图标 + 名字 + 一行 meta」，2x1 才展开第二行；2x2 才铺开列表。
//  所以内容构建按 columnSpan 分支，而不是给同一套子视图改字号。
//
//  编辑态三件事同时成立（§5.2）：内容不可交互、每卡都有可见手柄、退出只切 flag。
//  引用失效走软失败：占位显示存卡时的兜底名 + 一句原因 + 「重新指定」，
//  卡片本身留在原地 —— 布局变更必须由用户自己授权。
//

#import <UIKit/UIKit.h>

#import "A2HomeLayout.h"

NS_ASSUME_NONNULL_BEGIN

@class A2HomeCardView;
@class A2Version;   // 列表行点按要回调「哪个版本」

@protocol A2HomeCardViewDelegate <NSObject>

/// 卡片本体被点（非编辑态）。快捷卡=启动，其它卡=打开对应页面。
- (void)homeCardViewDidActivate:(A2HomeCardView *)view;
/// 卡片里某一行版本被点（最近游玩 / 收藏版本列表）。
- (void)homeCardView:(A2HomeCardView *)view didActivateVersion:(A2Version *)version;
/// 右上 ⋯（仅在编辑态出现）。
- (void)homeCardViewDidRequestMenu:(A2HomeCardView *)view;

@end

@interface A2HomeCardView : UIView

@property (nonatomic, strong, readonly) A2HomeCard *card;
@property (nonatomic, weak, nullable) id<A2HomeCardViewDelegate> delegate;

/// 编辑态：内容不可点、露出编辑条、虚线框。
@property (nonatomic, assign, getter=isEditing) BOOL editing;

/// 显示用的**压缩后**列跨度（窄屏时可能小于 card.size 的档位，压缩结果不落盘）。
@property (nonatomic, assign) NSInteger displayColumnSpan;

- (instancetype)initWithCard:(A2HomeCard *)card;

/// 卡片数据变了（改尺寸 / 换目标 / 选项）后重画内容。
- (void)updateCard:(A2HomeCard *)card;

/// 拖动浮起 / 落下：只抬 elevation 档 + 打开 M3 state layer，不自己编阴影数值。
- (void)setLifted:(BOOL)lifted;
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
