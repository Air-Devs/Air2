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

- (void)buildAccounts {
    // 示例数据，待接 Core 层的账号管理
    NSArray<NSArray<id> *> *accounts = @[
        @[@"Steve", @"Microsoft 正版账号", @YES, @YES],
        @[@"Offline", @"离线登录", @NO, @NO],
    ];

    for (NSArray<id> *a in accounts) {
        A2AccountRowView *row = [[A2AccountRowView alloc] initWithName:a[0] type:a[1]];
        row.current = [a[2] boolValue];
        row.refreshable = [a[3] boolValue];

        __weak typeof(self) weakSelf = self;
        __weak A2AccountRowView *weakRow = row;
        NSString *name = a[0];

        row.onSelect = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self selectAccount:weakRow];
        };
        row.onRefresh = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [A2Toast show:[NSString stringWithFormat:@"正在刷新 %@", name] inView:self.view];
        };
        row.onMore = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self showMoreMenuForName:name fromView:weakRow];
        };

        [_rows addObject:row];
        [_accountStack addArrangedSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:_accountStack.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:_accountStack.trailingAnchor],
        ]];
    }
}

- (void)selectAccount:(A2AccountRowView *)selected {
    for (A2AccountRowView *r in _rows) {
        r.current = (r == selected);
    }
    [A2Toast show:[NSString stringWithFormat:@"已切换到 %@", selected.accountName] inView:self.view];
}

- (void)showMoreMenuForName:(NSString *)name fromView:(UIView *)source {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:name message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *actions = @[@"皮肤与披风", @"复制 UUID", @"移除账号"];
    for (NSString *a in actions) {
        BOOL destructive = [a isEqualToString:@"移除账号"];
        [sheet addAction:[UIAlertAction actionWithTitle:a
                                                 style:(destructive ? UIAlertActionStyleDestructive
                                                                    : UIAlertActionStyleDefault)
                                               handler:^(UIAlertAction *action) {
            [A2Toast show:[NSString stringWithFormat:@"%@：%@", a, name] inView:self.view];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
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
        NSString *title = options[i][0];
        row.onTap = ^{
            [A2Toast show:title inView:self.view];
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
