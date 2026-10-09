//
//  A2ModListViewController.m
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
//  实现见头文件。行内交互只有开关与删除，点行身等于拨开关
//  （同一动作大一点的热区，不另起行为）。
//

#import "A2ModListViewController.h"
#import "A2VersionManager.h"
#import "A2LocalMod.h"
#import "A2ModScanner.h"
#import "A2GameFiles.h"
#import "A2Log.h"
#import "A2GlassCard.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

/// 行副标题：加载器 版本 · 作者（只取前两位，人多标等N人）。
/// 未识别只有一句话，不拼。
static NSString *A2ModRowMeta(A2LocalMod *mod) {
    if (mod.isNotMod) return @"文件无法识别";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *loader = A2ModLoaderKindDisplayName(mod.loaderKind);
    if (mod.version.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"%@ %@", loader, mod.version]];
    } else {
        [parts addObject:loader];
    }
    if (mod.authors.count > 0) {
        NSArray<NSString *> *shown = [mod.authors subarrayWithRange:
                                      NSMakeRange(0, MIN(2, mod.authors.count))];
        NSString *authors = [shown componentsJoinedByString:@"、"];
        if (mod.authors.count > 2) {
            authors = [authors stringByAppendingFormat:@"等%lu人",
                       (unsigned long)mod.authors.count];
        }
        [parts addObject:authors];
    }
    return [parts componentsJoinedByString:@" · "];
}

#pragma mark - 行

@interface A2ModRowView : UIControl

@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) UIView *iconBox;
@property (nonatomic, strong) UILabel *initialLabel;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UISwitch *enableSwitch;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@property (nonatomic, copy, nullable) void (^onToggle)(void);
@property (nonatomic, copy, nullable) void (^onDelete)(void);

- (instancetype)initWithMod:(A2LocalMod *)mod;
- (void)applyTheme;

@end

@implementation A2ModRowView {
    UISelectionFeedbackGenerator *_feedback;
}

- (instancetype)initWithMod:(A2LocalMod *)mod {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _enabled = mod.isEnabled;
    _feedback = [UISelectionFeedbackGenerator new];

    UIStackView *textStack = [self setupSubviewsWithMod:mod];
    [self setupConstraintsWithTextStack:textStack];

    // 行身点按等于拨开关（同一动作，热区大一点）。
    [self addTarget:self action:@selector(handleToggle) forControlEvents:UIControlEventTouchUpInside];

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(applyTheme)
                                               name:A2ThemeDidChangeNotification
                                             object:nil];
    return self;
}

/// 建子视图（只创建装配，不碰约束）。
- (UIStackView *)setupSubviewsWithMod:(A2LocalMod *)mod {
    _fillView = [[UIView alloc] initWithFrame:CGRectZero];
    _fillView.translatesAutoresizingMaskIntoConstraints = NO;
    _fillView.userInteractionEnabled = NO;
    _fillView.layer.cornerRadius = A2RadiusM;
    _fillView.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_fillView];

    _iconBox = [[UIView alloc] initWithFrame:CGRectZero];
    _iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBox.layer.cornerRadius = A2RadiusS;
    _iconBox.layer.cornerCurve = kCACornerCurveContinuous;
    _iconBox.clipsToBounds = YES;
    [self addSubview:_iconBox];

    _initialLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _initialLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _initialLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    _initialLabel.textAlignment = NSTextAlignmentCenter;
    _initialLabel.text = mod.displayName.length
        ? [[mod.displayName substringToIndex:1] uppercaseString] : @"?";
    [_iconBox addSubview:_initialLabel];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _nameLabel.text = mod.displayName;
    _nameLabel.numberOfLines = 1;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.75;

    _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metaLabel.font = [A2Typography subtitleCard];
    _metaLabel.text = A2ModRowMeta(mod);
    _metaLabel.numberOfLines = 1;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel, _metaLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 1;
    [self addSubview:textStack];

    _enableSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _enableSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    _enableSwitch.on = mod.isEnabled;
    [_enableSwitch addTarget:self action:@selector(handleToggle)
            forControlEvents:UIControlEventValueChanged];
    [self addSubview:_enableSwitch];

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    _deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_deleteButton setImage:[UIImage systemImageNamed:@"trash" withConfiguration:cfg]
                   forState:UIControlStateNormal];
    [_deleteButton addTarget:self action:@selector(handleDelete)
            forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_deleteButton];

    return textStack;
}

/// 布约束（视图已就位，这里只谈位置）。
- (void)setupConstraintsWithTextStack:(UIStackView *)textStack {
    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:64],

        [_fillView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_fillView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_fillView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_fillView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [_iconBox.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceM],
        [_iconBox.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconBox.widthAnchor constraintEqualToConstant:36],
        [_iconBox.heightAnchor constraintEqualToConstant:36],
        [_initialLabel.centerXAnchor constraintEqualToAnchor:_iconBox.centerXAnchor],
        [_initialLabel.centerYAnchor constraintEqualToAnchor:_iconBox.centerYAnchor],

        [textStack.leadingAnchor constraintEqualToAnchor:_iconBox.trailingAnchor constant:A2SpaceM],
        [textStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_enableSwitch.leadingAnchor
                                                           constant:-A2SpaceS],

        [_enableSwitch.trailingAnchor constraintEqualToAnchor:_deleteButton.leadingAnchor],
        [_enableSwitch.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

        [_deleteButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-A2SpaceS],
        [_deleteButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_deleteButton.widthAnchor constraintEqualToConstant:44],
        [_deleteButton.heightAnchor constraintEqualToConstant:44],
    ]];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    _enableSwitch.on = enabled;
    [self applyTheme];
}

- (void)handleToggle {
    [_feedback selectionChanged];
    if (self.onToggle) self.onToggle();
}

- (void)handleDelete {
    [_feedback selectionChanged];
    if (self.onDelete) self.onDelete();
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _fillView.backgroundColor = t.cSurfaceContainerLow;
    _iconBox.backgroundColor = t.cPrimaryContainer;
    _initialLabel.textColor = t.cOnPrimaryContainer;
    _nameLabel.textColor = t.cOnSurface;
    _metaLabel.textColor = t.cOnSurfaceVariant;
    _enableSwitch.onTintColor = t.cPrimary;
    _deleteButton.tintColor = t.cError;
    self.alpha = self.isEnabled ? 1.0 : 0.55;
}

@end

#pragma mark - 页面

@interface A2ModListViewController ()

@property (nonatomic, strong) A2Version *version;
@property (nonatomic, strong, nullable) A2ModScanner *scanner;
@property (nonatomic, strong, nullable) A2GameFiles *files;
@property (nonatomic, copy) NSArray<A2LocalMod *> *mods;
@property (nonatomic, strong) NSMutableArray<A2ModRowView *> *rowViews;
@property (nonatomic, weak, nullable) UILabel *emptyTitleLabel;
@property (nonatomic, weak, nullable) UILabel *emptySubtitleLabel;

@end

@implementation A2ModListViewController

- (instancetype)initWithVersion:(A2Version *)version {
    self = [super init];
    if (!self) return nil;
    _version = version;
    _mods = @[];
    _rowViews = [NSMutableArray array];
    return self;
}

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：无版本的模组页是非法状态。
    return nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.pageTitle = @"模组管理";

    NSString *modsDir = [self.version modsDirectory];
    NSError *err = nil;
    _scanner = [[A2ModScanner alloc] initWithModsDirectory:modsDir error:&err];
    _files = [[A2GameFiles alloc] initWithRootPath:modsDir error:nil];
    if (!_scanner) {
        [A2Log log:@"mod: 目录缺失 %@（%@），按空列表展示",
                 modsDir, err.localizedDescription ?: @"未知错误"];
    }

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(refreshEmptyStateTheme)
                                               name:A2ThemeDidChangeNotification
                                             object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// 每次回到本页都重扫（下载页装完模组回来、开关改动后都要刷新）。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadMods];
}

/// 扫描放后台，建行回主线程（jar 解析是同步 IO）。
- (void)reloadMods {
    for (UIView *v in self.contentStack.arrangedSubviews) {
        [self.contentStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [_rowViews removeAllObjects];
    _emptyTitleLabel = nil;
    _emptySubtitleLabel = nil;

    __weak typeof(self) weakSelf = self;
    A2ModScanner *scanner = _scanner;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<A2LocalMod *> *mods = scanner ? [scanner scanMods:nil] : @[];
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSArray<A2LocalMod *> *found = [mods copy] ?: @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.mods = found;
            [self buildList];
        });
    });
}

- (void)buildList {
    if (self.mods.count == 0) {
        [self buildEmptyState];
        return;
    }
    for (A2LocalMod *mod in self.mods) {
        A2ModRowView *row = [[A2ModRowView alloc] initWithMod:mod];
        __weak typeof(self) weakSelf = self;
        __weak A2ModRowView *weakRow = row;
        row.onToggle = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self toggleMod:mod row:weakRow];
        };
        row.onDelete = ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self confirmDeleteMod:mod];
        };
        [_rowViews addObject:row];
        [self.contentStack addArrangedSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:self.contentStack.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:self.contentStack.trailingAnchor],
        ]];
    }
}

/// 空目录：只给一句话。模组靠下载页来，这里不编安装入口。
- (void)buildEmptyState {
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusM;
    card.elevation = A2CardElevationLow;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [A2Typography titleCard];
    title.textAlignment = NSTextAlignmentCenter;
    title.text = @"还没有安装模组";

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.font = [A2Typography subtitleCard];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;
    subtitle.text = @"把 jar 放进 mods 目录，或去下载页安装";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceM;
    stack.alignment = UIStackViewAlignmentFill;

    [card.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [self.contentStack addArrangedSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:self.contentStack.leadingAnchor],
        [card.trailingAnchor constraintEqualToAnchor:self.contentStack.trailingAnchor],
    ]];

    _emptyTitleLabel = title;
    _emptySubtitleLabel = subtitle;
    [self refreshEmptyStateTheme];
}

- (void)refreshEmptyStateTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _emptyTitleLabel.textColor = t.cOnSurface;
    _emptySubtitleLabel.textColor = t.cOnSurfaceVariant;
}

/// 开关：失败回滚行态（模型不可变，成功直接重扫拿新模型）。
- (void)toggleMod:(A2LocalMod *)mod row:(A2ModRowView *)row {
    if (!self.scanner) return;
    BOOL target = !mod.isEnabled;
    NSError *err = nil;
    if ([self.scanner applyMod:mod enabled:target error:&err]) {
        [A2Toast show:(target ? @"已启用" : @"已禁用") inView:self.view];
        [self reloadMods];
    } else {
        row.enabled = mod.isEnabled;
        [A2Toast show:(err.localizedDescription ?: @"切换失败") inView:self.view];
    }
}

/// 删除二次确认（mods 可重下，但手滑不可撤销，先问一句）。
- (void)confirmDeleteMod:(A2LocalMod *)mod {
    if (!self.files) return;
    __weak typeof(self) weakSelf = self;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"删除模组"
                                            message:[NSString stringWithFormat:
                @"将删除 %@，不可撤销。", mod.displayName]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) self = weakSelf;
        NSError *err = nil;
        if ([self.files deleteEntryAt:mod.fileName error:&err]) {
            [A2Log log:@"mod: 删除 %@（%@）", mod.displayName, mod.fileName];
            [self reloadMods];
            [A2Toast show:@"已删除" inView:self.view];
        } else {
            [A2Toast show:(err.localizedDescription ?: @"删除失败") inView:self.view];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
