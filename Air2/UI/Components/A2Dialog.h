//
//  A2Dialog.h
//  Air2
//
//  Material Design 3 弹窗 —— 替代系统 UIAlertController。
//
//  ## 为什么要自己写
//
//  系统 UIAlertController 在 iOS 上是「居中小圆角白卡片 +
//  蓝色文字按钮」，与 Air2 的 MD3 视觉（大圆角、容器色阶、
//  主色填充按钮、无边框）完全不搭。57 个地方在用它，
//  每一处都是视觉上的破绽。
//
//  ## MD3 规格（对照 Material 3 Dialogs）
//
//    容器：圆角 28、色 surfaceContainerHigh、内边距 24
//    标题：headlineSmall（24sp semibold）、色 onSurface
//    正文：bodyMedium（14sp）、色 onSurfaceVariant
//    按钮：文字按钮，主色 cPrimary；破坏性操作用 cError
//    动作区右对齐，按钮间距 8
//    遮罩：黑色 32% 不透明
//    进场：缩放 0.85 → 1.0 + 淡入，spring(0.78)
//
//  ## 用法
//
//    [A2Dialog showInView:self.view
//                   title:@"确认删除"
//                 message:@"删除后无法恢复"
//                 actions:@[
//                     [A2DialogAction actionWithTitle:@"取消" style:A2DialogActionStyleText handler:nil],
//                     [A2DialogAction actionWithTitle:@"删除" style:A2DialogActionStyleDestructive handler:^{ ... }]
//                 ]];
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2DialogActionStyle) {
    A2DialogActionStyleText = 0,     ///< 主色文字按钮
    A2DialogActionStyleFilled,       ///< 主色填充按钮（强调操作用）
    A2DialogActionStyleDestructive,  ///< 错误色文字按钮（删除等）
};

@interface A2DialogAction : NSObject
+ (instancetype)actionWithTitle:(NSString *)title
                          style:(A2DialogActionStyle)style
                        handler:(nullable void (^)(void))handler;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, assign, readonly) A2DialogActionStyle style;
@property (nonatomic, copy, nullable, readonly) void (^handler)(void);
@end

@interface A2Dialog : UIView

/// 弹出（挂在指定视图上，覆盖全屏）
+ (instancetype)showInView:(UIView *)host
                     title:(nullable NSString *)title
                   message:(nullable NSString *)message
                   actions:(NSArray<A2DialogAction *> *)actions;

/// 带自定义内容的弹窗（例如分辨率设置、选项列表）
+ (instancetype)showInView:(UIView *)host
                     title:(nullable NSString *)title
                   message:(nullable NSString *)message
               contentView:(nullable UIView *)contentView
                   actions:(NSArray<A2DialogAction *> *)actions;

- (void)dismiss;

@end

NS_ASSUME_NONNULL_END
