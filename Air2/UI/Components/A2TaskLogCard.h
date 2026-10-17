//
//  A2TaskLogCard.h
//  Air2
//
//  任务日志卡片 —— 对照 ZL2 的 ui/components/TaskLogCard.kt。
//
//  视觉（照搬 ZL2 的规格）：
//    ┌─────────────────────────────┐
//    │ 安装 1.20.1-fabric           │  标题（titleMedium 16pt）
//    ├─────────────────────────────┤
//    │ [12:34:56] 开始下载客户端      │  日志区
//    │ [12:34:58] 下载中 45%         │  surfaceContainer 底
//    │ [12:35:02] 解压依赖库…         │  8dp 圆角
//    │                             │  等宽字体 11pt
//    └─────────────────────────────┘  自动滚到最新
//

#import <UIKit/UIKit.h>
#import "A2TaskLogOutput.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2TaskLogCard : UIView

/// 绑定一个日志输出对象 —— 自动订阅其变化
@property (nonatomic, strong, nullable) A2TaskLogOutput *logOutput;

/// 是否自动跟随滚动到底部（用户手动上翻时应暂停跟随）
@property (nonatomic, assign) BOOL followScroll;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
