//
//  A2TaskLogCard.h
//  Air2
//
//  侧边任务进度卡片 —— 对照 ZL2 的 TaskLogCard。
//
//  ## 它出现在哪
//
//  不是弹窗、不是全屏遮罩，而是**挂在主界面旁边的一张小卡片**：
//
//    ┌──────────────────┐
//    │  任务菜单         │
//    │  ✗ 统计验证任务   │
//    │    ▓▓▓░░░        │
//    │                  │
//    │  （可展开日志）   │
//    └──────────────────┘
//
//  ## 为什么不用弹窗
//
//  启动前的检查（账号/版本/渲染器/插件）通常几秒就完成。
//  弹窗要遮挡整个界面、要点「取消」才能回退。
//  卡片只是「在旁边显示进展」，检查完自动消失，
//  用户全程可以继续操作界面。
//
//  ## 两种形态
//
//    收起：只有标题 + 一行任务 + 细进度条（约 80pt 高）
//    展开：多行任务 + 日志区（点标题展开）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2TaskCardState) {
    A2TaskCardStateRunning = 0,
    A2TaskCardStateSuccess,
    A2TaskCardStateFailed,
};

@class A2TaskLogOutput;

@interface A2TaskLogCard : UIView

/// 外部日志源（安装页会传进来，卡片自动订阅它的输出）
@property (nonatomic, strong, nullable) A2TaskLogOutput *logOutput;

/// 挂到宿主视图的右上角（自动布局）
+ (instancetype)presentInView:(UIView *)host title:(NSString *)title;

@property (nonatomic, copy, readonly) NSString *title;

/// 更新当前任务
- (void)updateTaskName:(NSString *)name
              progress:(double)progress   // 0~1，负数=不确定
                  rate:(nullable NSString *)rate;

/// 完成 / 失败
- (void)finishWithState:(A2TaskCardState)state message:(nullable NSString *)message;

/// 追加日志
- (void)appendLog:(NSString *)line;

/// 展开 / 收起日志区
- (void)toggleExpanded;

/// 淡出并移除
- (void)dismissAfterDelay:(NSTimeInterval)delay;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
