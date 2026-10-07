//
//  A2Toast.h
//  Air2
//
//  轻提示 —— 短暂显示一句话，不打断操作。
//  用途限于「操作已触发」这类即时反馈；需要用户确认的一律用弹窗，不要用 Toast。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2Toast : NSObject

/// 在指定视图上显示提示，1.4 秒后自动消失
+ (void)show:(NSString *)message inView:(UIView *)view;

@end

NS_ASSUME_NONNULL_END
