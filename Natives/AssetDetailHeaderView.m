#import "utils.h"
//
//  AssetDetailHeaderView.m
//  Amethyst
//
//  资源详情页头部视图实现（参照 FCL/ZL2 的项目详情 header 设计）
//
//  视觉规范（与 ModernAssetCell / ModVersionTableViewCell 统一）：
//    - 圆角卡片容器：16pt 圆角 + 0.5pt 浅边框 + 浅阴影(offset 0,4 / opacity 0.12 / radius 8) + 半透明背景 + 毛玻璃
//    - 项目封面图：72x72，14pt 圆角，ScaleAspectFill + clipsToBounds，带占位 SF Symbol 背景
//    - 标签 pill：8pt 圆角，18pt 高，10pt bold 白字，按加载器/类别品牌色配色
//

#import "AssetDetailHeaderView.h"
#import "BackgroundManager.h"
// 注意：UIKit+AFNetworking 已替换为 IconLoader 统一加载器
// （AFNetworking 仅内存缓存无降采样，IconLoader 提供双层缓存+降采样+CDN镜像+并发控制）
#import "IconLoader.h"
#import "ModLoaderIconHelper.h"

@interface AssetDetailHeaderView ()

// 卡片容器（圆角 + 阴影 + 半透明背景 + 毛玻璃）
@property (nonatomic, strong) UIView *cardContainer;

// 顶部水平区：封面图 + 标题/作者
@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UIView *iconPlaceholderContainer; // 无图时显示 SF Symbol
@property (nonatomic, strong) UIImageView *placeholderSymbolView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *authorLabel;

// 元信息行：下载量 / 关注量 / 最后更新
@property (nonatomic, strong) UIStackView *metaInfoStack;

// 标签容器（多行水平 stack，自动换行）
@property (nonatomic, strong) UIStackView *categoriesStack;

// 描述区
@property (nonatomic, strong) UILabel *descriptionLabel;
@property (nonatomic, strong) UIButton *expandToggleButton;

// 当前展开状态
@property (nonatomic, assign) BOOL descriptionExpanded;
// 描述是否超过 3 行（决定是否显示展开按钮）
@property (nonatomic, assign) BOOL descriptionTruncated;

// 缓存的占位配置
@property (nonatomic, copy, nullable) NSString *placeholderSymbolName;
@property (nonatomic, strong, nullable) UIColor *placeholderColor;

@end

@implementation AssetDetailHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        [self setupViews];
    }
    return self;
}

#pragma mark - Setup

- (void)setupViews {
    // ===== 卡片容器：圆角 + 半透明背景 + 浅阴影（与 ModernAssetCell / ModVersionTableViewCell 统一）=====
    self.cardContainer = [[UIView alloc] init];
    self.cardContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    self.cardContainer.layer.cornerRadius = 16;
    self.cardContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.cardContainer.layer.borderWidth = 0.5;
    self.cardContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    self.cardContainer.layer.shadowColor = [UIColor blackColor].CGColor;
    self.cardContainer.layer.shadowOffset = CGSizeMake(0, 4);
    self.cardContainer.layer.shadowOpacity = 0.12;
    self.cardContainer.layer.shadowRadius = 8;
    [self addSubview:self.cardContainer];

    // 应用毛玻璃背景效果（与启动器整体风格一致）
    [[BackgroundManager sharedManager] applyEffectToView:self.cardContainer];

    // ===== 顶部水平区：封面图 + 标题/作者 =====
    // 封面图容器（72x72，14pt 圆角，半透明占位背景）
    self.iconPlaceholderContainer = [[UIView alloc] init];
    self.iconPlaceholderContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconPlaceholderContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10];
    self.iconPlaceholderContainer.layer.cornerRadius = 14;
    self.iconPlaceholderContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.iconPlaceholderContainer.layer.masksToBounds = YES;
    [self.cardContainer addSubview:self.iconPlaceholderContainer];

    // 占位 SF Symbol（居中显示在封面图容器内，有真实图时隐藏）
    self.placeholderSymbolView = [[UIImageView alloc] init];
    self.placeholderSymbolView.translatesAutoresizingMaskIntoConstraints = NO;
    self.placeholderSymbolView.contentMode = UIViewContentModeScaleAspectFit;
    self.placeholderSymbolView.tintColor = [UIColor systemBlueColor];
    [self.iconPlaceholderContainer addSubview:self.placeholderSymbolView];

    // 真实封面图 ImageView（覆盖在占位容器上，有图时显示）
    self.iconImageView = [[UIImageView alloc] init];
    self.iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.iconImageView.clipsToBounds = YES;
    self.iconImageView.layer.cornerRadius = 14;
    self.iconImageView.layer.cornerCurve = kCACornerCurveContinuous;
    self.iconImageView.backgroundColor = [UIColor clearColor];
    // 始终显示：加载成功时显示真实图覆盖下方占位 SF Symbol，加载失败/加载中时透明透出占位
    self.iconImageView.hidden = NO;
    [self.iconPlaceholderContainer addSubview:self.iconImageView];

    // 标题（18pt bold，最多 2 行）
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.75;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.cardContainer addSubview:self.titleLabel];

    // 作者（13pt secondary，带 person.crop.circle 图标，用 NSAttributedString）
    self.authorLabel = [[UILabel alloc] init];
    self.authorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.authorLabel.font = [UIFont systemFontOfSize:13];
    self.authorLabel.textColor = [UIColor secondaryLabelColor];
    self.authorLabel.numberOfLines = 1;
    self.authorLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.cardContainer addSubview:self.authorLabel];

    // ===== 元信息行：下载量 / 关注量 / 最后更新 =====
    self.metaInfoStack = [[UIStackView alloc] init];
    self.metaInfoStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.metaInfoStack.axis = UILayoutConstraintAxisHorizontal;
    self.metaInfoStack.spacing = 14;
    self.metaInfoStack.alignment = UIStackViewAlignmentCenter;
    self.metaInfoStack.distribution = UIStackViewDistributionFill;
    [self.cardContainer addSubview:self.metaInfoStack];

    // ===== 标签容器（垂直 stack，内部每行是水平 stack，自动换行）=====
    self.categoriesStack = [[UIStackView alloc] init];
    self.categoriesStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.categoriesStack.axis = UILayoutConstraintAxisVertical;
    self.categoriesStack.spacing = 6;
    self.categoriesStack.alignment = UIStackViewAlignmentLeading;
    [self.cardContainer addSubview:self.categoriesStack];

    // ===== 描述区 =====
    self.descriptionLabel = [[UILabel alloc] init];
    self.descriptionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.descriptionLabel.font = [UIFont systemFontOfSize:14];
    self.descriptionLabel.textColor = [UIColor secondaryLabelColor];
    self.descriptionLabel.numberOfLines = 3; // 默认 3 行
    self.descriptionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.cardContainer addSubview:self.descriptionLabel];

    // 展开/收起按钮
    self.expandToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.expandToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.expandToggleButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.expandToggleButton setTitle:localize(@"i18n_str_26", nil) forState:UIControlStateNormal];
    [self.expandToggleButton addTarget:self action:@selector(toggleDescriptionExpanded) forControlEvents:UIControlEventTouchUpInside];
    self.expandToggleButton.hidden = YES; // 默认隐藏，仅当描述超 3 行时显示
    [self.cardContainer addSubview:self.expandToggleButton];

    // ===== 布局约束 =====
    [NSLayoutConstraint activateConstraints:@[
        // 卡片容器：左右各留 16pt 边距，上下各留 8pt
        [self.cardContainer.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [self.cardContainer.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [self.cardContainer.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [self.cardContainer.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],

        // 封面图容器：72x72，左上各 16pt
        [self.iconPlaceholderContainer.topAnchor constraintEqualToAnchor:self.cardContainer.topAnchor constant:16],
        [self.iconPlaceholderContainer.leadingAnchor constraintEqualToAnchor:self.cardContainer.leadingAnchor constant:16],
        [self.iconPlaceholderContainer.widthAnchor constraintEqualToConstant:72],
        [self.iconPlaceholderContainer.heightAnchor constraintEqualToConstant:72],

        // 占位 SF Symbol 居中，28x28
        [self.placeholderSymbolView.centerXAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.centerXAnchor],
        [self.placeholderSymbolView.centerYAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.centerYAnchor],
        [self.placeholderSymbolView.widthAnchor constraintEqualToConstant:30],
        [self.placeholderSymbolView.heightAnchor constraintEqualToConstant:30],

        // 真实封面图充满占位容器
        [self.iconImageView.topAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.topAnchor],
        [self.iconImageView.leadingAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.leadingAnchor],
        [self.iconImageView.trailingAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.trailingAnchor],
        [self.iconImageView.bottomAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.bottomAnchor],

        // 标题：封面图右侧 12pt，顶部对齐，右边留 16pt
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.trailingAnchor constant:12],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.cardContainer.topAnchor constant:18],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.cardContainer.trailingAnchor constant:-16],

        // 作者：标题下方 4pt
        [self.authorLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.authorLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4],
        [self.authorLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],

        // 元信息行：封面图下方 14pt，左边 16pt
        [self.metaInfoStack.topAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.bottomAnchor constant:14],
        [self.metaInfoStack.leadingAnchor constraintEqualToAnchor:self.cardContainer.leadingAnchor constant:16],
        [self.metaInfoStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.cardContainer.trailingAnchor constant:-16],

        // 标签容器：元信息行下方 12pt
        [self.categoriesStack.topAnchor constraintEqualToAnchor:self.metaInfoStack.bottomAnchor constant:12],
        [self.categoriesStack.leadingAnchor constraintEqualToAnchor:self.cardContainer.leadingAnchor constant:16],
        [self.categoriesStack.trailingAnchor constraintEqualToAnchor:self.cardContainer.trailingAnchor constant:-16],

        // 描述区：标签容器下方 12pt
        [self.descriptionLabel.topAnchor constraintEqualToAnchor:self.categoriesStack.bottomAnchor constant:12],
        [self.descriptionLabel.leadingAnchor constraintEqualToAnchor:self.cardContainer.leadingAnchor constant:16],
        [self.descriptionLabel.trailingAnchor constraintEqualToAnchor:self.cardContainer.trailingAnchor constant:-16],

        // 展开按钮：描述下方 6pt，右对齐
        [self.expandToggleButton.topAnchor constraintEqualToAnchor:self.descriptionLabel.bottomAnchor constant:6],
        [self.expandToggleButton.trailingAnchor constraintEqualToAnchor:self.cardContainer.trailingAnchor constant:-16],
        [self.expandToggleButton.bottomAnchor constraintEqualToAnchor:self.cardContainer.bottomAnchor constant:-16],
    ]];
}

#pragma mark - Configure

- (void)configureWithIconURL:(nullable NSString *)iconURL
                       title:(NSString *)title
                      author:(nullable NSString *)author
                   downloads:(nullable NSNumber *)downloads
                       likes:(nullable NSNumber *)likes
             descriptionText:(nullable NSString *)descriptionText
                 categories:(nullable NSArray<NSString *> *)categories
                lastUpdated:(nullable NSString *)lastUpdated
        placeholderSymbolName:(NSString *)placeholderSymbolName
            placeholderColor:(UIColor *)placeholderColor {
    // 缓存占位配置（图片加载失败时回退用）
    self.placeholderSymbolName = placeholderSymbolName;
    self.placeholderColor = placeholderColor;

    // --- 标题 ---
    self.titleLabel.text = title ?: localize(@"i18n_str_27", nil);

    // --- 作者 ---
    if (author.length > 0) {
        // 用 SF Symbol + 文字组合，参照 FCL 的作者展示
        UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIFontWeightRegular];
        UIImage *personIcon = [UIImage systemImageNamed:@"person.crop.circle" withConfiguration:symbolConfig];
        NSMutableAttributedString *attrText = [[NSMutableAttributedString alloc] init];
        if (personIcon) {
            NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
            attachment.image = personIcon;
            attachment.bounds = CGRectMake(0, -1, 12, 12);
            [attrText appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
            [attrText appendAttributedString:[[NSAttributedString alloc] initWithString:@" "]];
        }
        [attrText appendAttributedString:[[NSAttributedString alloc] initWithString:author
                                                                       attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13],
                                                                                    NSForegroundColorAttributeName: [UIColor secondaryLabelColor]}]];
        self.authorLabel.attributedText = attrText;
    } else {
        self.authorLabel.text = localize(@"i18n_str_28", nil);
    }

    // --- 元信息行 ---
    [self rebuildMetaInfoStackWithDownloads:downloads likes:likes lastUpdated:lastUpdated];

    // --- 标签行 ---
    [self rebuildCategoriesStackWithCategories:categories];

    // --- 描述 ---
    NSString *desc = descriptionText.length > 0 ? descriptionText : localize(@"i18n_str_29", nil);
    self.descriptionLabel.text = desc;
    self.descriptionExpanded = NO;
    self.descriptionLabel.numberOfLines = 3;

    // 检测描述是否超过 3 行（决定是否显示展开按钮）
    [self evaluateDescriptionTruncation];

    // --- 封面图 ---
    [self loadIconFromURL:iconURL placeholderSymbolName:placeholderSymbolName placeholderColor:placeholderColor];
}

#pragma mark - Meta Info

/// 重建元信息行（下载量 / 关注量 / 最后更新）
- (void)rebuildMetaInfoStackWithDownloads:(nullable NSNumber *)downloads
                                    likes:(nullable NSNumber *)likes
                             lastUpdated:(nullable NSString *)lastUpdated {
    // 清空旧的
    [self.metaInfoStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    // 下载量
    if (downloads) {
        UIView *item = [self createMetaInfoItemWithSymbol:@"arrow.down.circle"
                                                    text:[self formatDownloadCount:downloads.integerValue]
                                               tintColor:[UIColor systemBlueColor]];
        [self.metaInfoStack addArrangedSubview:item];
    }

    // 关注量
    if (likes) {
        UIView *item = [self createMetaInfoItemWithSymbol:@"heart"
                                                    text:[self formatDownloadCount:likes.integerValue]
                                               tintColor:[UIColor systemPinkColor]];
        [self.metaInfoStack addArrangedSubview:item];
    }

    // 最后更新
    if (lastUpdated.length > 0) {
        UIView *item = [self createMetaInfoItemWithSymbol:@"clock"
                                                    text:[self formatDateString:lastUpdated]
                                               tintColor:[UIColor systemOrangeColor]];
        [self.metaInfoStack addArrangedSubview:item];
    }
}

/// 创建单个元信息项（SF Symbol + 文字，水平排列）
- (UIView *)createMetaInfoItemWithSymbol:(NSString *)symbolName
                                    text:(NSString *)text
                               tintColor:(UIColor *)tintColor {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIFontWeightMedium];
    UIImage *symbolImage = [UIImage systemImageNamed:symbolName withConfiguration:config] ?: [UIImage systemImageNamed:symbolName];

    UIImageView *iconView = [[UIImageView alloc] initWithImage:symbolImage];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.tintColor = tintColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = text;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;

    UIStackView *item = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, label]];
    item.translatesAutoresizingMaskIntoConstraints = NO;
    item.axis = UILayoutConstraintAxisHorizontal;
    item.spacing = 3;
    item.alignment = UIStackViewAlignmentCenter;

    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:15],
        [iconView.heightAnchor constraintEqualToConstant:15],
    ]];

    [item setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [item setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return item;
}

#pragma mark - Categories (标签 pill)

/// 重建标签行（自动换行：每行一个水平 stack，超过容器宽度则换行）
- (void)rebuildCategoriesStackWithCategories:(nullable NSArray<NSString *> *)categories {
    // 清空旧的
    [self.categoriesStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    if (![categories isKindOfClass:[NSArray class]] || categories.count == 0) return;

    // 估算可用宽度（卡片宽度 - 左右 padding 32pt）
    // 注意：此时 layout 可能尚未完成，用 cardContainer 的约束预估
    CGFloat availableWidth = MAX(self.bounds.size.width - 16 * 2 - 16 * 2, 200); // 左右各 16pt(card外) + 16pt(card内)

    UIStackView *currentLine = [self createCategoriesLineStack];
    CGFloat currentLineWidth = 0;
    CGFloat spacing = 6;

    for (NSString *category in categories) {
        if (![category isKindOfClass:[NSString class]] || category.length == 0) continue;

        UILabel *badge = [self createCategoryBadge:category];
        // sizeToFit 获取实际宽度
        [badge sizeToFit];
        CGFloat badgeWidth = badge.frame.size.width + 16; // + 左右 padding 各 8pt（已在 createCategoryBadge 中加，这里 sizeToFit 后重新算）
        // 修正：createCategoryBadge 内已设宽度约束，这里估算用约束前的 sizeToFit 宽度 + padding
        [badge invalidateIntrinsicContentSize];
        CGFloat estimateWidth = [badge systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].width;

        if (currentLineWidth + estimateWidth > availableWidth && currentLine.arrangedSubviews.count > 0) {
            // 当前行放不下，换行
            [self.categoriesStack addArrangedSubview:currentLine];
            currentLine = [self createCategoriesLineStack];
            currentLineWidth = 0;
        }

        [currentLine addArrangedSubview:badge];
        currentLineWidth += estimateWidth + spacing;
    }

    // 添加最后一行
    if (currentLine.arrangedSubviews.count > 0) {
        [self.categoriesStack addArrangedSubview:currentLine];
    }
}

/// 创建标签行的水平 stack
- (UIStackView *)createCategoriesLineStack {
    UIStackView *line = [[UIStackView alloc] init];
    line.axis = UILayoutConstraintAxisHorizontal;
    line.spacing = 6;
    line.alignment = UIStackViewAlignmentCenter;
    line.distribution = UIStackViewDistributionFill;
    return line;
}

/// 创建单个标签 pill（8pt 圆角，18pt 高，10pt bold 白字，按类别品牌色配色）
- (UILabel *)createCategoryBadge:(NSString *)category {
    UILabel *badge = [[UILabel alloc] init];
    badge.text = category;
    badge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    badge.textColor = [UIColor whiteColor];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = [self colorForCategory:category];
    badge.layer.cornerRadius = 8;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.layer.masksToBounds = YES;
    badge.translatesAutoresizingMaskIntoConstraints = NO;

    [badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [badge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    // 高度固定 18pt
    [NSLayoutConstraint activateConstraints:@[
        [badge.heightAnchor constraintEqualToConstant:18]
    ]];

    // 宽度 = 文字宽度 + 左右 padding 12pt
    [badge sizeToFit];
    CGFloat textWidth = badge.frame.size.width;
    [badge.widthAnchor constraintEqualToConstant:textWidth + 12].active = YES;
    return badge;
}

/// 类别名称 → 品牌色映射（加载器品牌色统一委托 ModLoaderIconHelper，类别色保持本地映射）
- (UIColor *)colorForCategory:(NSString *)category {
    NSString *lower = category.lowercaseString;

    // 加载器品牌色：统一委托 ModLoaderIconHelper（优先 PNG 图标的官方配色）
    if ([ModLoaderIconHelper isKnownLoader:category]) {
        return [ModLoaderIconHelper brandColorForLoader:category];
    }

    // 常见类别色
    if ([lower containsString:@"performance"])   return [UIColor colorWithRed:0.30 green:0.80 blue:0.40 alpha:1.0]; // 绿
    if ([lower containsString:@"optimization"])  return [UIColor colorWithRed:0.30 green:0.80 blue:0.40 alpha:1.0];
    if ([lower containsString:@"utility"])       return [UIColor colorWithRed:0.35 green:0.60 blue:0.85 alpha:1.0]; // 蓝
    if ([lower containsString:@"tech"])          return [UIColor colorWithRed:0.75 green:0.55 blue:0.20 alpha:1.0]; // 棕黄
    if ([lower containsString:@"magic"])         return [UIColor colorWithRed:0.65 green:0.40 blue:0.85 alpha:1.0]; // 紫
    if ([lower containsString:@"adventure"])     return [UIColor colorWithRed:0.80 green:0.45 blue:0.30 alpha:1.0]; // 橙红
    if ([lower containsString:@"worldgen"])      return [UIColor colorWithRed:0.40 green:0.70 blue:0.40 alpha:1.0]; // 绿
    if ([lower containsString:@"decoration"])    return [UIColor colorWithRed:0.90 green:0.55 blue:0.65 alpha:1.0]; // 粉
    if ([lower containsString:@"storage"])       return [UIColor colorWithRed:0.55 green:0.55 blue:0.60 alpha:1.0]; // 灰
    if ([lower containsString:@"food"])          return [UIColor colorWithRed:0.85 green:0.65 blue:0.30 alpha:1.0]; // 黄橙
    if ([lower containsString:@"transportation"]) return [UIColor colorWithRed:0.30 green:0.70 blue:0.80 alpha:1.0]; // 青
    if ([lower containsString:@"mobs"])          return [UIColor colorWithRed:0.80 green:0.35 blue:0.40 alpha:1.0]; // 红
    if ([lower containsString:@"equipment"])     return [UIColor colorWithRed:0.70 green:0.60 blue:0.45 alpha:1.0]; // 棕
    if ([lower containsString:@"social"])        return [UIColor colorWithRed:0.55 green:0.45 blue:0.75 alpha:1.0]; // 紫

    // 兜底：使用主题强调色（避免与背景融合）
    return [UIColor colorWithRed:0.45 green:0.55 blue:0.65 alpha:1.0];
}

#pragma mark - Description Expand/Collapse

/// 检测描述是否超过 3 行（决定是否显示展开按钮）
- (void)evaluateDescriptionTruncation {
    [self.descriptionLabel layoutIfNeeded];

    // 方法：比较 numberOfLines=0（无限）和 numberOfLines=3 时的高度
    // 若无限高度 > 3 行高度，说明被截断了
    CGFloat unlimitedHeight = [self calculateDescriptionHeightWithLines:0];
    CGFloat limitedHeight = [self calculateDescriptionHeightWithLines:3];

    self.descriptionTruncated = (unlimitedHeight > limitedHeight + 1);
    self.expandToggleButton.hidden = !self.descriptionTruncated;

    if (self.descriptionTruncated) {
        [self.expandToggleButton setTitle:localize(@"i18n_str_26", nil) forState:UIControlStateNormal];
    }
}

/// 计算描述 label 在指定行数限制下的高度
- (CGFloat)calculateDescriptionHeightWithLines:(NSInteger)lines {
    UILabel *measureLabel = [[UILabel alloc] init];
    measureLabel.font = self.descriptionLabel.font;
    measureLabel.numberOfLines = lines;
    measureLabel.text = self.descriptionLabel.text;
    measureLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    // 使用当前 descriptionLabel 的实际宽度
    CGFloat width = self.descriptionLabel.bounds.size.width;
    if (width <= 0) {
        // layout 未完成，用预估宽度（屏幕宽度 - 卡片内外边距）
        width = MAX([UIScreen mainScreen].bounds.size.width - 16 * 2 - 16 * 2, 200);
    }

    CGSize size = [measureLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    return size.height;
}

/// 切换描述展开/收起状态
- (void)toggleDescriptionExpanded {
    self.descriptionExpanded = !self.descriptionExpanded;
    self.descriptionLabel.numberOfLines = self.descriptionExpanded ? 0 : 3;
    [self.expandToggleButton setTitle:self.descriptionExpanded ? localize(@"i18n_str_2051", nil) : localize(@"i18n_str_26", nil) forState:UIControlStateNormal];

    // 通知控制器重新计算 tableHeaderView 高度
    if (self.onSizeChanged) {
        self.onSizeChanged();
    }
}

#pragma mark - Icon Loading

/// 加载项目封面图（使用 IconLoader 统一加载器）
/// 对应 ZL2 AssetsIcon 的 loadIcon 逻辑：双层缓存 + 降采样 + CDN 镜像 + 占位/兜底
- (void)loadIconFromURL:(nullable NSString *)iconURL
   placeholderSymbolName:(NSString *)symbolName
       placeholderColor:(UIColor *)color {
    // 先设置占位 SF Symbol（始终显示在底层，真实图加载成功后被覆盖）
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIFontWeightRegular];
    UIImage *placeholderSymbol = [UIImage systemImageNamed:symbolName withConfiguration:config] ?: [UIImage systemImageNamed:@"puzzlepiece.extension.fill" withConfiguration:config];
    self.placeholderSymbolView.image = placeholderSymbol;
    self.placeholderSymbolView.tintColor = color ?: [UIColor systemBlueColor];
    self.iconPlaceholderContainer.backgroundColor = [color ?: [UIColor systemBlueColor] colorWithAlphaComponent:0.18];

    // 无 URL 或非法 URL：iconImageView 保持透明，透出底层占位 SF Symbol
    if (!iconURL || iconURL.length == 0) {
        [IconLoader cancelLoadingForImageView:self.iconImageView];
        self.iconImageView.image = nil;
        return;
    }

    // 用 IconLoader 加载（自带内存+磁盘缓存+降采样+CDN镜像），placeholderImage=nil
    // 加载成功：iconImageView 显示真实图，覆盖下方占位 SF Symbol
    // 加载失败/加载中：iconImageView 为空（透明），透出下方占位 SF Symbol
    // 封面图显示尺寸 72x72（在 setupViews 中定义），降采样到此尺寸避免按原图解码
    [IconLoader loadIconForImageView:self.iconImageView
                                 URL:iconURL
                         placeholder:nil
                            fallback:nil
                           targetSize:CGSizeMake(72, 72)];
}

#pragma mark - Formatting Helpers

/// 格式化下载量（1234 → "1.2k"，1234567 → "1.2M"）
- (NSString *)formatDownloadCount:(NSInteger)count {
    if (count >= 1000000) {
        return [NSString stringWithFormat:@"%.1fM", count / 1000000.0];
    } else if (count >= 1000) {
        return [NSString stringWithFormat:@"%.1fk", count / 1000.0];
    }
    return [NSString stringWithFormat:@"%ld", (long)count];
}

/// 格式化日期字符串（ISO8601 → 短日期；非 ISO 则原样返回）
- (NSString *)formatDateString:(NSString *)dateString {
    if (dateString.length == 0) return @"";

    // 尝试 ISO8601 解析
    NSISO8601DateFormatter *isoFormatter = [[NSISO8601DateFormatter alloc] init];
    NSDate *date = [isoFormatter dateFromString:dateString];
    if (date) {
        NSDateFormatter *displayFormatter = [[NSDateFormatter alloc] init];
        displayFormatter.dateStyle = NSDateFormatterShortStyle;
        displayFormatter.timeStyle = NSDateFormatterNoStyle;
        return [displayFormatter stringFromDate:date];
    }

    // 非 ISO 格式，原样返回（可能是已格式化的日期）
    return dateString;
}

#pragma mark - Sizing

/// 计算并返回 header 在指定宽度下的适配高度
- (CGFloat)fittingHeightForWidth:(CGFloat)width {
    // 给一个足够大的高度，让自动布局自适应压缩
    self.frame = CGRectMake(0, 0, width, 10000);
    [self setNeedsLayout];
    [self layoutIfNeeded];

    CGSize size = [self systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                                         withHorizontalFittingPriority:UILayoutPriorityRequired
                                               verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    return ceil(size.height);
}

@end
