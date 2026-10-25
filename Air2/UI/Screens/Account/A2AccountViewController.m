//
//  A2AccountViewController.m
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
//  账号管理 —— 整屏一张大卡，里面是账号列表。
//
//  结构对齐 ZL2 的 AccountManageScreen：
//    ┌────────────────────────────────────────────────┐
//    │ ┌────────────────────────────────────────────┐ │
//    │ │ ○ [S] Steve               🔄  ⋮            │ │
//    │ │       Microsoft 正版账号                    │ │
//    │ ├────────────────────────────────────────────┤ │
//    │ │ ○ [离] 离线账号            🔄  ⋮            │ │
//    │ │       离线登录                              │ │
//    │ └────────────────────────────────────────────┘ │
//    │                                                │
//    │              [+ 添加账号]                       │
//    └────────────────────────────────────────────────┘
//
//  注意：不是「头像卡 + 添加入口卡 + 设置卡」三块分离 ——
//  账号相关的东西都在这张卡里，靠分组自然分层。
//

#import "A2AccountViewController.h"
#import "A2AccountRowView.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2SettingsSection.h"
#import "A2Dialog.h"
#import "A2AccountLeftPanel.h"
#import "A2SettingsRow.h"
#import "A2AccountManager.h"
#import "A2Wardrobe.h"
#import "A2SkinHeadView.h"
#import "A2Account.h"
#import "A2MicrosoftAuth.h"
#import "A2LoginViewController.h"
#import "A2Settings.h"
#import "A2Log.h"

@interface A2AccountViewController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
/// 正在设置皮肤的账号（选择器回调时用）
@property (nonatomic, strong, nullable) A2Account *pendingSkinAccount;
@property (nonatomic, strong) A2GlassCard *listCard;
@property (nonatomic, strong) UIStackView *accountStack;
@property (nonatomic, strong) NSMutableArray<A2AccountRowView *> *rows;
@property (nonatomic, strong) UIStackView *emptyView;
/// 左栏（对照 ZL2 的 ActionsLayout：当前账号 + 添加按钮）
@property (nonatomic, strong) A2AccountLeftPanel *leftPanel;
@end

@implementation A2AccountViewController

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    // ⚠️ 必须在 init 里设，不能等到 viewDidLoad ——
    // 基类的 viewDidLoad 会先根据这个标志决定创建
    // setupScrollContent 还是 setupPlainContent。
    // 我在子类 viewDidLoad 里设成 NO 时，plainContentView 已经是 nil 了，
    // 后面拿它当约束宿主就是「anchor 到 nil」，直接崩溃。
    _usesScrollContent = NO;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"账号管理";
    _rows = [NSMutableArray array];

    // 左右 3:7 布局（对照 ZL2 的 AccountManageScreen）
    //   左：当前账号 + 添加按钮
    //   右：账号列表
    [self setupSplitLayout];
    [self buildAccounts];
    [self setupManageSection];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(buildAccounts)
                                              name:A2AccountsDidChangeNotification
                                            object:nil];
}

#pragma mark - 账号列表（一张大卡）

- (void)setupSplitLayout {
    // 左右 3:7（对照 ZL2 的 AccountManageScreen）
    // usesScrollContent 已在 init 里设为 NO
    UIView *host = self.plainContentView ?: self.view;

    // ---- 左栏 ----
    _leftPanel = [[A2AccountLeftPanel alloc] initWithFrame:CGRectZero];
    __weak typeof(self) weakSelf = self;
    _leftPanel.onAddAccount = ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self presentLoginChooser];
    };
    [host addSubview:_leftPanel];

    // ---- 右栏：账号列表卡 ----
    _listCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _listCard.translatesAutoresizingMaskIntoConstraints = NO;
    _listCard.cornerRadius = A2RadiusXL;
    _listCard.elevation = A2CardElevationLow;
    _listCard.contentInsets = UIEdgeInsetsMake(6, 12, 6, 12);

    _accountStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _accountStack.translatesAutoresizingMaskIntoConstraints = NO;
    _accountStack.axis = UILayoutConstraintAxisVertical;
    _accountStack.spacing = A2SpaceM;
    [_listCard.contentView addSubview:_accountStack];

    [NSLayoutConstraint activateConstraints:@[
        [_accountStack.topAnchor constraintEqualToAnchor:_listCard.contentView.topAnchor],
        [_accountStack.bottomAnchor constraintEqualToAnchor:_listCard.contentView.bottomAnchor],
        [_accountStack.leadingAnchor constraintEqualToAnchor:_listCard.contentView.leadingAnchor],
        [_accountStack.trailingAnchor constraintEqualToAnchor:_listCard.contentView.trailingAnchor],
    ]];

    // 右栏要能滚动（账号多时）
    UIScrollView *listScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    listScroll.translatesAutoresizingMaskIntoConstraints = NO;
    listScroll.showsVerticalScrollIndicator = NO;
    [listScroll addSubview:_listCard];
    [host addSubview:listScroll];

    [NSLayoutConstraint activateConstraints:@[
        // 左栏：宽占 30%
        [_leftPanel.topAnchor constraintEqualToAnchor:host.topAnchor constant:A2SpaceM],
        [_leftPanel.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-A2SpaceM],
        [_leftPanel.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:A2SpaceL],
        [_leftPanel.widthAnchor constraintEqualToAnchor:host.widthAnchor multiplier:0.28],

        // 右栏：占剩余
        [listScroll.topAnchor constraintEqualToAnchor:host.topAnchor constant:A2SpaceM],
        [listScroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-A2SpaceM],
        [listScroll.leadingAnchor constraintEqualToAnchor:_leftPanel.trailingAnchor
                                                 constant:A2SpaceL],
        [listScroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor
                                                  constant:-A2SpaceL],

        [_listCard.topAnchor constraintEqualToAnchor:listScroll.contentLayoutGuide.topAnchor],
        [_listCard.bottomAnchor constraintEqualToAnchor:listScroll.contentLayoutGuide.bottomAnchor],
        [_listCard.leadingAnchor constraintEqualToAnchor:listScroll.frameLayoutGuide.leadingAnchor],
        [_listCard.trailingAnchor constraintEqualToAnchor:listScroll.frameLayoutGuide.trailingAnchor],
    ]];
}

/// 点「添加账号」→ 选登录方式
- (void)presentLoginChooser {
    __weak typeof(self) weakSelf = self;
    [A2Dialog showInView:self.view
                   title:@"添加账号"
                 message:@"选择登录方式"
                 actions:@[
        [A2DialogAction actionWithTitle:@"微软账号" style:A2DialogActionStyleText handler:^{
            __strong typeof(weakSelf) self = weakSelf;
            [self presentLoginWithMode:A2LoginModeMicrosoft];
        }],
        [A2DialogAction actionWithTitle:@"离线账号" style:A2DialogActionStyleText handler:^{
            __strong typeof(weakSelf) self = weakSelf;
            [self presentLoginWithMode:A2LoginModeOffline];
        }],
        [A2DialogAction actionWithTitle:@"外置账号" style:A2DialogActionStyleText handler:^{
            __strong typeof(weakSelf) self = weakSelf;
            [self presentLoginWithMode:A2LoginModeThirdParty];
        }],
    ]];
}

- (void)presentLoginWithMode:(A2LoginMode)mode {
    A2LoginViewController *vc = [[A2LoginViewController alloc] initWithMode:mode];
    __weak typeof(self) weakSelf = self;
    vc.onSuccess = ^(A2Account *account) {
        __strong typeof(weakSelf) self = weakSelf;
        [self buildAccounts];
    };
    [self.navigationController pushViewController:vc animated:YES];
}

/// 从 A2AccountManager 读真实账号
- (void)buildAccounts {
    // 左栏跟随当前账号
    [_leftPanel updateWithAccount:A2AccountManager.shared.currentAccount];

    for (UIView *v in _accountStack.arrangedSubviews) {
        [_accountStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [_rows removeAllObjects];

    A2AccountManager *mgr = A2AccountManager.shared;
    NSArray<A2Account *> *accounts = mgr.accounts;

    if (accounts.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectZero];
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        empty.text = @"还没有添加账号";
        empty.font = [A2Typography body];
        empty.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
        empty.textAlignment = NSTextAlignmentCenter;
        [empty.heightAnchor constraintEqualToConstant:80].active = YES;
        [_accountStack addArrangedSubview:empty];
        return;
    }

    for (A2Account *acc in accounts) {
        A2AccountRowView *row = [[A2AccountRowView alloc] initWithName:acc.username
                                                                 type:acc.typeDisplayName];
        row.current = (acc == mgr.currentAccount);
        row.refreshable = acc.canRefresh;

        __weak typeof(self) weakSelf = self;
        __weak A2AccountRowView *weakRow = row;

        // 头像优先显示皮肤：本地已有就直接用，没有则按需拉一次后回填。
        row.skinPath = acc.skinPath;
        if (acc.skinPath.length == 0) {
            [A2AccountManager.shared ensureSkinForAccount:acc
                                               completion:^(A2Account *a) {
                if (a.skinPath.length) weakRow.skinPath = a.skinPath;
            }];
        }

        row.onSelect = ^{
            __strong typeof(weakSelf) self = weakSelf;
            if ([A2AccountManager.shared selectCurrentAccount:acc]) {
                [A2Log log:@"AccountVC: 切换到账号 %@", acc.username];
                for (A2AccountRowView *r in self.rows) r.current = (r == weakRow);
                [self.leftPanel updateWithAccount:acc];
                [A2Toast show:[NSString stringWithFormat:@"已切换到 %@", acc.username]
                       inView:self.view];
            }
        };
        row.onRefresh = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self refreshAccount:acc];
        };
        row.onMore = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self showMoreMenuForAccount:acc fromView:weakRow];
        };

        [_rows addObject:row];
        [_accountStack addArrangedSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:_accountStack.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:_accountStack.trailingAnchor],
        ]];
    }
}

/// 手动刷新凭据
- (void)refreshAccount:(A2Account *)acc {
    [A2Log log:@"AccountVC: 手动刷新账号 %@", acc.username];
    [A2Toast show:[NSString stringWithFormat:@"正在刷新 %@…", acc.username] inView:self.view];
    __weak typeof(self) weakSelf = self;
    if (acc.type == A2AccountTypeMicrosoft) {
        A2MicrosoftAuth *auth = [A2MicrosoftAuth new];
        [auth refreshAccount:acc completion:^(A2Account *newAcc, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (newAcc) {
                    [A2AccountManager.shared addAccount:newAcc];
                    [A2Log log:@"AccountVC: 账号 %@ 凭据刷新成功", acc.username];
                    [A2Toast show:@"凭据已刷新" inView:self.view];
                } else {
                    [A2Log log:@"AccountVC: 账号 %@ 凭据刷新失败 %@",
                                acc.username, error.localizedDescription ?: @"未知错误"];
                    [A2Toast show:(error.localizedDescription ?: @"刷新失败") inView:self.view];
                }
            });
        }];
    } else {
        [A2Log log:@"AccountVC: 账号 %@ 无需刷新", acc.username];
        [A2Toast show:@"此账号无需刷新" inView:self.view];
    }
}


/// 账号的更多操作
/// 选皮肤图并应用。
///
/// 用系统相册选择器 —— 皮肤图通常是玩家存的 PNG。
/// 选好后交给 A2Wardrobe 规整到 64x64 再落盘。
- (void)presentSkinPickerForAccount:(A2Account *)acc {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationPopover;
    picker.popoverPresentationController.sourceView = self.view;
    picker.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);

    _pendingSkinAccount = acc;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:nil];

    A2Account *acc = _pendingSkinAccount;
    _pendingSkinAccount = nil;
    if (!image || !acc) return;

    [A2Toast show:@"正在应用皮肤…" inView:self.view];

    // 规整到标准皮肤尺寸（64x64）后再交给 Core ——
    // Core 层不引 UIKit，图片处理必须在 UI 层做完。
    // 直接存原图会让头像裁剪坐标算错（A2SkinHeadView 按标准布局
    // 的固定像素位置取头部区域）。
    UIImage *normalized = image;
    if (image.size.width != 64 || image.size.height != 64) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(64, 64), NO, 1.0);
        [image drawInRect:CGRectMake(0, 0, 64, 64)];
        normalized = UIGraphicsGetImageFromCurrentImageContext() ?: image;
        UIGraphicsEndImageContext();
    }
    NSData *pngData = UIImagePNGRepresentation(normalized);
    if (!pngData) {
        [A2Toast show:@"图片格式无法处理" inView:self.view];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [[A2Wardrobe new] setLocalSkinData:pngData forAccount:acc completion:^(BOOL success) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (success) {
            [A2AccountManager.shared persistAccount:acc];
            [self buildAccounts];
            [A2Toast show:@"皮肤已更新" inView:self.view];
        } else {
            [A2Toast show:@"皮肤应用失败" inView:self.view];
        }
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
    _pendingSkinAccount = nil;
}

- (void)showMoreMenuForAccount:(A2Account *)acc fromView:(UIView *)source {
    // MD3 弹窗 —— 之前是系统 UIAlertController，与整体视觉不搭。
    // ZL2 / FCL 也都用自己的弹窗，不用系统样式。
    NSMutableArray<A2DialogAction *> *actions = [NSMutableArray array];

    // 设置皮肤 —— 离线账号也能用（拉不到远端材质，改用本地图）
    __weak typeof(self) weakSelf = self;
    [actions addObject:[A2DialogAction actionWithTitle:@"设置皮肤"
                                                 style:A2DialogActionStyleText
                                               handler:^{
        __strong typeof(weakSelf) self = weakSelf;
        [self presentSkinPickerForAccount:acc];
    }]];

    if (acc.type != A2AccountTypeOffline) {
        [actions addObject:[A2DialogAction actionWithTitle:@"复制 UUID"
                                                     style:A2DialogActionStyleText
                                                   handler:^{
            UIPasteboard.generalPasteboard.string = acc.profileID ?: @"";
            [A2Toast show:@"UUID 已复制" inView:UIApplication.sharedApplication.keyWindow];
        }]];
    }

    [actions addObject:[A2DialogAction actionWithTitle:@"移除账号"
                                                 style:A2DialogActionStyleDestructive
                                               handler:^{
        __strong typeof(weakSelf) self = weakSelf;
        [A2Log log:@"AccountVC: 移除账号 %@", acc.username];
        [A2AccountManager.shared removeAccount:acc];
        [self buildAccounts];
        [A2Toast show:@"已移除" inView:self.view];
    }]];

    [A2Dialog showInView:self.view
                   title:acc.username
                 message:acc.typeDisplayName
                 actions:actions];
}

#pragma mark - 添加账号

- (void)setupAddSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"添加账号"];
    section.footerText = @"支持正版账号、离线与第三方认证服务器（Yggdrasil）；进入后可切换登录方式。";

    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = @"person.badge.plus";
    row.title = @"添加账号";
    row.subtitle = @"正版、离线或第三方登录";
    row.accessory = A2SettingsRowAccessoryDisclosure;

    __weak typeof(self) weakSelf = self;
    row.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        A2LoginViewController *vc = [[A2LoginViewController alloc] initWithMode:A2LoginModeMicrosoft];
        vc.onSuccess = ^(A2Account *account) {
            [self buildAccounts];
        };
        [self.navigationController pushViewController:vc animated:YES];
    };
    [section addRow:row];

    [self addSection:section];
}

#pragma mark - 管理

- (void)setupManageSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:nil];

    A2SettingsRow *autoRow = [[A2SettingsRow alloc] init];
    autoRow.symbolName = @"checkmark.seal";
    autoRow.title = @"启动时自动登录";
    autoRow.subtitle = @"启动时刷新当前账号的登录凭据";
    autoRow.accessory = A2SettingsRowAccessorySwitch;
    autoRow.on = A2Settings.shared.autoLogin;
    autoRow.onToggle = ^(BOOL isOn) {
        A2Settings.shared.autoLogin = isOn;
    };
    [section addRow:autoRow];

    [self addSection:section];
}

@end
