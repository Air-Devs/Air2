//
//  A2SettingsRow.h
//  Air2
//
//  设置项行 —— 设置页与各种配置页的通用单元格。
//  支持：纯文字、带副标题、带右侧值、带开关、带箭头、带自定义右侧视图。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2SettingsRowAccessory) {
    A2SettingsRowAccessoryNone = 0,
    A2SettingsRowAccessoryDisclosure,   ///< 右箭头，可进入下级
    A2SettingsRowAccessorySwitch,       ///< 开关
    A2SettingsRowAccessoryCheckmark,    ///< 选中勾
    A2SettingsRowAccessoryCustom,       ///< 自定义右侧视图
};

@interface A2SettingsRow : UIView

/// 图标（SF Symbol 名），可选
@property (nonatomic, copy, nullable) NSString *symbolName;
/// 图标底色，可选。为空时用主题主色。
@property (nonatomic, strong, nullable) UIColor *symbolColor;

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, copy, nullable) NSString *valueText;

@property (nonatomic, assign) A2SettingsRowAccessory accessory;
@property (nonatomic, strong, nullable) UIView *customAccessoryView;

/// 开关状态（accessory 为 Switch 时有效）
@property (nonatomic, assign, getter=isOn) BOOL on;
/// 开关变化回调
@property (nonatomic, copy, nullable) void (^onToggle)(BOOL isOn);

/// 点击回调（非开关行）
@property (nonatomic, copy, nullable) void (^onTap)(void);

/// 是否显示顶部分隔线（用于同组内的行）
@property (nonatomic, assign) BOOL showsTopSeparator;
/// 是否显示底部分隔线
@property (nonatomic, assign) BOOL showsBottomSeparator;

/// 危险样式（红色文字，用于删除类操作）
@property (nonatomic, assign, getter=isDestructive) BOOL destructive;

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
