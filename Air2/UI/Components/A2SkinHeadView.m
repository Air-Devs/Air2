//
//  A2SkinHeadView.m
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
//  见头文件。裁剪逻辑全部收在本文件，不对外暴露。
//

#import "A2SkinHeadView.h"
#import "A2ThemeManager.h"

// 皮肤材质里「头」的坐标，以 64x64 为基准（实际按材质宽度等比缩放）：
//   正面 (8,8,8,8)，第二层（帽子/头发）(40,8,8,8)，后者叠在脸之上。
static const CGFloat kSkinBaseWidth = 64.0;
static const CGFloat kHeadOriginX   = 8.0;
static const CGFloat kHeadOriginY   = 8.0;
static const CGFloat kHatOriginX    = 40.0;
static const CGFloat kHeadSide      = 8.0;

// 占位字号与方框高度的比例：46pt 头像约 19pt，与替换前的观感一致。
static const CGFloat kFallbackFontRatio = 0.41;

@interface A2SkinHeadView ()
@property (nonatomic, strong) UIImageView *headView;
@property (nonatomic, strong) UILabel *fallbackLabel;
@end

@implementation A2SkinHeadView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.clipsToBounds = YES;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    _headView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _headView.translatesAutoresizingMaskIntoConstraints = NO;
    _headView.contentMode = UIViewContentModeScaleToFill;
    // 皮肤是像素画：放大必须最近邻，否则糊成一团。
    _headView.layer.magnificationFilter = kCAFilterNearest;
    _headView.layer.minificationFilter = kCAFilterNearest;
    [self addSubview:_headView];

    _fallbackLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _fallbackLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _fallbackLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_fallbackLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_headView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_headView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_headView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_headView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [_fallbackLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_fallbackLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    [self refresh];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat side = CGRectGetHeight(self.bounds);
    self.layer.cornerRadius = side / 2;
    // 占位字号随头像尺寸走，避免为每个使用点各配一次。
    _fallbackLabel.font = [UIFont systemFontOfSize:MAX(11, side * kFallbackFontRatio)
                                             weight:UIFontWeightSemibold];
}

#pragma mark - 属性

- (void)setSkinPath:(NSString *)skinPath {
    if (skinPath == _skinPath || [skinPath isEqualToString:_skinPath]) return;
    _skinPath = [skinPath copy];
    [self refresh];
}

- (void)setFallbackText:(NSString *)fallbackText {
    if (fallbackText == _fallbackText || [fallbackText isEqualToString:_fallbackText]) return;
    _fallbackText = [fallbackText copy];
    [self refresh];
}

#pragma mark - 内容

- (void)refresh {
    UIImage *head = _skinPath.length ? [self headImageAtPath:_skinPath] : nil;

    _headView.image = head;
    _headView.hidden = (head == nil);
    _fallbackLabel.hidden = (head != nil);
    _fallbackLabel.text = head ? nil
        : (_fallbackText.length
           ? [[_fallbackText substringToIndex:1] uppercaseString] : @"?");

    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    // 有皮肤时头像自带画面，不铺底色；否则用容器色托住占位文字。
    self.backgroundColor = _headView.image ? UIColor.clearColor : t.cPrimaryContainer;
    _fallbackLabel.textColor = t.cOnPrimaryContainer;
}

#pragma mark - 裁剪

/// 从皮肤材质裁出「头」：正面 + 第二层（帽子/头发）叠加。
///
/// 关键：只在原始像素尺寸下拼合（画布 1pt=1px），不在这里放大 ——
/// 放大交给 headView 的最近邻过滤，避免在这里引入插值把像素画糊掉。
- (nullable UIImage *)headImageAtPath:(NSString *)path {
    UIImage *skin = [UIImage imageWithContentsOfFile:path];
    CGImageRef source = skin.CGImage;
    if (!source) return nil;

    CGFloat width = CGImageGetWidth(source);
    // 只认不小于 64 宽的标准材质；尺寸不对就不猜，交给调用方退回占位。
    if (width < kSkinBaseWidth) return nil;
    CGFloat s = width / kSkinBaseWidth;

    CGImageRef face = CGImageCreateWithImageInRect(
        source, CGRectMake(kHeadOriginX * s, kHeadOriginY * s,
                           kHeadSide * s, kHeadSide * s));
    if (!face) return nil;
    CGImageRef hat = CGImageCreateWithImageInRect(
        source, CGRectMake(kHatOriginX * s, kHeadOriginY * s,
                           kHeadSide * s, kHeadSide * s));

    CGSize size = CGSizeMake(kHeadSide * s, kHeadSide * s);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;      // 1pt = 1px：按原始像素拼合，不触发重采样
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *result = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        [[UIImage imageWithCGImage:face] drawInRect:rect];
        if (hat) [[UIImage imageWithCGImage:hat] drawInRect:rect];
    }];

    CGImageRelease(face);
    if (hat) CGImageRelease(hat);
    return result;
}

@end
