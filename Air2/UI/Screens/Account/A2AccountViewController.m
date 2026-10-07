//
//  A2AccountViewController.m
//  Air2
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
#import "A2SettingsRow.h"
#import "A2AccountManager.h"
#import "A2LoginViewController.h"

@interface A2AccountViewController ()
@property (nonatomic, strong) A2GlassCard *listCard;
@property (nonatomic, strong) UIStackView *accountStack;
@property (nonatomic, strong) NSMutableArray<A2AccountRowView *> *rows;
@property (nonatomic, strong) UIStackView *emptyView;
@end

@implementation A2AccountViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"账号管理";
    _rows = [NSMutableArray array];

    [self setupListCard];
    [self buildAccounts];
    [self setupAddSection];
    [self setupManageSection];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(buildAccounts)
                                              name:A2AccountsDidChangeNotification
                                            object:nil];
}

#pragma mark - 账号列表（一张大卡）

- (void)setupListCard {
    _listCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _listCard.cornerRadius = A2RadiusXL;
    _listCard.elevation = A2CardElevationLow;
    _listCard.contentInsets = UIEdgeInsetsMake(6, 12, 6, 12);   // ZL2: 上下 6、左右 12

    _accountStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _accountStack.translatesAutoresizingMaskIntoConstraints = NO;
    _accountStack.axis = UILayoutConstraintAxisVertical;
    _accountStack.spacing = A2SpaceM;   // 每项垂直间距 12

    [_listCard.contentView addSubview:_accountStack];
    [NSLayoutConstraint activateConstraints:@[
        [_accountStack.topAnchor constraintEqualToAnchor:_listCard.contentView.topAnchor],
        [_accountStack.bottomAnchor constraintEqualToAnchor:_listCard.contentView.bottomAnchor],
        [_accountStack.leadingAnchor constraintEqualToAnchor:_listCard.contentView.leadingAnchor],
        [_accountStack.trailingAnchor constraintEqualToAnchor:_listCard.contentView.trailingAnchor],
    ]];

    [self addSection:_listCard];
}

/// 从 A2AccountManager 读真实账号
- (void)buildAccounts {
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

        row.onSelect = ^{
            __strong typeof(weakSelf) self = weakSelf;
            if ([A2AccountManager.shared setCurrentAccount:acc]) {
                for (A2AccountRowView *r in self.rows) r.current = (r == weakRow);
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
    [A2Toast show:[NSString stringWithFormat:@"正在刷新 %@…", acc.username] inView:self.view];
    __weak typeof(self) weakSelf = self;
    if (acc.type == A2AccountTypeMicrosoft) {
        A2MicrosoftAuth *auth = [A2MicrosoftAuth new];
        [auth refreshAccount:acc completion:^(A2Account *newAcc, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (newAcc) {
                    [A2AccountManager.shared addAccount:newAcc];
                    [A2Toast show:@"凭据已刷新" inView:self.view];
                } else {
                    [A2Toast show:(error.localizedDescription ?: @"刷新失败") inView:self.view];
                }
            });
        }];
    } else {
        [A2Toast show:@"此账号无需刷新" inView:self.view];
    }
}


/// 账号的更多操作
- (void)showMoreMenuForAccount:(A2Account *)acc fromView:(UIView *)source {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:acc.username
                                            message:acc.typeDisplayName
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    if (acc.type != A2AccountTypeOffline) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"复制 UUID"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            UIPasteboard.generalPasteboard.string = acc.profileID ?: @"";
            [A2Toast show:@"UUID 已复制" inView:self.view];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"移除账号"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *a) {
        [A2AccountManager.shared removeAccount:acc];
        [self buildAccounts];
        [A2Toast show:@"已移除" inView:self.view];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    sheet.popoverPresentationController.sourceView = source;
    sheet.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 添加账号

- (void)setupAddSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"添加账号"];
    section.footerText = @"Microsoft 正版账号可加入正版服务器；离线账号仅用于单机与离线服务器。";

    NSArray<NSArray<NSString *> *> *options = @[
        @[@"Microsoft 登录", @"使用正版账号，支持皮肤与正版服务器", @"person.badge.key.fill"],
        @[@"离线登录", @"仅输入用户名，无需密码", @"person.fill"],
        @[@"第三方认证服务器", @"Yggdrasil 协议，如 LittleSkin", @"server.rack"],
    ];

    for (NSUInteger i = 0; i < options.count; i++) {
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = options[i][2];
        row.title = options[i][0];
        row.subtitle = options[i][1];
        row.accessory = A2SettingsRowAccessoryDisclosure;
        A2LoginMode mode = A2LoginModeMicrosoft;
        if (i == 1) mode = A2LoginModeOffline;
        else if (i == 2) mode = A2LoginModeThirdParty;

        __weak typeof(self) weakSelf = self;
        row.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            A2LoginViewController *vc = [[A2LoginViewController alloc] initWithMode:mode];
            vc.onSuccess = ^(A2Account *account) {
                [self buildAccounts];
            };
            [self.navigationController pushViewController:vc animated:YES];
        };
        [section addRow:row];
    }

    [self addSection:section];
}

#pragma mark - 管理

- (void)setupManageSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:nil];

    A2SettingsRow *autoRow = [[A2SettingsRow alloc] init];
    autoRow.symbolName = @"checkmark.seal";
    autoRow.title = @"启动时自动登录";
    autoRow.accessory = A2SettingsRowAccessorySwitch;
    autoRow.on = YES;
    autoRow.onToggle = ^(BOOL isOn) {};
    [section addRow:autoRow];

    [self addSection:section];
}

@end
