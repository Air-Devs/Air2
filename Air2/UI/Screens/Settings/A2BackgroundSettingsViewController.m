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
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface A2BackgroundSettingsViewController () <UIImagePickerControllerDelegate,
                                                 UINavigationControllerDelegate,
                                                 UIDocumentPickerDelegate>
@property (nonatomic, strong) UIImageView *previewView;
@property (nonatomic, strong) A2GlassCard *previewCard;
@property (nonatomic, strong) A2SettingsRow *sourceRow;
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
    A2ThemeManager *tm = A2ThemeManager.shared;
    A2BackgroundMediaKind kind = tm.backgroundMediaKind;

    // 视频背景用首帧海报做预览（和实际播放前的兜底画面一致）
    UIImage *img = (kind == A2BackgroundMediaKindVideo) ? tm.backgroundPosterImage
                                                        : tm.backgroundImage;
    _previewView.image = img;

    if (!img) {
        // 无媒体时用当前主题的渐变示意
        A2ColorTheme *theme = tm.theme;
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

    switch (kind) {
        case A2BackgroundMediaKindVideo: _sourceRow.valueText = @"视频"; break;
        case A2BackgroundMediaKindImage: _sourceRow.valueText = @"图片"; break;
        case A2BackgroundMediaKindNone:
        default:                         _sourceRow.valueText = @"未设置"; break;
    }
}

#pragma mark - 来源

- (void)setupSourceSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"背景来源"];
    section.footerText = @"图片或视频会作为整个启动器的背景（主页与所有二级页面）。"
                          "视频静音循环播放，进后台自动暂停；"
                          "右侧操作栏会叠加一层渐隐遮罩，保证卡片对比度稳定。";

    _sourceRow = [[A2SettingsRow alloc] init];
    _sourceRow.symbolName = @"photo.on.rectangle";
    _sourceRow.title = @"当前背景";
    _sourceRow.subtitle = @"图片与视频二选一，后设置的会替换前一个";
    _sourceRow.accessory = A2SettingsRowAccessoryNone;
    [section addRow:_sourceRow];

    A2SettingsRow *pickRow = [[A2SettingsRow alloc] init];
    pickRow.symbolName = @"photo.on.rectangle";
    pickRow.title = @"从相册选择图片";
    pickRow.accessory = A2SettingsRowAccessoryDisclosure;
    pickRow.onTap = ^{ [self presentImagePicker]; };
    [section addRow:pickRow];

    A2SettingsRow *videoRow = [[A2SettingsRow alloc] init];
    videoRow.symbolName = @"film";
    videoRow.title = @"从文件选择视频";
    videoRow.subtitle = @"支持 mov / mp4 等系统可解码格式";
    videoRow.accessory = A2SettingsRowAccessoryDisclosure;
    videoRow.onTap = ^{ [self presentVideoPicker]; };
    [section addRow:videoRow];

    A2SettingsRow *clearRow = [[A2SettingsRow alloc] init];
    clearRow.symbolName = @"arrow.counterclockwise";
    clearRow.title = @"恢复默认外观";
    clearRow.subtitle = @"清除自定义图片/视频，回到主题纯色";
    clearRow.accessory = A2SettingsRowAccessoryDisclosure;
    clearRow.showsSeparator = NO;
    clearRow.onTap = ^{
        [A2ThemeManager.shared clearBackgroundMedia];
        [self refreshPreview];
        [A2Toast show:@"已恢复默认外观" inView:self.view];
    };
    [section addRow:clearRow];

    [self addSection:section];
    [self refreshPreview];   // sourceRow 已创建，回填「当前背景」的值
}

#pragma mark - 调整

- (void)setupAdjustSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"显示调整"];
    A2ThemeManager *tm = A2ThemeManager.shared;

    // ---- 模糊 ----
    _blurRow = [[A2SettingsRow alloc] init];
    _blurRow.symbolName = @"drop.halffull";
    _blurRow.title = @"背景模糊";
    _blurRow.subtitle = @"0 为清晰原图，调高后逐级柔化（全页面生效）";
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
    _overlayRow.subtitle = @"模糊开启时按比例压暗；清晰模式不生效";
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

#pragma mark - 选视频

/// 用文档选择器选本地视频。
///
/// content types 用 UTTypeMovie 而不是字符串 —— 后者在新系统上
/// 可能匹配不到，选择器里会出现「文件变灰不可选」。
- (void)presentVideoPicker {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie]
                                                                   asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [controller dismissViewControllerAnimated:YES completion:nil];

    NSURL *url = urls.firstObject;
    if (!url) return;

    [A2Toast show:@"正在导入视频…" inView:self.view];
    __weak typeof(self) weakSelf = self;
    [A2ThemeManager.shared importBackgroundVideoFromURL:url
                                             completion:^(BOOL ok, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (!ok) {
            [A2Toast show:(error.localizedDescription ?: @"视频导入失败") inView:self.view];
            return;
        }
        [self refreshPreview];
        [A2Toast show:@"视频背景已更新" inView:self.view];
    }];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:nil];
}

@end
