//
//  A2LogViewController.m
//  Air2
//
//  「运行日志」页。默认显示 ★本次会话日志★（A2Log → Documents/lastlog.txt）——
//  判据行（[A2-PAIRPIN] / [RXPC] / [FRAME] / [MEM]）都落在那一份：Air2 侧走
//  +[A2Log criterion:]，native 侧走 a2_log_criterion，两侧共用同一个落盘函数
//  （见 A2Log.h 头部说明）。控制台归档（Documents/latestlog.txt，stderr 的去处）
//  与它一起导出 —— native 里裸写的 NSLog 只出现在那一份。
//

#import "A2LogViewController.h"
#import "A2GlassCard.h"
#import "A2PrimaryButton.h"
#import "A2Toast.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2Log.h"

@interface A2LogViewController ()
@property (nonatomic, strong) UITextView *logView;
/// 文件路径 / 大小 / 用法说明（「标明文件路径/大小」）
@property (nonatomic, strong) UILabel *metaLabel;
@end

@implementation A2LogViewController

- (void)viewDidLoad {
    // ★必须在 super 之前设★：基类在 viewDidLoad 里
    // 按 _usesScrollContent 决定建哪种内容容器（该 ivar 在 -init 里默认 YES）。
    // 设晚了基类已经建好滚动容器、_plainContentViewInternal 一直是 nil，
    // 于是 self.plainContentView 返回 nil，下面
    //   [self.plainContentView addSubview:…]      → 空操作，卡没进视图树
    //   [x.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor …]
    //   → 目标 anchor 是 nil，CoreAutoLayout 把它当成「把 NSLayoutYAxisAnchor
    //     约束到常量」并抛 NSInvalidArgumentException（真机日志：
    //     "A constraint cannot be made from <NSLayoutYAxisAnchor …A2GlassCard….top>
    //      to a constant. Location anchors require being paired."），
    //     随后进程 abort（信号 6）。
    // 其它 plain 页面（下载 / 设置 / 版本列表 / 选版页）都是这个顺序，别改回去。
    self.usesScrollContent = NO;
    [super viewDidLoad];
    self.pageTitle = @"运行日志";

    [self addTrailingButtonWithSymbol:@"square.and.arrow.up" action:^{
        [self exportLog];
    }];

    // ---- 路径 / 大小 / 用法 ----
    _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metaLabel.numberOfLines = 0;
    _metaLabel.font = [A2Typography caption];
    _metaLabel.text = [self metaText];

    // ---- 日志正文 ----
    A2GlassCard *card = [[A2GlassCard alloc] initWithFrame:CGRectZero];
    card.cornerRadius = A2RadiusXL;
    card.elevation = A2CardElevationLow;
    card.contentInsets = UIEdgeInsetsMake(A2SpaceM, A2SpaceM, A2SpaceM, A2SpaceM);
    card.translatesAutoresizingMaskIntoConstraints = NO;

    _logView = [[UITextView alloc] initWithFrame:CGRectZero];
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    _logView.editable = NO;
    _logView.backgroundColor = UIColor.clearColor;
    _logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.textContainerInset = UIEdgeInsetsZero;
    _logView.textContainer.lineFragmentPadding = 0;
    _logView.text = [self sessionLogText];

    [card.contentView addSubview:_logView];
    [self.plainContentView addSubview:_metaLabel];
    [self.plainContentView addSubview:card];

    [NSLayoutConstraint activateConstraints:@[
        [_metaLabel.topAnchor constraintEqualToAnchor:self.plainContentView.topAnchor
                                            constant:A2SpaceM],
        [_metaLabel.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                                constant:A2PageMargin],
        [_metaLabel.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                                 constant:-A2PageMargin],

        [card.topAnchor constraintEqualToAnchor:_metaLabel.bottomAnchor
                                       constant:A2SpaceM],
        [card.bottomAnchor constraintEqualToAnchor:self.plainContentView.bottomAnchor
                                          constant:-A2SpaceM],
        [card.leadingAnchor constraintEqualToAnchor:self.plainContentView.leadingAnchor
                                           constant:A2PageMargin],
        [card.trailingAnchor constraintEqualToAnchor:self.plainContentView.trailingAnchor
                                            constant:-A2PageMargin],

        [_logView.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [_logView.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [_logView.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [_logView.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
    ]];

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// 日志是边跑边长的：从别的页面切回来要看到最新那一行。
/// （判据行的用法就是「点一下按钮 → 回本页看那一行 → 导出」。）
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadLog];
}

#pragma mark - 内容

/// 读当前会话日志。没有日志时给出明确提示，而不是空白页。
- (NSString *)sessionLogText {
    NSString *path = [A2Log currentLogPath];
    NSString *content = path.length
        ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]
        : nil;
    if (content.length > 0) {
        return content;
    }
    return @"暂无日志。\n\n本次会话还没有写过任何一行。启动器跑起来之后：\n"
            "· Documents/lastlog.txt —— 会话日志（判据行 [A2-PAIRPIN]/[RXPC]/[FRAME]/[MEM] 都在这里）\n"
            "· Documents/latestlog.txt —— 控制台归档（native 层裸写的 NSLog 只在这里）";
}

/// 两个文件的路径 + 大小 + 一句话说明。
/// 路径按沙盒口径显示（真机绝对路径又长又带随机容器 UUID，看不全也没意义）。
- (NSString *)metaText {
    NSString *session = [A2Log currentLogPath];
    NSString *console = [A2Log consoleLogPath];
    return [NSString stringWithFormat:
            @"会话日志：%@（%@）\n控制台归档：%@（%@）\n"
            @"判据行形如 [A2-PAIRPIN] / [RXPC] / [FRAME] / [MEM]；右上角一次导出上面两份。",
            [self displayPath:session], [self sizeTextForPath:session],
            [self displayPath:console], [self sizeTextForPath:console]];
}

- (NSString *)displayPath:(NSString *)path {
    if (path.length == 0) { return @"（不可用）"; }
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                              NSUserDomainMask, YES).firstObject;
    if (documents.length > 0 && [path hasPrefix:documents]) {
        return [@"Documents" stringByAppendingString:[path substringFromIndex:documents.length]];
    }
    return path.lastPathComponent ?: path;
}

- (NSString *)sizeTextForPath:(NSString *)path {
    NSDictionary *attributes = path.length
        ? [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil]
        : nil;
    if (attributes == nil) { return @"尚未生成"; }
    return [NSByteCountFormatter stringFromByteCount:(long long)[attributes[NSFileSize] longLongValue]
                                           countStyle:NSByteCountFormatterCountStyleFile];
}

- (void)reloadLog {
    _logView.text = [self sessionLogText];
    _metaLabel.text = [self metaText];
}

#pragma mark - 导出

/// 导出：把 ①会话日志 ②控制台归档 折成一个文本文件交给系统分享
/// （AirDrop / 存到「文件」/ 直接发出去）。折文件的实现放在 A2Log
/// （与「打包整个日志目录」是同一类职责），本页只做调用与呈现。
- (void)exportLog {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"Air2-log-%@.txt",
                      [formatter stringFromDate:[NSDate date]]];
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:name];

    NSError *error = nil;
    if (![A2Log exportCombinedLogToPath:tmp error:&error]) {
        [A2Toast show:(error.localizedDescription ?: @"导出失败") inView:self.view];
        return;
    }
    [self presentShareForFile:tmp];
}

- (void)presentShareForFile:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *vc =
        [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                          applicationActivities:nil];
    vc.popoverPresentationController.sourceView = self.view;
    vc.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                             CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    _logView.textColor = t.cOnSurfaceVariant;
    _metaLabel.textColor = t.cOnSurfaceVariant;
}

@end
