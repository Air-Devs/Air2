//
//  A2LauncherViewController+Cards.m
//  Air2
//
//  主界面三张卡片的构建：账户卡、版本卡、快捷入口。
//  拆出来是因为每张卡的内部布局都会随后续功能增长。
//

#import "A2LauncherViewController_Internal.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2QuickActionCard.h"
#import "A2Toast.h"

@implementation A2LauncherViewController (Cards)


#pragma mark 账户卡

- (void)buildAccountCard {
    _accountCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _accountCard.cornerRadius = A2RadiusL;
    _accountCard.elevation = A2CardElevationLow;
    _accountCard.tappable = YES;
    _accountCard.onTap = ^{ [self openAccount]; };

    _avatarView = [[UIView alloc] initWithFrame:CGRectZero];
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarView.layer.cornerRadius = 22;
    _avatarView.layer.cornerCurve = kCACornerCurveContinuous;
    _avatarView.clipsToBounds = YES;

    _avatarInitial = [[UILabel alloc] initWithFrame:CGRectZero];
    _avatarInitial.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarInitial.text = @"S";
    _avatarInitial.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    _avatarInitial.textAlignment = NSTextAlignmentCenter;
    [_avatarView addSubview:_avatarInitial];

    _accountNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _accountNameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _accountNameLabel.text = @"Steve";

    _accountTypeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _accountTypeLabel.font = [A2Typography caption];
    _accountTypeLabel.text = @"Microsoft 正版账号";

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_accountNameLabel, _accountTypeLabel]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 1;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_avatarView, textStack]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = A2SpaceM;
    row.alignment = UIStackViewAlignmentCenter;

    [_accountCard.contentView addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.widthAnchor constraintEqualToConstant:44],
        [_avatarView.heightAnchor constraintEqualToConstant:44],
        [_avatarInitial.centerXAnchor constraintEqualToAnchor:_avatarView.centerXAnchor],
        [_avatarInitial.centerYAnchor constraintEqualToAnchor:_avatarView.centerYAnchor],
        [row.topAnchor constraintEqualToAnchor:_accountCard.contentView.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:_accountCard.contentView.bottomAnchor],
        [row.leadingAnchor constraintEqualToAnchor:_accountCard.contentView.leadingAnchor],
        [row.trailingAnchor constraintLessThanOrEqualToAnchor:_accountCard.contentView.trailingAnchor],
    ]];

    [_panelStack addArrangedSubview:_accountCard];
}

#pragma mark 版本卡

- (void)buildVersionCard {
    _versionCard = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    _versionCard.cornerRadius = A2RadiusL;
    _versionCard.elevation = A2CardElevationHigh;

    // —— 顶行：图标 + 版本名 + 设置按钮 ——
    _versionIconBox = [[UIView alloc] initWithFrame:CGRectZero];
    _versionIconBox.translatesAutoresizingMaskIntoConstraints = NO;
    _versionIconBox.layer.cornerRadius = A2RadiusXS;
    _versionIconBox.layer.cornerCurve = kCACornerCurveContinuous;
    _versionIconBox.clipsToBounds = YES;

    _versionInitial = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionInitial.translatesAutoresizingMaskIntoConstraints = NO;
    _versionInitial.text = @"1";
    _versionInitial.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    _versionInitial.textAlignment = NSTextAlignmentCenter;
    [_versionIconBox addSubview:_versionInitial];

    _versionNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionNameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _versionNameLabel.text = @"1.21.5-fabric";
    _versionNameLabel.adjustsFontSizeToFitWidth = YES;
    _versionNameLabel.minimumScaleFactor = 0.75;

    _versionMetaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionMetaLabel.font = [A2Typography caption];
    _versionMetaLabel.text = @"Fabric 0.16.10 · Java 21";

    UIStackView *versionTextStack =
        [[UIStackView alloc] initWithArrangedSubviews:@[_versionNameLabel, _versionMetaLabel]];
    versionTextStack.axis = UILayoutConstraintAxisVertical;
    versionTextStack.spacing = 1;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    UIButton *settingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    settingsBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [settingsBtn setImage:[UIImage systemImageNamed:@"gearshape" withConfiguration:cfg]
                 forState:UIControlStateNormal];
    settingsBtn.tag = 701;
    [settingsBtn addAction:[UIAction actionWithHandler:^(UIAction *action) {
        [self openVersionSettings];
    }] forControlEvents:UIControlEventTouchUpInside];

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[_versionIconBox, versionTextStack, settingsBtn]];
    topRow.translatesAutoresizingMaskIntoConstraints = NO;
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.spacing = A2SpaceM;
    topRow.alignment = UIStackViewAlignmentCenter;
    [topRow setCustomSpacing:A2SpaceS afterView:versionTextStack];

    // —— 启动按钮 ——
    _launchButton = [[A2PrimaryButton alloc] initWithTitle:@"启动游戏" style:A2ButtonStylePrimary];
    [_launchButton addTarget:self action:@selector(launchGame) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[topRow, _launchButton]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceL;

    [_versionCard.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_versionIconBox.widthAnchor constraintEqualToConstant:34],
        [_versionIconBox.heightAnchor constraintEqualToConstant:34],
        [_versionInitial.centerXAnchor constraintEqualToAnchor:_versionIconBox.centerXAnchor],
        [_versionInitial.centerYAnchor constraintEqualToAnchor:_versionIconBox.centerYAnchor],
        [settingsBtn.widthAnchor constraintEqualToConstant:36],
        [settingsBtn.heightAnchor constraintEqualToConstant:36],

        [stack.topAnchor constraintEqualToAnchor:_versionCard.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_versionCard.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_versionCard.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_versionCard.contentView.trailingAnchor],
    ]];

    [_panelStack addArrangedSubview:_versionCard];
}

#pragma mark 快捷入口

- (void)buildQuickGrid {
    NSArray<NSArray<NSString *> *> *items = @[
        @[@"版本管理", @"square.stack.3d.up",          @"openVersions"],
        @[@"下载",     @"arrow.down.circle",           @"openDownload"],
        @[@"联机",     @"antenna.radiowaves.left.and.right", @"openMultiplayer"],
        @[@"文件",     @"folder",                      @"openFiles"],
    ];

    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    for (UIStackView *r in @[row1, row2]) {
        r.translatesAutoresizingMaskIntoConstraints = NO;
        r.axis = UILayoutConstraintAxisHorizontal;
        r.distribution = UIStackViewDistributionFillEqually;
        r.spacing = A2SpaceM;
    }

    for (NSUInteger i = 0; i < items.count; i++) {
        A2QuickActionCard *card = [[A2QuickActionCard alloc] initWithTitle:items[i][0]
                                                                symbolName:items[i][1]];
        SEL sel = NSSelectorFromString(items[i][2]);
        __weak typeof(self) weakSelf = self;
        card.onSelect = ^{
            __strong typeof(weakSelf) self = weakSelf;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            if ([self respondsToSelector:sel]) [self performSelector:sel];
#pragma clang diagnostic pop
        };
        [(i < 2 ? row1 : row2) addArrangedSubview:card];
    }

    _quickRow1 = row1;
    _quickRow2 = row2;

    UIStackView *grid = [[UIStackView alloc] initWithArrangedSubviews:@[row1, row2]];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = A2SpaceM;

    [_panelStack addArrangedSubview:grid];
}
@end
