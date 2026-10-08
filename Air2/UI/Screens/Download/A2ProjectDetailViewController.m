//
//  A2ProjectDetailViewController.m
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
//  详情页只干三件事：讲清这是什么（头信息）、有哪些版本、下到哪。
//  无 icon 时首字母占位（列表页同款做法，不引入图片库）；
//  禁分发与空版本各走独立空态，不共用“加载失败”。
//

#import "A2ProjectDetailViewController.h"
#import "A2ContentSource.h"
#import "A2DownloadManifest.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import "A2DownloadEngine.h"

static NSString *const kVersionCellID = @"A2ProjectVersionCell";

@interface A2ProjectDetailViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) A2ContentItem *project;
@property (nonatomic, copy) NSString *targetSubdir;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) A2PrimaryButton *downloadButton;
@property (nonatomic, strong) NSArray<A2ContentVersion *> *versions;
@end

@implementation A2ProjectDetailViewController

- (instancetype)initWithProject:(A2ContentItem *)project targetSubdir:(NSString *)subdir {
    self = [super init];
    if (!self) return nil;
    _project = project;
    _targetSubdir = [subdir copy] ?: @"downloads";
    _versions = @[];
    return self;
}

- (void)viewDidLoad {
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = _project.title;

    [self setupHeader];
    [self setupTable];
    [self reloadVersions];
}

#pragma mark - 头信息

- (void)setupHeader {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.cornerRadius = A2RadiusL;
    card.elevation = A2CardElevationLow;
    [self.plainContentView addSubview:card];

    // 首字母占位（无图库依赖；有 iconURL 也不拉，列表页同样处理）。
    UILabel *avatar = [[UILabel alloc] initWithFrame:CGRectZero];
    avatar.translatesAutoresizingMaskIntoConstraints = NO;
    avatar.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    avatar.textAlignment = NSTextAlignmentCenter;
    NSString *first = _project.title.length ? [_project.title substringToIndex:1] : @"?";
    avatar.text = first.uppercaseString;
    avatar.textColor = A2ThemeManager.shared.scheme.cPrimary;
    [card.contentView addSubview:avatar];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.text = _project.title;
    title.numberOfLines = 2;
    title.textColor = A2ThemeManager.shared.scheme.cOnSurface;
    [card.contentView addSubview:title];

    UILabel *meta = [[UILabel alloc] initWithFrame:CGRectZero];
    meta.translatesAutoresizingMaskIntoConstraints = NO;
    meta.font = [A2Typography caption];
    meta.numberOfLines = 0;
    meta.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    NSMutableArray<NSString *> *bits = [NSMutableArray array];
    if (_project.author.length) [bits addObject:_project.author];
    if (_project.downloadCount > 0) {
        [bits addObject:[NSString stringWithFormat:@"%@ 次下载", [self formatCount:_project.downloadCount]]];
    }
    if (_project.followCount > 0) {
        [bits addObject:[NSString stringWithFormat:@"%@ 关注", [self formatCount:_project.followCount]]];
    }
    meta.text = [bits componentsJoinedByString:@" · "];
    [card.contentView addSubview:meta];

    UILabel *summary = [[UILabel alloc] initWithFrame:CGRectZero];
    summary.translatesAutoresizingMaskIntoConstraints = NO;
    summary.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    summary.numberOfLines = 0;
    summary.text = _project.summary.length ? _project.summary : @"暂无简介";
    summary.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    [card.contentView addSubview:summary];

    _downloadButton = [[A2PrimaryButton alloc] initWithTitle:@"下载最新版"
                                                      style:A2ButtonStylePrimary];
    _downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_downloadButton addTarget:self
                        action:@selector(downloadLatest)
              forControlEvents:UIControlEventTouchUpInside];
    [card.contentView addSubview:_downloadButton];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor constant:A2SpaceS],
        [card.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                           constant:A2PageMargin],
        [card.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                            constant:-A2PageMargin],
        [avatar.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [avatar.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [avatar.widthAnchor constraintEqualToConstant:56],
        [avatar.heightAnchor constraintEqualToConstant:56],
        [title.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [title.leadingAnchor constraintEqualToAnchor:avatar.trailingAnchor constant:A2SpaceM],
        [title.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [meta.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [meta.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [meta.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [summary.topAnchor constraintEqualToAnchor:avatar.bottomAnchor constant:A2SpaceM],
        [summary.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [summary.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [_downloadButton.topAnchor constraintEqualToAnchor:summary.bottomAnchor constant:A2SpaceM],
        [_downloadButton.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [_downloadButton.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [_downloadButton.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [_downloadButton.heightAnchor constraintEqualToConstant:A2ButtonHeight],
    ]];
}

#pragma mark - 版本列表

- (void)setupTable {
    // 头卡已在 setupHeader 加到 plainContentView；table 锚到它下面。
    // 为拿到头卡底部约束，这里按 subviews 顺序取最后一个卡片。
    UIView *header = self.plainContentView.subviews.lastObject;

    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.font = [A2Typography caption];
    _emptyLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.hidden = YES;
    [self.plainContentView addSubview:_emptyLabel];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.rowHeight = 64;
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, A2SpaceXXL, 0);
    [_tableView registerClass:UITableViewCell.class forCellReuseIdentifier:kVersionCellID];
    [self.plainContentView addSubview:_tableView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    _spinner.color = A2ThemeManager.shared.scheme.cPrimary;
    [self.plainContentView addSubview:_spinner];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:A2SpaceS],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_emptyLabel.centerXAnchor constraintEqualToAnchor:_tableView.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:_tableView.centerYAnchor
                                                  constant:-40],
        [_spinner.centerXAnchor constraintEqualToAnchor:_tableView.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:_tableView.centerYAnchor
                                               constant:-40],
    ]];
}

- (void)reloadVersions {
    // 禁分发的项目不请求版本列表，直接给专属空态（计划 P1 四空态之一）。
    if (!_project.downloadable) {
        _versions = @[];
        [_tableView reloadData];
        _emptyLabel.hidden = NO;
        _emptyLabel.text = @"该作者禁止第三方分发，请前往官网下载";
        _downloadButton.enabled = NO;
        return;
    }
    [_spinner startAnimating];
    _emptyLabel.hidden = YES;
    [[A2ContentSource sourceForPlatform:_project.platform] versionsForProject:_project.projectID
                                                                 gameVersion:nil
                                                                      loader:nil
                                                                  completion:^(NSArray<A2ContentVersion *> *versions, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            if (error || versions.count == 0) {
                self.versions = @[];
                [self.tableView reloadData];
                self.emptyLabel.hidden = NO;
                self.emptyLabel.text = error ? [NSString stringWithFormat:@"加载失败：%@",
                                                error.localizedDescription] : @"没有可用的版本";
                self.downloadButton.enabled = NO;
                return;
            }
            self.versions = versions;
            [self.tableView reloadData];
            self.emptyLabel.hidden = YES;
            self.downloadButton.enabled = YES;
            [self refreshUpdateState];
        });
    }];
}

// 更新提示：装过该项目、且最新版没装 → 主按钮改“更新到 x”。
// 不在列表页做行级提示：那需要每行一次版本请求（N+1），
// 又贵又抖；详情页版本已拉到手，对比零成本。
- (void)refreshUpdateState {
    A2ContentVersion *latest = _versions.firstObject;
    if (!latest) return;
    BOOL installedProject = [[A2DownloadManifest shared] isProjectInstalled:_project.projectID];
    BOOL latestInstalled = [[A2DownloadManifest shared] isVersionInstalled:_project.projectID
                                                                versionID:latest.versionID];
    if (installedProject && !latestInstalled) {
        _downloadButton.title = [NSString stringWithFormat:@"更新到 %@",
                                 latest.versionNumber];
    } else {
        _downloadButton.title = @"下载最新版";
    }
}

#pragma mark - 下载（从列表页搬家，逻辑逐行未改）

- (void)downloadLatest {
    A2ContentVersion *v = _versions.firstObject;
    if (!v) {
        [A2Toast show:@"没有可用的版本" inView:self.view];
        return;
    }
    [self downloadVersion:v];
}

- (void)downloadVersion:(A2ContentVersion *)version {
    if (version.candidateURLs.count == 0) {
        [A2Toast show:@"此版本没有可下载的文件（可能作者禁止第三方分发）"
               inView:self.view];
        return;
    }

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [[[docs stringByAppendingPathComponent:@".minecraft"]
                      stringByAppendingPathComponent:_targetSubdir] copy];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *fileName = version.fileName.length ? version.fileName
        : [NSString stringWithFormat:@"%@-%@.jar", _project.projectID, version.versionNumber];
    NSString *dest = [dir stringByAppendingPathComponent:fileName];

    [A2Toast show:[NSString stringWithFormat:@"开始下载 %@", fileName] inView:self.view];

    A2DownloadRequest *req = [A2DownloadRequest new];
    // candidateURLs 里已含镜像候选（按设置排序），下载引擎会依次尝试
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *u in version.candidateURLs) {
        NSURL *url = [NSURL URLWithString:u];
        if (url) [urls addObject:url];
    }
    req.candidateURLs = urls;
    req.destinationPath = dest;
    req.expectedSize = version.fileSize;
    req.allowZipFallbackCheck = YES;

    [[A2DownloadEngine sharedClient] startRequest:req
        progress:nil
           speed:nil
      completion:^(BOOL success, NSError *error) {
        // 落盘成功才记清单（失败不记，避免角标撒谎）。
        if (success) {
            [[A2DownloadManifest shared] recordDownloadWithProjectID:self->_project.projectID
                                                           versionID:version.versionID
                                                            fileName:fileName
                                                              subdir:self->_targetSubdir];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [A2Toast show:[NSString stringWithFormat:@"已下载 %@", fileName] inView:self.view];
            } else {
                [A2Toast show:[NSString stringWithFormat:@"下载失败：%@", error.localizedDescription]
                       inView:self.view];
            }
        });
    }];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _versions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kVersionCellID
                                                           forIndexPath:indexPath];
    A2ContentVersion *v = _versions[indexPath.row];
    cell.backgroundColor = UIColor.clearColor;
    cell.textLabel.text = v.versionNumber;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.textLabel.textColor = A2ThemeManager.shared.scheme.cOnSurface;
    NSMutableArray<NSString *> *bits = [NSMutableArray array];
    if (indexPath.row == 0) [bits addObject:@"最新"];
    if (v.loaders.count) [bits addObject:v.loaders.firstObject];
    if (v.fileSize > 0) [bits addObject:[self displaySize:v.fileSize]];
    if (v.gameVersions.count) [bits addObject:[v.gameVersions componentsJoinedByString:@", "]];
    cell.detailTextLabel.text = [bits componentsJoinedByString:@" · "];
    cell.detailTextLabel.font = [A2Typography caption];
    cell.detailTextLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    // 装过的版本打勾（按 versionID 查清单，文件被手删则不算装过）。
    BOOL installed = [[A2DownloadManifest shared] isVersionInstalled:_project.projectID
                                                           versionID:v.versionID];
    cell.accessoryType = installed ? UITableViewCellAccessoryCheckmark
                                   : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self downloadVersion:_versions[indexPath.row]];
}

- (NSString *)formatCount:(long long)count {
    if (count >= 1000000) return [NSString stringWithFormat:@"%.1fM", count / 1000000.0];
    if (count >= 1000) return [NSString stringWithFormat:@"%.1fK", count / 1000.0];
    return [NSString stringWithFormat:@"%lld", count];
}

- (NSString *)displaySize:(long long)n {
    if (n < 1024) return [NSString stringWithFormat:@"%lld B", n];
    if (n < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", n / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", n / 1048576.0];
}

@end
