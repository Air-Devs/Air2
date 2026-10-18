// ★ [VI-MIGRATE-AUTO] 版本隔离「自动识别迁移」页实现。
// 形式：选一个文件夹 → 自动识别归属(版本+加载器) → 分组给用户确认 → 再复制。
// ★ [VI-FLOW]（用户修正 4）：目标（归属到哪个实例 / 目录）**完全由自动识别决定**，
//   本页【不提供】「改归属 / 改目标文件夹」入口 —— 用户只决定「搬不搬、搬哪些」(勾选)。
// 视觉沿用启动器既有「分组列表 + 勾选」样式，不改其它页风格。
// 执行复用 VersionDataMigration 引擎（ameVIAExecute → ameVDMExecuteItem）。
//
// ★ [VI-UI-FIX] 用户实测反馈 bug①「看不出哪个是 mod / 存档 / 资源包，且没有类型筛选」：
//   * 每项标题补【类型标签】（由识别结果 category 直接得出，四语本地化；不再裸露 "mods"/"saves" 生串）；
//   * 顶部新增【类型筛选】分段控件（全部/模组/存档/资源包/光影/数据包/配置/其他），
//     沿用既有分段控件样式（横向可滚动，放得下就不滚）；筛选后列表、勾选数、体量文案同步刷新。
//   * 勾选状态改为按【组稳定键】保存（原先按行下标 ⇒ 一旦筛选/重排就会错位）。
//
// ★ [VI-ORIGIN] 用户要求：在【类型】之上再区分【来源】= 加载器自带 / 玩家添加 / Mod 生成 / 未识别。
//   * 每项标题与副标题都带【来源标签】+【来源依据】（可解释，来自引擎 origin/originReason）；
//   * 顶部新增【来源筛选】分段控件（全部/加载器自带/玩家添加/Mod 生成/未识别），与类型筛选并联、可叠加；
//   * 默认勾选策略「不惊吓」：只默认勾选【玩家添加】且【已匹配到实例】的组；加载器自带 / Mod 生成 / 未识别
//     一律默认【不勾】—— 迁移只搬玩家自己的内容，绝不自动搬加载器基线或来源不明的项。

#import "VersionAutoMigrateViewController.h"
#import "VersionDataMigrationAuto.h"
#import "VersionDataMigration.h"
#import "utils.h"

@interface VersionAutoMigrateViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSString *srcRoot;
@property (nonatomic, strong) NSArray<NSDictionary *> *targets;
@property (nonatomic, strong) NSArray<NSDictionary *> *allGroups;    // ★ [VI-UI-FIX] 全量分组（未筛选）
@property (nonatomic, strong) NSArray<NSDictionary *> *groups;       // ★ [VI-UI-FIX] 当前可见分组（已筛选）
@property (nonatomic, strong) NSMutableSet<NSString *> *checkedKeys;// ★ [VI-UI-FIX] 勾选 = 组稳定键集合
@property (nonatomic, assign) NSInteger selectedTypeIndex;          // ★ [VI-UI-FIX] 类型筛选下标（0=全部）
@property (nonatomic, assign) NSInteger selectedOriginIndex;        // ★ [VI-ORIGIN] 来源筛选下标（0=全部）
@property (nonatomic, strong) UIBarButtonItem *runButton;
@end

@implementation VersionAutoMigrateViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"preference.migrate.auto.title", nil);
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(actionRescan)];
    self.runButton = [[UIBarButtonItem alloc] initWithTitle:localize(@"preference.migrate.auto.run", nil)
                                                      style:UIBarButtonItemStyleDone
                                                     target:self action:@selector(actionRun)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                          target:self action:@selector(actionClose)];

    // 默认源 = resolver 的「关隔离」值（用户当前真正在用的那个目录），也可改选。
    NSString *vid = [self versionId];
    self.srcRoot = amePCLSharedGameDirForProfile(self.profile, vid);
    self.selectedTypeIndex = 0;    // ★ [VI-UI-FIX] 默认「全部」
    self.selectedOriginIndex = 0;  // ★ [VI-ORIGIN] 默认「全部」
    [self reloadScan];
}

- (NSString *)versionId {
    id vid = self.profile[@"lastVersionId"];
    return [vid isKindOfClass:NSString.class] ? (NSString *)vid : nil;
}

- (NSString *)humanBytes:(unsigned long long)b {
    return [NSByteCountFormatter stringFromByteCount:(long long)b countStyle:NSByteCountFormatterCountStyleFile];
}

#pragma mark - ★ [VI-UI-FIX] 类型标签 / 筛选

/// 筛选分段顺序：全部 / 模组 / 存档 / 资源包 / 光影 / 数据包 / 配置 / 其他。
- (NSArray<NSString *> *)typeOrder {
    return @[ @"all", @"mods", @"saves", @"resourcepacks", @"shaderpacks", @"datapacks", @"config", @"other" ];
}

/// 类别 → 面向用户的类型文案（四语，走 localize）。
- (NSString *)typeLabelForCategory:(NSString *)category {
    if (![category isKindOfClass:NSString.class]) return localize(@"preference.migrate.type.other", nil);
    NSString *key;
    if ([category isEqualToString:ameVIACatMod])               key = @"preference.migrate.type.mods";
    else if ([category isEqualToString:ameVIACatWorld])        key = @"preference.migrate.type.saves";
    else if ([category isEqualToString:ameVIACatResourcePack]) key = @"preference.migrate.type.resourcepacks";
    else if ([category isEqualToString:ameVIACatShaderPack])   key = @"preference.migrate.type.shaderpacks";
    else if ([category isEqualToString:ameVIACatDataPack])     key = @"preference.migrate.type.datapacks";
    else if ([category isEqualToString:ameVIACatConfig])       key = @"preference.migrate.type.config";
    else                                                       key = @"preference.migrate.type.other";
    return localize(key, nil);
}

/// 筛选键文案（分段控件用；"all"/"other" 用通用键）。
- (NSString *)typeLabelForKey:(NSString *)key {
    if ([key isEqualToString:@"all"])   return localize(@"preference.migrate.type.all", nil);
    if ([key isEqualToString:@"other"]) return localize(@"preference.migrate.type.other", nil);
    return [self typeLabelForCategory:key];
}

/// 某类别是否属于当前筛选键（"." 根散文件 与 "other" 一律归入「其他」）。
- (BOOL)category:(NSString *)cat matchesFilterKey:(NSString *)key {
    if ([key isEqualToString:@"all"])   return YES;
    if ([key isEqualToString:@"other"]) return ([cat isEqualToString:ameVIACatRoot] || [cat isEqualToString:ameVIACatOther]);
    return [cat isEqualToString:key];
}

#pragma mark - ★ [VI-ORIGIN] 来源标签 / 筛选

/// 来源筛选分段顺序：全部 / 加载器自带 / 玩家添加 / Mod 生成 / 未识别。
- (NSArray<NSString *> *)originOrder {
    return @[ @"all", ameVIAOriginLoader, ameVIAOriginPlayer, ameVIAOriginMod, ameVIAOriginUnknown ];   // ★ [VI-ORIGIN]
}

/// 来源 → 面向用户的文案（四语，走 localize）。
- (NSString *)originLabelForOrigin:(NSString *)origin {
    if (![origin isKindOfClass:NSString.class]) return localize(@"preference.migrate.origin.unknown", nil);
    if ([origin isEqualToString:ameVIAOriginLoader])  return localize(@"preference.migrate.origin.loader", nil);
    if ([origin isEqualToString:ameVIAOriginPlayer])  return localize(@"preference.migrate.origin.player", nil);
    if ([origin isEqualToString:ameVIAOriginMod])     return localize(@"preference.migrate.origin.mod", nil);
    return localize(@"preference.migrate.origin.unknown", nil);
}

/// 来源筛选键文案。
- (NSString *)originLabelForKey:(NSString *)key {
    if ([key isEqualToString:@"all"]) return localize(@"preference.migrate.origin.all", nil);
    return [self originLabelForOrigin:key];
}

/// 某组来源是否属于当前来源筛选键。
- (BOOL)origin:(NSString *)origin matchesFilterKey:(NSString *)key {
    if ([key isEqualToString:@"all"]) return YES;
    if (![origin isKindOfClass:NSString.class]) origin = ameVIAOriginUnknown;
    return [origin isEqualToString:key];
}

/// 组的稳定键（同一识别结果恒等；与 ameVIAGroupUnits 的索引键一致 ⇒ 唯一）。
- (NSString *)keyForGroup:(NSDictionary *)g {
    id v = g[@"mcVersion"]; NSString *vs = [v isKindOfClass:NSString.class] ? v : @"";
    id l = g[@"loader"];    NSString *ls = [l isKindOfClass:NSString.class] ? l : @"";
    id c = g[@"category"];  NSString *cs = [c isKindOfClass:NSString.class] ? c : @"";
    id o = g[@"origin"];    NSString *os = [o isKindOfClass:NSString.class] ? o : @"";   // ★ [VI-ORIGIN]
    return [NSString stringWithFormat:@"%@|%@|%@|%@", vs, ls, cs, os];
}

/// 按当前【类型 + 来源】两个筛选键重算可见分组（勾选状态不丢 —— 勾选按稳定键保存）。
- (void)applyFilters {
    NSInteger ti = MIN(MAX(self.selectedTypeIndex, 0), (NSInteger)self.typeOrder.count - 1);
    self.selectedTypeIndex = ti;
    NSString *tkey = self.typeOrder[ti];
    NSInteger oi = MIN(MAX(self.selectedOriginIndex, 0), (NSInteger)self.originOrder.count - 1);
    self.selectedOriginIndex = oi;
    NSString *okey = self.originOrder[oi];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *g in self.allGroups) {
        if (![self category:g[@"category"] matchesFilterKey:tkey]) continue;
        if (![self origin:g[@"origin"] matchesFilterKey:okey]) continue;
        [out addObject:g];
    }
    self.groups = out;
}

#pragma mark - 扫描

- (void)reloadScan {
    if (self.srcRoot.length == 0) { [self updateRunButton]; return; }
    // 目标实例根 = 与 resolver 同源（POJAV_GAME_DIR / 实例根）；扫 versions/*。
    NSString *instRoot = amePCLSharedGameDirAbsolute();
    self.targets = ameVIAEnumerateTargets(instRoot ?: @"");
    NSDictionary *scan = ameVIAScanFolder(self.srcRoot);
    self.allGroups = ameVIAGroupUnits(scan[@"units"] ?: @[], self.targets);

    // 默认勾选（★ [VI-ORIGIN] 不惊吓策略）：只勾【玩家添加】且【已匹配到实例】的组；
    // 加载器自带 / Mod 生成 / 未识别 一律默认【不勾】（按稳定键记录）。迁移只搬玩家自己的内容。
    self.checkedKeys = [NSMutableSet set];
    for (NSDictionary *g in self.allGroups) {
        NSString *m = g[@"match"];
        NSString *origin = [g[@"origin"] isKindOfClass:NSString.class] ? g[@"origin"] : ameVIAOriginUnknown;
        BOOL matched = !([m isEqualToString:@"unrecognized"] || [m isEqualToString:@"none"]);
        BOOL on = [origin isEqualToString:ameVIAOriginPlayer] && matched;
        if (on) [self.checkedKeys addObject:[self keyForGroup:g]];
    }
    [self applyFilters];
    // ★ [VI-ORIGIN] 真机核对：打印各来源组数（不做判定，仅供日志）。
    {
        NSMutableDictionary<NSString *, NSNumber *> *cnt = [NSMutableDictionary dictionary];
        for (NSDictionary *g in self.allGroups) {
            NSString *o = [g[@"origin"] isKindOfClass:NSString.class] ? g[@"origin"] : ameVIAOriginUnknown;
            cnt[o] = @([cnt[o] unsignedIntegerValue] + 1);
        }
        NSLog(@"★ [VI-ORIGIN] scan src=%@ groups=%lu origins=loader:%@ player:%@ mod:%@ unknown:%@",
              self.srcRoot, (unsigned long)self.allGroups.count,
              cnt[ameVIAOriginLoader] ?: @0, cnt[ameVIAOriginPlayer] ?: @0,
              cnt[ameVIAOriginMod] ?: @0, cnt[ameVIAOriginUnknown] ?: @0);
    }
    [self.tableView reloadData];
    [self updateRunButton];
}

- (void)updateRunButton {
    // ★ [VI-UI-FIX] 勾选数按【当前可见（筛选后）分组】统计 ⇒ 筛选与计数同步。
    NSUInteger on = 0;
    for (NSDictionary *g in self.groups) if ([self.checkedKeys containsObject:[self keyForGroup:g]]) on++;
    self.runButton.enabled = (on > 0);
}

/// ★ [VI-UI-FIX] 当前筛选视图下：可见组数 / 已勾选组数 / 已勾选体量。
- (void)filteredCountsVisible:(NSUInteger *)visible
                      checked:(NSUInteger *)checkedN
                        bytes:(unsigned long long *)bytes {
    NSUInteger v = 0, c = 0; unsigned long long b = 0;
    for (NSDictionary *g in self.groups) {
        v++;
        if ([self.checkedKeys containsObject:[self keyForGroup:g]]) {
            c++;
            b += [g[@"bytes"] unsignedLongLongValue];
        }
    }
    if (visible)  *visible  = v;
    if (checkedN) *checkedN = c;
    if (bytes)    *bytes    = b;
}

#pragma mark - 目标解析（★ [VI-FLOW]：目标一律用自动识别结果，无任何用户改写）

- (NSString *)resolvedDirForGroup:(NSUInteger)idx {
    // ★ [VI-FLOW]（用户修正 4）：不再叠加任何用户改写 —— 目标目录只来自自动识别匹配结果。
    id t = self.groups[idx][@"targetDir"];
    return [t isKindOfClass:NSString.class] ? (NSString *)t : nil;
}

- (NSString *)resolvedLabelForGroup:(NSUInteger)idx {
    // ★ [VI-FLOW]（用户修正 4）：目标标签同样只来自自动识别匹配结果。
    NSDictionary *t = self.groups[idx][@"target"];
    if ([t isKindOfClass:NSDictionary.class]) {
        return [NSString stringWithFormat:@"%@ · %@", t[@"version"] ?: @"?", t[@"loader"] ?: @"?"];
    }
    return nil;
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }   // ★ [VI-UI-FIX] 0=源 / 1=筛选 / 2=分组

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return localize(@"preference.migrate.auto.source", nil);
    if (s == 1) return localize(@"preference.migrate.filter.title", nil);   // ★ [VI-UI-FIX]
    return localize(@"preference.migrate.auto.groups", nil);
}

// ★ [VI-POLISH] C：共享边界文案写进本页页脚（涉及隔离 ⇒ 必须说清哪些始终共享）。
// ★ [VI-UI-FIX]：只在最后一组（分组列表）显示一次，并补「筛选后 可见/勾选/体量」实时摘要。
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 1) return localize(@"preference.migrate.origin.note", nil);   // ★ [VI-ORIGIN] 默认勾选策略说明
    if (s != 2) return nil;
    NSUInteger visible = 0, checked = 0; unsigned long long bytes = 0;
    [self filteredCountsVisible:&visible checked:&checked bytes:&bytes];
    NSString *summary = [NSString stringWithFormat:localize(@"preference.migrate.filter.summary", nil),
                         (unsigned long)visible, (unsigned long)checked, [self humanBytes:bytes]];
    return [NSString stringWithFormat:@"%@\n%@", summary, localize(@"preference.vi.shared.boundary", nil)];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 1;
    if (s == 1) return 2;                       // ★ [VI-UI-FIX] 筛选行 0=类型 / 1=来源（★ [VI-ORIGIN]）
    return (NSInteger)self.groups.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 1) {                                                 // ★ [VI-ORIGIN] 类型 / 来源 两行
        if (ip.row == 0) {
            NSMutableArray<NSString *> *titles = [NSMutableArray array];
            for (NSString *k in [self typeOrder]) [titles addObject:[self typeLabelForKey:k]];
            return [self ameSegmentedFilterCellInTable:tv tagBase:9100 titles:titles
                                         selectedIndex:self.selectedTypeIndex
                                                action:@selector(actionTypeFilterChanged:)];
        }
        NSMutableArray<NSString *> *titles = [NSMutableArray array];
        for (NSString *k in [self originOrder]) [titles addObject:[self originLabelForKey:k]];
        return [self ameSegmentedFilterCellInTable:tv tagBase:9200 titles:titles
                                     selectedIndex:self.selectedOriginIndex
                                            action:@selector(actionOriginFilterChanged:)];
    }

    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];

    if (ip.section == 0) {
        cell.textLabel.text = localize(@"preference.migrate.auto.pick", nil);
        cell.detailTextLabel.text = self.srcRoot.length ? self.srcRoot : localize(@"preference.migrate.auto.no.source", nil);
        cell.imageView.image = [UIImage systemImageNamed:@"folder"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.textColor = [UIColor labelColor];
        return cell;
    }

    NSDictionary *g = self.groups[ip.row];
    NSString *ver = [g[@"mcVersion"] isKindOfClass:NSString.class] ? g[@"mcVersion"] : @"?";
    NSString *loader = [g[@"loader"] isKindOfClass:NSString.class] ? g[@"loader"] : @"?";
    NSString *match = g[@"match"];
    NSString *target = [self resolvedLabelForGroup:ip.row];
    if (!target) {
        target = [match isEqualToString:@"unrecognized"] ? localize(@"preference.migrate.auto.group.unrecognized", nil)
                                                         : localize(@"preference.migrate.auto.group.unmatched", nil);
    }
    // ★ [VI-UI-FIX] 标题：版本 · 加载器 · 【类型标签】；★ [VI-ORIGIN] 追加【来源标签】 → 目标实例。
    NSString *typeLabel = [self typeLabelForCategory:g[@"category"]];
    NSString *originLabel = [self originLabelForOrigin:g[@"origin"]];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@ · %@ → %@",
                           ver, loader, typeLabel, originLabel, target];
    cell.imageView.image = [UIImage systemImageNamed:
        [match isEqualToString:@"unrecognized"] ? @"questionmark.circle" :
        ([match isEqualToString:@"none"] ? @"exclamationmark.triangle" : @"arrow.right.square")];
    // 副标题：识别依据 + 体量；再用一行写明【来源 + 来源依据】（可解释）。
    NSString *baseDetail = [NSString stringWithFormat:
        localize(@"preference.migrate.auto.group.detail", nil),
        (unsigned long)[g[@"files"] unsignedIntegerValue], [self humanBytes:[g[@"bytes"] unsignedLongLongValue]],
        g[@"reason"] ?: @""];
    NSString *originDetail = [NSString stringWithFormat:localize(@"preference.migrate.origin.detail", nil),   // ★ [VI-ORIGIN]
                              originLabel,
                              [g[@"originReason"] isKindOfClass:NSString.class] ? g[@"originReason"] : @""];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@", originDetail, baseDetail];
    cell.detailTextLabel.numberOfLines = 4;

    // ★ [VI-UI-FIX] 勾选状态按稳定键判定（筛选/重排不会错位）。
    BOOL on = [self.checkedKeys containsObject:[self keyForGroup:g]];
    cell.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    // ★ [VI-FLOW]（用户修正 4）：删掉「改归属」按钮 —— 目标只由自动识别决定，用户只勾选「搬不搬」。
    cell.accessoryView = nil;
    return cell;
}

// ★ [VI-ORIGIN] 通用筛选行载体：横向可滚动的分段控件（沿用既有分段控件样式，放不下时可滑动）。
// 类型 / 来源 两行复用（tagBase 不同 ⇒ 各自独立的 scrollview/seg）。
- (UITableViewCell *)ameSegmentedFilterCellInTable:(UITableView *)tv
                                          tagBase:(NSInteger)tagBase
                                           titles:(NSArray<NSString *> *)titles
                                    selectedIndex:(NSInteger)selectedIndex
                                           action:(SEL)action {
    NSInteger svTag = tagBase + 1, segTag = tagBase + 2;
    NSString *cellId = [NSString stringWithFormat:@"VIAFilterCell-%ld", (long)tagBase];
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cellId];
    UIScrollView *sv;
    UISegmentedControl *seg;
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        sv = [[UIScrollView alloc] initWithFrame:CGRectZero];
        sv.showsHorizontalScrollIndicator = NO;
        sv.tag = svTag;
        sv.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:sv];
        [NSLayoutConstraint activateConstraints:@[
            [sv.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor  constant:16],
            [sv.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
            [sv.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor      constant:6],
            [sv.bottomAnchor   constraintEqualToAnchor:cell.contentView.bottomAnchor   constant:-6],
        ]];
        seg = [[UISegmentedControl alloc] initWithItems:@[]];
        seg.tag = segTag;
        [sv addSubview:seg];
    } else {
        sv = [cell.contentView viewWithTag:svTag];
        seg = (UISegmentedControl *)[sv viewWithTag:segTag];
    }

    // 逐次重建分段项（语言可能切换），保持当前选择。
    [seg removeAllSegments];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        [seg insertSegmentWithTitle:titles[i] atIndex:i animated:NO];
    }
    seg.selectedSegmentIndex = MIN(MAX(selectedIndex, 0), (NSInteger)titles.count - 1);
    [seg removeTarget:self action:NULL forControlEvents:UIControlEventValueChanged];
    [seg addTarget:self action:action forControlEvents:UIControlEventValueChanged];

    // seg 宽度 = 内容宽度（不足则撑满可见区），放进横向滚动容器。
    CGSize fit = [seg sizeThatFits:CGSizeMake(CGFLOAT_MAX, 32)];
    CGFloat visibleW = MAX(0.0, tv.bounds.size.width - 64.0);
    CGFloat segW = MAX(fit.width, visibleW);
    seg.frame = CGRectMake(0, 0, segW, 32);
    sv.contentSize = CGSizeMake(segW, 32);
    return cell;
}

// ★ [VI-UI-FIX] 类型分段回调：改筛选 ⇒ 重算可见分组 + 刷新列表 + 同步计数器。
- (void)actionTypeFilterChanged:(UISegmentedControl *)sender {
    self.selectedTypeIndex = MIN(MAX(sender.selectedSegmentIndex, 0), (NSInteger)self.typeOrder.count - 1);
    [self applyFilters];
    [self.tableView reloadData];
    [self updateRunButton];
}

// ★ [VI-ORIGIN] 来源分段回调：与类型筛选并联生效。
- (void)actionOriginFilterChanged:(UISegmentedControl *)sender {
    self.selectedOriginIndex = MIN(MAX(sender.selectedSegmentIndex, 0), (NSInteger)self.originOrder.count - 1);
    [self applyFilters];
    [self.tableView reloadData];
    [self updateRunButton];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) { [self actionPickSource]; return; }
    if (ip.section == 1) return;   // ★ [VI-UI-FIX] 筛选行由分段控件自身处理，不吃行点击
    // 点整行 = 勾选/取消勾选（按稳定键）
    NSDictionary *g = self.groups[ip.row];
    NSString *key = [self keyForGroup:g];
    if ([self.checkedKeys containsObject:key]) [self.checkedKeys removeObject:key];
    else [self.checkedKeys addObject:key];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    [self updateRunButton];
    // 页脚摘要随之更新
    [tv reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - 选源文件夹

- (void)actionPickSource {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:localize(@"preference.migrate.auto.source", nil)
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak VersionAutoMigrateViewController *ws = self;
    NSString *shared = amePCLSharedGameDirForProfile(self.profile, [self versionId]);
    if (shared.length) {
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@\n%@",
                        localize(@"preference.migrate.auto.source.shared", nil), shared]
                                             style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
            ws.srcRoot = shared; [ws reloadScan];
        }]];
    }
    for (NSDictionary *other in self.targets) {
        NSString *dir = other[@"dir"];
        if (dir.length && ![dir isEqualToString:shared]) {
            [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ %@ · %@",
                            localize(@"preference.migrate.auto.source.instance", nil), other[@"version"], other[@"id"]]
                                                 style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
                ws.srcRoot = dir; [ws reloadScan];
            }]];
        }
    }
    [a addAction:[UIAlertAction actionWithTitle:localize(@"preference.migrate.auto.source.other", nil)
                                          style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        [ws promptManualSource];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    if (a.popoverPresentationController) {
        a.popoverPresentationController.sourceView = self.tableView;
        a.popoverPresentationController.sourceRect = self.tableView.bounds;
    }
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptManualSource {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:localize(@"preference.migrate.auto.source.other", nil)
                                                               message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = self.srcRoot ?: @"";
        tf.placeholder = @"/var/mobile/...";
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *wa = a;
    __weak VersionAutoMigrateViewController *ws = self;
    [a addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        NSString *t = [wa.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length) { ws.srcRoot = t; [ws reloadScan]; }
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 执行

- (void)actionRun {
    if (self.srcRoot.length == 0) { [self showDialog:localize(@"preference.migrate.auto.need.pick", nil)]; return; }
    NSMutableArray<NSDictionary *> *units = [NSMutableArray array];
    NSUInteger groupsOn = 0; unsigned long long totalBytes = 0; NSUInteger totalFiles = 0;
    NSMutableSet<NSString *> *dstRoots = [NSMutableSet set];
    // ★ [VI-UI-FIX] 只搬【当前筛选视图内、且被勾选】的组 —— 与列表/计数完全同步。
    for (NSUInteger i = 0; i < self.groups.count; i++) {
        if (![self.checkedKeys containsObject:[self keyForGroup:self.groups[i]]]) continue;
        NSString *dst = [self resolvedDirForGroup:i];
        if (dst.length == 0) continue;
        groupsOn++;
        [dstRoots addObject:dst];
        for (NSDictionary *u in self.groups[i][@"units"]) {
            [units addObject:@{ @"unit": u[@"unit"], @"dstRoot": dst }];
            totalFiles += [u[@"files"] unsignedIntegerValue];
            totalBytes += [u[@"bytes"] unsignedLongLongValue];
        }
    }
    if (units.count == 0) { [self showDialog:localize(@"preference.migrate.auto.none.selected", nil)]; return; }

    NSString *msg = [NSString stringWithFormat:localize(@"preference.migrate.auto.confirm.msg", nil),
                     (unsigned long)groupsOn, (unsigned long)totalFiles, [self humanBytes:totalBytes],
                     (unsigned long)dstRoots.count];
    UIAlertController *c = [UIAlertController alertControllerWithTitle:localize(@"preference.migrate.auto.confirm.title", nil)
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak VersionAutoMigrateViewController *ws = self;
    [c addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [c addAction:[UIAlertAction actionWithTitle:localize(@"preference.migrate.auto.run", nil)
                                          style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        [ws executeUnits:units];
    }]];
    [self presentViewController:c animated:YES completion:nil];
}

- (void)executeUnits:(NSArray<NSDictionary *> *)units {
    NSDictionary *opts = @{ @"conflictPolicy": @(ameVDMConflictSkip), @"removeSource": @NO };
    NSDictionary *rep = ameVIAExecute(self.srcRoot, units, opts);
    NSString *body = [NSString stringWithFormat:localize(@"preference.migrate.auto.done.msg", nil),
                      (unsigned long)[rep[@"copied"] unsignedIntegerValue],
                      (unsigned long)[rep[@"identical"] unsignedIntegerValue],
                      (unsigned long)[rep[@"conflicts"] unsignedIntegerValue],
                      (unsigned long)[rep[@"renamed"] unsignedIntegerValue]];
    if ([rep[@"errors"] count] > 0) {
        NSArray *e = rep[@"errors"];
        body = [body stringByAppendingFormat:@"\n\n%@\n· %@",
                localize(@"preference.migrate.issues", nil), [e componentsJoinedByString:@"\n· "]];
    }
    UIAlertController *r = [UIAlertController alertControllerWithTitle:localize(@"preference.migrate.auto.done.title", nil)
                                                               message:body
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [r addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:r animated:YES completion:nil];
    [self reloadScan];   // 迁移后重扫：已复制的项会显示为「已存在/无新增」
}

#pragma mark - 杂

- (void)actionRescan { [self reloadScan]; }
- (void)actionClose { [self.navigationController dismissViewControllerAnimated:YES completion:nil]; }

- (void)showDialog:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:self.title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
