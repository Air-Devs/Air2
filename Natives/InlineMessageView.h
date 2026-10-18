//
//  InlineMessageView.h
//  Amethyst
//
//  参照 FCL/ZL2 的内联消息显示，替代 UIAlertController 弹窗
//  在内容区中央显示加载/错误/成功/信息状态，不阻塞用户操作
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, InlineMessageType) {
    InlineMessageTypeLoading,  // 加载中（带转圈，不自动消失）
    InlineMessageTypeError,    // 错误（红色，不自动消失，需手动关闭）
    InlineMessageTypeSuccess,  // 成功（绿色，1.5s 后自动消失）
    InlineMessageTypeInfo,     // 信息（蓝色，1.5s 后自动消失）
};

@interface InlineMessageView : UIView

/// 当前显示的消息类型
@property (nonatomic, assign, readonly) InlineMessageType messageType;
/// 点击消息视图的回调（可选，用于 loading 类型提供"查看详情"等入口）
@property (nonatomic, copy, nullable) void (^onTap)(void);
/// 点击关闭按钮的回调（可选，设置后会替代默认的 dismiss 行为，用于取消下载等场景）
@property (nonatomic, copy, nullable) void (^onClose)(void);
/// 是否显示关闭按钮（默认仅 error 类型显示）
@property (nonatomic, assign) BOOL showsCloseButton;

/// 在指定父视图上显示消息（自动布局到中央内容区）
+ (instancetype)showInViewController:(UIViewController *)vc
                             title:(NSString *)title
                          message:(nullable NSString *)message
                             type:(InlineMessageType)type;

/// 在指定父视图上显示消息（带关闭按钮选项）
+ (instancetype)showInViewController:(UIViewController *)vc
                             title:(NSString *)title
                          message:(nullable NSString *)message
                             type:(InlineMessageType)type
                  showsCloseButton:(BOOL)showsCloseButton;

/// 更新当前消息内容与类型
- (void)updateWithMessage:(NSString *)message type:(InlineMessageType)type;

/// 仅更新消息文本（保持当前类型）
- (void)updateMessage:(NSString *)message;

/// 关闭消息视图（带动画）
- (void)dismiss;

/// 关闭消息视图（无动画，立即移除）
- (void)dismissImmediately;

@end

NS_ASSUME_NONNULL_END
