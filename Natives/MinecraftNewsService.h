//
//  MinecraftNewsService.h
//  Amethyst
//
//  Minecraft 官方新闻抓取服务
//  参考 PCL-CE (PCL.Core/ViewModel/Homepage/NewsViewModel.cs) 的实现：
//    - 数据源：https://net-secondary.web.minecraft-services.net/api/v1.0/{locale}/search
//    - 参数：pageSize=24&sortType=Recent&category=News&newsOnly=true&page=N
//    - 无需鉴权，仅需 User-Agent 头
//    - 图片/链接 URL 均为绝对地址，无需拼接前缀
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class MinecraftNewsItem;

/// 错误域
extern NSString * const MCNewsErrorDomain;

typedef NS_ENUM(NSInteger, MCNewsErrorCode) {
    MCNewsErrorCodeNetwork = 1,
    MCNewsErrorCodeParsing,
    MCNewsErrorCodeEmpty,
};

/// 单条新闻抓取完成回调
typedef void(^MCNewsFetchHandler)(NSArray<MinecraftNewsItem *> *items,
                                  NSInteger totalCount,
                                  NSError * _Nullable error);

@interface MinecraftNewsService : NSObject

+ (instancetype)sharedService;

/// 当前请求 locale（默认 zh-cn，跟随系统语言可在设置中切换）
@property (nonatomic, copy) NSString *locale;

/// 抓取新闻列表
/// @param page 页码（从 1 开始）
/// @param pageSize 每页条数（PCL-CE 用 24）
/// @param completion 主线程回调，items 为本页新闻数组，totalCount 为总条数
- (void)fetchNewsWithPage:(NSInteger)page
                 pageSize:(NSInteger)pageSize
               completion:(MCNewsFetchHandler)completion;

/// 便捷抓取首页新闻（page=1, pageSize=24）
- (void)fetchLatestNewsWithCompletion:(MCNewsFetchHandler)completion;

/// 链接安全检查（参考 PCL-CE IsSafeNewsLink）
/// 仅允许 minecraft.net / minecraft-services.net / microsoft.com 三个域及其子域
+ (BOOL)isSafeNewsLink:(NSString *)urlString;

@end

NS_ASSUME_NONNULL_END
