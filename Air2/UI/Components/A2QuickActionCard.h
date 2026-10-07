//
//  A2QuickActionCard.h
//  Air2
//
//  主页快捷操作卡片 —— 图标 + 标题的方形玻璃卡。
//

#import "A2GlassCard.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2QuickActionCard : A2GlassCard

- (instancetype)initWithTitle:(NSString *)title symbolName:(NSString *)symbolName;

@property (nonatomic, copy) NSString *title;
/// SF Symbol 名
@property (nonatomic, copy) NSString *symbolName;

/// 点击回调
@property (nonatomic, copy, nullable) void (^onSelect)(void);

@end

NS_ASSUME_NONNULL_END
