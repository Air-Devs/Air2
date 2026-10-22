//
//  A2MultiplayerViewController.m
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
//
//
//  A2MultiplayerViewController.m
//  Air2
//

#import "A2MultiplayerViewController.h"
#import "A2GlassCard.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Settings.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Multiplayer.h"
#import "A2PrimaryButton.h"

/// 左侧说明的三种内容
typedef NS_ENUM(NSInteger, A2MultiplayerTab) {
    A2MultiplayerTabNotice = 0,     ///< 用户须知
    A2MultiplayerTabHostGuide,      ///< 房主教程
    A2MultiplayerTabGuestGuide,     ///< 房客教程
};

@interface A2MultiplayerViewController ()
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UILabel *guideTitleLabel;
@property (nonatomic, strong) UITextView *guideTextView;
@property (nonatomic, strong) A2GlassCard *leftCard;
@property (nonatomic, strong) NSLayoutConstraint *underlineLeading;
@property (nonatomic) CGFloat underlineWidth;
@end

@implementation A2MultiplayerViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.usesScrollContent = NO;
    self.pageTitle = @"陶瓦联机";

    [self setupLayout];
    [self selectTab:A2MultiplayerTabNotice animated:NO];
}

#pragma mark - 布局

- (void)setupLayout {
    // ---- 左侧：说明卡 ----
    _leftCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _leftCard.cornerRadius = A2RadiusXL;
    _leftCard.elevation = A2CardElevationLow;
    _leftCard.contentInsets = UIEdgeInsetsZero;

    [self buildGuideTabs];

    _guideTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _guideTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _guideTitleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];

    _guideTextView = [[UITextView alloc] initWithFrame:CGRectZero];
    _guideTextView.translatesAutoresizingMaskIntoConstraints = NO;
    _guideTextView.editable = NO;
    _guideTextView.scrollEnabled = YES;
    _guideTextView.backgroundColor = UIColor.clearColor;
    _guideTextView.textContainerInset = UIEdgeInsetsMake(0, 0, 0, 0);
    _guideTextView.textContainer.lineFragmentPadding = 0;
    _guideTextView.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _guideTextView.selectable = YES;   // 允许复制说明文字

    [_leftCard.contentView addSubview:_guideTitleLabel];
    [_leftCard.contentView addSubview:_guideTextView];

    // ---- 右侧：设置项 ----
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:nil];
    section.footerText = @"陶瓦联机是第三方开源自由软件，遇到问题请通过其官方渠道反馈。"
                          "联机使用 P2P 技术，房间内用户之间直接连接，"
                          "不经过第三方服务器转发。";

    A2SettingsRow *enableRow = [[A2SettingsRow alloc] init];
    enableRow.title = @"启用多人联机";
    enableRow.accessory = A2SettingsRowAccessorySwitch;
    enableRow.on = [A2Settings.shared boolForKey:@"terracottaEnabled" default:NO];
    enableRow.onToggle = ^(BOOL isOn) {
        [A2Settings.shared setBool:isOn forKey:@"terracottaEnabled"];
    };
    [section addRow:enableRow];

    A2SettingsRow *nodeRow = [[A2SettingsRow alloc] init];
    nodeRow.title = @"自定义 EasyTier 服务器节点";
    nodeRow.accessory = A2SettingsRowAccessorySwitch;
    nodeRow.on = [A2Settings.shared boolForKey:@"terracottaCustomNode" default:NO];
    nodeRow.onToggle = ^(BOOL isOn) {
        [A2Settings.shared setBool:isOn forKey:@"terracottaCustomNode"];
    };
    [section addRow:nodeRow];

    A2SettingsRow *logRow = [[A2SettingsRow alloc] init];
    logRow.title = @"分享联机核心日志";
    logRow.subtitle = @"导出日志文件，便于排查联机问题";
    logRow.accessory = A2SettingsRowAccessoryDisclosure;
    logRow.onTap = ^{
        [A2Toast show:@"日志文件不存在" inView:self.view];
    };
    [section addRow:logRow];

    A2SettingsRow *aboutRow = [[A2SettingsRow alloc] init];
    aboutRow.title = @"关于 EasyTier";
    aboutRow.accessory = A2SettingsRowAccessoryDisclosure;
    aboutRow.showsSeparator = NO;
    aboutRow.onTap = ^{
        NSURL *url = [NSURL URLWithString:@"https://github.com/EasyTier/EasyTier"];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    };
    [section addRow:aboutRow];

    // 未就绪时明确提示，而不是让用户点了没反应
    if (!A2Multiplayer.shared.available) {
        A2SettingsRow *notReadyRow = [[A2SettingsRow alloc] init];
        notReadyRow.title = @"联机组件未就绪";
        notReadyRow.subtitle = @"需要 libterracotta 库，当前构建中未包含";
        notReadyRow.accessory = A2SettingsRowAccessoryWarning;
        [section addRow:notReadyRow];
    }

    _leftCard.translatesAutoresizingMaskIntoConstraints = NO;
    section.translatesAutoresizingMaskIntoConstraints = NO;
    [self.plainContentView addSubview:_leftCard];
    [self.plainContentView addSubview:section];

    [NSLayoutConstraint activateConstraints:@[
        // 左侧占一半（对应 ZL2 的 weight(0.5f)）
        [_leftCard.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [_leftCard.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor],
        [_leftCard.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor],
        [_leftCard.widthAnchor constraintEqualToAnchor:self.plainContentView.widthAnchor
                                            multiplier:0.5
                                              constant:-A2SpaceL],

        // 右侧占一半
        [section.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor],
        [section.leadingAnchor constraintEqualToAnchor:_leftCard.trailingAnchor
                                              constant:A2SpaceL],
        [section.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor],
    ]];

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// 左侧的 Tab 切换（对应 ZL2 的 TabRow，下方带下划线指示器）
- (void)buildGuideTabs {
    _tabControl = [[UISegmentedControl alloc] initWithItems:@[@"用户须知", @"房主教程", @"房客教程"]];
    _tabControl.translatesAutoresizingMaskIntoConstraints = NO;
    _tabControl.selectedSegmentIndex = 0;
    [_tabControl addTarget:self action:@selector(tabChanged)
          forControlEvents:UIControlEventValueChanged];
    [_leftCard.contentView addSubview:_tabControl];

    [_leftCard.contentView addSubview:_guideTitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_tabControl.topAnchor constraintEqualToAnchor:_leftCard.contentView.topAnchor
                                              constant:A2SpaceL],
        [_tabControl.leadingAnchor constraintEqualToAnchor:_leftCard.contentView.leadingAnchor
                                                  constant:A2SpaceL],
        [_tabControl.trailingAnchor constraintEqualToAnchor:_leftCard.contentView.trailingAnchor
                                                   constant:-A2SpaceL],

        [_guideTitleLabel.topAnchor constraintEqualToAnchor:_tabControl.bottomAnchor
                                                   constant:A2SpaceL],
        [_guideTitleLabel.leadingAnchor constraintEqualToAnchor:_leftCard.contentView.leadingAnchor
                                                        constant:A2SpaceL],
        [_guideTitleLabel.trailingAnchor constraintEqualToAnchor:_leftCard.contentView.trailingAnchor
                                                         constant:-A2SpaceL],

        [_guideTextView.topAnchor constraintEqualToAnchor:_guideTitleLabel.bottomAnchor
                                                 constant:A2SpaceM],
        [_guideTextView.leadingAnchor constraintEqualToAnchor:_leftCard.contentView.leadingAnchor
                                                     constant:A2SpaceL],
        [_guideTextView.trailingAnchor constraintEqualToAnchor:_leftCard.contentView.trailingAnchor
                                                      constant:-A2SpaceL],
        [_guideTextView.bottomAnchor constraintEqualToAnchor:_leftCard.contentView.bottomAnchor
                                                    constant:-A2SpaceL],
    ]];
}

#pragma mark - Tab

- (void)tabChanged {
    [self selectTab:(A2MultiplayerTab)_tabControl.selectedSegmentIndex animated:YES];
}

- (void)selectTab:(A2MultiplayerTab)tab animated:(BOOL)animated {
    _tabControl.selectedSegmentIndex = tab;

    void (^update)(void) = ^{
        self.guideTitleLabel.text = [self titleForTab:tab];
        self.guideTextView.text = [self bodyForTab:tab];
        [self applyTheme];
    };

    if (animated) {
        // 切换时淡入，避免文字突变
        [UIView transitionWithView:_guideTextView
                          duration:A2AnimDurationFast
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:update
                        completion:nil];
    } else {
        update();
    }
}

- (NSString *)titleForTab:(A2MultiplayerTab)tab {
    switch (tab) {
        case A2MultiplayerTabNotice:     return @"用户须知";
        case A2MultiplayerTabHostGuide:  return @"房主教程";
        case A2MultiplayerTabGuestGuide: return @"房客教程";
    }
    return @"";
}

- (NSString *)bodyForTab:(A2MultiplayerTab)tab {
    switch (tab) {
        case A2MultiplayerTabNotice:
            return @"陶瓦联机是第三方开源自由软件，您在使用过程中所遇到的问题"
                    "请通过相关渠道进行反馈。\n\n"
                    "陶瓦联机使用 P2P 技术，联机成功后房间内用户之间将直接连接，"
                    "不会使用第三方服务器对您的流量进行转发。最终联机体验和"
                    "参与联机者的网络情况有较大关系。\n\n"
                    "在多人联机全过程中，您必须严格遵守您所在国家与地区的"
                    "全部法律法规。";

        case A2MultiplayerTabHostGuide:
            return @"1. 在「设置 - 陶瓦联机」中启用多人联机。\n\n"
                    "2. 启动游戏，进入任意世界。\n\n"
                    "3. 打开游戏内菜单，选择「对局域网开放」，"
                    "记下聊天栏显示的端口号。\n\n"
                    "4. 回到启动器，在联机页创建房间，"
                    "其他人即可通过房间号加入。\n\n"
                    "5. 联机结束后，记得在启动器中关闭房间。";

        case A2MultiplayerTabGuestGuide:
            return @"1. 在「设置 - 陶瓦联机」中启用多人联机。\n\n"
                    "2. 向房主索取房间号。\n\n"
                    "3. 在启动器联机页输入房间号并加入。\n\n"
                    "4. 加入成功后启动游戏，"
                    "在多人游戏列表中即可看到房主的服务器。\n\n"
                    "5. 若无法连接，请检查双方网络是否允许 P2P；"
                    "部分运营商网络需要中继节点。";
    }
    return @"";
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _guideTitleLabel.textColor = t.cOnSurface;
    _guideTextView.textColor = t.cOnSurfaceVariant;
    _guideTextView.tintColor = t.cPrimary;
    _tabControl.selectedSegmentTintColor = t.cPrimary;
}

@end
