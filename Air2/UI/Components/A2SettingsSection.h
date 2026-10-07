//
//  A2SettingsSection.h
//  Air2
//
//  设置分组 —— 毛玻璃容器 + 标题 + 若干 A2SettingsRow。
//  行与行之间自动处理分隔线，最后一行不带底部分隔线。
//

#import <UIKit/UIKit.h>
#import "A2GlassCard.h"
#import "A2SettingsRow.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2SettingsSection : A2GlassCard

- (instancetype)initWithTitle:(NSString *)title;

@property (nonatomic, copy, nullable) NSString *sectionTitle;
/// 分组底部的说明文字
@property (nonatomic, copy, nullable) NSString *footerText;

/// 添加一行。自动处理分隔线。
- (void)addRow:(A2SettingsRow *)row;

/// 添加自定义视图（非行内容）
- (void)addCustomView:(UIView *)view;

@property (nonatomic, strong, readonly) NSArray<A2SettingsRow *> *rows;

@end

NS_ASSUME_NONNULL_END
