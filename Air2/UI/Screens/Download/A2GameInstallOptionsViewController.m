//
//  A2GameInstallOptionsViewController.m
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
//  见头文件：加载器候选覆盖安装器能自动装的全部类型；OptiFine 无公开安装接口，
//  给出入口但置灰，副标题说明原因，不假装能装。
//  「请求加载器版本列表」与「选择加载器版本」都收在同一张可展开卡里完成
//  （见 A2LoaderCard）：点卡头就地展开、选完自动收起，不另开页面。
//  版本名默认取 MC 版本号，未手动改过时随加载器选择自动改成 {mc}-{loader}。
//

#import "A2GameInstallOptionsViewController.h"
#import "A2InstallingViewController.h"
#import "A2LoaderCard.h"
#import "A2SettingsSection.h"
#import "A2TextField.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Icon.h"
#import "A2Metrics.h"
#import "A2ModLoaderAPI.h"
#import "A2ModLoaderSelection.h"
#import "A2ModLoaderInstaller.h"
#import "A2VersionManager.h"
#import "A2Log.h"

@interface A2GameInstallOptionsViewController () <A2LoaderCardDelegate>

@property (nonatomic, copy) NSString *versionID;

@property (nonatomic, strong) A2TextField *nameField;
@property (nonatomic, assign) BOOL nameValid;
/// 用户是否手动编辑过版本名；编辑过就不再自动改
@property (nonatomic, assign) BOOL userEditedName;

@property (nonatomic, strong) A2SettingsSection *loaderSection;
@property (nonatomic, strong) UIStackView *loaderStack;
/// 全部加载器卡（含原版卡）
@property (nonatomic, strong) NSMutableArray<A2LoaderCard *> *loaderCards;
/// 选择模型 —— 负责互斥与 API 配对（对照 ZL2 DownloadGameModLoaderLists）
@property (nonatomic, strong) A2ModLoaderSelection *selection;
/// 当前选中的卡。原版卡默认选中，因此不为 nil。
@property (nonatomic, strong, nullable) A2LoaderCard *chosenLoaderCard;

@property (nonatomic, strong) A2SettingsSection *actionSection;
@property (nonatomic, strong) A2PrimaryButton *installButton;

@end

@implementation A2GameInstallOptionsViewController

- (instancetype)initWithVersionID:(NSString *)versionID {
    self = [super init];
    if (!self) return nil;
    _versionID = [versionID copy];
    _loaderCards = [NSMutableArray array];
    _nameValid = YES;

    // ⚠️ 必须创建选择模型！
    //
    // 之前这个属性声明了但从没初始化，而代码里到处用 _selection.xxx。
    // 给 nil 发消息返回 0/NO —— 于是：
    //   ![_selection canSelectType:type]  →  !NO  →  YES
    //   _selection.versions[@(type)] == nil  →  YES
    //   两个条件都成立 → 判定「与已选的加载器冲突」→ 点任何加载器都弹冲突。
    //
    // 这就是「默认选原版，点模组加载器就显示冲突」的真正原因。
    _selection = [[A2ModLoaderSelection alloc] init];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = _versionID;

    [self setupNameSection];
    [self setupLoaderSection];
    [self setupActionSection];
    [self setupThemeObserver];

    [self applyTheme];
    [self validateName];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setupThemeObserver {
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

#pragma mark - 布局

- (void)setupNameSection {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"版本名"];

    _nameField = [[A2TextField alloc] initWithLabel:@"版本名"];
    _nameField.text = _versionID;
    _nameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    __weak typeof(self) weakSelf = self;
    _nameField.onTextChange = ^(NSString *text) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.userEditedName = YES;
        [self validateName];
    };
    [section addCustomView:_nameField];

    [self addSection:section];
}

- (void)setupLoaderSection {
    _loaderSection = [[A2SettingsSection alloc] initWithTitle:@"模组加载器"];
    _loaderSection.footerText =
        @"不选择加载器即为原版。OptiFine 官方无自动安装接口，需自行手动安装。";

    _loaderStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _loaderStack.axis = UILayoutConstraintAxisVertical;
    _loaderStack.spacing = A2CardSpacing;

    // 原版排第一：它就是「不装加载器」，是默认态，放最前符合阅读顺序。
    A2LoaderCard *vanilla = [[A2LoaderCard alloc] initAsVanilla];
    vanilla.delegate = self;
    vanilla.chosen = YES;
    _chosenLoaderCard = vanilla;
    [_loaderCards addObject:vanilla];
    [_loaderStack addArrangedSubview:vanilla];

    // 主加载器
    for (NSNumber *n in [A2ModLoaderSelection allPrimaryLoaders]) {
        A2ModLoaderType type = (A2ModLoaderType)n.integerValue;
        A2LoaderCard *card = [[A2LoaderCard alloc] initWithLoaderType:type mcVersion:_versionID];
        card.delegate = self;
        // 官方没有稳定自动化接口的加载器只给入口、不给假希望。
        if (![A2ModLoaderInstaller supportsAutoInstall:type]) {
            card.unavailableReason = @"官方无自动安装接口，需手动安装";
        }
        [_loaderCards addObject:card];
        [_loaderStack addArrangedSubview:card];
    }

    // API 模组 —— 对照 ZL2：它们是独立选项，依附于对应的主加载器。
    // 比如选了 Fabric 才能选 Fabric API（它自身也是模组，只是必装）。
    UILabel *apiHeader = [[UILabel alloc] initWithFrame:CGRectZero];
    apiHeader.translatesAutoresizingMaskIntoConstraints = NO;
    apiHeader.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    apiHeader.text = @"前置模组";
    [_loaderStack addArrangedSubview:apiHeader];

    for (NSNumber *n in [A2ModLoaderSelection allAPIMods]) {
        A2ModLoaderType type = (A2ModLoaderType)n.integerValue;
        A2LoaderCard *card = [[A2LoaderCard alloc] initWithLoaderType:type mcVersion:_versionID];
        card.delegate = self;
        card.unavailableReason = @"需先选择对应的加载器";
        [_loaderCards addObject:card];
        [_loaderStack addArrangedSubview:card];
    }

    [_loaderSection addCustomView:_loaderStack];
    [self addSection:_loaderSection];
}

- (void)setupActionSection {
    _actionSection = [[A2SettingsSection alloc] initWithTitle:nil];

    _installButton = [[A2PrimaryButton alloc] initWithTitle:@"安装" style:A2ButtonStylePrimary];
    [_installButton addTarget:self action:@selector(startInstall)
             forControlEvents:UIControlEventTouchUpInside];
    [_actionSection addCustomView:_installButton];
    [NSLayoutConstraint activateConstraints:@[
        [_installButton.heightAnchor constraintEqualToConstant:A2ButtonHeight],
    ]];

    [self addSection:_actionSection];
}

#pragma mark - 加载器选择

- (void)loaderCardSelectionDidChange:(A2LoaderCard *)card {
    // 原版即「不装任何加载器」—— 清空全部选择
    if (card.isVanilla) {
        [_selection.versions removeAllObjects];
        for (A2LoaderCard *c in _loaderCards) {
            if (c != card) { c.chosen = NO; [c collapse]; }
        }
        _chosenLoaderCard = card;
        [self refreshSelectionAvailability];
        [self syncNameForLoaderType:nil];
        return;
    }

    A2ModLoaderType type = card.loaderType;

    // 主加载器之间是【切换】而不是“冲突”：选了 Forge 再点 Fabric，
    // 直接把旧加载器顶掉即可 —— selectType:version: 内部会清掉互斥项。
    // 只有 API 模组（Fabric API 之类）依附主加载器，配错了才提示冲突。
    if (A2ModLoaderIsAPIMod(type) && ![_selection canSelectType:type] &&
        _selection.versions[@(type)] == nil) {
        [A2Toast show:@"与已选的加载器冲突" inView:self.view];
        card.chosen = NO;
        return;
    }

    // selectedVersion 是 A2ModLoaderVersion 对象，不是字符串 ——
    // 之前直接赋给 NSString *，运行时崩
    // "[A2ModLoaderVersion length]: unrecognized selector"。
    A2ModLoaderVersion *sel = card.selectedVersion;
    NSString *version = sel.version ?: @"";
    [_selection selectType:type version:version];

    // 同步 UI：被互斥清掉的卡片要复位
    [self syncCardsWithSelection];

    // 只有主加载器影响版本命名；API 模组不参与。
    // OptiFine 叠加在 Forge/NeoForge 上时也不改名 —— 它不是主加载器。
    BOOL optifineOnTop = (type == A2ModLoaderTypeOptiFine &&
                          [self hasNonOptiFineLoaderSelected]);
    if (A2ModLoaderIsLoader(type) && !optifineOnTop) {
        _chosenLoaderCard = card;
        [self syncNameForLoaderType:version.length ? @(type) : nil];
    }
}

/// 当前是否已经选了 OptiFine 以外的主加载器。
- (BOOL)hasNonOptiFineLoaderSelected {
    for (NSNumber *key in _selection.versions) {
        A2ModLoaderType t = (A2ModLoaderType)key.integerValue;
        if (A2ModLoaderIsLoader(t) && t != A2ModLoaderTypeOptiFine) return YES;
    }
    return NO;
}

/// 让所有卡片的状态与选择模型一致。
/// 被互斥清掉的卡片要取消选中并收起，冲突的卡片要置灰。
- (void)syncCardsWithSelection {
    for (A2LoaderCard *c in _loaderCards) {
        if (c.isVanilla) continue;

        BOOL selected = (_selection.versions[@(c.loaderType)] != nil);
        if (selected) {
            c.chosen = YES;
        } else if (c.chosen) {
            // 曾经选中但现在被互斥清掉了
            c.chosen = NO;
            [c collapse];
        }

        // 冲突态：与已选互斥且自己没被选
        c.conflicting = [self.selection isConflictingType:c.loaderType];
    }
}

/// 没有任何选择时回到「原版」
- (void)refreshSelectionAvailability {
    for (A2LoaderCard *c in _loaderCards) {
        c.conflicting = [self.selection isConflictingType:c.loaderType];
    }
}

- (void)loaderCardDidExpand:(A2LoaderCard *)card {
    // 同时只允许一张卡展开，免得全部打开后页面被拉得很长。
    for (A2LoaderCard *c in _loaderCards) {
        if (c != card) [c collapse];
    }
}

/// 未手动改过版本名时，跟随加载器自动改名（原版还原为 MC 版本号）。
- (void)syncNameForLoaderType:(nullable NSNumber *)type {
    if (_userEditedName) return;
    if (type) {
        NSString *ident = [A2ModLoaderAPI identifierForType:(A2ModLoaderType)type.integerValue];
        _nameField.text = [NSString stringWithFormat:@"%@-%@", _versionID, ident];
    } else {
        _nameField.text = _versionID;
    }
    [self validateName];
}

#pragma mark - 校验

- (void)validateName {
    NSString *name = _nameField.text;
    if (name.length == 0) {
        _nameValid = NO;
        _nameField.errorText = @"内容不能为空！";
        return;
    }
    for (A2Version *v in A2VersionManager.shared.versions) {
        if ([v.name isEqualToString:name]) {
            _nameValid = NO;
            _nameField.errorText = @"此名称的版本已经存在！";
            return;
        }
    }
    _nameValid = YES;
    _nameField.errorText = nil;
}

#pragma mark - 安装

- (void)startInstall {
    [self validateName];
    if (!_nameValid) {
        [A2Toast show:@"请先修正版本名" inView:self.view];
        return;
    }

    // 从选择模型取（它已处理互斥与 API 配对）
    NSNumber *loaderType = _selection.selectedLoaderType;
    NSString *loaderVersion = nil;
    if (loaderType) {
        loaderVersion = _selection.versions[loaderType];
        if (loaderVersion.length == 0) {
            [A2Toast show:[NSString stringWithFormat:@"请先选择 %@ 的版本",
                           [A2ModLoaderAPI displayNameForType:
                            (A2ModLoaderType)loaderType.integerValue]]
                   inView:self.view];
            return;
        }
    }

    // API 模组（Fabric API 等）—— 它是独立的下载项，
    // 装完加载器后要单独装。对照 ZL2：两者在界面上并列，
    // 但下载流程是分开的两步。
    NSNumber *apiType = _selection.selectedAPIType;
    NSString *apiVersion = apiType ? _selection.versions[apiType] : nil;

    [A2Log log:@"download: 开始安装 mc=%@ 版本名=%@ 加载器=%@ 加载器版本=%@ 前置模组=%@",
        _versionID, _nameField.text,
        loaderType ? [A2ModLoaderAPI displayNameForType:(A2ModLoaderType)loaderType.integerValue]
                   : @"原版",
        loaderVersion ?: @"-",
        apiType ? [A2ModLoaderAPI displayNameForType:(A2ModLoaderType)apiType.integerValue]
                : @"无"];

    // 用弹窗形态（ZL2 的 TitleTaskFlowDialog），而不是整页推进去的圆环页。
    //
    // 两套界面并存是我之前的问题：A2InstallingViewController 是早期做的
    // 圆环 + 大进度条版本，而 A2InstallProgressDialog 是按 ZL2 的
    // 任务清单做的。用户看到的是前者，所以「感觉没变」。
    //
    // 现在统一走弹窗：任务清单 + 进度条/速率/百分比同行 + 底部取消。
    [A2InstallingViewController presentAsDialogFrom:self
                                          mcVersion:_versionID
                                        versionName:_nameField.text
                                         loaderType:loaderType
                                      loaderVersion:loaderVersion
                                            apiType:apiType
                                         apiVersion:apiVersion];
}

@end
