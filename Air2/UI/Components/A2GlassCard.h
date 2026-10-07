//
//  A2GlassCard.h
//  Air2
//
//  MD3 卡片 —— 界面基础容器。
//
//  用 surfaceContainer 的五档层级表达深度，而不是玻璃模糊。
//  理由：MD3 的表面体系本身就是分层的，用色值表达更可控；
//  模糊在卡片数量多时掉帧，且叠在用户自定义背景上色彩不可预测。
//  用户显式开启背景模糊时，卡片才会跟随。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 卡片层级，对应 MD3 的 surfaceContainer 档位
typedef NS_ENUM(NSInteger, A2CardElevation) {
    A2CardElevationSurface = 0,  ///< 最低，用于嵌在卡片内的条目
    A2CardElevationLow,          ///< 默认
    A2CardElevationHigh,         ///< 需要突出
    A2CardElevationHighest,      ///< 最高，用于弹层
};

@interface A2GlassCard : UIView

@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) UIEdgeInsets contentInsets;
@property (nonatomic, assign) A2CardElevation elevation;

/// 卡片自身是否跟随背景模糊，0~1。需要用户在设置里开启背景模糊才生效。
@property (nonatomic, assign) CGFloat blurAmount;

/// 可点击（会带按压缩放反馈）
@property (nonatomic, assign) BOOL tappable;
@property (nonatomic, copy, nullable) void (^onTap)(void);

/// 内容容器，往这里加子视图
@property (nonatomic, strong, readonly) UIView *contentView;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
