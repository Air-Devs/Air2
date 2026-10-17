#import <Foundation/Foundation.h>
#import "BaseAuthenticator.h"

@interface ThirdPartyAuthenticator : BaseAuthenticator

- (void)loginWithCallback:(Callback)callback;
- (void)refreshTokenWithCallback:(Callback)callback;
- (NSArray *)getJvmArgsForAuthlib;

/// 参照 authlib-injector 启动器技术规范解析 ALI（API Location Indication）
/// 将用户输入的简写地址解析为完整 API Root，并预取服务器元数据
/// completion 在主线程回调，resolvedURL 为最终 API Root（解析失败返回原始输入）
/// metadata 为服务器元数据 JSON 字符串（用于 prefetched 参数，失败为 nil）
+ (void)resolveAuthserverURL:(NSString *)inputURL
                  completion:(void (^)(NSString *resolvedURL, NSString *_Nullable metadata))completion;

@end