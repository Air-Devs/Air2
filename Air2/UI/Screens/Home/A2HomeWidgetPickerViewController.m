//
//  A2HomeWidgetPickerViewController.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  加卡 / 换目标面板实现。见头文件说明。
//

#import "A2HomeWidgetPickerViewController.h"

#import "A2HomeLayout.h"
#import "A2HomeRuntime.h"
#import "A2InputDialog.h"
#import "A2Log.h"
#import "A2OptionSheet.h"
#import "A2SettingsRow.h"
#import "A2SettingsSection.h"
#import "A2Toast.h"
#import "A2VersionManager.h"

/// 图标的中文名（只用于选择表；出现的一定是 A2HomeCustomSymbolChoices() 的成员）。
static NSString *A2HomeCustomSymbolTitle(NSString *symbol) {
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{@"link": @"链接",
                  @"arrow.down.circle.fill": @"下载",
                  @"cube.fill": @"方块",
                  @"person.crop.circle.fill": @"账户",
                  @"network": @"联机",
                  @"folder.fill": @"文件夹",
                  @"gearshape.fill": @"设置",
                  @"globe": @"地球",
                  @"star.fill": @"星标",
                  @"book.fill": @"书",
                  @"gamecontroller.fill": @"手柄",
                  @"map.fill": @"地图"};
    });
    return names[symbol] ?: symbol;
}

@interface A2HomeWidgetPickerViewController ()

@property (nonatomic, strong) A2HomeProfile *profile;
@property (nonatomic, copy, nullable) NSString *replacingCardID;
/// 自定义卡片编辑页的草稿卡（改标题/图标/跳转都改它，最后一步才交给主页）。
@property (nonatomic, strong, nullable) A2HomeCard *customDraftCard;

- (void)clearContent;
- (void)rebuildCatalog;
- (void)selectKind:(A2HomeCardKind)kind;
- (void)showVersionListForKind:(A2HomeCardKind)kind;
- (void)showWorldListForKind:(A2HomeCardKind)kind version:(A2Version *)version;
- (void)promptServerAddress;
- (void)finishWithCard:(A2HomeCard *)card;
- (A2HomeCard *)newCardForKind:(A2HomeCardKind)kind;
- (BOOL)isKindAlreadyAdded:(A2HomeCardKind)kind;
- (A2SettingsRow *)backRowWithTitle:(NSString *)title;

/// ---- 自定义卡片（图标 / 标题 / 跳转目标）----
- (void)showCustomEditorStartingFromCard:(A2HomeCard *)card;
- (void)rebuildCustomEditor;
- (void)editCustomTitle;
- (void)editCustomSymbol;
- (void)editCustomJump;
- (void)promptCustomURL;
- (void)commitCustomDraft;
- (A2SettingsRow *)customRowWithSymbol:(NSString *)symbol
                                title:(NSString *)title
                             subtitle:(nullable NSString *)subtitle
                            valueText:(nullable NSString *)valueText
                           disclosure:(BOOL)disclosure
                                onTap:(void (^)(void))onTap;

@end

@implementation A2HomeWidgetPickerViewController

- (instancetype)initWithProfile:(A2HomeProfile *)profile
                replacingCardID:(nullable NSString *)replacingCardID {
    self = [super init];
    if (!self) return nil;
    _profile = profile;
    _replacingCardID = [replacingCardID copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = self.replacingCardID.length ? @"更换目标" : @"添加卡片";
    // 作为 M3 bottom sheet 呈现时没有导航栈，顶栏返回键要变成「关闭」。
    if (self.navigationController == nil) {
        __weak typeof(self) weakSelf = self;
        self.onBack = ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self dismissViewControllerAnimated:YES completion:nil];
        };
    }
    [self rebuildCatalog];
}

#pragma mark - 目录

- (void)clearContent {
    for (UIView *view in self.contentStack.arrangedSubviews.copy) {
        [view removeFromSuperview];
    }
}

- (BOOL)isKindAlreadyAdded:(A2HomeCardKind)kind {
    if (!A2HomeKindIsSingleton(kind)) return NO;
    // 正在换目标的那张卡不算「已添加」（否则换了以后仍然禁用）。
    if (self.replacingCardID.length) {
        A2HomeCard *existing = [self.profile cardWithID:self.replacingCardID];
        if (existing && existing.kind == kind) return NO;
    }
    return [self.profile containsKind:kind];
}

- (void)rebuildCatalog {
    [self clearContent];

    NSArray<NSArray<NSNumber *> *> *groups = @[
        @[@(A2HomeCardKindGreeting), @(A2HomeCardKindRecent), @(A2HomeCardKindCalendar)],
        @[@(A2HomeCardKindPinnedVersions), @(A2HomeCardKindPinnedWorlds), @(A2HomeCardKindPinnedServers)],
        @[@(A2HomeCardKindShortcutVersion), @(A2HomeCardKindShortcutWorld), @(A2HomeCardKindShortcutServer)],
        @[@(A2HomeCardKindShortcutCustom)],
    ];
    NSArray<NSString *> *titles = @[@"总览", @"收藏集", @"单项快捷", @"自定义"];

    __weak typeof(self) weakSelf = self;
    for (NSUInteger g = 0; g < groups.count; g++) {
        A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:titles[g]];
        for (NSNumber *number in groups[g]) {
            A2HomeCardKind kind = (A2HomeCardKind)number.integerValue;
            A2SettingsRow *row = [[A2SettingsRow alloc] init];
            row.symbolName = A2HomeKindSymbolName(kind);
            row.title = A2HomeKindDisplayName(kind);
            row.subtitle = A2HomeKindSummary(kind);
            if (!A2HomeKindIsAvailable(kind)) {
                row.valueText = @"暂不可用";
                row.enabled = NO;
            } else if ([self isKindAlreadyAdded:kind]) {
                row.valueText = @"已添加";
                row.enabled = NO;
            } else if (A2HomeKindRequiresTarget(kind)) {
                row.accessory = A2SettingsRowAccessoryDisclosure;
            }
            row.onTap = ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;
                [self selectKind:kind];
            };
            [row applyTheme];
            [section addRow:row];
        }
        [self addSection:section];
    }
}

#pragma mark - 选类型

- (void)selectKind:(A2HomeCardKind)kind {
    if (kind == A2HomeCardKindShortcutCustom) {
        // 自定义卡片没有「选中即完成」的一步：先进编辑页填标题 / 图标 / 跳转。
        [self showCustomEditorStartingFromCard:[self newCardForKind:kind]];
        return;
    }
    if (kind == A2HomeCardKindShortcutServer) {
        [self promptServerAddress];
        return;
    }
    if (A2HomeKindRequiresTarget(kind)) {
        [self showVersionListForKind:kind];
        return;
    }
    [self finishWithCard:[self newCardForKind:kind]];
}

- (A2HomeCard *)newCardForKind:(A2HomeCardKind)kind {
    A2HomeCard *card = [A2HomeCard cardWithKind:kind];
    if (self.replacingCardID.length == 0) return card;

    // 换目标：id / 尺寸 / 坐标全保留，换目标不该让卡片跳位置。
    A2HomeCard *existing = [self.profile cardWithID:self.replacingCardID];
    if (!existing) return card;
    card.cardID = existing.cardID;
    card.size = existing.size;
    card.hasPosition = existing.hasPosition;
    card.column = existing.column;
    card.row = existing.row;
    if (existing.kind == kind) card.options = [existing.options copy];
    return card;
}

#pragma mark - 下钻：选版本

- (A2SettingsRow *)backRowWithTitle:(NSString *)title {
    __weak typeof(self) weakSelf = self;
    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = @"chevron.left";
    row.title = title;
    row.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self rebuildCatalog];
    };
    [row applyTheme];
    return row;
}

- (void)showVersionListForKind:(A2HomeCardKind)kind {
    [self clearContent];

    A2SettingsSection *head = [[A2SettingsSection alloc] initWithTitle:nil];
    [head addRow:[self backRowWithTitle:@"选择版本"]];
    [self addSection:head];

    NSArray<A2Version *> *versions = A2VersionManager.shared.versions ?: @[];
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:nil];
    if (versions.count == 0) {
        A2SettingsRow *empty = [[A2SettingsRow alloc] init];
        empty.title = @"还没有安装版本";
        empty.subtitle = @"先在版本页装一个版本再回来布置主页";
        empty.enabled = NO;
        [empty applyTheme];
        [section addRow:empty];
        [self addSection:section];
        return;
    }

    __weak typeof(self) weakSelf = self;
    for (A2Version *version in versions) {
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = @"cube.fill";
        row.title = version.name;
        row.subtitle = version.loaderInfo.length ? version.loaderInfo : @"原版";
        row.accessory = (kind == A2HomeCardKindShortcutWorld) ? A2SettingsRowAccessoryDisclosure
                                                              : A2SettingsRowAccessoryNone;
        row.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (kind == A2HomeCardKindShortcutWorld) {
                [self showWorldListForKind:kind version:version];
                return;
            }
            A2HomeCard *card = [self newCardForKind:kind];
            card.target = [A2HomeCardTarget targetWithGameHome:version.gameHome
                                                   versionName:version.name
                                                     worldPath:nil
                                                       address:nil
                                                 fallbackLabel:version.name];
            [self finishWithCard:card];
        };
        [row applyTheme];
        [section addRow:row];
    }
    [self addSection:section];
}

#pragma mark - 下钻：选存档

- (void)showWorldListForKind:(A2HomeCardKind)kind version:(A2Version *)version {
    [self clearContent];

    A2SettingsSection *head = [[A2SettingsSection alloc] initWithTitle:nil];
    [head addRow:[self backRowWithTitle:[NSString stringWithFormat:@"选择存档 · %@", version.name]]];
    [self addSection:head];

    NSError *error = nil;
    NSArray<NSDictionary<NSString *, id> *> *worlds = [A2HomeRuntime.shared worldsForVersion:version error:&error];
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:nil];
    if (worlds.count == 0) {
        A2SettingsRow *empty = [[A2SettingsRow alloc] init];
        empty.title = @"这个版本还没有存档";
        empty.subtitle = @"进游戏存一次档之后再来";
        empty.enabled = NO;
        [empty applyTheme];
        [section addRow:empty];
        [self addSection:section];
        return;
    }

    __weak typeof(self) weakSelf = self;
    for (NSDictionary<NSString *, id> *world in worlds) {
        NSString *name = [world[@"name"] isKindOfClass:NSString.class] ? world[@"name"] : @"存档";
        NSString *path = [world[@"path"] isKindOfClass:NSString.class] ? world[@"path"] : @"";
        A2SettingsRow *row = [[A2SettingsRow alloc] init];
        row.symbolName = @"map.fill";
        row.title = name;
        row.subtitle = path;
        row.onTap = ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            A2HomeCard *card = [self newCardForKind:kind];
            card.target = [A2HomeCardTarget targetWithGameHome:version.gameHome
                                                   versionName:version.name
                                                     worldPath:path
                                                       address:nil
                                                 fallbackLabel:name];
            [self finishWithCard:card];
        };
        [row applyTheme];
        [section addRow:row];
    }
    [self addSection:section];
}

#pragma mark - 服务器地址

- (void)promptServerAddress {
    A2Version *version = A2VersionManager.shared.currentVersion;
    if (!version) {
        [A2Toast show:@"先选一个版本，服务器快捷卡会用它来启动" inView:self.view];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [A2InputDialog presentFrom:self
                         title:@"服务器地址"
                         label:@"地址（例如 play.example.com 或 host:25566）"
                   initialText:nil
                      onFinish:^(BOOL committed, NSString *text) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !committed) return;
        NSString *normalized = A2HomeNormalizedServerAddress(text);
        if (normalized.length == 0) {
            [A2Toast show:@"地址不能为空" inView:self.view];
            return;
        }
        A2HomeCard *card = [self newCardForKind:A2HomeCardKindShortcutServer];
        card.target = [A2HomeCardTarget targetWithGameHome:version.gameHome
                                               versionName:version.name
                                                 worldPath:nil
                                                   address:normalized
                                             fallbackLabel:normalized];
        [self finishWithCard:card];
    }];
}

#pragma mark - 自定义卡片（标题 / 图标 / 跳转目标）

- (A2SettingsRow *)customRowWithSymbol:(NSString *)symbol
                                title:(NSString *)title
                             subtitle:(nullable NSString *)subtitle
                            valueText:(nullable NSString *)valueText
                           disclosure:(BOOL)disclosure
                                onTap:(void (^)(void))onTap {
    __weak typeof(self) weakSelf = self;
    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = symbol;
    row.title = title;
    row.subtitle = subtitle;
    row.valueText = valueText;
    if (disclosure) row.accessory = A2SettingsRowAccessoryDisclosure;
    row.onTap = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (onTap) onTap();
    };
    [row applyTheme];
    return row;
}

- (void)showCustomEditorStartingFromCard:(A2HomeCard *)card {
    if (!card) return;
    self.customDraftCard = card;
    [self rebuildCustomEditor];
}

/// 编辑页每次改动都整页重建：行内容（标题/图标/目标）全靠草案卡算出来，
/// 局部刷新反而要维护三处状态。
- (void)rebuildCustomEditor {
    A2HomeCard *card = self.customDraftCard;
    if (!card) return;
    [self clearContent];

    A2HomeCardOptions *options = card.options;
    BOOL isURL = (options.jumpKind == A2HomeJumpKindURL);
    __weak typeof(self) weakSelf = self;

    A2SettingsSection *head = [[A2SettingsSection alloc] initWithTitle:nil];
    [head addRow:[self backRowWithTitle:@"返回"]];
    [self addSection:head];

    A2SettingsSection *look = [[A2SettingsSection alloc] initWithTitle:@"外观"];
    [look addRow:[self customRowWithSymbol:@"textformat"
                                     title:@"标题"
                                  subtitle:nil
                                 valueText:(options.customTitle.length ? options.customTitle : @"（默认）")
                                disclosure:YES
                                     onTap:^{ [weakSelf editCustomTitle]; }]];
    [look addRow:[self customRowWithSymbol:options.customSymbol
                                     title:@"图标"
                                  subtitle:nil
                                 valueText:A2HomeCustomSymbolTitle(options.customSymbol)
                                disclosure:YES
                                     onTap:^{ [weakSelf editCustomSymbol]; }]];
    [self addSection:look];

    NSString *reason = nil;
    BOOL usable = [options isJumpUsableWithReason:&reason];
    NSString *targetValue = isURL
        ? (options.jumpURLString.length ? options.jumpURLString : @"（未设置）")
        : A2HomeJumpPageDisplayName(options.jumpPage);

    A2SettingsSection *jump = [[A2SettingsSection alloc] initWithTitle:@"跳转目标"];
    [jump addRow:[self customRowWithSymbol:(isURL ? @"globe" : A2HomeJumpPageSymbolName(options.jumpPage))
                                     title:(isURL ? @"网址" : @"内置页")
                                  subtitle:(usable ? @"点按更改" : reason)
                                 valueText:targetValue
                                disclosure:YES
                                     onTap:^{ [weakSelf editCustomJump]; }]];
    [self addSection:jump];

    BOOL replacing = (self.replacingCardID.length > 0);
    A2SettingsSection *foot = [[A2SettingsSection alloc] initWithTitle:nil];
    [foot addRow:[self customRowWithSymbol:@"checkmark.circle.fill"
                                     title:(replacing ? @"保存修改" : @"添加卡片")
                                  subtitle:nil
                                 valueText:nil
                                disclosure:NO
                                     onTap:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self commitCustomDraft];
    }]];
    [self addSection:foot];
}

- (void)editCustomTitle {
    __weak typeof(self) weakSelf = self;
    [A2InputDialog presentFrom:self
                         title:@"卡片标题"
                         label:[NSString stringWithFormat:@"标题（最多 %ld 字，留空用跳转目标名）",
                                                          (long)A2HomeCustomTitleMaxLength]
                   initialText:self.customDraftCard.options.customTitle
                      onFinish:^(BOOL committed, NSString *text) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !committed) return;
        NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > (NSUInteger)A2HomeCustomTitleMaxLength) {
            trimmed = [trimmed substringToIndex:(NSUInteger)A2HomeCustomTitleMaxLength];
        }
        self.customDraftCard.options.customTitle = trimmed;
        [self rebuildCustomEditor];
    }];
}

- (void)editCustomSymbol {
    __weak typeof(self) weakSelf = self;
    NSString *current = self.customDraftCard.options.customSymbol;
    A2OptionSheet *sheet = [A2OptionSheet sheetWithTitle:@"选择图标" message:@"只列本版内置的图标"];
    for (NSString *symbol in A2HomeCustomSymbolChoices()) {
        [sheet addOptionWithTitle:A2HomeCustomSymbolTitle(symbol)
                         selected:[symbol isEqualToString:current]
                      destructive:NO
                          handler:^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.customDraftCard.options.customSymbol = symbol;
            [self rebuildCustomEditor];
        }];
    }
    [sheet presentFrom:self];
}

- (void)editCustomJump {
    A2HomeCardOptions *options = self.customDraftCard.options;
    __weak typeof(self) weakSelf = self;
    A2OptionSheet *sheet = [A2OptionSheet sheetWithTitle:@"跳转目标"
                                                 message:@"内置页走主页的 fix2PushTab:；网址交给浏览器"];
    for (NSNumber *number in A2HomeJumpPagesAll()) {
        A2HomeJumpPage page = (A2HomeJumpPage)number.integerValue;
        [sheet addOptionWithTitle:[NSString stringWithFormat:@"内置页 · %@", A2HomeJumpPageDisplayName(page)]
                         selected:(options.jumpKind == A2HomeJumpKindPage && options.jumpPage == page)
                      destructive:NO
                          handler:^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            A2HomeCardOptions *draft = self.customDraftCard.options;
            draft.jumpKind = A2HomeJumpKindPage;
            draft.jumpPage = page;
            // 标题还空着就跟着目标走：卡片上不能出现一个没有名字的入口。
            if (draft.customTitle.length == 0) draft.customTitle = A2HomeJumpPageDisplayName(page);
            [self rebuildCustomEditor];
        }];
    }
    [sheet addOptionWithTitle:@"网址…"
                     selected:(options.jumpKind == A2HomeJumpKindURL)
                  destructive:NO
                      handler:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self promptCustomURL];
    }];
    [sheet presentFrom:self];
}

- (void)promptCustomURL {
    __weak typeof(self) weakSelf = self;
    A2HomeCardOptions *options = self.customDraftCard.options;
    NSString *initial = (options.jumpKind == A2HomeJumpKindURL) ? options.jumpURLString : @"";
    [A2InputDialog presentFrom:self
                         title:@"网址"
                         label:@"以 http:// 或 https:// 开头"
                   initialText:initial
                      onFinish:^(BOOL committed, NSString *text) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !committed) return;
        NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSURL *url = A2HomeWebURLFromString(trimmed);
        if (!url) {
            // 非法网址不进草案：留着原目标，用户还能改（与导入时「不动现有配置」同一口径）。
            [A2Toast show:@"只支持 http / https 网址" inView:self.view];
            return;
        }
        A2HomeCardOptions *draft = self.customDraftCard.options;
        draft.jumpKind = A2HomeJumpKindURL;
        draft.jumpURLString = url.absoluteString ?: trimmed;
        if (draft.customTitle.length == 0) draft.customTitle = url.host ?: @"链接";
        [self rebuildCustomEditor];
    }];
}

- (void)commitCustomDraft {
    A2HomeCard *card = self.customDraftCard;
    if (!card) return;
    A2HomeCardOptions *options = card.options;
    if (options.customTitle.length == 0) {
        options.customTitle = (options.jumpKind == A2HomeJumpKindURL)
            ? (A2HomeWebURLFromString(options.jumpURLString).host ?: @"链接")
            : A2HomeJumpPageDisplayName(options.jumpPage);
    }
    if (options.customSymbol.length == 0) options.customSymbol = A2HomeCustomDefaultSymbol();
    self.customDraftCard = nil;
    [self finishWithCard:card];
}

#pragma mark - 收尾

- (void)finishWithCard:(A2HomeCard *)card {
    if (!card) return;
    [A2Log log:@"[A2-HOME] picker 选定：kind=%@ size=%@%@",
                A2HomeCardKindToken(card.kind), A2HomeCardSizeToken(card.size),
                self.replacingCardID.length ? @"（换目标）" : @"（新卡）"];
    if (self.onPickCard) self.onPickCard(card);
    if (self.navigationController.topViewController == self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

@end
