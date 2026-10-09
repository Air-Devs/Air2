//
//  A2FavoritesViewController.m
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
//  卡片列表 + 左滑删除 + 变更通知刷新，空态提示。
//

#import "A2FavoritesViewController.h"
#import "A2DownloadFavorites.h"
#import "A2ContentSource.h"
#import "A2ResourceDetailViewController.h"
#import "A2GlassCard.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import "A2Log.h"

static NSString *const kFavoriteCellID = @"A2FavoriteCell";

static NSString *A2FavoritePlatformName(A2ContentPlatform platform) {
    return (platform == A2ContentPlatformCurseForge) ? @"CurseForge" : @"Modrinth";
}

static NSString *A2FavoriteFormatCount(long long count) {
    if (count >= 1000000) return [NSString stringWithFormat:@"%.1fM", count / 1000000.0];
    if (count >= 1000) return [NSString stringWithFormat:@"%.1fK", count / 1000.0];
    return [NSString stringWithFormat:@"%lld", count];
}

#pragma mark - 收藏项行

@interface A2FavoriteCell : UITableViewCell
@property (nonatomic, strong) A2GlassCard *card;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UILabel *statsLabel;
@property (nonatomic, strong) UILabel *tagLabel;
- (void)configureWithFavorite:(A2FavoriteItem *)item;
@end

@implementation A2FavoriteCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _card.cornerRadius = A2RadiusL;
    _card.elevation = A2CardElevationLow;
    [self.contentView addSubview:_card];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [A2Typography titleCard];
    _titleLabel.numberOfLines = 1;

    _summaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _summaryLabel.font = [A2Typography subtitleCard];
    _summaryLabel.numberOfLines = 2;

    _statsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statsLabel.font = [A2Typography caption];

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:
                              @[_titleLabel, _summaryLabel, _statsLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 3;

    _tagLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _tagLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _tagLabel.font = [A2Typography caption];
    _tagLabel.textAlignment = NSTextAlignmentCenter;
    _tagLabel.layer.cornerRadius = 8;
    _tagLabel.layer.cornerCurve = kCACornerCurveContinuous;
    _tagLabel.clipsToBounds = YES;

    [_card.contentView addSubview:textStack];
    [_card.contentView addSubview:_tagLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:3],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3],
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],

        [textStack.topAnchor constraintEqualToAnchor:_card.contentView.topAnchor],
        [textStack.bottomAnchor constraintEqualToAnchor:_card.contentView.bottomAnchor],
        [textStack.leadingAnchor constraintEqualToAnchor:_card.contentView.leadingAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_tagLabel.leadingAnchor
                                                           constant:-A2SpaceS],

        [_tagLabel.trailingAnchor constraintEqualToAnchor:_card.contentView.trailingAnchor],
        [_tagLabel.topAnchor constraintEqualToAnchor:_card.contentView.topAnchor],
        [_tagLabel.widthAnchor constraintGreaterThanOrEqualToConstant:64],
        [_tagLabel.heightAnchor constraintEqualToConstant:22],
    ]];

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)configureWithFavorite:(A2FavoriteItem *)item {
    _titleLabel.text = item.title.length ? item.title : item.projectID;
    _summaryLabel.text = item.summary.length ? item.summary : @"暂无简介";
    _statsLabel.text = [NSString stringWithFormat:@"%@ · %@ 次下载",
                        A2FavoritePlatformName(item.platform),
                        A2FavoriteFormatCount(item.downloadCount)];
    _tagLabel.text = A2FavoritePlatformName(item.platform);
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _titleLabel.textColor = t.cOnSurface;
    _summaryLabel.textColor = t.cOnSurfaceVariant;
    _statsLabel.textColor = [t.cOnSurfaceVariant colorWithAlphaComponent:0.8];
    _tagLabel.textColor = t.cPrimary;
    _tagLabel.backgroundColor = [t.cPrimary colorWithAlphaComponent:0.15];
}

@end

#pragma mark - 收藏页

@interface A2FavoritesViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSArray<A2FavoriteItem *> *items;
@end

@implementation A2FavoritesViewController

- (void)viewDidLoad {
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = @"收藏";
    self.items = @[];

    [self setupTable];
    [self reloadFavorites];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleFavoritesChanged:)
                                              name:A2FavoritesDidChangeNotification
                                            object:nil];
}

- (void)setupTable {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.rowHeight = 92;
    _tableView.contentInset = UIEdgeInsetsMake(A2SpaceS, 0, A2SpaceXXL, 0);
    [_tableView registerClass:A2FavoriteCell.class forCellReuseIdentifier:kFavoriteCellID];
    [self.plainContentView addSubview:_tableView];

    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.font = [A2Typography caption];
    _emptyLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.text = @"还没有收藏，去搜索里收藏喜欢的项目吧";
    [self.plainContentView addSubview:_emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                 constant:A2PageMargin],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                  constant:-A2PageMargin],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],

        [_emptyLabel.centerXAnchor constraintEqualToAnchor:self.plainContentView.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:self.plainContentView.centerYAnchor
                                                  constant:-40],
        [_emptyLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.plainContentView.leadingAnchor
                                                               constant:A2PageMargin],
        [_emptyLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.plainContentView.trailingAnchor
                                                             constant:-A2PageMargin],
    ]];
}

- (void)reloadFavorites {
    self.items = [[A2DownloadFavorites shared] allFavorites];
    [_tableView reloadData];
    _emptyLabel.hidden = (self.items.count > 0);
}

- (void)handleFavoritesChanged:(NSNotification *)note {
    [self reloadFavorites];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    A2FavoriteCell *cell = [tableView dequeueReusableCellWithIdentifier:kFavoriteCellID
                                                          forIndexPath:indexPath];
    [cell configureWithFavorite:self.items[indexPath.row]];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    A2FavoriteItem *fav = self.items[indexPath.row];
    A2ContentItem *item = [self contentItemFromFavorite:fav];
    A2ResourceDetailViewController *vc = [[A2ResourceDetailViewController alloc]
                                         initWithProject:item
                                         contentClass:[self contentClassForFavorite:fav]];
    [self.navigationController pushViewController:vc animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf = self;
    UIContextualAction *remove = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"取消收藏"
                          handler:^(UIContextualAction *action, UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
        __strong typeof(weakSelf) self = weakSelf;
        NSString *projectID = self.items[indexPath.row].projectID;
        [[A2DownloadFavorites shared] removeFavoriteWithID:projectID];
        [A2Log log:@"download: 收藏页移除收藏 %@", projectID];
        [A2Toast show:@"已取消收藏" inView:self.view];
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}

#pragma mark - 转换

- (A2ContentItem *)contentItemFromFavorite:(A2FavoriteItem *)fav {
    A2ContentItem *item = [[A2ContentItem alloc] init];
    item.platform = fav.platform;
    item.projectID = fav.projectID;
    item.title = fav.title;
    item.summary = fav.summary;
    item.iconURL = fav.iconURL;
    item.categories = fav.categories;
    item.downloadCount = fav.downloadCount;
    item.downloadable = YES;
    return item;
}

/// 按项目分类猜一个资源大类；拿不准时按模组处理。
- (A2ContentClass)contentClassForFavorite:(A2FavoriteItem *)fav {
    A2ContentClass cls = A2ContentClassMod;
    for (NSString *category in fav.categories) {
        NSString *lower = category.lowercaseString;
        if ([lower containsString:@"shader"]) { cls = A2ContentClassShader; break; }
        if ([lower containsString:@"resource"]) { cls = A2ContentClassResourcePack; break; }
        if ([lower containsString:@"modpack"]) { cls = A2ContentClassModPack; break; }
        if ([lower containsString:@"datapack"]) { cls = A2ContentClassDataPack; break; }
        if ([lower containsString:@"world"]) { cls = A2ContentClassWorld; break; }
    }
    return cls;
}

@end
