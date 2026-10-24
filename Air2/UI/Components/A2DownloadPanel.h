//
//  A2DownloadPanel.h
//  Air2
//
//  下载侧边面板 —— 结合 FCL 的 DownloadSlidePanel 与 ZL2 的任务列表。
//
//  ## 为什么是侧边面板而不是全屏页
//
//  下载是**后台任务**。用户在主页浏览、装模组、调设置的时候，
//  进度应该一直可感知 —— 全屏页一旦 pop 掉就看不见了。
//
//  FCL 的做法：右下角一个可展开的滑出面板。
//  ZL2 的做法：居中弹窗（任务列表）。
//
//  我们取 FCL 的形态（不挡主界面）+ ZL2 的信息密度（速率/百分比/状态）。
//
//  ## 结构
//
//    ┌─────────────────────────┐  收起态：右下角小胶囊
//    │ ↓ 3 个任务 · 4.2 MB/s   │
//    └─────────────────────────┘
//              ↓ 点击
//    ┌───────────────────────────┐
//    │ 下载中 (3)       ⏸  ⨯     │  展开态：右侧滑出（宽 320）
//    ├───────────────────────────┤
//    │ Minecraft 26.3            │
//    │ ▓▓▓▓▓░░░░░  68%  4.2MB/s │
//    │ 正在下载依赖库 12/80       │
//    ├───────────────────────────┤
//    │ Fabric API 0.92           │
//    │ ▓▓▓░░░░░░░  31%  1.8MB/s │
//    ├───────────────────────────┤
//    │ OptiFine HD U I9          │
//    │ 待安装 · 点击安装          │   ← FCL 的设计
//    └───────────────────────────┘
//
//  ## MD3 视觉
//
//    胶囊容器：surfaceContainerHigh，圆角 24
//    面板：surfaceContainer，圆角 28（左上/左下）
//    进度条：4pt 高，主色填充，圆角 2
//    动作：文字按钮，主色
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 一个下载任务在面板里的展示数据
@interface A2DownloadPanelItem : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
/// 状态文字（「正在下载依赖库 12/80」）
@property (nonatomic, copy, nullable) NSString *statusText;
@property (nonatomic, assign) double progress;          ///< 0~1
@property (nonatomic, assign) double speedBytesPerSec;
/// 下载完成、等待用户点「安装」（FCL 的设计）
@property (nonatomic, assign, getter=isReadyToInstall) BOOL readyToInstall;
@property (nonatomic, assign, getter=hasFailed) BOOL failed;
@end

@protocol A2DownloadPanelDelegate <NSObject>
@optional
- (void)downloadPanelDidTapCancel:(A2DownloadPanelItem *)item;
- (void)downloadPanelDidTapInstall:(A2DownloadPanelItem *)item;
- (void)downloadPanelDidTapCancelAll;
@end

@interface A2DownloadPanel : UIView

+ (instancetype)attachToView:(UIView *)host;

@property (nonatomic, weak, nullable) id<A2DownloadPanelDelegate> delegate;

/// 整批任务（覆盖式更新，面板自己算汇总）
- (void)updateItems:(NSArray<A2DownloadPanelItem *> *)items;

/// 展开 / 收起
@property (nonatomic, assign, readonly, getter=isExpanded) BOOL expanded;
- (void)expand;
- (void)collapse;

/// 没有任何任务时自动隐藏（收成一个不占位的状态）
@property (nonatomic, assign) BOOL autoHideWhenEmpty;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
