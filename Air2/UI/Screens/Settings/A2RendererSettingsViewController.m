//
//  A2RendererSettingsViewController.m
//  Air2
//

#import "A2RendererSettingsViewController.h"
#import "A2RendererPlugin.h"
#import "A2RendererRegistry.h"
#import "A2RendererImporter.h"
#import "A2RendererPluginViewController.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2GlassCard.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

@interface A2RendererSettingsViewController ()
@property (nonatomic, strong) A2SettingsRow *currentRow;
@property (nonatomic, strong) A2SettingsSection *listSection;
@end

@implementation A2RendererSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"渲染器";

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
    // ---- 当前渲染器 ----
    A2SettingsSection *top = [[A2SettingsSection alloc] initWithTitle:@"全局渲染器"];

    _currentRow = [[A2SettingsRow alloc] init];
    _currentRow.symbolName = @"cube.transparent";
    _currentRow.title = @"渲染器";
    _currentRow.subtitle = @"全局默认的渲染器，通过动态库转换层确保游戏能在移动端运行";
    _currentRow.accessory = A2SettingsRowAccessoryDownloadable;

    __weak typeof(self) weakSelf = self;
    _currentRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self showRendererPicker];
    };
    [top addRow:_currentRow];

    // 配置入口 —— 仅当选中的渲染器有可配置项时显示
    A2RendererEntry *current = [self currentEntry];
    if (current.hasConfigurableOptions) {
        A2SettingsRow *configRow = [[A2SettingsRow alloc] init];
        configRow.symbolName = @"gearshape";
        configRow.title = @"渲染器配置";
        configRow.subtitle = [NSString stringWithFormat:@"%@ 的可调项", current.displayName];
        configRow.accessory = A2SettingsRowAccessoryDisclosure;
        configRow.showsSeparator = NO;
        configRow.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self showConfigForRenderer:current];
        };
        [top addRow:configRow];
    } else {
        _currentRow.showsSeparator = NO;
    }

    [self addSection:top];

    // ---- 全部渲染器 ----
    _listSection = [[A2SettingsSection alloc] initWithTitle:@"可用渲染器"];
    _listSection.footerText = @"「来自插件」的渲染器由用户导入。"
                               "导入的库需要与 Air2 使用相同签名才能加载。";
    [self addSection:_listSection];

    [self rebuildList];

    // ---- 插件管理入口 ----
    A2SettingsSection *manage = [[A2SettingsSection alloc] initWithTitle:@"插件"];
    A2SettingsRow *pluginRow = [[A2SettingsRow alloc] init];
    pluginRow.symbolName = @"puzzlepiece.extension";
    pluginRow.title = @"渲染器插件";
    pluginRow.subtitle = @"导入 .air2plugin 包以获得更多渲染器";
    pluginRow.accessory = A2SettingsRowAccessoryDisclosure;
    pluginRow.showsSeparator = NO;
    pluginRow.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        A2RendererPluginViewController *vc = [[A2RendererPluginViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    };
    [manage addRow:pluginRow];
    [self addSection:manage];
}

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
        [v appendFormat:@"（来自 %@）", e.sourceName];
    }
    _currentRow.valueText = v;
}

- (void)rebuildList {
    // A2SettingsSection 不支持移除单行（它的 rows 是只读的），
    // 所以重建整个 section —— 移除旧的、建新的。
    // 这比给组件加 removeRow: 更简单，且不影响其他地方的使用。
    if (_listSection) {
        [_listSection removeFromSuperview];
        _listSection = nil;
    }

    _listSection = [[A2SettingsSection alloc] initWithTitle:@"可用渲染器"];
    _listSection.footerText = @"「来自插件」的渲染器由用户导入。"
                               "导入的库需要与 Air2 使用相同签名才能加载。";

    A2RendererRegistry *reg = A2RendererRegistry.shared;
    NSArray<A2RendererEntry *> *all = reg.allRenderers;
    NSString *selected = reg.selectedIdentifier;

    for (NSUInteger i = 0; i < all.count; i++) {
        A2RendererEntry *e = all[i];

        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = e.isBuiltin ? @"cpu" : @"puzzlepiece.extension.fill";
        row.title = e.displayName;

        NSMutableArray *bits = [NSMutableArray array];
        if (e.summary.length) [bits addObject:e.summary];
        if (!e.isBuiltin && e.sourceName.length) {
            [bits addObject:[NSString stringWithFormat:@"来自插件 %@", e.sourceName]];
        }
        row.subtitle = [bits componentsJoinedByString:@" · "];

        if (e.availability != A2RendererAvailabilityAvailable) {
            // 不可用的显示警告 + 原因，而不是隐藏 —— 用户要知道为什么
            row.accessory = A2SettingsRowAccessoryWarning;
            row.subtitle = e.unavailableReason ?: @"不可用";
        } else if ([e.identifier isEqualToString:selected]) {
            row.accessory = A2SettingsRowAccessoryCheckmark;
        } else {
            row.accessory = A2SettingsRowAccessoryNone;
        }

        if (i == all.count - 1) row.showsSeparator = NO;

        __weak typeof(self) weakSelf = self;
        row.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self selectRenderer:e];
        };

        [_listSection addRow:row];
    }

    // 放到「插件」分组之前 —— 用 insert 保证顺序稳定
    [self insertSection:_listSection before:nil];

    [self refreshCurrentRow];
}

/// 把 section 插到内容栈中。before 为 nil 时插到末尾之前的位置。
///
/// 为什么需要它：重建列表后要把新 section 放回原位置，
/// 而不是每次 addSection 到最末尾（那样顺序会乱）。
- (void)insertSection:(UIView *)section before:(nullable UIView *)before {
    if (self.contentStack) {
        if (before && [self.contentStack.arrangedSubviews containsObject:before]) {
            NSUInteger idx = [self.contentStack.arrangedSubviews indexOfObject:before];
            [self.contentStack insertArrangedSubview:section atIndex:idx];
            return;
        }
    }
    [self addSection:section];
}

- (void)onPluginsChanged {
    [A2RendererRegistry.shared reload];
    [self rebuildList];
}

#pragma mark - 交互

- (void)selectRenderer:(A2RendererEntry *)entry {
    if (entry.availability != A2RendererAvailabilityAvailable) {
        [A2Toast show:entry.unavailableReason ?: @"该渲染器当前不可用" inView:self.view];
        return;
    }

    A2RendererRegistry.shared.selectedIdentifier = entry.identifier;
    [self rebuildList];

    UISelectionFeedbackGenerator *fb = [UISelectionFeedbackGenerator new];
    [fb selectionChanged];

    [A2Toast show:[NSString stringWithFormat:@"已切换到 %@", entry.displayName]
           inView:self.view];
}

- (void)showRendererPicker {
    NSArray<A2RendererEntry *> *all = A2RendererRegistry.shared.allRenderers;
    NSString *selected = A2RendererRegistry.shared.selectedIdentifier;

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"选择渲染器"
                                            message:@"不同渲染器在不同设备上表现差异明显，"
                                                     "建议逐个尝试后选择最稳的那个"
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    for (A2RendererEntry *e in all) {
        NSString *title = e.displayName;
        if (e.availability != A2RendererAvailabilityAvailable) {
            title = [title stringByAppendingString:@"（不可用）"];
        } else if ([e.identifier isEqualToString:selected]) {
            title = [@"✓ " stringByAppendingString:title];
        }

        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) self = weakSelf;
            [self selectRenderer:e];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    sheet.popoverPresentationController.sourceView = _currentRow;
    sheet.popoverPresentationController.sourceRect = _currentRow.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

/// 渲染器配置页 —— 把 manifest 里的 env 声明展开成控件。
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
        NSString *storageKey = [prefix stringByAppendingString:
                                (spec.type == A2RendererEnvTypeToggleable
                                 ? [spec.key stringByAppendingString:@".enabled"]
                                 : spec.key)];

        if (spec.type == A2RendererEnvTypeNormal) continue;   // 固定值不需要 UI

        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.title = spec.title.length ? spec.title : spec.key;

        if (spec.type == A2RendererEnvTypeToggleable) {
            row.accessory = A2SettingsRowAccessorySwitch;
            NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:storageKey];
            row.on = saved ? saved.boolValue : spec.defaultOn;
            __weak A2SettingsRow *weakRow = row;
            row.onToggle = ^(BOOL isOn) {
                (void)weakRow;
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
    (void)t;

    // 用一个轻量的容器页承载
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
