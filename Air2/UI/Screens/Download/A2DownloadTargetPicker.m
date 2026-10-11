//
//  A2DownloadTargetPicker.m
//  Air2
//

#import "A2DownloadTargetPicker.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2VersionManager.h"
#import "A2ContentSource.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2Metrics.h"

#pragma mark - 依赖项

@implementation A2DownloadDependency
@end

#pragma mark - 版本选择行

@interface A2TargetVersionRow : UIControl
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIView *checkBox;
@property (nonatomic, strong) UIImageView *checkIcon;
@property (nonatomic, assign, getter=isChosen) BOOL chosen;
- (instancetype)initWithVersion:(A2Version *)version;
- (void)applyTheme;
@end

@implementation A2TargetVersionRow

- (instancetype)initWithVersion:(A2Version *)version {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = A2RadiusM;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    _checkBox = [[UIView alloc] initWithFrame:CGRectZero];
    _checkBox.translatesAutoresizingMaskIntoConstraints = NO;
    _checkBox.layer.cornerRadius = 4;
    _checkBox.layer.borderWidth = 1.5;
    _checkBox.userInteractionEnabled = NO;
    [self addSubview:_checkBox];

    _checkIcon = [[UIImageView alloc] initWithImage:
                  [UIImage systemImageNamed:@"checkmark"]];
    _checkIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _checkIcon.contentMode = UIViewContentModeScaleAspectFit;
    _checkIcon.hidden = YES;
    [_checkBox addSubview:_checkIcon];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _nameLabel.text = version.name;

    _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metaLabel.font = [A2Typography caption];
    _metaLabel.text = version.loaderInfo.length ? version.loaderInfo : @"原版";

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:
                              @[_nameLabel, _metaLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 1;
    [self addSubview:textStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:52],

        [_checkBox.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:A2SpaceM],
        [_checkBox.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_checkBox.widthAnchor constraintEqualToConstant:20],
        [_checkBox.heightAnchor constraintEqualToConstant:20],
        [_checkIcon.centerXAnchor constraintEqualToAnchor:_checkBox.centerXAnchor],
        [_checkIcon.centerYAnchor constraintEqualToAnchor:_checkBox.centerYAnchor],
        [_checkIcon.widthAnchor constraintEqualToConstant:13],
        [_checkIcon.heightAnchor constraintEqualToConstant:13],

        [textStack.leadingAnchor constraintEqualToAnchor:_checkBox.trailingAnchor
                                                constant:A2SpaceM],
        [textStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                 constant:-A2SpaceM],
        [textStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setChosen:(BOOL)chosen {
    _chosen = chosen;
    _checkIcon.hidden = !chosen;
    [self applyTheme];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _nameLabel.textColor = t.cOnSurface;
    _metaLabel.textColor = t.cOnSurfaceVariant;

    // 选中态：填充主色 + 白色勾；未选中：描边
    _checkBox.backgroundColor = self.isChosen ? t.cPrimary : UIColor.clearColor;
    _checkBox.layer.borderColor = (self.isChosen ? t.cPrimary : t.cOutline).CGColor;
    _checkIcon.tintColor = t.cOnPrimary;

    self.backgroundColor = self.isChosen
        ? [t.cPrimaryContainer colorWithAlphaComponent:0.4]
        : UIColor.clearColor;
}

@end

#pragma mark - 弹窗

@interface A2DownloadTargetPickerVC : UIViewController
@property (nonatomic, strong) A2ContentItem *project;
@property (nonatomic, assign) A2ContentClass contentClass;
@property (nonatomic, strong) NSArray<A2DownloadDependency *> *dependencies;
@property (nonatomic, copy) void (^onConfirm)(NSArray<A2Version *> *, NSArray<A2DownloadDependency *> *);

@property (nonatomic, strong) NSMutableArray<A2Version *> *chosenVersions;
@property (nonatomic, strong) NSMutableSet<NSString *> *chosenDeps;
@property (nonatomic, strong) NSMutableArray<A2TargetVersionRow *> *rows;
@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, strong) UIView *card;
@end

@implementation A2DownloadTargetPickerVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    _chosenVersions = [NSMutableArray array];
    _chosenDeps = [NSMutableSet set];
    _rows = [NSMutableArray array];

    _backdrop = [[UIView alloc] initWithFrame:CGRectZero];
    _backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    _backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    [_backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                     initWithTarget:self action:@selector(dismiss)]];
    [self.view addSubview:_backdrop];

    [self setupCard];

    [NSLayoutConstraint activateConstraints:@[
        [_backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (void)setupCard {
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.layer.cornerRadius = A2RadiusXL;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    [self.view addSubview:_card];

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    title.text = @"安装到哪个版本";
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitle.font = [A2Typography caption];
    subtitle.text = _project.title;
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 1;

    // 版本列表（可滚动）
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceXS;
    [scroll addSubview:stack];

    NSArray<A2Version *> *versions = A2VersionManager.shared.versions;
    A2Version *current = A2VersionManager.shared.currentVersion;

    if (versions.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectZero];
        empty.text = @"还没有安装任何版本";
        empty.font = [A2Typography body];
        empty.textAlignment = NSTextAlignmentCenter;
        [stack addArrangedSubview:empty];
    } else {
        for (A2Version *v in versions) {
            if (!v.isValid) continue;
            A2TargetVersionRow *row = [[A2TargetVersionRow alloc] initWithVersion:v];
            // 默认选中当前版本 —— 多数情况下用户就是要装到正在用的那个
            if (v == current) {
                row.chosen = YES;
                [_chosenVersions addObject:v];
            }
            [row addTarget:self action:@selector(rowTapped:)
          forControlEvents:UIControlEventTouchUpInside];
            row.tag = [_rows count];
            [_rows addObject:row];
            [stack addArrangedSubview:row];
        }
    }

    // 依赖区（可选）
    UIView *depBlock = nil;
    if (_dependencies.count > 0) {
        depBlock = [self buildDependencyBlock];
    }

    // 按钮
    A2PrimaryButton *cancel = [[A2PrimaryButton alloc] initWithTitle:@"取消"
                                                               style:A2ButtonStyleSecondary];
    [cancel addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];

    A2PrimaryButton *confirm = [[A2PrimaryButton alloc] initWithTitle:@"开始安装"
                                                                style:A2ButtonStylePrimary];
    [confirm addTarget:self action:@selector(confirm)
       forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[cancel, confirm]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.distribution = UIStackViewDistributionFillEqually;
    buttonRow.spacing = A2SpaceM;

    [_card addSubview:title];
    [_card addSubview:subtitle];
    [_card addSubview:scroll];
    if (depBlock) [_card addSubview:depBlock];
    [_card addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_card.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor
                                                  multiplier:0.7],
        [_card.widthAnchor constraintGreaterThanOrEqualToConstant:380],
        [_card.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor
                                                   multiplier:0.85],

        [title.topAnchor constraintEqualToAnchor:_card.topAnchor constant:A2SpaceXL],
        [title.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceXL],
        [title.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceXL],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:A2SpaceXS],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],

        [scroll.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:A2SpaceL],
        [scroll.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceL],
        [scroll.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceL],

        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor],
        [stack.heightAnchor constraintGreaterThanOrEqualToConstant:0],
        [scroll.heightAnchor constraintLessThanOrEqualToConstant:240],
    ]];

    // 依赖块与按钮的位置
    UIView *above = depBlock ?: scroll;
    if (depBlock) {
        [NSLayoutConstraint activateConstraints:@[
            [depBlock.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:A2SpaceM],
            [depBlock.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceL],
            [depBlock.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceL],
        ]];
    }

    [NSLayoutConstraint activateConstraints:@[
        [buttonRow.topAnchor constraintEqualToAnchor:above.bottomAnchor constant:A2SpaceL],
        [buttonRow.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:A2SpaceL],
        [buttonRow.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-A2SpaceL],
        [buttonRow.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-A2SpaceL],
        [buttonRow.heightAnchor constraintEqualToConstant:A2ButtonHeight],
    ]];

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

/// 依赖块 —— 列出前置项，让用户决定一起装
- (UIView *)buildDependencyBlock {
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceS;

    UILabel *header = [[UILabel alloc] initWithFrame:CGRectZero];
    header.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    header.text = @"前置依赖";
    [stack addArrangedSubview:header];

    for (A2DownloadDependency *dep in _dependencies) {
        UIControl *row = [[UIControl alloc] initWithFrame:CGRectZero];
        row.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        label.text = dep.installed
            ? [NSString stringWithFormat:@"%@（已安装）", dep.title]
            : dep.title;

        [row addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [row.heightAnchor constraintEqualToConstant:32],
            [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        ]];

        if (!dep.installed) {
            // 未安装的默认勾上 —— 不装前置的话模组大概率跑不起来
            [_chosenDeps addObject:dep.projectID];
        }
        [stack addArrangedSubview:row];
    }
    return stack;
}

- (void)rowTapped:(UIControl *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)_rows.count) return;

    A2TargetVersionRow *row = _rows[index];
    A2Version *version = A2VersionManager.shared.versions[index];

    row.chosen = !row.isChosen;
    if (row.isChosen) {
        [_chosenVersions addObject:version];
    } else {
        [_chosenVersions removeObject:version];
    }

    UISelectionFeedbackGenerator *fb = [UISelectionFeedbackGenerator new];
    [fb selectionChanged];
}

- (void)confirm {
    if (_chosenVersions.count == 0) {
        [A2Toast show:@"请至少选择一个版本" inView:self.view];
        return;
    }

    NSMutableArray<A2DownloadDependency *> *deps = [NSMutableArray array];
    for (A2DownloadDependency *d in _dependencies) {
        if ([_chosenDeps containsObject:d.projectID]) [deps addObject:d];
    }

    void (^cb)(NSArray<A2Version *> *, NSArray<A2DownloadDependency *> *) = _onConfirm;
    NSArray<A2Version *> *versions = [_chosenVersions copy];
    NSArray<A2DownloadDependency *> *finalDeps = [deps copy];

    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(versions, finalDeps);
    }];
}

- (void)dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _card.backgroundColor = t.cSurfaceContainerHigh;

    for (UIView *v in _card.subviews) {
        if (![v isKindOfClass:UILabel.class]) continue;
        ((UILabel *)v).textColor = t.cOnSurface;
    }
}

@end

#pragma mark - 对外接口

@implementation A2DownloadTargetPicker

+ (void)presentFrom:(UIViewController *)host
            project:(A2ContentItem *)project
       contentClass:(A2ContentClass)contentClass
       dependencies:(NSArray<A2DownloadDependency *> *)dependencies
          onConfirm:(void (^)(NSArray<A2Version *> *, NSArray<A2DownloadDependency *> *))onConfirm {

    // 一个版本都没有就直接提示 —— 弹窗里也没什么可选的
    if (A2VersionManager.shared.versions.count == 0) {
        [A2Toast show:@"还没有安装任何版本，请先安装游戏" inView:host.view];
        return;
    }

    A2DownloadTargetPickerVC *vc = [[A2DownloadTargetPickerVC alloc] init];
    vc.project = project;
    vc.contentClass = contentClass;
    vc.dependencies = dependencies ?: @[];
    vc.onConfirm = onConfirm;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [host presentViewController:vc animated:YES completion:nil];
}

@end
