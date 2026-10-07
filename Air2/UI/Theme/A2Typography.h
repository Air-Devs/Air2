//
//  A2Typography.h
//  Air2
//
//  字体阶梯。用系统字体 + 明确的字号/字重组合，
//  不引入自定义字体（首包体积与中文字重覆盖都不划算）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2Typography : NSObject

/// 大标题 —— 页面主标题，如"版本管理"
+ (UIFont *)titleLarge;
/// 卡片标题
+ (UIFont *)titleCard;
/// 卡片副标题 / 次要信息
+ (UIFont *)subtitleCard;
/// 正文
+ (UIFont *)body;
/// 说明文字
+ (UIFont *)caption;
/// 按钮文字
+ (UIFont *)button;
/// 数字强调（进度、大小、时长）—— 等宽数字，避免跳动
+ (UIFont *)numeric;

@end

NS_ASSUME_NONNULL_END
