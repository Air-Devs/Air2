//
//  A2BackgroundSettingsViewController.m
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

#import "A2BackgroundSettingsViewController.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2BackgroundSettingsViewController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) UIImageView *previewView;
@property (nonatomic, strong) A2GlassCard *previewCard;
@property (nonatomic, strong) A2SettingsRow *blurRow;
@property (nonatomic, strong) A2SettingsRow *overlayRow;
@property (nonatomic, strong) A2SettingsRow *fadeRow;
@end

@implementation A2BackgroundSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"自定义背景";

    [self setupPreview];
    [self setupSourceSection];
    [self setupAdjustSection];
}

#pragma mark - 预览

- (void)setupPreview {
    _previewCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _previewCard.cornerRadius = A2RadiusL;
    _previewCard.contentInsets = UIEdgeInsetsZero;

    _previewView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _previewView.translatesAutoresizingMaskIntoConstraints = NO;
    _previewView.contentMode = UIViewContentModeScaleAspectFill;
    _previewView.clipsToBounds = YES;
    _previewView.layer.cornerRadius = A2RadiusL;
    _previewView.layer.cornerCurve = kCACornerCurveContinuous;
    _previewView.backgroundColor = A2ThemeManager.shared.scheme.cSurfaceContainerHigh;

    [_previewCard.contentView addSubview:_previewView];

    [NSLayoutConstraint activateConstraints:@[
        [_previewView.topAnchor constraintEqualToAnchor:_previewCard.contentView.topAnchor],
        [_previewView.bottomAnchor constraintEqualToAnchor:_previewCard.contentView.bottomAnchor],
        [_previewView.leadingAnchor constraintEqualToAnchor:_previewCard.contentView.leadingAnchor],
        [_previewView.trailingAnchor constraintEqualToAnchor:_previewCard.contentView.trailingAnchor],
        [_previewView.heightAnchor constraintEqualToConstant:150],
    ]];

    [self addSection:_previewCard];
    [self refreshPreview];
}

- (void)refreshPreview {
    UIImage *img = A2ThemeManager.shared.backgroundImage;
    _previewView.image = img;
    if (!img) {
        // 无图时用当前主题的渐变示意
        A2ColorTheme *theme = A2ThemeManager.shared.theme;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(2, 1), YES, 1.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        NSArray<UIColor *> *colors = theme.backgroundGradient;
        for (NSUInteger i = 0; i < colors.count; i++) {
            CGContextSetFillColorWithColor(ctx, colors[i].CGColor);
            CGContextFillRect(ctx, CGRectMake(i, 0, 1, 1));
        }
        UIImage *grad = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        _previewView.image = grad;
    }
}

#pragma mark - 来源

- (void)setupSourceSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"背景来源"];
    section.footerText = @"背景图片显示在主界面左侧的个性化区域，"
                          "右侧操作栏会叠加一层渐隐遮罩，保证卡片对比度稳定。";

    A2SettingsRow *pickRow = [[A2SettingsRow alloc] init];
    pickRow.symbolName = @"photo.on.rectangle";
    pickRow.title = @"从相册选择";
    pickRow.accessory = A2SettingsRowAccessoryDisclosure;
    pickRow.onTap = ^{ [self presentImagePicker]; };
    [section addRow:pickRow];

    A2SettingsRow *clearRow = [[A2SettingsRow alloc] init];
    clearRow.symbolName = @"arrow.counterclockwise";
    clearRow.title = @"恢复默认渐变";
    clearRow.subtitle = @"使用当前主题的配色";
    clearRow.accessory = A2SettingsRowAccessoryDisclosure;
    clearRow.showsSeparator = NO;
    clearRow.onTap = ^{
        [A2ThemeManager.shared clearBackgroundImage];
        [self refreshPreview];
        [A2Toast show:@"已恢复默认渐变" inView:self.view];
    };
    [section addRow:clearRow];

    [self addSection:section];
}

#pragma mark - 调整

- (void)setupAdjustSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"显示调整"];
    A2ThemeManager *tm = A2ThemeManager.shared;

    // ---- 模糊 ----
    _blurRow = [[A2SettingsRow alloc] init];
    _blurRow.symbolName = @"drop.halffull";
    _blurRow.title = @"背景模糊";
    _blurRow.subtitle = @"让背景更柔和，也让卡片文字更清晰";
    _blurRow.valueText = [NSString stringWithFormat:@"%ld%%", (long)tm.backgroundBlur];
    UISlider *blurSlider = [self makeSlider:0 max:100 value:tm.backgroundBlur];
    __weak typeof(self) weakSelf = self;
    [blurSlider addAction:[UIAction actionWithHandler:^(UIAction *action) {
        UISlider *s = action.sender;
        A2ThemeManager.shared.backgroundBlur = (NSInteger)s.value;
        weakSelf.blurRow.valueText = [NSString stringWithFormat:@"%ld%%", (long)(NSInteger)s.value];
    }] forControlEvents:UIControlEventValueChanged];
    _blurRow.customAccessoryView = blurSlider;
    [section addRow:_blurRow];

    // ---- 暗色遮罩 ----
    _overlayRow = [[A2SettingsRow alloc] init];
    _overlayRow.symbolName = @"circle.lefthalf.filled";
    _overlayRow.title = @"暗色模式遮罩";
    _overlayRow.subtitle = @"暗色下压暗背景，提升可读性";
    _overlayRow.valueText = [NSString stringWithFormat:@"%.0f%%", tm.backgroundDarkOverlay * 100];
    UISlider *overlaySlider = [self makeSlider:0 max:80 value:tm.backgroundDarkOverlay * 100];
    [overlaySlider addAction:[UIAction actionWithHandler:^(UIAction *action) {
        UISlider *s = action.sender;
        A2ThemeManager.shared.backgroundDarkOverlay = s.value / 100.0;
        weakSelf.overlayRow.valueText = [NSString stringWithFormat:@"%.0f%%", s.value];
    }] forControlEvents:UIControlEventValueChanged];
    _overlayRow.customAccessoryView = overlaySlider;
    [section addRow:_overlayRow];

    // ---- 右侧渐隐 ----
    _fadeRow = [[A2SettingsRow alloc] init];
    _fadeRow.symbolName = @"rectangle.righthalf.inset.filled";
    _fadeRow.title = @"操作栏渐隐宽度";
    _fadeRow.subtitle = @"背景向操作栏过渡的遮罩范围";
    _fadeRow.valueText = [NSString stringWithFormat:@"%.0f%%", tm.backgroundFadeRatio * 100];
    _fadeRow.showsSeparator = NO;
    UISlider *fadeSlider = [self makeSlider:0 max:70 value:tm.backgroundFadeRatio * 100];
    [fadeSlider addAction:[UIAction actionWithHandler:^(UIAction *action) {
        UISlider *s = action.sender;
        A2ThemeManager.shared.backgroundFadeRatio = s.value / 100.0;
        weakSelf.fadeRow.valueText = [NSString stringWithFormat:@"%.0f%%", s.value];
    }] forControlEvents:UIControlEventValueChanged];
    _fadeRow.customAccessoryView = fadeSlider;
    [section addRow:_fadeRow];

    [self addSection:section];
}

- (UISlider *)makeSlider:(CGFloat)min max:(CGFloat)max value:(CGFloat)value {
    UISlider *s = [[UISlider alloc] initWithFrame:CGRectZero];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    s.minimumValue = min;
    s.maximumValue = max;
    s.value = value;
    s.minimumTrackTintColor = A2ThemeManager.shared.scheme.cPrimary;
    [NSLayoutConstraint activateConstraints:@[
        [s.widthAnchor constraintEqualToConstant:130],
    ]];
    return s;
}

#pragma mark - 选图

- (void)presentImagePicker {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationPopover;
    picker.popoverPresentationController.sourceView = self.view;
    picker.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                 CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:nil];

    if (!image) return;

    A2ThemeManager *tm = A2ThemeManager.shared;
    [tm persistBackgroundImage:image];
    tm.backgroundImage = image;

    [self refreshPreview];
    [A2Toast show:@"背景已更新" inView:self.view];

    // 「动态取色」主题依赖背景图，换了图提示一下
    if (tm.selectedKind == A2ThemeKindDynamic) {
        [A2Toast show:@"已根据新背景重新提取主题色" inView:self.view];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end
