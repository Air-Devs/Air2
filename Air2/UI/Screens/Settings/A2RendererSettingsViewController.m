//
//  A2RendererSettingsViewController.m
//  Air2
//
//  渲染器选择页 —— 对照 ZL2 的 RendererSettingsScreen.kt。
//
//  **不要用系统 UIAlertController。** 最初我用了 ActionSheet，
//  但 ZL2 的做法是【卡片内嵌就地展开】：
//
//    ┌────────────────────────────────────┐
//    │ 渲染器                      ⬇      │
//    │ 全局默认的渲染器…                    │
//    │ 当前选择项：NG-GL4ES（内置）         │
//    ├────────────────────────────────────┤  ← 展开后多出这块
//    │ 描述文字…                            │
//    │  ┌──────────────────────────────┐  │
//    │  │ NG-GL4ES                ✓   │  │  ← 选中态：填充 + 勾
//    │  └──────────────────────────────┘  │
//    │  ┌──────────────────────────────┐  │
//    │  │ Zink                         │  │
//    │  └──────────────────────────────┘  │
//    ├────────────────────────────────────┤
//    │ 可用渲染器                          │
//    │  [图标] NG-GL4ES        ✓          │
//    │         说明文字…                   │
//    └────────────────────────────────────┘
//
//  展开列表在【同一个卡片内】，带描述头，选中项高亮。
//

#import "A2RendererSettingsViewController.h"
#import "A2RendererRegistry.h"
#import "A2RendererPlugin.h"
#import "A2RendererImporter.h"
#import "A2RendererPluginViewController.h"
#import "A2GlassCard.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

#pragma mark - 选择行（卡片内的可展开列表项）

@interface A2RendererChoiceRow : UIControl
@property (nonatomic, strong, readonly) A2RendererEntry *entry;
- (instancetype)initWithEntry:(A2RendererEntry *)entry chosen:(BOOL)chosen;
- (void)applyTheme;
@end

@implementation A2RendererChoiceRow {
    UILabel *_nameLabel;
    UIImageView *_checkView;
}

- (instancetype)initWithEntry:(A2RendererEntry *)entry chosen:(BOOL)chosen {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _entry = entry;

    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = A2RadiusM;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.selected = chosen;

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _nameLabel.text = entry.displayName;

    // 不可用的加后缀而不是隐藏 —— 用户要知道为什么不能选
    if (entry.availability != A2RendererAvailabilityAvailable) {
        _nameLabel.text = [entry.displayName stringByAppendingString:@"（不可用）"];
    }

    _checkView = [[UIImageView alloc] initWithImage:
                  [UIImage systemImageNamed:@"checkmark"]];
    _checkView.translatesAutoresizingMaskIntoConstraints = NO;
    _checkView.contentMode = UIViewContentModeScaleAspectFit;
    _checkView.hidden = !chosen;

    [self addSubview:_nameLabel];
    [self addSubview:_checkView];

    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintEqualToConstant:44],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                 constant:A2SpaceM],
        [_nameLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_checkView.leadingAnchor
                                                            constant:-A2SpaceS],

        [_checkView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                  constant:-A2SpaceM],
        [_checkView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_checkView.widthAnchor constraintEqualToConstant:18],
        [_checkView.heightAnchor constraintEqualToConstant:18],
    ]];

    [self applyTheme];
    return self;
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    if (self.selected) {
        self.backgroundColor = t.cPrimaryContainer;
        _nameLabel.textColor = t.cOnPrimaryContainer;
        _checkView.tintColor = t.cPrimary;
    } else {
        self.backgroundColor = UIColor.clearColor;
        _nameLabel.textColor = (_entry.availability == A2RendererAvailabilityAvailable)
            ? t.cOnSurface
            : [t.cOnSurfaceVariant colorWithAlphaComponent:0.5];
        _checkView.tintColor = UIColor.clearColor;
    }
}

@end

#pragma mark - 页面

@interface A2RendererSettingsViewController ()
@property (nonatomic, strong) A2SettingsRow *currentRow;
@property (nonatomic, strong) UIView *expandContainer;
@property (nonatomic, strong) UILabel *expandDescLabel;
@property (nonatomic, strong) UIStackView *choiceStack;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, strong) NSLayoutConstraint *expandHeightConstraint;
@property (nonatomic, strong) UIImpactFeedbackGenerator *feedback;
@end

@implementation A2RendererSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"渲染器";
    _feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

    [self buildUI];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(onPluginsChanged)
                                              name:A2RendererPluginsDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - UI

- (void)buildUI {
    A2SettingsSection *top = [[A2SettingsSection alloc] initWithTitle:@"全局渲染器"];

    _currentRow = [[A2SettingsRow alloc] init];
    _currentRow.symbolName = @"video.fill";
    _currentRow.title = @"渲染器";
    _currentRow.subtitle = @"选择图形渲染后端。不同渲染器在不同设备上表现差异明显，"
                            "建议逐个尝试后选择最稳定的一个。";
    _currentRow.accessory = A2SettingsRowAccessoryDownloadable;
    _currentRow.showsSeparator = NO;

    __weak typeof(self) weakSelf = self;
    _currentRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self toggleExpanded];
    };
    [top addRow:_currentRow];

    [top addCustomView:[self makeExpandContainer]];

    [self addSection:top];

    // 可选配置入口（仅当有可配置项）
    A2RendererEntry *current = [self currentEntry];
    if (current.hasConfigurableOptions) {
        A2SettingsSection *cfg = [[A2SettingsSection alloc] initWithTitle:@"配置"];
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = @"gearshape";
        row.title = [NSString stringWithFormat:@"%@ 的可调项", current.displayName];
        row.accessory = A2SettingsRowAccessoryDisclosure;
        row.showsSeparator = NO;
        row.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self showConfigForRenderer:[self currentEntry]];
        };
        [cfg addRow:row];
        [self addSection:cfg];
    }

    [self refreshCurrentRow];
}

/// 展开容器：描述头 + 可选列表
- (UIView *)makeExpandContainer {
    _expandContainer = [[UIView alloc] initWithFrame:CGRectZero];
    _expandContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _expandContainer.clipsToBounds = YES;
    _expandContainer.hidden = YES;

    _expandDescLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _expandDescLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _expandDescLabel.font = [A2Typography caption];
    _expandDescLabel.numberOfLines = 0;
    _expandDescLabel.text = @"选择要使用的渲染器。带「来自插件」标记的由用户导入。";

    _choiceStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _choiceStack.translatesAutoresizingMaskIntoConstraints = NO;
    _choiceStack.axis = UILayoutConstraintAxisVertical;
    _choiceStack.spacing = 2;

    UIStackView *inner = [[UIStackView alloc] initWithArrangedSubviews:
                          @[_expandDescLabel, _choiceStack]];
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    inner.axis = UILayoutConstraintAxisVertical;
    inner.spacing = A2SpaceS;
    [_expandContainer addSubview:inner];

    // 收起时高度 0 —— 用约束控制展开/收起
    _expandHeightConstraint = [_expandContainer.heightAnchor constraintEqualToConstant:0];
    _expandHeightConstraint.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:_expandContainer.topAnchor
                                       constant:A2SpaceS],
        [inner.leadingAnchor constraintEqualToAnchor:_expandContainer.leadingAnchor],
        [inner.trailingAnchor constraintEqualToAnchor:_expandContainer.trailingAnchor],
        [inner.bottomAnchor constraintLessThanOrEqualToAnchor:_expandContainer.bottomAnchor
                                                    constant:-A2SpaceS],
    ]];

    return _expandContainer;
}

#pragma mark - 展开 / 收起

- (void)toggleExpanded {
    _expanded = !_expanded;
    [_feedback impactOccurred];

    if (_expanded) {
        [self rebuildChoices];
        _expandContainer.hidden = NO;
        [_expandHeightConstraint setActive:NO];
        _expandHeightConstraint = nil;
    } else {
        _expandHeightConstraint = [_expandContainer.heightAnchor constraintEqualToConstant:0];
        _expandHeightConstraint.active = YES;
    }

    __weak typeof(self) weakSelf = self;
    UIViewPropertyAnimator *anim = A2SpringAnimator(A2AnimDuration);
    [anim addAnimations:^{
        __strong typeof(weakSelf) self = weakSelf;
        [self.view layoutIfNeeded];
        [self rotateCurrentRowChevron];
    }];
    [anim addCompletion:^(UIViewAnimatingPosition pos) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self.expanded) self.expandContainer.hidden = YES;
    }];
    [anim startAnimation];
}

/// 让当前行的下拉箭头朝上/朝下。
- (void)rotateCurrentRowChevron {
    for (UIView *v in _currentRow.subviews) {
        [self rotateChevronIn:v];
    }
}

- (void)rotateChevronIn:(UIView *)root {
    if ([root isKindOfClass:UIImageView.class]) {
        UIImageView *iv = (UIImageView *)root;
        if (iv.image && ([[iv.image.description lowercaseString] containsString:@"chevron"] ||
                         [iv.image.description containsString:@"arrow"])) {
            iv.transform = _expanded ? CGAffineTransformMakeRotation(M_PI)
                                     : CGAffineTransformIdentity;
        }
    }
    for (UIView *child in root.subviews) {
        [self rotateChevronIn:child];
    }
}

/// 构建可选项。与「可用渲染器」列表不同，这里是紧凑的单选列表。
- (void)rebuildChoices {
    for (UIView *v in [_choiceStack.arrangedSubviews copy]) {
        [_choiceStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    NSArray<A2RendererEntry *> *all = A2RendererRegistry.shared.allRenderers;
    NSString *selected = A2RendererRegistry.shared.selectedIdentifier;

    // 空列表要给明确说明，而不是让用户面对一个空的展开区
    if (all.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectZero];
        empty.font = [A2Typography caption];
        empty.textAlignment = NSTextAlignmentCenter;
        empty.numberOfLines = 0;
        empty.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
        empty.text = @"还没有可用的渲染器。\n"
                      "内置渲染器未随此构建打包，请导入渲染器插件。";
        [_choiceStack addArrangedSubview:empty];
        return;
    }

    for (A2RendererEntry *e in all) {
        BOOL chosen = [e.identifier isEqualToString:selected];
        A2RendererChoiceRow *row = [[A2RendererChoiceRow alloc] initWithEntry:e chosen:chosen];

        __weak typeof(self) weakSelf = self;
        __weak A2RendererChoiceRow *weakRow = row;
        [row addAction:[UIAction actionWithHandler:^(UIAction *a) {
            __strong typeof(weakSelf) self = weakSelf;
            [self selectRenderer:weakRow.entry];
        }] forControlEvents:UIControlEventTouchUpInside];

        [_choiceStack addArrangedSubview:row];
    }
}

#pragma mark - 数据

- (A2RendererEntry *)currentEntry {
    A2RendererRegistry *reg = A2RendererRegistry.shared;
    return [reg rendererWithIdentifier:reg.selectedIdentifier];
}

- (void)refreshCurrentRow {
    A2RendererEntry *e = [self currentEntry];
    if (!e) {
        _currentRow.valueText = @"当前未选择";
        return;
    }
    NSMutableString *v = [NSMutableString stringWithFormat:@"当前选择项：%@", e.displayName];
    if (e.isBuiltin) {
        [v appendString:@"（内置）"];
    } else if (e.sourceName.length) {
        [v appendFormat:@"（来自插件 %@）", e.sourceName];
    }
    _currentRow.valueText = v;
}

- (void)selectRenderer:(A2RendererEntry *)entry {
    if (entry.availability != A2RendererAvailabilityAvailable) {
        [A2Toast show:entry.unavailableReason ?: @"该渲染器当前不可用" inView:self.view];
        return;
    }
    if ([entry.identifier isEqualToString:A2RendererRegistry.shared.selectedIdentifier]) {
        return;
    }

    A2RendererRegistry.shared.selectedIdentifier = entry.identifier;
    [_feedback impactOccurred];

    [self refreshCurrentRow];
    [self rebuildChoices];

    [A2Toast show:[NSString stringWithFormat:@"已切换到 %@", entry.displayName]
           inView:self.view];
}

- (void)onPluginsChanged {
    [self refreshCurrentRow];
    if (_expanded) [self rebuildChoices];
}

#pragma mark - 渲染器配置

/// 把 manifest 里的 env 声明展开成控件。
///
/// 对照 ZL2 的 RendererV2ConfigDialog：
///   Toggleable → 开关
///   Selectable → 单选列表
///   Customizable → 输入框
- (void)showConfigForRenderer:(A2RendererEntry *)entry {
    if (!entry.plugin) return;

    NSString *prefix = [NSString stringWithFormat:@"RenderEnv.%@.", entry.identifier];
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:entry.displayName];
    section.footerText = @"这些选项由渲染器插件声明，会作为环境变量在启动游戏时生效。";

    for (A2RendererEnvSpec *spec in entry.plugin.envSpecs) {
        if (spec.type == A2RendererEnvTypeNormal) continue;

        NSString *storageKey = [prefix stringByAppendingString:
                                (spec.type == A2RendererEnvTypeToggleable
                                 ? [spec.key stringByAppendingString:@".enabled"]
                                 : spec.key)];

        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.title = spec.title.length ? spec.title : spec.key;

        if (spec.type == A2RendererEnvTypeToggleable) {
            row.accessory = A2SettingsRowAccessorySwitch;
            NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:storageKey];
            row.on = saved ? saved.boolValue : spec.defaultOn;
            row.onToggle = ^(BOOL isOn) {
                [NSUserDefaults.standardUserDefaults setBool:isOn forKey:storageKey];
            };
        } else {
            row.accessory = A2SettingsRowAccessoryDropdown;
            NSString *cur = [NSUserDefaults.standardUserDefaults stringForKey:storageKey];
            if (cur.length == 0) cur = spec.defaultValue ?: spec.customDefault;
            row.valueText = cur.length ? cur : @"未设置";
        }

        [section addRow:row];
    }

    UIViewController *host = [[UIViewController alloc] init];
    host.view.backgroundColor = t.cSurface;
    host.title = entry.displayName;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [host.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[section]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    [scroll addSubview:stack];

    UILayoutGuide *frame = scroll.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:host.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:host.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:host.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:host.view.trailingAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.centerXAnchor constraintEqualToAnchor:frame.centerXAnchor],
        [stack.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-24],
    ]];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:host];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

@end
