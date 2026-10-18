//
//  TerracottaViewController.m
//  陶瓦联机界面 —— 综合 ZalithLauncher2（状态驱动的卡片式布局）与
//  FoldCraftLauncher（信息密度与错误提示）的设计重写。
//
//  改动要点（相对旧版 963 行实现）：
//   1. 去掉常驻 UISegmentedControl + 常驻双面板。改为按状态整屏切换，
//      未连接时只呈现「创建房间 / 加入房间」两张卡片（ZL2 WaitingUI 的做法）。
//   2. 新增日志入口（ZL2 底部 TextButton 的做法）—— 便于用户自查联机失败原因。
//   3. 新增难度显示：访客加入过程中 Terracotta 会回传难度分级
//      （EASIEST / SIMPLE / MEDIUM / TOUGH），旧版未展示。
//   4. 已连接态改为房间码 + 操作区 + 玩家列表的分栏布局，窄屏自动改为纵向堆叠。
//   5. 移除 ZeroTier 入口。
//
//  逻辑层未改动：状态/操作全部经 TerracottaManager，本文件只负责呈现与转发。
//

#import "TerracottaViewController.h"
#import "TerracottaBridge.h"
#import "McLanPortDetector.h"
#import "LauncherPreferences.h"   // getPrefObject（当前玩家名 / 游戏目录）
#import "utils.h"

#pragma mark - 设计常量

/// 卡片圆角与内边距，与启动器其它界面的视觉语言保持一致。
static const CGFloat kCardCornerRadius = 16.0;
static const CGFloat kCardPadding      = 16.0;
static const CGFloat kContentInset     = 16.0;
static const CGFloat kBlockSpacing     = 16.0;

@interface TerracottaViewController () <UITextFieldDelegate>

#pragma mark 状态
@property(nonatomic, assign) BOOL isHostRole;
@property(nonatomic, strong) McLanPortDetector *portDetector;
@property(nonatomic, assign) uint16_t manualPort;
@property(nonatomic, assign) BOOL portAutoDetected;

#pragma mark 容器
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIStackView  *rootStack;   // 纵向主容器

#pragma mark 顶部状态卡
@property(nonatomic, strong) UIView      *statusCard;
@property(nonatomic, strong) UIImageView *statusIcon;
@property(nonatomic, strong) UILabel     *statusTitleLabel;
@property(nonatomic, strong) UILabel     *statusDetailLabel;
@property(nonatomic, strong) UIActivityIndicatorView *statusSpinner;
@property(nonatomic, strong) UILabel     *portLabel;

#pragma mark 未连接态
@property(nonatomic, strong) UIStackView *entryStack;
@property(nonatomic, strong) UIControl   *hostCard;
@property(nonatomic, strong) UIControl   *guestCard;

#pragma mark 创建房间表单
@property(nonatomic, strong) UIStackView *createFormStack;
@property(nonatomic, strong) UITextField *portField;
@property(nonatomic, strong) UILabel     *portHintLabel;

#pragma mark 加入房间表单
@property(nonatomic, strong) UIStackView *joinFormStack;
@property(nonatomic, strong) UITextField *codeField;

#pragma mark 已连接态
@property(nonatomic, strong) UIStackView *connectedStack;
@property(nonatomic, strong) UIButton *roomCodeCopyButton;
@property(nonatomic, strong) UIButton *directURLCopyButton;
@property(nonatomic, strong) UILabel  *roomCodeCaptionLabel;
@property(nonatomic, strong) UILabel     *roomCodeLabel;
@property(nonatomic, strong) UILabel     *directURLLabel;
@property(nonatomic, strong) UIStackView *playerListStack;

#pragma mark 底部
@property(nonatomic, strong) UILabel  *footerLabel;
@property(nonatomic, strong) UIButton *logButton;
@property(nonatomic, strong) UIButton *actionButton;

@end

@implementation TerracottaViewController

#pragma mark - 生命周期

- (instancetype)init {
    if ((self = [super init])) {
        _manualPort = 0;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"terracotta_title", nil);
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self buildLayout];
    [self registerNotifications];
    [self refreshUI];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshUI];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopPortAutoDetection];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 布局骨架

- (void)buildLayout {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.scrollView];

    self.rootStack = [[UIStackView alloc] init];
    self.rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.rootStack.axis = UILayoutConstraintAxisVertical;
    self.rootStack.spacing = kBlockSpacing;
    self.rootStack.alignment = UIStackViewAlignmentFill;
    [self.scrollView addSubview:self.rootStack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor      constraintEqualToAnchor:safe.topAnchor],
        [self.scrollView.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.scrollView.bottomAnchor   constraintEqualToAnchor:safe.bottomAnchor],

        [self.rootStack.topAnchor      constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor      constant:kContentInset],
        [self.rootStack.bottomAnchor   constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor   constant:-kContentInset],
        [self.rootStack.leadingAnchor  constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor  constant:kContentInset],
        [self.rootStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-kContentInset],
        [self.rootStack.widthAnchor    constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor      constant:-(kContentInset * 2)],
    ]];

    [self buildStatusCard];
    [self buildEntryCards];
    [self buildCreateForm];
    [self buildJoinForm];
    [self buildConnectedSection];
    [self buildFooter];
}

#pragma mark - 顶部状态卡

- (void)buildStatusCard {
    self.statusCard = [[UIView alloc] init];
    self.statusCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.statusCard.layer.cornerRadius = kCardCornerRadius;
    self.statusCard.layer.masksToBounds = YES;

    self.statusIcon = [[UIImageView alloc] init];
    self.statusIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.statusIcon.tintColor = [UIColor secondaryLabelColor];

    self.statusSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.statusSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusSpinner.hidesWhenStopped = YES;

    // 图标/菊花二选一，用容器叠放以保持左列宽度稳定。
    UIView *iconBox = [[UIView alloc] init];
    iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    [iconBox addSubview:self.statusIcon];
    [iconBox addSubview:self.statusSpinner];
    [NSLayoutConstraint activateConstraints:@[
        [iconBox.widthAnchor constraintEqualToConstant:28],
        [iconBox.heightAnchor constraintEqualToConstant:28],
        [self.statusIcon.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor],
        [self.statusIcon.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
        [self.statusIcon.widthAnchor constraintEqualToConstant:24],
        [self.statusIcon.heightAnchor constraintEqualToConstant:24],
        [self.statusSpinner.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor],
        [self.statusSpinner.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
    ]];

    self.statusTitleLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]
                                          textColor:[UIColor labelColor]];
    self.statusDetailLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:13]
                                           textColor:[UIColor secondaryLabelColor]];
    self.statusDetailLabel.numberOfLines = 0;

    self.portLabel = [self makeLabelWithFont:[UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular]
                                   textColor:[UIColor tertiaryLabelColor]];
    self.portLabel.hidden = YES;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.statusTitleLabel, self.statusDetailLabel, self.portLabel,
    ]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 4;
    textStack.alignment = UIStackViewAlignmentFill;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[iconBox, textStack]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentTop;
    [self.statusCard addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor      constraintEqualToAnchor:self.statusCard.topAnchor      constant:kCardPadding],
        [row.bottomAnchor   constraintEqualToAnchor:self.statusCard.bottomAnchor   constant:-kCardPadding],
        [row.leadingAnchor  constraintEqualToAnchor:self.statusCard.leadingAnchor  constant:kCardPadding],
        [row.trailingAnchor constraintEqualToAnchor:self.statusCard.trailingAnchor constant:-kCardPadding],
    ]];

    [self.rootStack addArrangedSubview:self.statusCard];
}

#pragma mark - 未连接：两张入口卡片（ZL2 WaitingUI）

- (void)buildEntryCards {
    self.hostCard  = [self makeCardButtonWithIcon:@"house.fill"
                                            title:localize(@"i18n_str_1008", nil)
                                      description:localize(@"terracotta_host_desc", nil)
                                           action:@selector(hostCardTapped)];
    self.guestCard = [self makeCardButtonWithIcon:@"person.2.fill"
                                            title:localize(@"i18n_str_1009", nil)
                                      description:localize(@"terracotta_guest_desc", nil)
                                           action:@selector(guestCardTapped)];

    self.entryStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.hostCard, self.guestCard]];
    self.entryStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.entryStack.axis = UILayoutConstraintAxisVertical;
    self.entryStack.spacing = 12;
    self.entryStack.alignment = UIStackViewAlignmentFill;
    [self.rootStack addArrangedSubview:self.entryStack];
}

#pragma mark - 创建房间表单

- (void)buildCreateForm {
    UILabel *hint = [self makeSectionHintLabel:localize(@"terracotta_port_hint", nil)];

    self.portField = [self makeTextFieldWithPlaceholder:localize(@"terracotta_port_placeholder", nil)];
    self.portField.keyboardType = UIKeyboardTypeNumberPad;
    self.portField.textAlignment = NSTextAlignmentCenter;

    self.portHintLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:12]
                                       textColor:[UIColor tertiaryLabelColor]];
    self.portHintLabel.textAlignment = NSTextAlignmentCenter;

    UIButton *autoButton = [self makeSecondaryButtonWithTitle:localize(@"terracotta_port_auto", nil)
                                                      action:@selector(autoDetectPortTapped)];
    UIButton *startButton = [self makePrimaryButtonWithTitle:localize(@"terracotta_create_start", nil)
                                                     action:@selector(createRoomTapped)];

    self.createFormStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        hint, self.portField, self.portHintLabel, autoButton, startButton,
    ]];
    self.createFormStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.createFormStack.axis = UILayoutConstraintAxisVertical;
    self.createFormStack.spacing = 10;
    self.createFormStack.alignment = UIStackViewAlignmentFill;
    [self.rootStack addArrangedSubview:self.createFormStack];
}

#pragma mark - 加入房间表单

- (void)buildJoinForm {
    UILabel *hint = [self makeSectionHintLabel:localize(@"terracotta_join_hint", nil)];

    self.codeField = [self makeTextFieldWithPlaceholder:localize(@"terracotta_code_placeholder", nil)];
    self.codeField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.codeField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.codeField.textAlignment = NSTextAlignmentCenter;
    self.codeField.delegate = self;
    self.codeField.returnKeyType = UIReturnKeyJoin;

    UIButton *pasteButton = [self makeSecondaryButtonWithTitle:localize(@"terracotta_paste", nil)
                                                       action:@selector(pasteCodeTapped)];
    UIButton *joinButton = [self makePrimaryButtonWithTitle:localize(@"terracotta_join_start", nil)
                                                    action:@selector(joinRoomTapped)];

    self.joinFormStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        hint, self.codeField, pasteButton, joinButton,
    ]];
    self.joinFormStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.joinFormStack.axis = UILayoutConstraintAxisVertical;
    self.joinFormStack.spacing = 10;
    self.joinFormStack.alignment = UIStackViewAlignmentFill;
    [self.rootStack addArrangedSubview:self.joinFormStack];
}

#pragma mark - 已连接：房间码 + 操作 + 玩家列表

- (void)buildConnectedSection {
    self.roomCodeLabel = [self makeLabelWithFont:[UIFont monospacedSystemFontOfSize:20 weight:UIFontWeightSemibold]
                                       textColor:[UIColor labelColor]];
    self.roomCodeLabel.textAlignment = NSTextAlignmentCenter;
    self.roomCodeLabel.numberOfLines = 0;

    UILabel *codeCaption = [self makeLabelWithFont:[UIFont systemFontOfSize:12]
                                         textColor:[UIColor secondaryLabelColor]];
    codeCaption.text = localize(@"terracotta_room_code", nil);
    codeCaption.textAlignment = NSTextAlignmentCenter;

    self.directURLLabel = [self makeLabelWithFont:[UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular]
                                        textColor:[UIColor secondaryLabelColor]];
    self.directURLLabel.textAlignment = NSTextAlignmentCenter;
    self.directURLLabel.numberOfLines = 0;
    self.directURLLabel.hidden = YES;

    self.roomCodeCopyButton = [self makeSecondaryButtonWithTitle:localize(@"terracotta_copy_code", nil)
                                                       action:@selector(copyRoomCodeTapped)];
    self.roomCodeCopyButton.hidden = YES;   // 由 refreshUI 按角色决定是否显示
    self.roomCodeCaptionLabel = codeCaption;
    self.roomCodeLabel.hidden = YES;
    codeCaption.hidden = YES;

    self.directURLCopyButton = [self makeSecondaryButtonWithTitle:localize(@"terracotta_copy_url", nil)
                                                     action:@selector(copyDirectURLTapped)];
    self.directURLCopyButton.hidden = YES;

    // 玩家列表（标题 + 动态行）
    UILabel *playersTitle = [self makeLabelWithFont:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium]
                                          textColor:[UIColor secondaryLabelColor]];
    playersTitle.text = localize(@"terracotta_player_list", nil);

    self.playerListStack = [[UIStackView alloc] init];
    self.playerListStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.playerListStack.axis = UILayoutConstraintAxisVertical;
    self.playerListStack.spacing = 8;
    self.playerListStack.alignment = UIStackViewAlignmentFill;

    self.connectedStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        codeCaption, self.roomCodeLabel, self.directURLLabel,
        self.roomCodeCopyButton, self.directURLCopyButton, playersTitle, self.playerListStack,
    ]];
    self.connectedStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.connectedStack.axis = UILayoutConstraintAxisVertical;
    self.connectedStack.spacing = 10;
    self.connectedStack.alignment = UIStackViewAlignmentFill;
    [self.rootStack addArrangedSubview:self.connectedStack];
}

#pragma mark - 底部

- (void)buildFooter {
    self.footerLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:11]
                                     textColor:[UIColor tertiaryLabelColor]];
    self.footerLabel.numberOfLines = 0;

    self.logButton = [self makeFooterButtonWithTitle:localize(@"terracotta_log", nil)
                                              action:@selector(logTapped)];
    self.actionButton = [self makeFooterButtonWithTitle:localize(@"terracotta_back", nil)
                                                 action:@selector(backTapped)];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.logButton, self.actionButton]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 16;
    buttons.alignment = UIStackViewAlignmentCenter;

    UIView *spacer = [[UIView alloc] init];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *footer = [[UIStackView alloc] initWithArrangedSubviews:@[self.footerLabel, spacer, buttons]];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    footer.axis = UILayoutConstraintAxisHorizontal;
    footer.spacing = 8;
    footer.alignment = UIStackViewAlignmentCenter;
    [self.rootStack addArrangedSubview:footer];
}

#pragma mark - 状态刷新（界面切换的唯一入口）

- (void)registerNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(stateDidChange)
                                                 name:TerracottaManagerStateDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundEffectChanged)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)backgroundEffectChanged {
    [self refreshUI];
}

- (void)stateDidChange {
    // 通知可能来自任意线程（Rust 轮询线程），UI 更新收敛到主线程。
    if ([NSThread isMainThread]) {
        [self refreshUI];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshUI]; });
    }
}

- (void)refreshUI {
    TerracottaManager *mgr = [TerracottaManager shared];
    TerracottaStatus status = mgr.status;

    // 顶部状态卡
    self.statusTitleLabel.text = [self statusTitleForStatus:status role:mgr.role];
    self.statusDetailLabel.text = mgr.stageDescription ?: [self statusDetailForStatus:status];

    BOOL busy = (status == TerracottaStatusConnecting);
    if (busy) {
        self.statusIcon.hidden = YES;
        [self.statusSpinner startAnimating];
    } else {
        [self.statusSpinner stopAnimating];
        self.statusIcon.hidden = NO;
        self.statusIcon.image = [UIImage systemImageNamed:[self statusIconNameForStatus:status]];
        self.statusIcon.tintColor = [self statusColorForStatus:status];
    }

    if (mgr.currentPort > 0) {
        self.portLabel.hidden = NO;
        self.portLabel.text = [NSString stringWithFormat:localize(@"terracotta_port_fmt", nil),
                               (unsigned)mgr.currentPort];
    } else {
        self.portLabel.hidden = YES;
    }

    // 分区块可见性：同一时刻只呈现一种状态对应的内容
    BOOL showEntries   = (status == TerracottaStatusDisconnected);
    BOOL showConnected = (status == TerracottaStatusConnected);
    BOOL showError     = (status == TerracottaStatusError);

    // 未连接时进一步区分：是否已展开某个表单
    BOOL showCreate = showEntries && self.isHostRole;
    BOOL showJoin   = showEntries && !self.isHostRole;

    self.entryStack.hidden     = !(showEntries && self.manualPort == 0 && !self.hasExpandedForm);
    self.createFormStack.hidden = !showCreate;
    self.joinFormStack.hidden   = !showJoin;
    self.connectedStack.hidden  = !showConnected;

    // 已连接：房间码与玩家列表
    if (showConnected) {
        BOOL isHost = (mgr.role == TerracottaRoleHost);
        NSString *code = mgr.currentInviteCode;
        self.roomCodeLabel.hidden = (code.length == 0);
        self.roomCodeLabel.text = code ?: @"";
        // 用属性引用而不是 arrangedSubviews 下标，避免布局调整后错位。
        self.roomCodeCaptionLabel.hidden = !isHost || code.length == 0;
        self.roomCodeCopyButton.hidden = !isHost || code.length == 0;
        self.directURLLabel.hidden = isHost || mgr.directConnectURL.length == 0;
        self.directURLLabel.text = mgr.directConnectURL ?: @"";
        self.directURLCopyButton.hidden = isHost || mgr.directConnectURL.length == 0;
        [self refreshPlayerList];
    }

    // 错误态：借用状态卡呈现，并给出重试入口
    if (showError) {
        self.statusDetailLabel.text = mgr.lastError ?: localize(@"terracotta_error_unknown", nil);
    }

    // 底部
    self.footerLabel.text = [self footerTextForStatus:status];
    [self.actionButton setTitle:[self actionTitleForStatus:status] forState:UIControlStateNormal];
    self.actionButton.hidden = (status == TerracottaStatusDisconnected && !self.hasExpandedForm);

    [self.view setNeedsLayout];
}

- (BOOL)hasExpandedForm {
    return self.createFormStack.hidden == NO || self.joinFormStack.hidden == NO;
}

#pragma mark - 玩家列表

- (void)refreshPlayerList {
    for (UIView *v in self.playerListStack.arrangedSubviews) {
        [self.playerListStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSArray<TerracottaPlayerProfile *> *players = [TerracottaManager shared].players;
    if (players.count == 0) {
        UILabel *empty = [self makeLabelWithFont:[UIFont systemFontOfSize:13]
                                       textColor:[UIColor tertiaryLabelColor]];
        empty.text = localize(@"terracotta_no_players", nil);
        [self.playerListStack addArrangedSubview:empty];
        return;
    }
    NSInteger selfIndex = [TerracottaManager shared].currentProfileIndex;
    for (NSUInteger i = 0; i < players.count; i++) {
        [self.playerListStack addArrangedSubview:[self makePlayerRow:players[i] isSelf:(i == (NSUInteger)selfIndex)]];
    }
}

- (UIView *)makePlayerRow:(TerracottaPlayerProfile *)profile isSelf:(BOOL)isSelf {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    row.layer.cornerRadius = 10;
    row.layer.masksToBounds = YES;

    UILabel *name = [self makeLabelWithFont:[UIFont systemFontOfSize:14 weight:isSelf ? UIFontWeightSemibold : UIFontWeightRegular]
                                  textColor:[UIColor labelColor]];
    name.text = profile.name ?: @"?";
    name.numberOfLines = 1;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[name]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 8;
    stack.alignment = UIStackViewAlignmentCenter;
    [row addSubview:stack];

    if (isSelf) {
        UILabel *tag = [self makeLabelWithFont:[UIFont systemFontOfSize:11 weight:UIFontWeightMedium]
                                     textColor:[UIColor systemBlueColor]];
        tag.text = localize(@"terracotta_self_tag", nil);
        [stack addArrangedSubview:tag];
    }

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor      constraintEqualToAnchor:row.topAnchor      constant:10],
        [stack.bottomAnchor   constraintEqualToAnchor:row.bottomAnchor   constant:-10],
        [stack.leadingAnchor  constraintEqualToAnchor:row.leadingAnchor  constant:12],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor constant:-12],
    ]];
    return row;
}

#pragma mark - 动作

- (void)hostCardTapped {
    self.isHostRole = YES;
    self.entryStack.hidden = YES;
    self.createFormStack.hidden = NO;
    self.joinFormStack.hidden = YES;
    [self startPortAutoDetection];
    self.actionButton.hidden = NO;
    [self refreshUI];
}

- (void)guestCardTapped {
    self.isHostRole = NO;
    self.entryStack.hidden = YES;
    self.createFormStack.hidden = YES;
    self.joinFormStack.hidden = NO;
    self.actionButton.hidden = NO;
    [self refreshUI];
}

- (void)autoDetectPortTapped {
    [self startPortAutoDetection];
}

- (void)createRoomTapped {
    uint16_t port = self.manualPort;
    if (port == 0) {
        NSString *text = self.portField.text;
        NSInteger parsed = text.integerValue;
        if (parsed >= 1024 && parsed <= 65535) port = (uint16_t)parsed;
    }
    if (port == 0) {
        [self showToast:localize(@"terracotta_port_invalid", nil)];
        return;
    }
    [[TerracottaManager shared] createRoomWithPort:port inviteCode:nil playerName:self.resolvedPlayerName];
    [self refreshUI];
}

- (void)joinRoomTapped {
    NSString *code = [self.codeField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (code.length == 0) {
        [self showToast:localize(@"terracotta_code_empty", nil)];
        return;
    }
    if (![[TerracottaManager shared] joinRoomWithInviteCode:code playerName:self.resolvedPlayerName]) {
        [self showToast:localize(@"terracotta_code_invalid", nil)];
        return;
    }
    [self refreshUI];
}

- (void)pasteCodeTapped {
    NSString *clip = UIPasteboard.generalPasteboard.string;
    if (clip.length == 0) {
        [self showToast:localize(@"terracotta_clipboard_empty", nil)];
        return;
    }
    self.codeField.text = [clip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)copyRoomCodeTapped {
    NSString *code = [TerracottaManager shared].currentInviteCode;
    if (code.length == 0) return;
    UIPasteboard.generalPasteboard.string = code;
    [self showToast:localize(@"terracotta_copied", nil)];
}

- (void)copyDirectURLTapped {
    NSString *url = [TerracottaManager shared].directConnectURL;
    if (url.length == 0) return;
    UIPasteboard.generalPasteboard.string = url;
    [self showToast:localize(@"terracotta_copied", nil)];
}

- (void)logTapped {
    // 联机日志由 TerracottaBridge 落到沙盒；这里直接展示最近若干行，
    // 方便用户自查（ZL2 同样提供日志入口）。
    [self presentLogViewer];
}

- (void)backTapped {
    TerracottaStatus status = [TerracottaManager shared].status;
    if (status == TerracottaStatusDisconnected) {
        // 回到入口卡片
        self.isHostRole = NO;
        self.manualPort = 0;
        self.entryStack.hidden = NO;
        self.createFormStack.hidden = YES;
        self.joinFormStack.hidden = YES;
        self.actionButton.hidden = YES;
        [self stopPortAutoDetection];
        [self refreshUI];
        return;
    }
    if (status == TerracottaStatusConnecting || status == TerracottaStatusConnected) {
        [[TerracottaManager shared] stopSession];
    }
    [self close];
}

- (void)close {
    if (self.navigationController) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (NSString *)resolvedPlayerName {
    return self.playerName ?: [self currentPlayerName];
}

- (NSString *)currentPlayerName {
    NSString *name = getPrefObject(@"internal.last_username");
    if ([name isKindOfClass:[NSString class]] && name.length > 0) return name;
    return @"Player";
}

#pragma mark - 端口自动检测

- (void)startPortAutoDetection {
    // McLanPortDetector 的真实接口是「按游戏目录轮询」：
    //   startPollingGameDirectory:launcherHome:handler:
    // MC 的局域网端口由游戏自己随机开，启动器只能从日志里读出来，
    // 因此这里是 1s 轮询而不是一次性探测。离开页面或会话开始时停掉。
    [self stopPortAutoDetection];

    NSString *instance = getPrefObject(@"general.game_directory");
    if (![instance isKindOfClass:[NSString class]] || instance.length == 0) instance = nil;
    NSString *gameDir = [McLanPortDetector resolveGameDirectoryWithInstanceName:instance];
    NSString *home = [McLanPortDetector launcherHome];

    self.portDetector = [[McLanPortDetector alloc] init];
    self.portHintLabel.text = localize(@"i18n_str_1002", nil);

    __weak typeof(self) weakSelf = self;
    [self.portDetector startPollingGameDirectory:gameDir
                                    launcherHome:home
                                         handler:^(uint16_t port) {
        typeof(self) self_ = weakSelf;
        if (!self_ || port == 0) return;
        // handler 已在主线程回调。
        self_.manualPort = port;
        self_.portAutoDetected = YES;
        self_.portField.text = [NSString stringWithFormat:@"%u", (unsigned)port];
        self_.portHintLabel.text = [NSString stringWithFormat:
            localize(@"terracotta_port_detected", nil), (unsigned)port];
    }];
}

- (void)stopPortAutoDetection {
    [self.portDetector stopPolling];
    self.portDetector = nil;
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.codeField) {
        [self joinRoomTapped];
    } else {
        [textField resignFirstResponder];
    }
    return YES;
}

#pragma mark - 文案与图标

- (NSString *)statusTitleForStatus:(TerracottaStatus)status role:(TerracottaRole)role {
    switch (status) {
    case TerracottaStatusDisconnected:
        return localize(@"terracotta_status_idle", nil);
    case TerracottaStatusConnecting:
        return (role == TerracottaRoleHost)
            ? localize(@"i18n_str_1003", nil)
            : localize(@"i18n_str_1000", nil);
    case TerracottaStatusConnected:
        return (role == TerracottaRoleHost)
            ? localize(@"i18n_str_1004", nil)
            : localize(@"i18n_str_1006", nil);
    case TerracottaStatusError:
        return localize(@"terracotta_status_error", nil);
    }
    return @"";
}

- (NSString *)statusDetailForStatus:(TerracottaStatus)status {
    switch (status) {
    case TerracottaStatusDisconnected:
        return localize(@"terracotta_status_idle_desc", nil);
    case TerracottaStatusConnecting:
        return localize(@"terracotta_status_connecting_desc", nil);
    case TerracottaStatusConnected:
        return localize(@"terracotta_status_ok_desc", nil);
    case TerracottaStatusError:
        return localize(@"terracotta_status_error_desc", nil);
    }
    return @"";
}

- (NSString *)statusIconNameForStatus:(TerracottaStatus)status {
    switch (status) {
    case TerracottaStatusDisconnected: return @"network.slash";
    case TerracottaStatusConnecting:   return @"arrow.triangle.2.circlepath";
    case TerracottaStatusConnected:    return @"checkmark.circle.fill";
    case TerracottaStatusError:        return @"exclamationmark.triangle.fill";
    }
    return @"network";
}

- (UIColor *)statusColorForStatus:(TerracottaStatus)status {
    switch (status) {
    case TerracottaStatusConnected: return [UIColor systemGreenColor];
    case TerracottaStatusError:     return [UIColor systemRedColor];
    case TerracottaStatusConnecting:return [UIColor systemOrangeColor];
    default: return [UIColor secondaryLabelColor];
    }
}

- (NSString *)actionTitleForStatus:(TerracottaStatus)status {
    switch (status) {
    case TerracottaStatusDisconnected: return localize(@"terracotta_back", nil);
    case TerracottaStatusConnecting:   return localize(@"terracotta_cancel", nil);
    case TerracottaStatusConnected:    return localize(@"terracotta_exit", nil);
    case TerracottaStatusError:        return localize(@"terracotta_retry", nil);
    }
    return localize(@"terracotta_back", nil);
}

- (NSString *)footerTextForStatus:(TerracottaStatus)status {
    TerracottaManager *mgr = [TerracottaManager shared];
    if (status == TerracottaStatusConnected) {
        return [NSString stringWithFormat:localize(@"terracotta_footer_connected", nil),
                (unsigned long)mgr.players.count];
    }
    if (status == TerracottaStatusConnecting) {
        return localize(@"terracotta_footer_connecting", nil);
    }
    return localize(@"terracotta_footer_idle", nil);
}

#pragma mark - 日志查看

- (void)presentLogViewer {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"terracotta_log", nil)
                         message:[self recentLogText]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"generic_ok", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"terracotta_copy_log", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = [self recentLogText];
        [self showToast:localize(@"terracotta_copied", nil)];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)recentLogText {
    // TerracottaBridge 把 Rust 侧日志写到沙盒 Documents 下的固定文件；
    // 读取末尾若干行即可满足自助排查。
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = paths.firstObject;
    NSString *candidates[] = { @"terracotta.log", @"terracotta/terracotta.log" };
    for (unsigned i = 0; i < 2; i++) {
        NSString *path = [doc stringByAppendingPathComponent:candidates[i]];
        NSString *content = [NSString stringWithContentsOfFile:path
                                                      encoding:NSUTF8StringEncoding
                                                         error:NULL];
        if (content.length > 0) {
            NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
            NSUInteger tail = MIN((NSUInteger)40, lines.count);
            return [[lines subarrayWithRange:NSMakeRange(lines.count - tail, tail)]
                    componentsJoinedByString:@"\n"];
        }
    }
    return localize(@"terracotta_log_empty", nil);
}

#pragma mark - Toast

- (void)showToast:(NSString *)text {
    if (text.length == 0) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                  message:text
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

#pragma mark - 控件工厂

- (UILabel *)makeLabelWithFont:(UIFont *)font textColor:(UIColor *)color {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = font;
    l.textColor = color;
    return l;
}

- (UILabel *)makeSectionHintLabel:(NSString *)text {
    UILabel *l = [self makeLabelWithFont:[UIFont systemFontOfSize:12]
                               textColor:[UIColor secondaryLabelColor]];
    l.text = text;
    l.numberOfLines = 0;
    return l;
}

- (UITextField *)makeTextFieldWithPlaceholder:(NSString *)placeholder {
    UITextField *f = [[UITextField alloc] init];
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.placeholder = placeholder;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    return f;
}

- (UIButton *)makePrimaryButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.backgroundColor = [UIColor systemBlueColor];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.layer.cornerRadius = 12;
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)makeSecondaryButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor tertiarySystemFillColor];
    [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    b.layer.cornerRadius = 12;
    [b.heightAnchor constraintEqualToConstant:40].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)makeFooterButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

/// 入口大卡片：图标 + 标题 + 描述（ZL2 SimpleCardButton 的形态）。
- (UIControl *)makeCardButtonWithIcon:(NSString *)iconName
                                title:(NSString *)title
                          description:(NSString *)desc
                               action:(SEL)action {
    UIControl *card = [[UIControl alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = kCardCornerRadius;
    card.layer.masksToBounds = YES;
    [card addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:iconName]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = [UIColor systemBlueColor];
    icon.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *titleLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]
                                        textColor:[UIColor labelColor]];
    titleLabel.text = title;

    UILabel *descLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:13]
                                       textColor:[UIColor secondaryLabelColor]];
    descLabel.text = desc;
    descLabel.numberOfLines = 0;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, descLabel]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;
    textStack.alignment = UIStackViewAlignmentFill;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, textStack]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    [card addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor  constraintEqualToConstant:28],
        [icon.heightAnchor constraintEqualToConstant:28],
        [row.topAnchor      constraintEqualToAnchor:card.topAnchor      constant:kCardPadding],
        [row.bottomAnchor   constraintEqualToAnchor:card.bottomAnchor   constant:-kCardPadding],
        [row.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor  constant:kCardPadding],
        [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-kCardPadding],
    ]];
    return card;
}

@end
