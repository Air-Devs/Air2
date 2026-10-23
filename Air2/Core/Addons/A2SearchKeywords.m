//
//  A2SearchKeywords.m
//  Air2
//

#import "A2SearchKeywords.h"

@implementation A2SearchKeywords

/// 中文 → 英文关键词表。
/// 选词原则：①玩家真会这么搜 ②英文词在两家源里都能命中 ③一词多义时给最常见的那个。
+ (NSDictionary<NSString *, NSString *> *)table {
    static NSDictionary<NSString *, NSString *> *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @{
            // 基础资源类型
            @"小地图": @"minimap",       @"地图": @"map",
            @"光影": @"shader",          @"着色器": @"shader",
            @"材质": @"resourcepack",    @"资源包": @"resourcepack",
            @"数据包": @"datapack",      @"整合包": @"modpack",
            @"前置": @"library",         @"库": @"library",
            @"优化": @"optimization",    @"性能": @"performance",
            @"汉化": @"translation",     @"中文": @"chinese",
            @"界面": @"gui",             @"背包": @"inventory",
            @"声音": @"sound",           @"音乐": @"music",
            @"字体": @"font",            @"按键": @"keybind",

            // 玩法/题材
            @"科技": @"tech",            @"工业": @"industrial",
            @"机械": @"create",          @"魔法": @"magic",
            @"农业": @"farming",         @"种田": @"farming",
            @"钓鱼": @"fishing",         @"建筑": @"building",
            @"装饰": @"decoration",      @"家具": @"furniture",
            @"武器": @"weapon",          @"盔甲": @"armor",
            @"工具": @"tool",            @"附魔": @"enchantment",
            @"生物": @"mob",             @"怪物": @"mob",
            @"怪物加强": @"mob difficulty",
            @"传送": @"teleport",        @"村庄": @"village",
            @"地牢": @"dungeon",         @"冒险": @"adventure",
            @"生存": @"survival",        @"创造": @"creative",
            @"食物": @"food",            @"农业机械": @"farming machine",
            @"拔刀剑": @"slashblade",

            // 载具/其它
            @"飞机": @"plane",           @"汽车": @"car",
            @"火车": @"train",           @"载具": @"vehicle",
            @"恐龙": @"dinosaur",        @"宠物": @"pet",
            @"服务器": @"server",        @"联机": @"multiplayer",
            @"皮肤": @"skin",            @"披风": @"cape",

            // 加载器（有时用户直接搜中文）
            @"锻造": @"forge",           @"插件": @"plugin",
        };
    });
    return t;
}

+ (BOOL)containsCJK:(NSString *)text {
    if (text.length == 0) return NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c >= 0x4E00 && c <= 0x9FFF) return YES;   // CJK 统一表意
    }
    return NO;
}

+ (NSString *)translateQuery:(NSString *)query {
    if (query.length == 0 || ![self containsCJK:query]) return query;

    NSMutableString *rest = [query mutableCopy];
    NSMutableArray<NSString *> *english = [NSMutableArray array];

    // 长词优先：避免「小地图」先被「地图」吃掉
    NSArray<NSString *> *keys = [[self table].allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return a.length > b.length ? NSOrderedAscending : (a.length < b.length ? NSOrderedDescending : NSOrderedSame);
    }];

    for (NSString *key in keys) {
        if ([rest containsString:key]) {
            [rest replaceOccurrencesOfString:key withString:@" " options:0 range:NSMakeRange(0, rest.length)];
            NSString *en = [self table][key];
            if (en.length && ![english containsObject:en]) [english addObject:en];
        }
    }

    // 剩余 ASCII（用户自己写的英文/版本号）保留
    NSString *leftover = [rest stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithArray:english];
    if (leftover.length > 0) {
        // 清掉中文残留，只留 ASCII
        NSMutableString *ascii = [NSMutableString string];
        for (NSUInteger i = 0; i < leftover.length; i++) {
            unichar c = [leftover characterAtIndex:i];
            [ascii appendFormat:@"%C", (c < 0x4E00 || c > 0x9FFF) ? c : (unichar)' '];
        }
        NSString *trimmed = [ascii stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length) [parts addObject:trimmed];
    }

    NSString *result = [parts componentsJoinedByString:@" "];
    result = [result stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    result = [result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return result.length ? result : query;
}

+ (NSArray<NSString *> *)matchedTermsInQuery:(NSString *)query {
    NSMutableArray *hits = [NSMutableArray array];
    if (query.length == 0) return hits;
    for (NSString *key in [self table]) {
        if ([query containsString:key]) {
            [hits addObject:[NSString stringWithFormat:@"%@→%@", key, [self table][key]]];
        }
    }
    return hits;
}

@end
