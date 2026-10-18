#import "UpdateDialogViewController.h"
#import "LauncherPreferences.h"
#import "utils.h"

#pragma mark - 本地强调色

/// 弹窗强调色。项目未提供全局 accentColor()，此处本地定义，
/// 避免隐式函数声明（Xcode 15/clang 下会直接编译失败）。
#pragma mark - 简易 Markdown 渲染

typedef NS_ENUM(NSInteger, AMEInlineKind) {
    AMEInlineKindBold = 1,
    AMEInlineKindCode = 2,
    AMEInlineKindLink = 3
};

static void AMECollectMarks(NSMutableArray *marks, NSString *line, NSString *pattern,
                           AMEInlineKind kind, NSUInteger textGroup, NSUInteger extraGroup) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    if (re == nil) return;
    NSArray *matches = [re matchesInString:line options:0 range:NSMakeRange(0, line.length)];
    for (NSTextCheckingResult *m in matches) {
        NSRange textRange = [m rangeAtIndex:textGroup];
        if (textRange.location == NSNotFound) continue;
        NSString *text = [line substringWithRange:textRange];
        NSString *extra = @"";
        if (extraGroup > 0) {
            NSRange extraRange = [m rangeAtIndex:extraGroup];
            if (extraRange.location != NSNotFound) {
                extra = [line substringWithRange:extraRange];
            }
        }
        [marks addObject:@{
            @"range": [NSValue valueWithRange:m.range],
            @"kind": @(kind),
            @"text": text,
            @"extra": extra
        }];
    }
}

/// 行内标记：**加粗**、`代码`、[文字](链接)
static NSAttributedString *AMEInlineAttributedString(NSString *line, UIFont *baseFont, UIColor *baseColor) {
    UIFont *boldFont = [UIFont boldSystemFontOfSize:baseFont.pointSize];
    UIFont *monoFont = [UIFont monospacedSystemFontOfSize:baseFont.pointSize - 1.0 weight:UIFontWeightRegular];

    NSMutableArray *marks = [NSMutableArray array];
    AMECollectMarks(marks, line, @"\\*\\*(.+?)\\*\\*", AMEInlineKindBold, 1, 0);
    AMECollectMarks(marks, line, @"__(.+?)__", AMEInlineKindBold, 1, 0);
    AMECollectMarks(marks, line, @"`(.+?)`", AMEInlineKindCode, 1, 0);
    AMECollectMarks(marks, line, @"\\[([^\\]]+)\\]\\(([^)]+)\\)", AMEInlineKindLink, 1, 2);

    [marks sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSUInteger la = [a[@"range"] rangeValue].location;
        NSUInteger lb = [b[@"range"] rangeValue].location;
        if (la < lb) return NSOrderedAscending;
        if (la > lb) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    NSDictionary *attrs = @{NSFontAttributeName: baseFont, NSForegroundColorAttributeName: baseColor};

    NSUInteger cursor = 0;
    for (NSDictionary *mark in marks) {
        NSRange r = [mark[@"range"] rangeValue];
        if (r.location < cursor) continue; /* 与已处理区间重叠，跳过 */
        if (r.location > cursor) {
            NSString *plain = [line substringWithRange:NSMakeRange(cursor, r.location - cursor)];
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:plain attributes:attrs]];
        }
        NSMutableDictionary *markAttrs = [attrs mutableCopy];
        AMEInlineKind kind = (AMEInlineKind)[mark[@"kind"] integerValue];
        if (kind == AMEInlineKindBold) {
            markAttrs[NSFontAttributeName] = boldFont;
        } else if (kind == AMEInlineKindCode) {
            markAttrs[NSFontAttributeName] = monoFont;
            if (@available(iOS 13.0, *)) {
                markAttrs[NSBackgroundColorAttributeName] = [UIColor tertiarySystemFillColor];
            } else {
                markAttrs[NSBackgroundColorAttributeName] = [UIColor colorWithWhite:0.9 alpha:1.0];
            }
        } else if (kind == AMEInlineKindLink) {
            NSString *urlStr = mark[@"extra"];
            NSURL *url = [NSURL URLWithString:urlStr];
            if (url != nil) {
                markAttrs[NSLinkAttributeName] = url;
                markAttrs[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
            }
            markAttrs[NSForegroundColorAttributeName] = accentColor();
        }
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:mark[@"text"] attributes:markAttrs]];
        cursor = NSMaxRange(r);
    }
    if (cursor < line.length) {
        NSString *tail = [line substringFromIndex:cursor];
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:tail attributes:attrs]];
    }
    return out;
}

/// 把 release body（Markdown）渲染成可显示的富文本。
/// 只处理最常见的几种语法：标题、无序列表、引用、分割线，以及上面的行内标记。
static NSAttributedString *AMERenderMarkdown(NSString *markdown, UIFont *bodyFont, UIColor *bodyColor) {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    if (markdown.length == 0) return result;

    NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];
    NSArray *lines = [markdown componentsSeparatedByCharactersInSet:newlines];
    BOOL inCodeBlock = NO;

    for (NSString *rawLine in lines) {
        NSString *line = rawLine;
        /* 代码块：整段按等宽原样输出，不做行内解析 */
        if ([line hasPrefix:@"```"]) {
            inCodeBlock = !inCodeBlock;
            continue;
        }
        if (inCodeBlock) {
            UIFont *mono = [UIFont monospacedSystemFontOfSize:bodyFont.pointSize - 1.0 weight:UIFontWeightRegular];
            NSDictionary *attrs = @{NSFontAttributeName: mono, NSForegroundColorAttributeName: bodyColor};
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:attrs]];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:attrs]];
            continue;
        }

        NSString *content = line;
        NSString *bullet = @"";
        UIFont *font = bodyFont;
        UIColor *color = bodyColor;

        /* 标题 */
        NSUInteger headingLevel = 0;
        while (headingLevel < 6 && [content hasPrefix:@"#"]) {
            headingLevel++;
            content = [content substringFromIndex:1];
        }
        if (headingLevel > 0) {
            content = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            CGFloat sizes[] = {22.0, 19.0, 17.0, 15.0, 14.0, 14.0};
            font = [UIFont boldSystemFontOfSize:sizes[headingLevel - 1]];
        } else if ([content hasPrefix:@"- "] || [content hasPrefix:@"* "]) {
            /* 无序列表 */
            content = [content substringFromIndex:2];
            bullet = @"•  ";
        } else if ([content hasPrefix:@"> "]) {
            /* 引用 */
            content = [content substringFromIndex:2];
            bullet = @"│ ";
            color = [UIColor secondaryLabelColor];
        } else if ([content isEqualToString:@"---"] || [content isEqualToString:@"***"] ||
                   [content isEqualToString:@"___"]) {
            /* 分割线 */
            NSMutableAttributedString *rule = [[NSMutableAttributedString alloc] initWithString:@"────────────\n"
                attributes:@{NSFontAttributeName: bodyFont,
                             NSForegroundColorAttributeName: [UIColor separatorColor]}];
            [result appendAttributedString:rule];
            continue;
        }

        NSMutableAttributedString *lineAttr = [[NSMutableAttributedString alloc] init];
        if (bullet.length > 0) {
            [lineAttr appendAttributedString:[[NSAttributedString alloc] initWithString:bullet
                attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}]];
        }
        [lineAttr appendAttributedString:AMEInlineAttributedString(content, font, color)];
        [lineAttr appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}]];
        [result appendAttributedString:lineAttr];
    }
    return result;
}

#pragma mark - UpdateDialogViewController

@interface UpdateDialogViewController ()
@property(nonatomic, strong) UpdateInfo *info;
@property(nonatomic, strong) UIView *containerView;
@end

@implementation UpdateDialogViewController

+ (instancetype)dialogWithInfo:(UpdateInfo *)info {
    UpdateDialogViewController *vc = [[UpdateDialogViewController alloc] init];
    vc.info = info;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    return vc;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    [self buildContainer];
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (void)buildContainer {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        container.backgroundColor = [UIColor secondarySystemBackgroundColor];
    } else {
        container.backgroundColor = [UIColor whiteColor];
    }
    container.layer.cornerRadius = 14.0;
    container.layer.cornerCurve = kCACornerCurveContinuous;   // ★ [CORNER-FIX] 连续圆角(与系统卡片一致)
    container.clipsToBounds = YES;
    [self.view addSubview:container];
    self.containerView = container;

    // ★ [ISSUE-90] 小屏(SE 320×568 / 6s 375×667)弹窗宽度必须夹在屏内：
    //   原式 MAX(320, MIN(520, view.w-80)) 在 320 屏上会把容器顶到 320pt(=整屏宽,左右留白归零)，
    //   375 屏上顶到 320(=只剩 27.5pt 边距，也比设计意图的 40pt 窄)。
    //   改为：先取设计上限 maxWidth，再夹到 [280, view.w-32] ⇒ 任何机型都不越界、且保留可读最小宽。
    CGFloat maxWidth = MIN(520.0, CGRectGetWidth(self.view.bounds) - 80.0);
    CGFloat maxHeight = MIN(560.0, CGRectGetHeight(self.view.bounds) - 60.0);
    CGFloat safeW = CGRectGetWidth(self.view.bounds) - 32.0;     // ★ [ISSUE-90] 左右各至少 16pt
    if (safeW < 1.0) safeW = CGRectGetWidth(self.view.bounds);
    CGFloat dialogWidth = MIN(MAX(280.0, maxWidth), safeW);      // ★ [ISSUE-90]

    [NSLayoutConstraint activateConstraints:@[
        [container.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [container.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [container.widthAnchor constraintEqualToConstant:dialogWidth],
        [container.heightAnchor constraintLessThanOrEqualToConstant:MAX(280.0, maxHeight)]
    ]];

    /* 顶部：标题 + 版本号 + 发布时间 */
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [UIFont boldSystemFontOfSize:19.0];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.text = localize(@"update_dialog.title", @"New version available");
    titleLabel.numberOfLines = 1;

    UILabel *versionLabel = [[UILabel alloc] init];
    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    versionLabel.font = [UIFont systemFontOfSize:13.0];
    versionLabel.textColor = [UIColor secondaryLabelColor];
    versionLabel.numberOfLines = 2;
    versionLabel.text = [self versionSubtitle];

    /* 中间：可滚动的更新日志 */
    UITextView *textView = [[UITextView alloc] init];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.editable = NO;
    textView.selectable = YES;
    textView.dataDetectorTypes = UIDataDetectorTypeLink;
    textView.backgroundColor = [UIColor clearColor];
    textView.alwaysBounceVertical = YES;
    textView.textContainerInset = UIEdgeInsetsMake(8, 12, 8, 12);
    textView.attributedText = AMERenderMarkdown(self.info.releaseNotes ?: @"",
                                                [UIFont systemFontOfSize:14.0],
                                                [UIColor labelColor]);

    UIView *topSeparator = [[UIView alloc] init];
    topSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    topSeparator.backgroundColor = [UIColor separatorColor];

    UIView *bottomSeparator = [[UIView alloc] init];
    bottomSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    bottomSeparator.backgroundColor = [UIColor separatorColor];

    /* 底部按钮 */
    UIButton *ignoreButton = [self makeButtonWithTitle:localize(@"update_dialog.ignore", @"Ignore this version")
                                                 prominent:NO
                                                action:@selector(onIgnoreTapped)];
    UIButton *laterButton = [self makeButtonWithTitle:localize(@"update_dialog.later", @"Later")
                                                prominent:NO
                                               action:@selector(onLaterTapped)];
    UIButton *updateButton = [self makeButtonWithTitle:localize(@"update_dialog.update", @"Update")
                                                 prominent:YES
                                                action:@selector(onUpdateTapped)];

    UIStackView *buttonStack = [[UIStackView alloc] initWithArrangedSubviews:@[ignoreButton, laterButton, updateButton]];
    buttonStack.translatesAutoresizingMaskIntoConstraints = NO;
    buttonStack.axis = UILayoutConstraintAxisHorizontal;
    buttonStack.distribution = UIStackViewDistributionFillEqually;
    buttonStack.spacing = 8.0;

    UIStackView *mainStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, versionLabel]];
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    mainStack.axis = UILayoutConstraintAxisVertical;
    mainStack.spacing = 4.0;

    [container addSubview:mainStack];
    [container addSubview:topSeparator];
    [container addSubview:textView];
    [container addSubview:bottomSeparator];
    [container addSubview:buttonStack];

    [NSLayoutConstraint activateConstraints:@[
        [mainStack.topAnchor constraintEqualToAnchor:container.topAnchor constant:16.0],
        [mainStack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:18.0],
        [mainStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-18.0],

        [topSeparator.topAnchor constraintEqualToAnchor:mainStack.bottomAnchor constant:12.0],
        [topSeparator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [topSeparator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [topSeparator.heightAnchor constraintEqualToConstant:1.0],

        [textView.topAnchor constraintEqualToAnchor:topSeparator.bottomAnchor],
        [textView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [textView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [bottomSeparator.topAnchor constraintEqualToAnchor:textView.bottomAnchor],
        [bottomSeparator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [bottomSeparator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [bottomSeparator.heightAnchor constraintEqualToConstant:1.0],

        [buttonStack.topAnchor constraintEqualToAnchor:bottomSeparator.bottomAnchor constant:12.0],
        [buttonStack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:18.0],
        [buttonStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-18.0],
        [buttonStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16.0],
        [buttonStack.heightAnchor constraintEqualToConstant:40.0],

        [textView.heightAnchor constraintGreaterThanOrEqualToConstant:120.0]
    ]];
}

- (UIButton *)makeButtonWithTitle:(NSString *)title
                            prominent:(BOOL)prominent
                           action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *config = (prominent == YES)
            ? [UIButtonConfiguration filledButtonConfiguration]
            : [UIButtonConfiguration plainButtonConfiguration];
        config.title = title;
        button.configuration = config;
    } else {
        [button setTitle:title forState:UIControlStateNormal];
        if (prominent == YES) {
            button.backgroundColor = accentColor();
            button.layer.cornerRadius = 8.0;
            button.layer.cornerCurve = kCACornerCurveContinuous;   // ★ [CORNER-FIX] 连续圆角(与系统卡片一致)
            [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        }
    }
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.8;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (NSString *)versionSubtitle {
    NSString *version = self.info.latestVersion ?: @"";
    NSString *current = self.info.currentVersion ?: @"";
    NSString *published = [self formattedPublishedAt];

    NSString *base;
    if (current.length > 0) {
        base = [NSString stringWithFormat:localize(@"update_dialog.version_from",
                                                    @"%@  (current: %@)"), version, current];
    } else {
        base = version;
    }
    if (published.length > 0) {
        return [NSString stringWithFormat:@"%@\n%@", base, published];
    }
    return base;
}

- (NSString *)formattedPublishedAt {
    NSString *raw = self.info.publishedAt;
    if (raw.length == 0) return @"";
    NSISO8601DateFormatter *parser = [[NSISO8601DateFormatter alloc] init];
    NSDate *date = [parser dateFromString:raw];
    if (date == nil) return @"";
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterNoStyle;
    NSString *dateStr = [formatter stringFromDate:date];
    if (dateStr.length == 0) return @"";
    return [NSString stringWithFormat:localize(@"update_dialog.published_at", @"Published %@"), dateStr];
}

#pragma mark - Actions

- (void)onIgnoreTapped {
    NSString *version = self.info.latestVersion ?: @"";
    if (version.length > 0) {
        [UpdateChecker skipVersion:version];
    }
    if (self.onSkipped) self.onSkipped(version);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onLaterTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onUpdateTapped {
    __weak typeof(self) weakSelf = self;
    [self dismissViewControllerAnimated:YES completion:^{
        [UpdateChecker openReleasePageForInfo:weakSelf.info];
    }];
}

@end
