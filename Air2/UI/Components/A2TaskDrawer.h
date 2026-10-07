//
//  A2TaskDrawer.h
//  Air2
//
//  底部任务抽屉 —— 显示正在进行的下载/安装任务。
//
//  收起时：一条 56pt 的窄条，显示当前任务与进度
//  展开时：露出完整任务列表，可暂停/取消
//
//  用底部而非侧边（ZL2 是左侧滑出 30% 宽的面板）：
//  手机单手操作时底部更易触及，且不遮挡内容。
//

#import <UIKit/UIKit.h>
#import "A2ProgressView.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2TaskDrawer : UIView

/// 收起态高度，默认 56
@property (nonatomic, assign) CGFloat collapsedHeight;
/// 展开态高度，默认 280
@property (nonatomic, assign) CGFloat expandedHeight;

/// 当前是否展开
@property (nonatomic, assign, readonly, getter=isExpanded) BOOL expanded;

/// 由宿主设置的高度约束（供外部拖拽调整）
@property (nonatomic, strong, nullable) NSLayoutConstraint *heightConstraint;

/// 添加一个任务视图
- (void)addTaskView:(A2TaskProgressView *)taskView;

/// 移除任务视图（带收起动画）
- (void)removeTaskView:(A2TaskProgressView *)taskView;

/// 设置收起态显示的主标题与进度
- (void)setSummaryTitle:(NSString *)title progress:(CGFloat)progress speed:(nullable NSString *)speed;

/// 展开 / 收起
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;

/// 没有任务时自动隐藏
- (void)updateVisibility;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
