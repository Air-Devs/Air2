//
//  A2RemoteImageView.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
//  网络图片视图 —— 列表/详情页的项目图标。
//
//  为什么单独做一个组件：资源页图标来自远端，直接在 cell 里同步下载会掉帧；
//  而 cell 复用又会让「上一次的下载回调」落到新内容上，必须靠请求令牌丢弃。
//  所以这里把「内存二级缓存 + 磁盘缓存 + 下采样 + 请求令牌」四件事收进一个视图，
//  对调用方只暴露「给个 URL、给个占位图」。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 轻量网络图片视图 —— 列表/详情页的项目图标。
/// 内存二级缓存（NSCache）+ 磁盘缓存（Caches 下子目录），下载后按目标尺寸下采样再解码。
@interface A2RemoteImageView : UIImageView

/// 显示默认占位样式（首字母由调用方通过 placeholder 传图；传 nil 则用浅色圆角底）
@property (nonatomic, assign) CGFloat cornerRadius;

/// 加载图片。urlString 为空时直接显示 placeholder 并返回。
- (void)setImageURL:(nullable NSString *)urlString placeholder:(nullable UIImage *)placeholder;

/// 取消当前进行中的加载（cell 复用时调用）
- (void)cancelLoading;

/// 根据主题刷新占位底色
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
