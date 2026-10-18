//
//  MinecraftNewsItem.m
//  Amethyst
//

#import "MinecraftNewsItem.h"

@implementation MinecraftNewsItem

/// HTML 实体反转义（处理 &amp; &lt; &gt; &quot; &#39; &apos; 等）
/// 参考 PCL-CE NewsViewModel 中 WebUtility.HtmlDecode(item.Description)
static NSString *MCNews_HTMLEntityDecode(NSString *input) {
    if (input.length == 0) return @"";
    NSMutableString *result = [input mutableCopy];
    [result replaceOccurrencesOfString:@"&amp;" withString:@"&"
                               options:NSLiteralSearch range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&lt;" withString:@"<"
                               options:NSLiteralSearch range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&gt;" withString:@">"
                               options:NSLiteralSearch range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&quot;" withString:@"\""
                               options:NSLiteralSearch range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&#39;" withString:@"'"
                               options:NSLiteralSearch range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&apos;" withString:@"'"
                               options:NSLiteralSearch range:NSMakeRange(0, result.length)];
    return [result copy];
}

+ (instancetype)itemFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    MinecraftNewsItem *item = [[MinecraftNewsItem alloc] init];
    item.title = dict[@"title"] ?: @"";
    item.articleURL = dict[@"url"] ?: @"";
    // description 字段做 HTML 实体反转义
    NSString *desc = dict[@"description"] ?: @"";
    item.summary = MCNews_HTMLEntityDecode(desc);
    item.author = dict[@"author"];
    item.imageURL = dict[@"image"] ?: @"";
    item.imageAltText = dict[@"imageAltText"];
    // time 字段是 Unix 秒时间戳（数值类型）
    id timeValue = dict[@"time"];
    if ([timeValue isKindOfClass:[NSNumber class]]) {
        item.publishDate = [(NSNumber *)timeValue doubleValue];
    } else if ([timeValue isKindOfClass:[NSString class]]) {
        item.publishDate = [(NSString *)timeValue doubleValue];
    }
    item.newsType = dict[@"type"];
    item.locale = dict[@"locale"];
    return item;
}

- (NSString *)formattedDateString {
    if (self.publishDate <= 0) return @"";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:self.publishDate];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    fmt.dateStyle = NSDateFormatterMediumStyle;
    fmt.timeStyle = NSDateFormatterNoStyle;
    return [fmt stringFromDate:date];
}

@end
