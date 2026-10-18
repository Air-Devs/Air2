//
//  ThirdPartyLoginViewController.h
//  Amethyst
//
//  参照 FCL (Fold Craft Launcher) 安卓版：
//  LittleSkin 与自定义 Yggdrasil 第三方登录共用一个卡片式登录表单页，
//  替代原来的 UIAlertController 双字段输入。
//  - LittleSkin 模式：预设 authserver，仅显示用户名/密码
//  - 自定义模式：额外提供服务器地址输入框
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ThirdPartyLoginMode) {
    ThirdPartyLoginModeLittleSkin = 0, // 预设 LittleSkin 皮肤站
    ThirdPartyLoginModeCustom,         // 任意 Yggdrasil 兼容服务器
};

@interface ThirdPartyLoginViewController : UIViewController

/// 登录模式（决定是否显示服务器地址输入框及预设 authserver）
@property (nonatomic, assign) ThirdPartyLoginMode mode;

/// 登录完成回调：success=YES 时调用方应 pop 当前 VC 并触发账户列表刷新
@property (nonatomic, copy) void (^onLoginComplete)(BOOL success, NSString *_Nullable errorMessage);

@end

NS_ASSUME_NONNULL_END
