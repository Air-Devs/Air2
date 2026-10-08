//
//  A2GameVersionListViewController.m
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
//  见头文件：只列清单、不安装；无网/坏清单直接报，不进空页面。
//

#import "A2GameVersionListViewController.h"
#import "A2GameInstallOptionsViewController.h"
#import "A2RemoteVersions.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import "A2Log.h"

static NSString *const kCellID = @"A2GameVersionCell";

@interface A2GameVersionListViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISegmentedControl *typeSwitch;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray<A2RemoteVersion *> *allVersions;
@property (nonatomic, assign) BOOL showSnapshot;
@end

@implementation A2GameVersionListViewController

- (void)viewDidLoad {
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = @"安装新版本";

    _typeSwitch = [[UISegmentedControl alloc] initWithItems:@[@"正式版", @"快照"]];
    _typeSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    _typeSwitch.selectedSegmentIndex = 0;
    [_typeSwitch addTarget:self action:@selector(typeChanged)
          forControlEvents:UIControlEventValueChanged];
    [self.plainContentView addSubview:_typeSwitch];

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
    _tableView.rowHeight = 56;
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, A2SpaceXXL, 0);
    [_tableView registerClass:UITableViewCell.class forCellReuseIdentifier:kCellID];
    [self.plainContentView addSubview:_tableView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    _spinner.color = A2ThemeManager.shared.scheme.cPrimary;
    [self.plainContentView addSubview:_spinner];

    [NSLayoutConstraint activateConstraints:@[
        [_typeSwitch.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor constant:A2SpaceS],
        [_typeSwitch.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                  constant:A2PageMargin],
        [_typeSwitch.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                   constant:-A2PageMargin],
        [_countLabel.topAnchor constraintEqualToAnchor:_typeSwitch.bottomAnchor constant:A2SpaceS],
        [_countLabel.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                  constant:A2PageMargin],
        [_countLabel.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                   constant:-A2PageMargin],
        [_tableView.topAnchor constraintEqualToAnchor:_countLabel.bottomAnchor constant:A2SpaceS],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_spinner.centerXAnchor constraintEqualToAnchor:_tableView.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:_tableView.centerYAnchor],
    ]];

    [self fetchManifest];
}

#pragma mark - 数据

- (void)typeChanged {
    _showSnapshot = (_typeSwitch.selectedSegmentIndex == 1);
    [self.tableView reloadData];
    [self updateCount];
}

// 清单 type 原样透出：release 进正式版，其余全进快照。
// old_beta/old_alpha 归快照不单列——版本太多，第三段只会增加选择负担。
- (NSArray<A2RemoteVersion *> *)visibleVersions {
    NSMutableArray<A2RemoteVersion *> *out = [NSMutableArray array];
    for (A2RemoteVersion *v in _allVersions) {
        BOOL isRelease = [v.type isEqualToString:@"release"];
        if (_showSnapshot ? !isRelease : isRelease) [out addObject:v];
    }
    return [out copy];
}

- (void)fetchManifest {
    [_spinner startAnimating];
    [A2RemoteVersions fetchVersionsWithCompletion:^(NSArray<A2RemoteVersion *> *versions, NSError *error) {
        [self.spinner stopAnimating];
        if (error || versions.count == 0) {
            [A2Log log:@"download: 版本清单拉取失败：%@", error.localizedDescription ?: @"空清单"];
            [A2Toast show:[NSString stringWithFormat:@"版本清单拉取失败：%@",
                           error.localizedDescription ?: @"空清单"]
                   inView:self.view];
            self.allVersions = @[];
        } else {
            self.allVersions = versions;
        }
        [self.tableView reloadData];
        [self updateCount];
    }];
}

- (void)updateCount {
    _countLabel.text = [NSString stringWithFormat:@"%@ · %lu 个版本",
                        _showSnapshot ? @"快照" : @"正式版",
                        (unsigned long)self.visibleVersions.count];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleVersions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID forIndexPath:indexPath];
    A2RemoteVersion *v = self.visibleVersions[indexPath.row];
    cell.backgroundColor = UIColor.clearColor;
    cell.textLabel.text = v.versionID;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.textLabel.textColor = A2ThemeManager.shared.scheme.cOnSurface;
    cell.detailTextLabel.text = _showSnapshot ? v.type : @"正式版";
    cell.detailTextLabel.font = [A2Typography caption];
    cell.detailTextLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    A2RemoteVersion *v = self.visibleVersions[indexPath.row];
    [A2Log log:@"download: 选中版本 %@（%@）", v.versionID, v.type];
    A2GameInstallOptionsViewController *vc =
        [[A2GameInstallOptionsViewController alloc] initWithVersionID:v.versionID];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
