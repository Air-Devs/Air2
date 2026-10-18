#import "LauncherLanguageViewController.h"

#import "utils.h"
#import "BackgroundManager.h"   // ★ [PAGE-GLASS] 走全局界面风格层

// ★ [I18N] 语言切换后广播：SceneDelegate 收到后会重建启动器根 UI（所有页面重跑
// localize 文案 ⇒ 真正即时生效）；本页与其它页面也可监听做局部刷新。
NSString * const AmeLauncherLanguageChangedNotification = @"AmeLauncherLanguageChanged";

@interface LauncherLanguageViewController () <UISearchResultsUpdating>

// ★ [I18N] 选单语言代码（= 支持白名单，按显示名排序；空壳 .lproj 不列）
@property (nonatomic, copy) NSArray<NSString *> *availableCodes;
// ★ [I18N] 搜索过滤后的结果；nil 表示未搜索（直接显示 availableCodes）
@property (nonatomic, copy) NSArray<NSString *> *filteredCodes;
@property (nonatomic, strong) UISearchController *searchController;

@end

@implementation LauncherLanguageViewController

- (instancetype)init {
    // ★ [I18N] 与设置页一致的 insetGrouped 分组样式（iOS 设置 App 观感）。
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // ★ [I18N] 标题/占位在 ameRelocalize 里统一重取（切语言后要能刷新）。
    self.availableCodes = AmeLauncherAvailableLanguageCodes();

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.tableView.rowHeight = 44;

    // ★ [I18N] 语言变化时（若本页未被根 UI 重建）即时刷新标题与勾选。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLanguageChanged:)
                                                 name:AmeLauncherLanguageChangedNotification
                                               object:nil];

    [self ameRelocalize];

    // ★ [PAGE-GLASS] 与其余设置子页(控制设置 / JRE 管理 / 实例设置…)一致:交给全局界面风格层 ——
    //   iOS≥26 走系统液态玻璃、iOS<26 走系统原生材质;iOS 会把 tableView 底清透让壁纸/背景透出。
    //   原先本页从不调用风格层 ⇒ 列表底是不透明系统底,与同族子页观感割裂。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AmeLauncherLanguageChangedNotification
                                                  object:nil];
}

#pragma mark - ★ [I18N] 文案重取

// 重取本页自身文案（标题 / 搜索占位 / 分组头）并刷新列表。语言变化时调用。
- (void)ameRelocalize {
    self.title = localize(@"preference.lang.title", @"语言");
    self.searchController.searchBar.placeholder = localize(@"preference.lang.search_placeholder", @"搜索语言");
    [self.tableView reloadData];
}

- (void)handleLanguageChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ameRelocalize];
    });
}

#pragma mark - 数据

// section 0 → nil（= 跟随系统）；section 1 → 具体语言代码。
- (nullable NSString *)codeForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return nil;
    if (self.filteredCodes) {
        return (indexPath.row < (NSInteger)self.filteredCodes.count) ? self.filteredCodes[indexPath.row] : nil;
    }
    return (indexPath.row < (NSInteger)self.availableCodes.count) ? self.availableCodes[indexPath.row] : nil;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return self.filteredCodes ? self.filteredCodes.count : self.availableCodes.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return localize(@"preference.lang.section.system", @"系统");
    return localize(@"preference.lang.section.available", @"可用语言");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"AmeLanguageCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    }
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    NSString *currentOverride = AmeLauncherPreferredLanguageOverride();

    if (indexPath.section == 0) {
        // ★ [I18N]「跟随系统」：副标题给出"跟随系统时实际生效的语言"，含义明确，
        // 直接回答"系统英文→英文、系统中文→中文"。显示与实际渲染同一事实源。
        cell.textLabel.text = localize(@"preference.lang.follow_system", @"跟随系统");
        // ★ [I18N-PARTIAL] 生效语言若是"部分翻译"语言（如日语），这里同样带「部分翻译」标注。
        cell.detailTextLabel.text = AmeLauncherDisplayNameAnnotatedForLanguageCode(AmeLauncherEffectiveLanguageCode());
        cell.accessoryType = (currentOverride.length == 0) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else {
        NSString *code = [self codeForRowAtIndexPath:indexPath];
        // ★ [I18N-PARTIAL] 部分翻译语言（单一事实源）显示为「日本語（部分翻译）」。
        cell.textLabel.text = AmeLauncherDisplayNameAnnotatedForLanguageCode(code);
        NSString *subtitle = code;
        // ★ [I18N-PARTIAL] 部分翻译语言：副标题一律给出说明行（如「部分界面仍为中文」），
        // 比只报翻译率百分比更直接地回答"选了会怎样"，杜绝"选了才发现大半是中文"。
        NSString *partialNote = AmeLauncherPartiallyTranslatedNoteForLanguageCode(code);
        if (partialNote.length > 0) {
            subtitle = [NSString stringWithFormat:@"%@ · %@", code, partialNote];
        } else {
            // ★ [I18N] 副标题：原始代码 +（部分翻译时）人工翻译率百分比 —— 一眼看出
            // "哪些完整、哪些只译了一部分"，杜绝"选了才发现大半是英文"。
            // ★ [I18N-ORDER] 阈值放宽到 0.85:完整语言里"AI/%d"等与英文同形的值会拉低比例,
            // 只对"大面积未翻译"的壳子语言标百分比,避免完整语言也显示 ·98% 之类噪音。
            double ratio = AmeLauncherLanguageTranslatedRatio(code);
            if (ratio > 0.0 && ratio < 0.85) {
                subtitle = [NSString stringWithFormat:@"%@ · %.0f%%", code, ratio * 100.0];
            }
        }
        cell.detailTextLabel.text = subtitle;
        cell.accessoryType = (code && [code isEqualToString:currentOverride])
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    // section 0 → nil（跟随系统）
    NSString *code = [self codeForRowAtIndexPath:indexPath];

    NSString *before = AmeLauncherPreferredLanguageOverride() ?: @"";
    // ★ [I18N] 持久化到自定义键（不碰系统 AppleLanguages）。
    AmeLauncherSetPreferredLanguageOverride(code);
    NSString *after = AmeLauncherPreferredLanguageOverride() ?: @"";

    [tableView reloadData];
    if (self.searchController.isActive) {
        self.searchController.active = NO;
    }

    if (![before isEqualToString:after]) {
        // ★ [I18N] 即时生效：异步广播 —— 由 SceneDelegate 重建启动器根 UI，所有页面
        // 重跑 localize 文案（含本页）。异步是为了让本次 didSelect 先干净返回，
        // 避免本控制器在自身回调栈里被替换/释放。
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:AmeLauncherLanguageChangedNotification
                                                                object:nil];
        });
    }
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) {
        self.filteredCodes = nil;
        [self.tableView reloadData];
        return;
    }
    NSString *lower = query.lowercaseString;
    NSMutableArray<NSString *> *results = [NSMutableArray array];
    for (NSString *code in self.availableCodes) {
        NSString *name = AmeLauncherDisplayNameForLanguageCode(code);
        if ([name.lowercaseString containsString:lower] || [code.lowercaseString containsString:lower]) {
            [results addObject:code];
        }
    }
    self.filteredCodes = results;
    [self.tableView reloadData];
}

@end
