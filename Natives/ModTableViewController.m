#import "utils.h"
//
//  ModTableViewController.m
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//  Updated: ensure 上网搜索 switch is placed directly left of refresh and visible reliably.
//

#import "ModTableViewController.h"
#import "ModItem.h"
#import "ModService.h"
#import "ModTableViewCell.h"
#import "BackgroundManager.h"

@interface ModTableViewController () <ModTableViewCellDelegate, UISearchBarDelegate>
@property (nonatomic, strong) NSArray<ModItem *> *mods;
@property (nonatomic, strong) NSArray<ModItem *> *filteredMods; // 用于存储搜索结果
@property (nonatomic, strong) UISwitch *onlineSearchSwitch;
@property (nonatomic, strong) UISearchBar *searchBar; // 搜索栏
@end

@implementation ModTableViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    // ModTableViewController 是 UITableViewController 子类，makeViewControllerTransparent 会自动处理 tableView 背景透明化
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // ★ [AUDIT-DECIDE] A-10：硬编码 "Mods" → 复用已有键 i18n_str_1283。
    self.title = localize(@"i18n_str_1283", nil);
    [self.tableView registerClass:[ModTableViewCell class] forCellReuseIdentifier:@"ModCell"];
    self.tableView.rowHeight = 96;

    // Create a container for label + switch and make it compact but wide enough
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 140, 32)];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 78, 32)];
    label.text = localize(@"i18n_str_455", nil);
    label.font = [UIFont systemFontOfSize:13];
    label.textAlignment = NSTextAlignmentRight;
    label.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleRightMargin;
    [container addSubview:label];

    self.onlineSearchSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(86, 4, 0, 0)];
    self.onlineSearchSwitch.on = [ModService sharedService].onlineSearchEnabled;
    [self.onlineSearchSwitch addTarget:self action:@selector(toggleOnlineSearch:) forControlEvents:UIControlEventValueChanged];
    self.onlineSearchSwitch.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [container addSubview:self.onlineSearchSwitch];

    UIBarButtonItem *switchContainerItem = [[UIBarButtonItem alloc] initWithCustomView:container];

    // Refresh button: rightmost
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshTapped)];

    // Put refresh as rightmost, switch container to its left
    self.navigationItem.rightBarButtonItems = @[refresh, switchContainerItem];

    // 创建搜索栏
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 44)];
    self.searchBar.placeholder = localize(@"i18n_str_456", nil);
    self.searchBar.delegate = self;
    self.searchBar.barStyle = UIBarStyleDefault;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    // 适配自定义启动器背景：透明化 searchBar 默认不透明背景，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] applyEffectToSearchBar:self.searchBar];

    // 将搜索栏添加到tableView的header中
    self.tableView.tableHeaderView = self.searchBar;
    
    // 初始化filteredMods
    self.filteredMods = @[];
    
    // Ensure switch reflects current state when view appears
    [self refreshTapped];

    // 监听背景效果变化通知，背景切换时重新应用透明效果
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)reapplyBackgroundEffect {
    // 背景效果改变时重新透明化当前 VC
    // UITableViewController 的 tableView 背景由 makeViewControllerTransparent 自动处理
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // 重新应用 searchBar 透明化效果（毛玻璃↔半透明切换后输入框背景需刷新）
    [[BackgroundManager sharedManager] applyEffectToSearchBar:self.searchBar];
}

- (void)dealloc {
    // 移除通知观察者，避免dealloc后收到通知导致崩溃
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.onlineSearchSwitch.on = [ModService sharedService].onlineSearchEnabled;
}

- (void)toggleOnlineSearch:(UISwitch *)sw {
    [ModService sharedService].onlineSearchEnabled = sw.isOn;
    [self refreshTapped];
}

- (void)refreshTapped {
    [[ModService sharedService] scanModsForProfile:self.profileName completion:^(NSArray<ModItem *> *mods) {
        self.mods = mods ?: @[];
        // 如果没有进行搜索，则显示所有Mod；否则显示搜索结果
        if (self.searchBar.text.length == 0) {
            self.filteredMods = self.mods;
        } else {
            [self filterModsForSearchText:self.searchBar.text];
        }
        [self.tableView reloadData];

        for (NSInteger i = 0; i < self.mods.count; i++) {
            ModItem *m = self.mods[i];
            [[ModService sharedService] fetchMetadataForMod:m completion:^(ModItem *item, NSError * _Nullable error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSUInteger idx = [self.mods indexOfObjectPassingTest:^BOOL(ModItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                        return [obj.filePath isEqualToString:item.filePath];
                    }];
                    if (idx != NSNotFound) {
                        NSIndexPath *path = [NSIndexPath indexPathForRow:idx inSection:0];
                        [self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
                    } else {
                        [self.tableView reloadData];
                    }
                });
            }];
        }
    }];
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self filterModsForSearchText:searchText];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [self filterModsForSearchText:@""];
    [searchBar resignFirstResponder];
}

- (void)filterModsForSearchText:(NSString *)searchText {
    if (searchText.length == 0) {
        // 如果搜索文本为空，则显示所有Mod
        self.filteredMods = self.mods;
    } else {
        // 根据搜索文本过滤Mod
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"displayName CONTAINS[cd] %@ OR modDescription CONTAINS[cd] %@", searchText, searchText];
        self.filteredMods = [self.mods filteredArrayUsingPredicate:predicate];
    }
    
    // 更新表格视图
    [self.tableView reloadData];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredMods.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModCell" forIndexPath:indexPath];
    ModItem *m = self.filteredMods[indexPath.row];
    cell.delegate = self;
    [cell configureWithMod:m displayMode:ModTableViewCellDisplayModeLocal];
    return cell;
}

#pragma mark - ModTableViewCellDelegate

- (void)modCellDidTapToggle:(UITableViewCell *)cell {
    NSIndexPath *ip = [self.tableView indexPathForCell:cell];
    if (!ip) return;
    ModItem *m = self.filteredMods[ip.row];
    NSError *err = nil;
    BOOL ok = [[ModService sharedService] toggleEnableForMod:m error:&err];
    if (!ok) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_42", nil) message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    } else {
        [self.tableView reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

- (void)modCellDidTapDelete:(UITableViewCell *)cell {
    NSIndexPath *ip = [self.tableView indexPathForCell:cell];
    if (!ip) return;
    ModItem *m = self.filteredMods[ip.row];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_457", nil) message:m.displayName preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_306", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        NSError *err = nil;
        if ([[ModService sharedService] deleteMod:m error:&err]) {
            // 从filteredMods和mods中移除
            NSMutableArray *newFiltered = [self.filteredMods mutableCopy];
            [newFiltered removeObjectAtIndex:ip.row];
            self.filteredMods = [newFiltered copy];
            
            NSMutableArray *newMods = [self.mods mutableCopy];
            NSUInteger originalIndex = [newMods indexOfObject:m];
            if (originalIndex != NSNotFound) {
                [newMods removeObjectAtIndex:originalIndex];
            }
            self.mods = [newMods copy];
            
            [self.tableView deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
        } else {
            UIAlertController *errAc = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_458", nil) message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [errAc addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:errAc animated:YES completion:nil];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)modCellDidTapOpenLink:(UITableViewCell *)cell {
    NSIndexPath *ip = [self.tableView indexPathForCell:cell];
    if (!ip) return;
    ModItem *m = self.filteredMods[ip.row];
    NSString *urlStr = m.homepage.length ? m.homepage : (m.sources.length ? m.sources : nil);
    if (!urlStr) return;
    NSURL *u = [NSURL URLWithString:urlStr];
    if (!u || !u.scheme) {
        NSString *withScheme = [NSString stringWithFormat:@"https://%@", urlStr];
        u = [NSURL URLWithString:withScheme];
    }
    if (u) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:^(BOOL success) {
                if (!success) {
                    UIAlertController *ac = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_459", nil) message:urlStr preferredStyle:UIAlertControllerStyleAlert];
                    [ac addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:ac animated:YES completion:nil];
                }
            }];
        });
    }
}

@end