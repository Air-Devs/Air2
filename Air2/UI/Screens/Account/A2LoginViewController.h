//
//  A2LoginViewController.h
//  Air2
//
//  三种登录方式共用一个页面，靠 mode 区分。
//  微软是「展示设备码 + 轮询」，其余是「表单输入」。
//

#import <UIKit/UIKit.h>
#import "A2BaseViewController.h"
#import "A2Account.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2LoginMode) {
    A2LoginModeMicrosoft = 0,
    A2LoginModeOffline,
    A2LoginModeThirdParty,
};

@interface A2LoginViewController : A2BaseViewController

- (instancetype)initWithMode:(A2LoginMode)mode;
/// 登录成功回调
@property (nonatomic, copy, nullable) void (^onSuccess)(A2Account *account);

@end

NS_ASSUME_NONNULL_END
