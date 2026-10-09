//
//  A2SearchByIdViewController.m
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
//  输入项目 ID/slug，调资源源按 ID 取项目，命中即进详情页。
//

#import "A2SearchByIdViewController.h"
#import "A2ContentSource.h"
#import "A2ResourceDetailViewController.h"
#import "A2TextField.h"
#import "A2PrimaryButton.h"
#import "A2GlassCard.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"
#import "A2Log.h"

@interface A2SearchByIdViewController ()
@property (nonatomic, strong) A2TextField *inputField;
@property (nonatomic, strong) A2PrimaryButton *queryButton;
@end

@implementation A2SearchByIdViewController

- (void)viewDidLoad {
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = @"按 ID 查询";
    [self setupUI];
}

- (void)setupUI {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.cornerRadius = A2RadiusL;
    card.elevation = A2CardElevationLow;
    [self.plainContentView addSubview:card];

    _inputField = [[A2TextField alloc] initWithLabel:@"项目 ID / slug"];
    _inputField.translatesAutoresizingMaskIntoConstraints = NO;
    _inputField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _inputField.supportText = @"支持 Modrinth 的 project id 或 slug，也支持 CurseForge 的 mod id。";

    _queryButton = [[A2PrimaryButton alloc] initWithTitle:@"查询" style:A2ButtonStylePrimary];
    _queryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_queryButton addTarget:self action:@selector(performQuery)
           forControlEvents:UIControlEventTouchUpInside];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectZero];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.font = [A2Typography caption];
    hint.numberOfLines = 0;
    hint.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    hint.text = [NSString stringWithFormat:@"当前资源源：%@",
                 [A2ContentSource sourceForPlatform:[A2ContentSource preferredPlatform]].displayName];

    [card.contentView addSubview:_inputField];
    [card.contentView addSubview:_queryButton];
    [card.contentView addSubview:hint];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor constant:A2SpaceM],
        [card.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                           constant:A2PageMargin],
        [card.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                            constant:-A2PageMargin],

        [_inputField.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [_inputField.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [_inputField.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],

        [_queryButton.topAnchor constraintEqualToAnchor:_inputField.bottomAnchor constant:A2SpaceL],
        [_queryButton.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [_queryButton.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [_queryButton.heightAnchor constraintEqualToConstant:A2ButtonHeight],

        [hint.topAnchor constraintEqualToAnchor:_queryButton.bottomAnchor constant:A2SpaceM],
        [hint.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [hint.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [hint.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
    ]];
}

#pragma mark - 查询

- (void)performQuery {
    [self.view endEditing:YES];

    NSString *text = [_inputField.text stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length == 0) {
        _inputField.errorText = @"请输入项目 ID";
        [A2Toast show:@"请输入项目 ID" inView:self.view];
        return;
    }
    _inputField.errorText = nil;

    A2ContentSource *source = [A2ContentSource sourceForPlatform:[A2ContentSource preferredPlatform]];
    if (!source.isAvailable) {
        [A2Toast show:(source.unavailableReason ?: @"该资源源不可用") inView:self.view];
        return;
    }

    [A2Log log:@"download: 按 ID 查询 %@（%@）", text, source.displayName];
    _queryButton.loading = YES;

    __weak typeof(self) weakSelf = self;
    [source projectWithID:text completion:^(A2ContentItem *item, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.queryButton.loading = NO;
            if (error || !item) {
                [A2Log log:@"download: 按 ID 查询失败 %@：%@", text,
                 error.localizedDescription ?: @"无匹配结果"];
                [A2Toast show:[NSString stringWithFormat:@"未找到项目：%@",
                               error.localizedDescription ?: @"请检查 ID"]
                       inView:self.view];
                return;
            }
            [A2Log log:@"download: 按 ID 命中 %@（%@）", item.projectID, item.title];
            A2ResourceDetailViewController *vc = [[A2ResourceDetailViewController alloc]
                                                 initWithProject:item
                                                 contentClass:[self contentClassForItem:item]];
            [self.navigationController pushViewController:vc animated:YES];
        });
    }];
}

/// 按项目分类猜一个资源大类；拿不准时按模组处理。
- (A2ContentClass)contentClassForItem:(A2ContentItem *)item {
    A2ContentClass cls = A2ContentClassMod;
    for (NSString *category in item.categories) {
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
