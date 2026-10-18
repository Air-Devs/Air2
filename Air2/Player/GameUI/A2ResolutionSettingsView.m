//
//  A2ResolutionSettingsView.m
//  Air2
//

#import "A2ResolutionSettingsView.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

@interface A2ResolutionSettingsView () <UITextFieldDelegate>
@property (nonatomic, strong) UISegmentedControl *ruleSegment;
@property (nonatomic, strong) UILabel *scaleTitle;
@property (nonatomic, strong) UISlider *scaleSlider;
@property (nonatomic, strong) UILabel *scaleValue;
@property (nonatomic, strong) UILabel *customTitle;
@property (nonatomic, strong) UITextField *widthField;
@property (nonatomic, strong) UITextField *heightField;
@property (nonatomic, strong) UILabel *resultLabel;
@property (nonatomic, strong) UIStackView *rootStack;
@end

@implementation A2ResolutionSettingsView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [self buildUI];
    [self syncFromManager];
    [self applyTheme];
    return self;
}

#pragma mark - 构建

- (void)buildUI {
    A2ResolutionManager *m = A2ResolutionManager.shared;

    // ---- 规则选择 ----
    _ruleSegment = [[UISegmentedControl alloc] initWithItems:@[@"固定", @"百分比", @"自定义"]];
    _ruleSegment.selectedSegmentIndex = m.rule;
    [_ruleSegment addTarget:self action:@selector(ruleChanged)
           forControlEvents:UIControlEventValueChanged];
    [_ruleSegment.heightAnchor constraintEqualToConstant:32].active = YES;

    // ---- 缩放滑块 ----
    _scaleTitle = [self makeLabel:@"渲染缩放" size:13 weight:UIFontWeightMedium];
    _scaleSlider = [[UISlider alloc] init];
    _scaleSlider.minimumValue = 0.5;
    _scaleSlider.maximumValue = 1.0;
    _scaleSlider.value = m.scale;
    [_scaleSlider addTarget:self action:@selector(scaleChanged)
           forControlEvents:UIControlEventValueChanged];
    _scaleValue = [self makeLabel:@"" size:13 weight:UIFontWeightRegular];
    _scaleValue.textAlignment = NSTextAlignmentRight;

    UIStackView *scaleHeader = [[UIStackView alloc] initWithArrangedSubviews:
                                @[_scaleTitle, _scaleValue]];
    scaleHeader.axis = UILayoutConstraintAxisHorizontal;
    scaleHeader.distribution = UIStackViewDistributionFill;

    // ---- 自定义尺寸 ----
    _customTitle = [self makeLabel:@"自定义尺寸" size:13 weight:UIFontWeightMedium];
    _widthField = [self makeNumberField:@"宽"];
    _heightField = [self makeNumberField:@"高"];

    UILabel *x = [self makeLabel:@"×" size:15 weight:UIFontWeightRegular];
    x.textAlignment = NSTextAlignmentCenter;

    UIStackView *customRow = [[UIStackView alloc] initWithArrangedSubviews:
                              @[_widthField, x, _heightField]];
    customRow.axis = UILayoutConstraintAxisHorizontal;
    customRow.spacing = A2SpaceS;
    customRow.distribution = UIStackViewDistributionFillEqually;

    // ---- 结果预览 ----
    _resultLabel = [self makeLabel:@"" size:12 weight:UIFontWeightRegular];
    _resultLabel.numberOfLines = 2;

    _rootStack = [[UIStackView alloc] initWithArrangedSubviews:
                  @[_ruleSegment, scaleHeader, _scaleSlider, _customTitle, customRow, _resultLabel]];
    _rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    _rootStack.axis = UILayoutConstraintAxisVertical;
    _rootStack.spacing = A2SpaceM;
    [self addSubview:_rootStack];

    [NSLayoutConstraint activateConstraints:@[
        [_rootStack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_rootStack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_rootStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_rootStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];
}

- (UILabel *)makeLabel:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.text = text;
    return l;
}

- (UITextField *)makeNumberField:(NSString *)placeholder {
    UITextField *f = [[UITextField alloc] init];
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.placeholder = placeholder;
    f.keyboardType = UIKeyboardTypeNumberPad;
    f.textAlignment = NSTextAlignmentCenter;
    f.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    f.layer.cornerRadius = 8;
    f.layer.cornerCurve = kCACornerCurveContinuous;
    f.delegate = self;
    [f.heightAnchor constraintEqualToConstant:34].active = YES;
    [f addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];
    return f;
}

#pragma mark - 同步

- (void)syncFromManager {
    A2ResolutionManager *m = A2ResolutionManager.shared;

    _ruleSegment.selectedSegmentIndex = m.rule;
    _scaleSlider.value = m.scale;
    _scaleValue.text = [NSString stringWithFormat:@"%.0f%%", m.scale * 100];

    if (CGSizeEqualToSize(m.customSize, CGSizeZero)) {
        _widthField.text = [NSString stringWithFormat:@"%.0f", m.nativeSize.width];
        _heightField.text = [NSString stringWithFormat:@"%.0f", m.nativeSize.height];
    } else {
        _widthField.text = [NSString stringWithFormat:@"%.0f", m.customSize.width];
        _heightField.text = [NSString stringWithFormat:@"%.0f", m.customSize.height];
    }

    [self updateVisibilityForRule:m.rule];
    [self updateResultLabel];
}

/// 按规则显示/隐藏控件组。
/// 不做置灰 —— 置灰会被误解为「不可用」，实际是「当前模式不需要」。
- (void)updateVisibilityForRule:(A2ResolutionRule)rule {
    BOOL showScale = (rule == A2ResolutionRuleFixed || rule == A2ResolutionRulePercentage);
    BOOL showCustom = (rule == A2ResolutionRuleCustom);

    _scaleTitle.superview.hidden = !showScale;
    _scaleSlider.hidden = !showScale;
    _customTitle.hidden = !showCustom;
    // customRow 是 customTitle 的兄弟，隐藏时一起处理
    for (UIView *v in _rootStack.arrangedSubviews) {
        if ([v isKindOfClass:UIStackView.class] && v != _scaleTitle.superview) {
            // 自定义行（含两个输入框）
            BOOL isCustomRow = ([v.subviews containsObject:_widthField]);
            if (isCustomRow) v.hidden = !showCustom;
        }
    }
}

- (void)updateResultLabel {
    A2ResolutionManager *m = A2ResolutionManager.shared;
    CGSize r = m.renderSize;
    CGSize n = m.nativeSize;
    CGFloat pct = (r.width * r.height) / MAX(1, n.width * n.height) * 100;

    _resultLabel.text = [NSString stringWithFormat:
        @"实际渲染 %.0f × %.0f（原生 %.0f × %.0f 的 %.0f%%）",
        r.width, r.height, n.width, n.height, pct];
}

#pragma mark - 交互

- (void)ruleChanged {
    A2ResolutionManager.shared.rule = (A2ResolutionRule)_ruleSegment.selectedSegmentIndex;
    [self updateVisibilityForRule:A2ResolutionManager.shared.rule];
    [self commit];
}

- (void)scaleChanged {
    // 滑块吸附到 5% 的整数档，避免值太零碎
    CGFloat v = round(_scaleSlider.value * 20) / 20.0;
    _scaleSlider.value = v;
    A2ResolutionManager.shared.scale = v;
    _scaleValue.text = [NSString stringWithFormat:@"%.0f%%", v * 100];
    [self commit];
}

- (void)textChanged {
    CGFloat w = _widthField.text.floatValue;
    CGFloat h = _heightField.text.floatValue;
    if (w > 0 && h > 0) {
        A2ResolutionManager.shared.customSize = CGSizeMake(w, h);
        [self commit];
    }
}

- (void)commit {
    [A2ResolutionManager.shared commitChange];
    [self updateResultLabel];
    if (self.onChange) self.onChange();
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    for (UIView *v in @[_scaleTitle, _customTitle, _resultLabel]) {
        ((UILabel *)v).textColor = t.cOnSurfaceVariant;
    }
    for (UIView *v in @[_widthField, _heightField]) {
        UITextField *f = (UITextField *)v;
        f.textColor = t.cOnSurface;
        f.backgroundColor = t.cSurfaceContainerHigh;
    }
    _scaleValue.textColor = t.cOnSurface;
    _scaleSlider.minimumTrackTintColor = t.cPrimary;
    _scaleSlider.maximumTrackTintColor = t.cOutlineVariant;

    _ruleSegment.selectedSegmentTintColor = t.cPrimary;
    [_ruleSegment setTitleTextAttributes:@{NSForegroundColorAttributeName: t.cOnSurfaceVariant}
                                forState:UIControlStateNormal];
    [_ruleSegment setTitleTextAttributes:@{NSForegroundColorAttributeName: t.cOnPrimary}
                                forState:UIControlStateSelected];
}

@end
