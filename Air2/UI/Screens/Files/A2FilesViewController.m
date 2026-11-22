//
//  A2FilesViewController.m
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
//  面包屑用导航栈天然表达：进子目录就 push 同类页面，返回即回退。
//  文件点击只报大小，不做预览（没预览器之前不挂羊头卖狗肉）。
//

#import "A2FilesViewController.h"
#import "A2GameFiles.h"
#import "A2Toast.h"
#import "A2InputDialog.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

static NSString *const kCellID = @"A2FileCell";

@interface A2FilesViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *rootPath;
@property (nonatomic, copy) NSString *relativePath;
@property (nonatomic, strong) A2GameFiles *store;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) NSArray<A2GameFileEntry *> *entries;
@end

@implementation A2FilesViewController

- (instancetype)initWithRootPath:(NSString *)rootPath displayName:(NSString *)displayName {
    return [self initWithRootPath:rootPath relativePath:@"" displayName:displayName];
}

- (instancetype)initWithRootPath:(NSString *)rootPath
                    relativePath:(NSString *)relativePath
                     displayName:(NSString *)displayName {
    self = [super init];
    if (!self) return nil;
    _rootPath = [rootPath copy];
    _relativePath = [relativePath copy] ?: @"";
    self.pageTitle = displayName.length ? displayName : @"文件";
    return self;
}

- (void)viewDidLoad {
    self.usesScrollContent = NO;
    [super viewDidLoad];

    NSError *err = nil;
    _store = [[A2GameFiles alloc] initWithRootPath:_rootPath error:&err];
    if (!_store) {
        [A2Toast show:(err.localizedDescription ?: @"目录打不开") inView:self.view];
    }

    [self setupTable];
    [self setupAddButton];
    [self reload];
}

- (void)setupTable {
    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [A2Typography caption];
    _countLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    [self.plainContentView addSubview:_countLabel];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.rowHeight = 60;
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, A2SpaceXXL, 0);
    [_tableView registerClass:UITableViewCell.class forCellReuseIdentifier:kCellID];
    [self.plainContentView addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_countLabel.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor constant:A2SpaceS],
        [_countLabel.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                  constant:A2PageMargin],
        [_countLabel.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                   constant:-A2PageMargin],
        [_tableView.topAnchor constraintEqualToAnchor:_countLabel.bottomAnchor constant:A2SpaceS],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
    ]];
}

- (void)setupAddButton {
    // 右上 + 只做“新建文件夹”（唯一写操作入口，语义单一）。
    [self addTrailingButtonWithSymbol:@"plus" action:^{
        __strong typeof(self) self = self;
        if (!self) return;
        [self askForNameWithTitle:@"新建文件夹" initial:@"" done:^(NSString *name) {
            NSError *err = nil;
            if ([self.store createDirectory:name inDirectory:self.relativePath error:&err]) {
                [self reload];
            } else {
                [A2Toast show:(err.localizedDescription ?: @"创建失败") inView:self.view];
            }
        }];
    }];
}

#pragma mark - 数据

- (void)reload {
    if (!_store) {
        _entries = @[];
        [_tableView reloadData];
        return;
    }
    NSError *err = nil;
    NSArray *list = [_store entriesInDirectory:_relativePath error:&err];
    if (!list) {
        [A2Toast show:(err.localizedDescription ?: @"读取失败") inView:self.view];
        list = @[];
    }
    _entries = list;
    // 根目录显示全路径，其余显示相对路径，定位不迷路。
    NSString *where = _relativePath.length ? _relativePath : _rootPath.lastPathComponent;
    _countLabel.text = [NSString stringWithFormat:@"%@ · %lu 项", where, (unsigned long)_entries.count];
    [_tableView reloadData];
}

- (NSString *)displaySize:(A2GameFileEntry *)e {
    if (e.isDirectory) return @"文件夹";
    long long n = e.fileSize;
    if (n < 1024) return [NSString stringWithFormat:@"%lld B", n];
    if (n < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", n / 1024.0];
    if (n < 1024LL * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", n / 1048576.0];
    return [NSString stringWithFormat:@"%.2f GB", n / 1073741824.0];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID forIndexPath:indexPath];
    A2GameFileEntry *e = _entries[indexPath.row];
    cell.backgroundColor = UIColor.clearColor;
    cell.textLabel.text = e.name;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.textLabel.textColor = A2ThemeManager.shared.scheme.cOnSurface;
    cell.detailTextLabel.text = [self displaySize:e];
    cell.detailTextLabel.font = [A2Typography caption];
    cell.detailTextLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    cell.imageView.image = [UIImage systemImageNamed:(e.isDirectory ? @"folder.fill" : @"doc.fill")];
    cell.imageView.tintColor = A2ThemeManager.shared.scheme.cPrimary;
    cell.accessoryType = e.isDirectory ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    A2GameFileEntry *e = _entries[indexPath.row];
    if (e.isDirectory) {
        // 进子目录就是 push 同类页面，导航栈即面包屑。
        NSString *sub = _relativePath.length
            ? [_relativePath stringByAppendingPathComponent:e.name] : e.name;
        A2FilesViewController *vc = [[A2FilesViewController alloc] initWithRootPath:_rootPath
                                                                      relativePath:sub
                                                                       displayName:e.name];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    // 文件不预览：报大小即可，比挂个打不开的预览器诚实。
    [A2Toast show:[NSString stringWithFormat:@"%@ · %@", e.name, [self displaySize:e]]
           inView:self.view];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsForRowAtIndexPath:(NSIndexPath *)indexPath {
    A2GameFileEntry *e = _entries[indexPath.row];
    NSString *target = _relativePath.length
        ? [_relativePath stringByAppendingPathComponent:e.name] : e.name;

    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                     title:@"删除"
                                                                   handler:^(UIContextualAction *a, UIView *v,
                                                                             void (^done)(BOOL)) {
        NSError *err = nil;
        if ([self.store deleteEntryAt:target error:&err]) {
            [self reload];
        } else {
            [A2Toast show:(err.localizedDescription ?: @"删除失败") inView:self.view];
        }
        done(YES);
    }];

    UIContextualAction *ren = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                     title:@"改名"
                                                                   handler:^(UIContextualAction *a, UIView *v,
                                                                             void (^done)(BOOL)) {
        [self askForNameWithTitle:@"重命名" initial:e.name done:^(NSString *name) {
            NSError *err = nil;
            if ([self.store renameEntryAt:target toName:name error:&err]) {
                [self reload];
            } else {
                [A2Toast show:(err.localizedDescription ?: @"重命名失败") inView:self.view];
            }
        }];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, ren]];
}

#pragma mark - 输入框（新建/改名共用，校验收敛到 Core）

- (void)askForNameWithTitle:(NSString *)title
                    initial:(NSString *)initial
                       done:(void (^)(NSString *))done {
    A2InputDialog *dlg = [A2InputDialog dialogWithTitle:title
                                                message:nil
                                                  label:@"名称"
                                            initialText:initial];
    dlg.autocapitalizationType = UITextAutocapitalizationTypeNone;
    dlg.validator = ^NSString *(NSString *text) {
        NSString *name = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        // 校验收敛到 Core：UI 不自己定规则，错因直接展示 Core 给的文案。
        NSError *err = nil;
        if (![A2GameFiles validateFileName:name error:&err]) {
            return err.localizedDescription ?: @"文件名非法";
        }
        return nil;
    };
    dlg.onFinish = ^(BOOL committed, NSString *text) {
        if (!committed) return;
        NSString *name = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (done) done(name);
    };
    [dlg presentFrom:self];
}

@end
