//
//  A2HomeGridView.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  自定义主页的卡片区（滚动容器 + 排布 + 拖拽）。
//
//  三条必须对齐的行为（docs/HOME-DESIGN.md §2.3.3 / §4.3）：
//    ① 顺序即布局：网格模式不存坐标，位置由 A2HomePacker 流式装箱算出来
//       ⇒ 不留洞以外的重叠，也没有「两份坐标」；
//    ② 显示位置 ≠ 存储位置：每次 layout 都从存储坐标重算显示坐标，
//       窄屏被挤开的坐标**不写回**；回宽屏原坐标自动复原；
//    ③ 窄屏只压列不压行：卡片视图拿到的是压缩后的列跨度，档位值不动。
//
//  编辑态是纯 UI 开关（`editing`），进门只切 flag，不碰数据、不落盘。
//  拖拽长按 0.4s 浮起 + 触觉反馈 + 跟手，松手时提交：
//    网格模式 = 改顺序（重排 cards 数组）；自由模式 = 改自己的坐标（吸附最近空格，不动别人）。
//

#import <UIKit/UIKit.h>

#import "A2HomeLayout.h"
#import "A2VersionManager.h"   // A2Version（卡片里点某一行启动它）

NS_ASSUME_NONNULL_BEGIN

@class A2HomeGridView;

@protocol A2HomeGridViewDelegate <NSObject>

- (void)homeGridViewDidRequestAddCard:(A2HomeGridView *)gridView;
- (void)homeGridView:(A2HomeGridView *)gridView didActivateCard:(A2HomeCard *)card;
- (void)homeGridView:(A2HomeGridView *)gridView didActivateVersion:(A2Version *)version;
- (void)homeGridView:(A2HomeGridView *)gridView didRequestMenuForCard:(A2HomeCard *)card;
/// 顺序或坐标已改（profile 内部已就地更新），调用方负责落盘。
- (void)homeGridViewDidChangeLayout:(A2HomeGridView *)gridView;

@end

@interface A2HomeGridView : UIView

/// 当前渲染的方案（强引用但不由本类持有所有权）。
@property (nonatomic, strong, nullable) A2HomeProfile *profile;
@property (nonatomic, weak, nullable) id<A2HomeGridViewDelegate> delegate;
@property (nonatomic, assign, getter=isEditing) BOOL editing;

/// 顶部横幅（只读模式 / 未保存提示）；nil 时隐藏。
@property (nonatomic, copy, nullable) NSString *bannerText;

/// 重建全部卡片视图（方案切换、增删卡、换目标后调）。
- (void)reloadCards;
- (void)applyTheme;

/// 当前列数（窄屏 1 / iPad 竖 2 / 横 3）。给调用方做日志与判据用。
@property (nonatomic, assign, readonly) NSInteger currentColumnCount;

@end

NS_ASSUME_NONNULL_END
