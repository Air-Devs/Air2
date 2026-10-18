// ★ [VI-FLOW] B：版本隔离向导实现。
//
// 形式：分组列表 —— 顶部一行【新功能提示】(现在可以开版本隔离了 + 按实例情况的建议) +
//   一组「实例 → 嗅探结果 → 建议隔离态」+ 底部「以后不再提示」动作行。
//   「一键应用」= 对勾选项批量写 profile.versionIsolation（自动 ⇒ 移除键 / 隔离 ⇒ "1" /
//   共享 ⇒ "0"）。★ 全程只写设置，一个文件都不搬。
//
// ★ [VI-FLOW]（用户修正 1 + 补充）三个动作语义：
//   * 「跳过」(导航左)        —— 本次关闭，什么都不写；下次进启动器【仍会再弹】；
//   * 「一键应用」(导航右)     —— 批量写设置（可跳过哨兵）；
//   * 「以后不再提示」(底部行) —— 幂等落哨兵 internal.version_isolation_wizard_off，从此不再【自动】弹；
//                               手动入口（实例设置页「版本隔离向导」）不受影响，随时可再看。
//
// 建议规则（刻意保守，保证「不改默认行为」）：
//   * profile 已有显式三态值 ⇒ 建议 = 该显式值，默认【不勾选】（不改用户已有选择）；
//   * 否则目录形状嗅探命中（versions/<id>/ 下 mods 有文件 或 saves 有子项）⇒ 建议「隔离」，
//     默认【勾选】（这本来就会被 resolver 自动判成隔离 ⇒ 应用后解析结果不变，只是变显式）；
//   * 否则 ⇒ 建议「自动」（默认仍是关），默认【不勾选】。
//   ⇒ 一键应用只会把「已经是隔离」的实例写成显式隔离，不会把任何实例从关变开、也不会搬文件。

#import "VersionIsolationWizardViewController.h"
#import "PLProfiles.h"
#import "utils.h"

@interface VersionIsolationWizardViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSDictionary *> *entries;      // 每项见下方 buildEntries
@property (nonatomic, strong) NSMutableSet<NSString *> *checkedNames;

@end

@implementation VersionIsolationWizardViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"preference.vi.wizard.title", nil);
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    // ★ 可跳过：左上角关闭（什么都不写）⇒ 下次进启动器【仍会再弹】。
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:localize(@"preference.vi.wizard.skip", nil)
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(actionSkip)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:localize(@"preference.vi.wizard.apply", nil)
                                         style:UIBarButtonItemStyleDone
                                        target:self action:@selector(actionApply)];

    [self buildEntries];
    [self.tableView reloadData];
}

#pragma mark - 数据

- (NSString *)versionIdOfProfile:(NSDictionary *)prof {
    id v = prof[@"lastVersionId"];
    return [v isKindOfClass:NSString.class] ? (NSString *)v : nil;
}

/// 只读扫描：为每个现有 profile 算出 嗅探结果 + 建议三态 + 是否默认勾选。
- (void)buildEntries {
    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    NSMutableSet<NSString *> *preChecked = [NSMutableSet set];

    NSDictionary<NSString *, NSDictionary *> *profiles = PLProfiles.current.profiles;
    NSArray<NSString *> *names = [[profiles allKeys]
        sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString *name in names) {
        NSDictionary *prof = profiles[name];
        if (![prof isKindOfClass:NSDictionary.class]) continue;

        NSString *vid = [self versionIdOfProfile:prof];
        AmeVIExplicitState explicitState = ameVIExplicitStateForProfile(prof);
        NSDictionary *sniff = vid.length ? ameVISniffVersionFolder(vid) : nil;
        BOOL hit = [sniff[@"hasAny"] boolValue];

        AmeVIExplicitState suggest;
        if (explicitState != AmeVIExplicitStateAuto) {
            suggest = explicitState;              // 尊重用户已落盘的显式选择
        } else if (hit) {
            suggest = AmeVIExplicitStateIsolated; // 已被当实例用 ⇒ 建议显式隔离
        } else {
            suggest = AmeVIExplicitStateAuto;     // 空实例 ⇒ 保持默认（关）
        }

        // 嗅探依据文案（哪目录存在）—— 供用户核对。
        NSString *sniffText;
        if (vid.length == 0) {
            sniffText = localize(@"preference.vi.wizard.sniff.noversion", nil);
        } else if (hit) {
            NSMutableArray *hits = [NSMutableArray array];
            if ([sniff[@"hasMods"] boolValue])  [hits addObject:@"mods"];
            if ([sniff[@"hasSaves"] boolValue]) [hits addObject:@"saves"];
            sniffText = [NSString stringWithFormat:localize(@"preference.vi.wizard.sniff.hit", nil),
                         [hits componentsJoinedByString:@" / "]];
        } else {
            sniffText = localize(@"preference.vi.wizard.sniff.miss", nil);
        }

        BOOL preCheck = (explicitState == AmeVIExplicitStateAuto && hit);
        if (preCheck) [preChecked addObject:name];

        [list addObject:@{ @"name": name,
                           @"versionId": vid ?: @"",
                           @"sniff": sniffText,
                           @"suggest": @(suggest),
                           @"hasAny": @(hit) }];
    }
    self.entries = list;
    self.checkedNames = preChecked;
}

- (NSString *)stateName:(AmeVIExplicitState)state {
    switch (state) {
        case AmeVIExplicitStateIsolated: return localize(@"preference.vi.state.isolated", nil);
        case AmeVIExplicitStateShared:   return localize(@"preference.vi.state.shared", nil);
        case AmeVIExplicitStateAuto:
        default:                         return localize(@"preference.vi.state.auto", nil);
    }
}

#pragma mark - UITableView

// 0 = 新功能提示  1 = 实例与建议  2 = 「以后不再提示」动作行（★ [VI-FLOW]）
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 1 ? localize(@"preference.vi.wizard.section", nil) : nil;
}

// ★ C：共享边界文案写进页脚；★ 「只写设置不搬文件」也写在这里；
// ★ [VI-FLOW]：动作行（第 3 段）另有说明页脚（讲清「跳过 ≠ 以后不弹」与手动重开入口）。
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return [NSString stringWithFormat:@"%@\n%@",
                        localize(@"preference.vi.shared.boundary", nil),
                        localize(@"preference.vi.recover.hint", nil)];
    if (s == 1) return localize(@"preference.vi.wizard.footer", nil);
    return localize(@"preference.vi.wizard.dontshow.footer", nil);   // ★ [VI-FLOW]
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 1;
    if (s == 2) return 1;   // ★ [VI-FLOW] 「以后不再提示」
    return (NSInteger)self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"w"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"w"];

    if (ip.section == 0) {
        // ★ [VI-FLOW]（用户补充）：先明确告诉用户「现在可以开版本隔离了」，再按实例情况给建议。
        cell.textLabel.text = localize(@"preference.vi.wizard.feature.title", nil);
        cell.textLabel.textColor = [UIColor labelColor];
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.text = [NSString stringWithFormat:localize(@"preference.vi.wizard.intro", nil),
                                     (unsigned long)self.entries.count];
        cell.detailTextLabel.numberOfLines = 0;
        cell.imageView.image = [UIImage systemImageNamed:@"sparkles"];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (ip.section == 2) {
        // ★ [VI-FLOW]（用户修正 1）：「以后不再提示」—— 点了才落哨兵，从此不再【自动】弹；
        //   手动入口（实例设置页「版本隔离向导」）不受影响，随时可再看。不写任何实例设置、不搬文件。
        cell.textLabel.text = localize(@"preference.vi.wizard.dontshow", nil);
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.text = nil;
        cell.imageView.image = [UIImage systemImageNamed:@"bell.slash"];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    NSDictionary *e = self.entries[ip.row];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    NSString *name = e[@"name"];
    NSString *vid = e[@"versionId"];
    AmeVIExplicitState suggest = (AmeVIExplicitState)[e[@"suggest"] integerValue];

    cell.textLabel.text = vid.length ? [NSString stringWithFormat:@"%@  (%@)", name, vid] : name;
    cell.detailTextLabel.text = [NSString stringWithFormat:localize(@"preference.vi.wizard.row.detail", nil),
                                 e[@"sniff"], [self stateName:suggest]];
    cell.detailTextLabel.numberOfLines = 0;
    cell.imageView.image = [UIImage systemImageNamed:
        [e[@"hasAny"] boolValue] ? @"shippingbox" : @"square.dashed"];
    BOOL on = [self.checkedNames containsObject:name];
    cell.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 2) { [self actionDontShowAgain]; return; }   // ★ [VI-FLOW]
    if (ip.section != 1) return;
    NSString *name = self.entries[ip.row][@"name"];
    if ([self.checkedNames containsObject:name]) [self.checkedNames removeObject:name];
    else [self.checkedNames addObject:name];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - 动作

- (void)actionSkip {
    // 跳过：什么都不写 ⇒ 下次进启动器【仍会再弹】（跳过 ≠ 以后不弹）。
    NSLog(@"★ [VI-FLOW] 向导：用户跳过本次（未写任何设置、未搬任何文件；下次仍会再弹）");
    [self dismissViewControllerAnimated:YES completion:nil];
}

/// ★ [VI-FLOW]（用户修正 1）：「以后不再提示」—— 幂等落哨兵（整个向导页唯一的哨兵【写】点），
/// 从此不再【自动】弹；手动入口（实例设置页）不受影响，随时可再看。不写任何设置、不搬文件。
- (void)actionDontShowAgain {
    ameVIWizardMarkDontShowAgain();
    NSLog(@"★ [VI-FLOW] 向导：用户选择「以后不再提示」⇒ 以后不再自动弹出");
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)actionApply {
    // ★ 只写设置：对每个勾选项，按建议三态写 profile.versionIsolation（自动 ⇒ 移除键）。
    // 不移动 / 不复制 / 不删除任何文件。
    // 用无泛型类型接收（PLProfiles.profiles 的泛型是 NSMutableDictionary<NSString*,NSMutableDictionary<NSString*,NSString*>*>*，
    // 直接写 NSMutableDictionary<NSString*, NSDictionary*>* 会触发 incompatible-pointer-types 警告）。
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSUInteger applied = 0;
    for (NSString *name in self.checkedNames) {
        NSMutableDictionary *prof = profiles[name];
        if (![prof isKindOfClass:NSMutableDictionary.class]) continue;
        AmeVIExplicitState suggest = AmeVIExplicitStateAuto;
        for (NSDictionary *e in self.entries) {
            if ([e[@"name"] isEqualToString:name]) {
                suggest = (AmeVIExplicitState)[e[@"suggest"] integerValue];
                break;
            }
        }
        ameVISetExplicitStateForProfile(prof, suggest);
        applied++;
    }
    if (applied > 0) [PLProfiles.current save];
    NSLog(@"★ [VI-FLOW] 向导：一键应用 %lu 个实例（只写设置、未搬文件）", (unsigned long)applied);

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:localize(@"preference.vi.wizard.done.title", nil)
                         message:[NSString stringWithFormat:localize(@"preference.vi.wizard.done.msg", nil),
                                  (unsigned long)applied]
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak VersionIsolationWizardViewController *ws = self;
    [a addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil)
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x){ [ws dismissViewControllerAnimated:YES completion:nil]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
