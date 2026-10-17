//
//  A2InstallProgressDialog.h
//  Air2
//
//  安装进度弹窗 —— **严格对照 ZL2 的 CommonElements.kt**。
//
//  ZL2 的实现（TitleTaskFlowDialog + TaskFlowListColumn + InstallingTaskItem）：
//
//    TitleTaskFlowDialog(title, tasks, onCancel, logOutput)
//      Dialog(Surface: extraLarge 圆角, 阴影 6, padding 16, 间距 16)
//        ├─ logOutput == nil → TaskFlowListColumn（单列，用系统默认宽）
//        └─ logOutput != nil → Row(1:1)
//                ├─ 左：TaskFlowListColumn
//                └─ 右：TaskLogCard
//        └─ Button「取消」(fillMaxWidth)
//
//    高度：heightIn(max) + wrapContentHeight（不超上限就自适应）
//    宽度：有日志时 fillMaxWidth(0.8f)
//
//  InstallingTaskItem：
//    Row(间距 8, 垂直居中)
//      ├─ Icon(24dp) —— PREPARING: clock / RUNNING: download / COMPLETED: check
//      └─ Column(weight 1)
//           ├─ 标题 labelLarge
//           └─ 仅 RUNNING:
//                ├─ message labelMedium（top 4）
//                └─ Row: LinearProgress(weight 1) + 速率 + 百分比
//
//  **关键：taskProgress < 0 表示不确定进度** —— 用转圈，不显示百分比。
//

#import <UIKit/UIKit.h>
@class A2TaskLogOutput;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2ProgressStepStage) {
    A2ProgressStepStagePreparing = 0,   ///< 未开始（clock）
    A2ProgressStepStageRunning,         ///< 进行中（download）
    A2ProgressStepStageCompleted,       ///< 已完成（check）
};

@interface A2InstallProgressDialog : UIViewController

/// 传入 logOutput 则右侧多一列日志（宽度 80%）；
/// 传 nil 走单列（系统默认宽）。
- (instancetype)initWithLogOutput:(nullable A2TaskLogOutput *)logOutput;

@property (nonatomic, copy) NSString *dialogTitle;

/// 设置步骤（安装开始时调一次）
- (void)setSteps:(NSArray<NSString *> *)stepTitles;

/// 更新某一步。
/// @param progress 0~1；**传负数表示不确定进度**（转圈，不显示百分比）
/// @param rate 速率字符串（如 "2.4 MB/s"），可为 nil
- (void)updateStepAtIndex:(NSInteger)index
                    stage:(A2ProgressStepStage)stage
                  message:(nullable NSString *)message
                 progress:(double)progress
                     rate:(nullable NSString *)rate;

@property (nonatomic, copy, nullable) void (^onCancel)(void);

- (void)dismissWithCompletion:(nullable void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
