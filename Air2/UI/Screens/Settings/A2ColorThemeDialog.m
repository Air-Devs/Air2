//
//  A2ColorThemeDialog.m
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

#import "A2ColorThemeDialog.h"
#import "A2ColorWheel.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2PrimaryButton.h"
#import "A2Log.h"
// 「插件主题」分组的数据来源：贡献点注册表（已启用插件）+ 安装器（读展示名）
#import "A2PluginContributionHost.h"
#import "A2PluginInstaller.h"
#import "A2PluginManifest.h"

/// 配色风格选项（名称与说明统一从 A2PaletteStyle 取，避免两处维护）
static NSArray<NSArray<NSString *> *> *A2PaletteStyleOptions(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger i = 0; i < 4; i++) {
        [out addObject:@[ A2PaletteStyleName((A2PaletteStyle)i),
                          A2PaletteStyleDescription((A2PaletteStyle)i) ]];
    }
    return out;
}

#pragma mark - 插件主题选项

/// 一条「插件贡献的颜色主题」。
///
/// token 原样来自贡献点注册表（安装期已校验过），这里只补两样**纯展示**信息：
/// 标题（插件 manifest 的 `name`）与预览色（这套 token 实际会得到的主色）。
@interface A2PluginThemeOption : NSObject

@property (nonatomic, copy) NSString *pluginId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *tokens;
/// 预览色点用。插件没给 primary 时它是回落后的当前主色，因此永远非 nil。
@property (nonatomic, strong) UIColor *previewColor;

@end

@implementation A2PluginThemeOption
@end

/// 已启用（= 已接入贡献点注册表）且**真的声明了**主题 token 的插件。
///
/// 顺序沿用 `attachedPluginIds`（字典序）：slot 那套 (priority, layer, …) 排序键是给
/// 「谁先渲染」用的，这里是给人挑颜色的列表，稳定可预期的顺序更好。
///
/// 返回空数组 ⇒ 调用方整组不画（**不留空分组**：没插件时对话框与以前一模一样）。
static NSArray<A2PluginThemeOption *> *A2PluginThemeOptions(void) {
    A2PluginContributionRegistry *registry = [A2PluginContributionHost contributionRegistry];
    NSArray<NSString *> *pluginIds = registry.attachedPluginIds;
    if (pluginIds.count == 0) return @[];

    A2PluginInstaller *installer = [A2PluginContributionHost installer];
    A2ColorTheme *current = A2ThemeManager.shared.theme;

    NSMutableArray<A2PluginThemeOption *> *options = [NSMutableArray array];
    for (NSString *pluginId in pluginIds) {
        NSDictionary<NSString *, NSString *> *tokens = [registry themeTokensForPlugin:pluginId];
        if (tokens.count == 0) continue;      // 这个插件不提供颜色主题

        // 标题走 manifest 的 `name`；读不出来就用 id —— 一个插件读不动不该让整组少一行。
        NSString *title = pluginId;
        A2PluginManifest *manifest = [installer installedManifestForPluginId:pluginId error:NULL];
        if (manifest.name.length > 0) title = manifest.name;

        A2PluginThemeOption *option = [A2PluginThemeOption new];
        option.pluginId = pluginId;
        option.title = title;
        option.tokens = tokens;
        // 预览色 = 这套 token 真正会得到的主色（含「插件没给 ⇒ 回落当前主题」）。
        // 颜色计算只走 A2ColorTheme 一处，弹窗不自己解析 hex，避免两套解析规则。
        option.previewColor = [A2ColorTheme themeWithPluginTokens:tokens
                                                             name:title
                                                             desc:@""
                                                             base:current].lightPrimary;
        [options addObject:option];
    }

    [A2Log criterion:@"[A2-PLUGIN-UI] 颜色主题 列出来自插件的主题 %lu 套（已启用插件 %lu 个）",
     (unsigned long)options.count, (unsigned long)pluginIds.count];
    return options;
}

#pragma mark - 风格选项行

@interface A2StyleOptionRow : UIControl
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UIView *radioOuter;
@property (nonatomic, strong) UIView *radioInner;
/// 文字栈（色点要约束到它的右边，所以留引用）
@property (nonatomic, strong) UIStackView *textStack;
/// 右侧色点：插件主题用它预览主色。设 nil ⇒ 不建视图（配色风格行保持原样）。
@property (nonatomic, strong, nullable) UIColor *swatchColor;
// selected 沿用 UIControl 自带的（不要重声明 BOOL selected，
// 否则子类不会自动合成 _selected，见 CI 报错根因）
@end

@implementation A2StyleOptionRow {
    UIView *_swatchView;
}

- (instancetype)initWithTitle:(NSString *)title desc:(NSString *)desc {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = A2RadiusM;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    _radioOuter = [[UIView alloc] initWithFrame:CGRectZero];
    _radioOuter.translatesAutoresizingMaskIntoConstraints = NO;
    _radioOuter.layer.cornerRadius = 10;
    _radioOuter.layer.borderWidth = 2;
    _radioOuter.userInteractionEnabled = NO;

    _radioInner = [[UIView alloc] initWithFrame:CGRectZero];
    _radioInner.translatesAutoresizingMaskIntoConstraints = NO;
    _radioInner.layer.cornerRadius = 5;
    _radioInner.hidden = YES;
    [_radioOuter addSubview:_radioInner];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _nameLabel.text = title;

    _descLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _descLabel.font = [A2Typography caption];
    _descLabel.text = desc;
    _descLabel.numberOfLines = 1;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel, _descLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 1;
    _textStack = textStack;

    [self addSubview:_radioOuter];
    [self addSubview:textStack];

    [NSLayoutConstraint activateConstraints:@[
        [_radioOuter.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceM],
        [_radioOuter.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_radioOuter.widthAnchor constraintEqualToConstant:20],
        [_radioOuter.heightAnchor constraintEqualToConstant:20],
        [_radioInner.centerXAnchor constraintEqualToAnchor:_radioOuter.centerXAnchor],
        [_radioInner.centerYAnchor constraintEqualToAnchor:_radioOuter.centerYAnchor],
        [_radioInner.widthAnchor constraintEqualToConstant:10],
        [_radioInner.heightAnchor constraintEqualToConstant:10],

        [textStack.leadingAnchor constraintEqualToAnchor:_radioOuter.trailingAnchor constant:A2SpaceM],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-A2SpaceM],
        [textStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:48],
    ]];

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    _radioInner.hidden = !selected;
    [self applyTheme];
}

- (void)setSwatchColor:(UIColor *)swatchColor {
    _swatchColor = swatchColor;
    if (!swatchColor) {
        _swatchView.hidden = YES;
        return;
    }
    if (!_swatchView) {
        _swatchView = [[UIView alloc] initWithFrame:CGRectZero];
        _swatchView.translatesAutoresizingMaskIntoConstraints = NO;
        _swatchView.layer.cornerRadius = 7;
        _swatchView.layer.cornerCurve = kCACornerCurveContinuous;
        _swatchView.userInteractionEnabled = NO;
        [self addSubview:_swatchView];
        // 色点只在插件主题行上建；配色风格行的约束与排版因此一字未改。
        [NSLayoutConstraint activateConstraints:@[
            [_swatchView.widthAnchor constraintEqualToConstant:14],
            [_swatchView.heightAnchor constraintEqualToConstant:14],
            [_swatchView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceM],
            [_swatchView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_swatchView.leadingAnchor
                                                                constant:-A2SpaceS],
        ]];
    }
    _swatchView.hidden = NO;
    _swatchView.backgroundColor = swatchColor;
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _radioOuter.layer.borderColor = (self.isSelected ? t.cPrimary : t.cOutline).CGColor;
    _radioInner.backgroundColor = t.cPrimary;
    _nameLabel.textColor = t.cOnSurface;
    _descLabel.textColor = t.cOnSurfaceVariant;
    self.backgroundColor = self.isSelected
        ? [t.cPrimaryContainer colorWithAlphaComponent:0.5]
        : UIColor.clearColor;
}

@end

#pragma mark - 弹窗

@interface A2ColorThemeDialog () <A2ColorWheelDelegate>
@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) A2ColorWheel *wheel;
@property (nonatomic, strong) UILabel *hexLabel;
@property (nonatomic, strong) NSMutableArray<A2StyleOptionRow *> *styleRows;

/// 「插件主题」分组（来自已启用插件的 resolvedThemeTokens）。空数组 ⇒ 整组不画。
@property (nonatomic, copy) NSArray<A2PluginThemeOption *> *pluginOptions;
@property (nonatomic, strong) NSMutableArray<A2StyleOptionRow *> *pluginRows;
/// 当前选中的插件主题；nil = 用色盘（与「配色风格」互斥）
@property (nonatomic, strong, nullable) A2PluginThemeOption *selectedPluginOption;

@property (nonatomic, strong, nullable) UIColor *seedColor;
@property (nonatomic, assign) A2PaletteStyle style;
@property (nonatomic, copy, nullable) void (^onComplete)(UIColor *, A2PaletteStyle, NSString *);
@end

@implementation A2ColorThemeDialog

+ (void)presentFrom:(UIViewController *)host
          seedColor:(UIColor *)seedColor
              style:(A2PaletteStyle)style
         onComplete:(void (^)(UIColor *, A2PaletteStyle, NSString *))onComplete {

    A2ColorThemeDialog *vc = [[A2ColorThemeDialog alloc] init];
    vc.seedColor = seedColor ?: A2ThemeManager.shared.scheme.cPrimary;
    vc.style = style;
    vc.onComplete = onComplete;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [host presentViewController:vc animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    // 背景：半透明遮罩，点击可关闭
    _backdrop = [[UIView alloc] initWithFrame:CGRectZero];
    _backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    _backdrop.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismiss)];
    [_backdrop addGestureRecognizer:tap];
    [self.view addSubview:_backdrop];

    [self setupCard];

    [NSLayoutConstraint activateConstraints:@[
        [_backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (void)setupCard {
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.layer.cornerRadius = A2RadiusXL;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    [self.view addSubview:_card];

    // ---- 标题 ----
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    title.text = @"颜色主题";
    title.textAlignment = NSTextAlignmentCenter;

    // ---- 左列：配色风格 ----
    UILabel *styleTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    styleTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    styleTitle.text = @"配色风格";

    _styleRows = [NSMutableArray array];
    UIStackView *styleStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    styleStack.translatesAutoresizingMaskIntoConstraints = NO;
    styleStack.axis = UILayoutConstraintAxisVertical;
    styleStack.spacing = A2SpaceXS;

    NSArray<NSArray<NSString *> *> *options = A2PaletteStyleOptions();
    for (NSUInteger i = 0; i < options.count; i++) {
        A2StyleOptionRow *row = [[A2StyleOptionRow alloc] initWithTitle:options[i][0]
                                                                   desc:options[i][1]];
        row.tag = i;
        [row addTarget:self action:@selector(styleTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_styleRows addObject:row];
        [styleStack addArrangedSubview:row];
    }

    UIStackView *leftColumn = [[UIStackView alloc] initWithArrangedSubviews:@[styleTitle, styleStack]];
    leftColumn.translatesAutoresizingMaskIntoConstraints = NO;
    leftColumn.axis = UILayoutConstraintAxisVertical;
    leftColumn.spacing = A2SpaceM;
    leftColumn.alignment = UIStackViewAlignmentFill;

    // ---- 左列追加：插件主题（来自已启用插件的主题 token）----
    //   没有插件提供色板时 `_pluginOptions` 为空 ⇒ 分组整个不建，等价于这个功能不存在。
    _pluginOptions = A2PluginThemeOptions();
    _pluginRows = [NSMutableArray array];
    UIView *pluginGroup = [self buildPluginThemeGroup];
    if (pluginGroup) {
        [leftColumn addArrangedSubview:pluginGroup];
        leftColumn.spacing = A2SpaceL;   // 两组之间留大一点，否则看起来是一串同级的选项
    }

    // ---- 右列：大色盘 + 明度 + 色值 ----
    _wheel = [[A2ColorWheel alloc] initWithFrame:CGRectZero];
    _wheel.translatesAutoresizingMaskIntoConstraints = NO;
    _wheel.delegate = self;
    [_wheel setColor:_seedColor animated:NO];

    _hexLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _hexLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
    _hexLabel.textAlignment = NSTextAlignmentCenter;

    UIStackView *rightColumn = [[UIStackView alloc] initWithArrangedSubviews:@[_wheel, _hexLabel]];
    rightColumn.translatesAutoresizingMaskIntoConstraints = NO;
    rightColumn.axis = UILayoutConstraintAxisVertical;
    rightColumn.spacing = A2SpaceM;

    // ---- 分栏 ----
    UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.tag = 801;

    UIStackView *bodyStack = [[UIStackView alloc] initWithArrangedSubviews:@[leftColumn, rightColumn]];
    bodyStack.translatesAutoresizingMaskIntoConstraints = NO;
    bodyStack.axis = UILayoutConstraintAxisHorizontal;
    bodyStack.spacing = A2SpaceXL;
    bodyStack.alignment = UIStackViewAlignmentTop;

    // ---- 底部按钮 ----
    A2PrimaryButton *cancel = [[A2PrimaryButton alloc] initWithTitle:@"取消" style:A2ButtonStyleSecondary];
    [cancel addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];

    A2PrimaryButton *confirm = [[A2PrimaryButton alloc] initWithTitle:@"确认" style:A2ButtonStylePrimary];
    [confirm addTarget:self action:@selector(confirm) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[cancel, confirm]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.distribution = UIStackViewDistributionFillEqually;
    buttonRow.spacing = A2SpaceM;

    [_card addSubview:title];
    [_card addSubview:bodyStack];
    [_card addSubview:divider];
    [_card addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        // 卡片：居中，定宽 540（小屏被 92% 上限压住时内容等比压缩）。
        [_card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        ({
            NSLayoutConstraint *w = [_card.widthAnchor constraintEqualToConstant:540];
            w.priority = UILayoutPriorityDefaultHigh;
            w;
        }),
        [_card.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor
                                                  multiplier:0.92],
        [_card.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor
                                                   multiplier:0.92],

        [title.topAnchor constraintEqualToAnchor:_card.topAnchor constant:A2SpaceXL],
        [title.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceXL],
        [title.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceXL],

        [bodyStack.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:A2SpaceXL],
        [bodyStack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceXL],
        [bodyStack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceXL],

        // 左列固定 200，右列吃掉剩余（最小屏横屏也能排下）
        [leftColumn.widthAnchor constraintEqualToConstant:200],
        [_wheel.widthAnchor constraintGreaterThanOrEqualToConstant:220],
        [_wheel.heightAnchor constraintEqualToConstant:200],

        [divider.topAnchor constraintEqualToAnchor:bodyStack.bottomAnchor constant:A2SpaceXL],
        [divider.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceXL],
        [divider.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceXL],
        [divider.heightAnchor constraintEqualToConstant:1],

        [buttonRow.topAnchor constraintEqualToAnchor:divider.bottomAnchor constant:A2SpaceL],
        [buttonRow.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceL],
        [buttonRow.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceL],
        [buttonRow.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-A2SpaceL],
        [buttonRow.heightAnchor constraintEqualToConstant:A2ButtonHeight],
    ]];

    [self restoreSelectedPluginTheme];
    [self refreshStyleSelection];
    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

#pragma mark - 插件主题分组

/// 建「插件主题」分组：小标题 + 一列单选行（行右侧带主色点）。
/// 没有可选主题时返回 nil —— 调用方据此**整组不建**，不留空标题、不占位。
///
/// 行数多时行区自己滚：卡片高度被「≤ 92% 屏幕」限死，
/// 装十几个插件不能把弹窗顶出屏幕（那会让底部按钮点不到）。
- (nullable UIView *)buildPluginThemeGroup {
    if (_pluginOptions.count == 0) return nil;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.text = @"插件主题";

    UIStackView *rows = [[UIStackView alloc] initWithFrame:CGRectZero];
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = A2SpaceXS;

    for (NSUInteger i = 0; i < _pluginOptions.count; i++) {
        A2PluginThemeOption *option = _pluginOptions[i];
        NSString *desc = [NSString stringWithFormat:@"插件贡献 · %lu 个色值",
                          (unsigned long)option.tokens.count];
        A2StyleOptionRow *row = [[A2StyleOptionRow alloc] initWithTitle:option.title desc:desc];
        row.tag = (NSInteger)i;
        row.swatchColor = option.previewColor;
        [row addTarget:self action:@selector(pluginThemeTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_pluginRows addObject:row];
        [rows addArrangedSubview:row];
    }

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.alwaysBounceVertical = NO;
    [scroll addSubview:rows];

    // 一行 48（A2StyleOptionRow 的最小高度）+ 4 间距；最多露 2 行，第 3 行起滚动。
    // ★为什么是 2★ 卡片高度被「≤ 92% 屏幕」限死：2 行让 667pt 及以上的机型仍有富余，
    //   3 行会把 iPhone 8 / SE2 那一档顶到上限。多出来的行滚动可见即可。
    CGFloat visibleRows = MIN(2.0, (CGFloat)_pluginOptions.count);
    CGFloat visibleHeight = visibleRows * 48.0 + MAX(0.0, visibleRows - 1.0) * A2SpaceXS;

    [NSLayoutConstraint activateConstraints:@[
        [scroll.heightAnchor constraintEqualToConstant:visibleHeight],
        [rows.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [rows.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [rows.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [rows.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [rows.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
    ]];

    UIStackView *group = [[UIStackView alloc] initWithArrangedSubviews:@[title, scroll]];
    group.translatesAutoresizingMaskIntoConstraints = NO;
    group.axis = UILayoutConstraintAxisVertical;
    group.spacing = A2SpaceXS;
    return group;
}

/// 打开弹窗时，若当前生效的就是某个插件主题，把对应行预选上 ——
/// 否则用户看不到「现在用的是哪一套」，只能靠猜。
- (void)restoreSelectedPluginTheme {
    NSString *activePluginId = A2ThemeManager.shared.pluginThemePluginId;
    if (activePluginId.length == 0) return;
    for (A2PluginThemeOption *option in _pluginOptions) {
        if ([option.pluginId isEqualToString:activePluginId]) {
            self.selectedPluginOption = option;
            return;
        }
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 交互

- (void)styleTapped:(A2StyleOptionRow *)sender {
    self.style = (A2PaletteStyle)sender.tag;
    // 选「配色风格」= 回到色盘那一路：确认后按「种子色 + 风格」重算，插件色板让位
    self.selectedPluginOption = nil;
    [self refreshStyleSelection];

    UISelectionFeedbackGenerator *fb = [UISelectionFeedbackGenerator new];
    [fb selectionChanged];
}

/// 选中一条「插件主题」（确认时才真正生效，取消仍然什么都不改）
- (void)pluginThemeTapped:(A2StyleOptionRow *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= _pluginOptions.count) return;
    self.selectedPluginOption = _pluginOptions[(NSUInteger)sender.tag];
    [self refreshStyleSelection];

    UISelectionFeedbackGenerator *fb = [UISelectionFeedbackGenerator new];
    [fb selectionChanged];
}

- (void)refreshStyleSelection {
    // 插件主题与「配色风格」是互斥的两条来源：只能亮一个圆点，
    // 否则用户看到两个都选中，却不知道到底哪套色板在生效。
    BOOL usingPluginTheme = (self.selectedPluginOption != nil);
    for (A2StyleOptionRow *row in _styleRows) {
        row.selected = (!usingPluginTheme && row.tag == (NSInteger)self.style);
    }
    for (NSUInteger i = 0; i < _pluginRows.count && i < _pluginOptions.count; i++) {
        _pluginRows[i].selected = usingPluginTheme &&
            [_pluginOptions[i].pluginId isEqualToString:self.selectedPluginOption.pluginId];
    }
}

- (void)dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)confirm {
    A2PluginThemeOption *pluginOption = self.selectedPluginOption;
    if (pluginOption) {
        // 插件主题由弹窗自己应用：token 只在它手里，而调用方只知道「种子色 + 风格」。
        // 回调里把 pluginThemeId 带出去，调用方据此**不写种子色**
        // —— 写下去会立刻把插件色板覆盖成种子色推导的结果。
        void (^cb)(UIColor *, A2PaletteStyle, NSString *) = self.onComplete;
        A2PaletteStyle style = self.style;
        NSString *pluginId = pluginOption.pluginId;
        NSString *title = pluginOption.title;
        NSDictionary<NSString *, NSString *> *tokens = pluginOption.tokens;
        [self dismissViewControllerAnimated:YES completion:^{
            [A2ThemeManager.shared applyPluginThemeFromPlugin:pluginId name:title tokens:tokens];
            if (cb) cb(nil, style, pluginId);
        }];
        return;
    }

    UIColor *c = _wheel.color;
    void (^cb)(UIColor *, A2PaletteStyle, NSString *) = self.onComplete;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(c, self.style, nil);
    }];
}

#pragma mark - A2ColorWheelDelegate

- (void)colorWheel:(A2ColorWheel *)wheel didChangeColor:(UIColor *)color {
    [self updateHexLabel:color];
}

- (void)colorWheel:(A2ColorWheel *)wheel didFinishWithColor:(UIColor *)color {
    [self updateHexLabel:color];
    // 动了色盘 = 想用这个种子色：插件主题取消选择（否则确认后色盘白调）
    if (self.selectedPluginOption) {
        self.selectedPluginOption = nil;
        [self refreshStyleSelection];
    }
    UISelectionFeedbackGenerator *fb = [UISelectionFeedbackGenerator new];
    [fb selectionChanged];
}

- (void)updateHexLabel:(UIColor *)color {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    _hexLabel.text = [NSString stringWithFormat:@"#%02X%02X%02X",
                      (unsigned)(r * 255), (unsigned)(g * 255), (unsigned)(b * 255)];
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _card.backgroundColor = t.cSurfaceContainerHigh;
    for (UILabel *l in _card.subviews) {
        if ([l isKindOfClass:UILabel.class]) l.textColor = t.cOnSurface;
    }
    for (UIView *v in _card.subviews) {
        if (v.tag == 801) v.backgroundColor = t.cOutlineVariant;
    }
    _hexLabel.textColor = t.cOnSurfaceVariant;
    [self updateHexLabel:_wheel.color];
}

@end
