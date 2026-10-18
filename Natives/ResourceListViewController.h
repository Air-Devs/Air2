//
//  ResourceListViewController.h
//  Amethyst
//
//  资源管理列表页公共基类（继承 UIViewController）
//  供 Mod / Shader / ResourcePack / DataPack / World / Modpack 六个资源管理界面复用，
//  统一提供：毛玻璃背景、胶囊搜索栏、无边框卡片表格、空/加载三态、
//  批量选择模式底部工具栏、连锁进场动画。
//
//  子类职责：设置 tableView.dataSource/delegate、注册并返回自己的 Cell
//  （建议继承 ResourceCardTableViewCell）、实现 heightForRow 与卡片间距
//  （可用 +cardSpacingHeaderView / ResourceListCardSpacing）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 卡片之间的垂直间距（子类在 heightForHeaderInSection 中返回此值，
/// 并在 viewForHeaderInSection 中返回 +cardSpacingHeaderView，实现无边框卡片间隔）
FOUNDATION_EXPORT CGFloat const ResourceListCardSpacing;

/// 卡片距屏幕左右的边距（基类已应用在 tableView 的左右约束上）
FOUNDATION_EXPORT CGFloat const ResourceListCardSideInset;

@interface ResourceListViewController : UIViewController

#pragma mark - 基础视图（基类构建，子类只读访问）

@property (nonatomic, strong, readonly) UITableView *tableView;
@property (nonatomic, strong, readonly) UISearchBar *searchBar;

#pragma mark - 便利初始化

/// 便利初始化：页面标题 + 资源类型 SF Symbol / 语义色（作为空状态默认图标与类型标识）
- (instancetype)initWithTitle:(NSString *)title
              resourceTypeIcon:(nullable NSString *)icon
                    iconColor:(nullable UIColor *)color;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property (nonatomic, copy, readonly) NSString *pageTitle;
@property (nonatomic, copy, readonly, nullable) NSString *resourceTypeIcon;
@property (nonatomic, strong, readonly, nullable) UIColor *resourceTypeIconColor;

#pragma mark - 三态（空 / 加载）

/// 显示空状态（图标未传时回退到初始化时的资源类型图标；actionTitle 为空则不显示引导按钮）
- (void)showEmptyStateWithIcon:(nullable NSString *)sfSymbol
                      iconColor:(nullable UIColor *)color
                        message:(NSString *)message
                   actionTitle:(nullable NSString *)actionTitle
                 actionHandler:(nullable void (^)(void))handler;
- (void)hideEmptyState;
- (void)setLoading:(BOOL)loading;

#pragma mark - 连锁进场动画

/// 首屏 ≤10 个 cell 连锁进场：每项延迟 50ms 从 -40pt 滑入 + 淡入（Spring 0.85 阻尼）
- (void)animateCellsInChain;

#pragma mark - 批量选择模式

/// 进入/退出批量选择模式：表格进入编辑（勾选）模式，底部工具栏滑入/滑出
- (void)setSelectMode:(BOOL)enabled;
@property (nonatomic, assign, readonly) BOOL selectModeEnabled;
/// 当前勾选的 indexPath（UITableView 编辑模式多选结果）
@property (nonatomic, copy, readonly) NSArray<NSIndexPath *> *selectedIndexPaths;

/// 批量选择模式底部工具栏（含全选/取消按钮 + batchActionStack）
@property (nonatomic, strong, readonly) UIView *batchToolbar;
/// 批量操作按钮区（子类把"删除选中"等具体操作按钮 addArrangedSubview 进来）
@property (nonatomic, strong, readonly) UIStackView *batchActionStack;

/// 选择模式切换钩子（子类重写以填充/清理 batchActionStack 中的操作按钮）
- (void)selectModeDidChange:(BOOL)enabled;

/// 勾选数量变化钩子（子类重写以同步"已选 N 个"等 UI）；
/// 在全选/取消全选（含进出选择模式时的勾选清理）后触发。
/// 单行点选的勾选增删不会经过此处，子类请在
/// tableView:didSelectRowAtIndexPath:/didDeselectRowAtIndexPath: 中自行处理。
- (void)selectionDidChange;

#pragma mark - 卡片间距辅助

/// 透明间距 header 视图（配合 heightForHeaderInSection 返回 ResourceListCardSpacing 使用）
+ (UIView *)cardSpacingHeaderView;

#pragma mark - 数据重新加载钩子

/// 子类重写此方法实现自己的列表重载（如 loadMods / refreshLocalShadersList）。
/// 基类在以下时机自动调用：
///   1. viewWillAppear（从下载页等返回时）
///   2. DownloadTaskManagerTaskCompletedNotification（资源下载完成，文件已落盘）
/// 关键修复（下载成功后资源管理页不刷新）：此前子类仅在 viewDidLoad 加载一次，
/// 下载完成后无法感知文件变化而页面不更新。
- (void)reloadResourceList;

@end

NS_ASSUME_NONNULL_END
