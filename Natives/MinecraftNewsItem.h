//
//  MinecraftNewsItem.h
//  Amethyst
//
//  Minecraft 官方新闻数据模型
//  参考 PCL-CE (PCL.Core/Model/Homepage/News/NewsItem.cs) 的字段定义
//
//  数据源：net-secondary.web.minecraft-services.net/api/v1.0/{locale}/search
//  字段映射：
//    title          -> title
//    url            -> articleURL (绝对地址，无需拼接)
//    description    -> summary (HTML 实体需反转义)
//    author         -> author
//    image          -> imageURL (绝对地址)
//    imageAltText   -> imageAltText
//    time           -> publishDate (Unix 秒时间戳)
//    type           -> newsType
//    locale         -> locale
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MinecraftNewsItem : NSObject

/// 文章标题
@property (nonatomic, copy) NSString *title;
/// 文章详情页 URL（绝对地址）
@property (nonatomic, copy) NSString *articleURL;
/// 摘要（API 返回 HTML 实体编码，已反转义）
@property (nonatomic, copy) NSString *summary;
/// 作者
@property (nonatomic, copy, nullable) NSString *author;
/// 封面图 URL（绝对地址）
@property (nonatomic, copy) NSString *imageURL;
/// 封面图 alt 文本
@property (nonatomic, copy, nullable) NSString *imageAltText;
/// 发布时间（Unix 秒时间戳）
@property (nonatomic, assign) NSTimeInterval publishDate;
/// 类型（如 "News"）
@property (nonatomic, copy, nullable) NSString *newsType;
/// 区域（如 "zh-cn"）
@property (nonatomic, copy, nullable) NSString *locale;

/// 从 API 返回的字典构造（字段缺失时使用空串兜底）
+ (instancetype)itemFromDictionary:(NSDictionary *)dict;

/// 格式化为本地日期字符串（如 "2026-07-16"）
- (NSString *)formattedDateString;

@end

NS_ASSUME_NONNULL_END
