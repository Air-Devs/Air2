//
//  A2HomeLayout.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  自定义主页模型实现。见 A2HomeLayout.h 顶部的三条不变式。
//

#import "A2HomeLayout.h"

#import "A2Log.h"
#import <math.h>

NSInteger const A2HomeSchemaVersion = 1;
NSInteger const A2HomeMaxColumns = 3;
CGFloat const A2HomeCardMinWidth = 300.0;
CGFloat const A2HomeCardRowHeight = 168.0;
CGFloat const A2HomeGridGap = 12.0;   // = A2CardSpacing（M3 卡片间距 token）
NSInteger const A2HomeMaxPositionRow = 512;

#pragma mark - 纯函数

NSString *A2HomeCardKindToken(A2HomeCardKind kind) {
    switch (kind) {
        case A2HomeCardKindGreeting:        return @"greeting";
        case A2HomeCardKindRecent:          return @"recent";
        case A2HomeCardKindCalendar:        return @"calendar";
        case A2HomeCardKindPinnedVersions:  return @"pinnedVersions";
        case A2HomeCardKindPinnedWorlds:    return @"pinnedWorlds";
        case A2HomeCardKindPinnedServers:   return @"pinnedServers";
        case A2HomeCardKindShortcutVersion: return @"shortcutVersion";
        case A2HomeCardKindShortcutWorld:   return @"shortcutWorld";
        case A2HomeCardKindShortcutServer:  return @"shortcutServer";
        case A2HomeCardKindShortcutCustom:  return @"shortcutCustom";
    }
    return @"greeting";
}

BOOL A2HomeCardKindFromToken(NSString *token, A2HomeCardKind *out) {
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSInteger k = A2HomeCardKindGreeting; k <= A2HomeCardKindShortcutCustom; k++) {
            d[A2HomeCardKindToken((A2HomeCardKind)k)] = @(k);
        }
        map = d.copy;
    });
    NSNumber *n = map[token];
    if (!n) return NO;
    if (out) *out = (A2HomeCardKind)n.integerValue;
    return YES;
}

NSString *A2HomeCardSizeToken(A2HomeCardSize size) {
    switch (size) {
        case A2HomeCardSizeOneByOne:  return @"1x1";
        case A2HomeCardSizeTwoByOne:  return @"2x1";
        case A2HomeCardSizeOneByTwo:  return @"1x2";
        case A2HomeCardSizeTwoByTwo:  return @"2x2";
        case A2HomeCardSizeThreeByOne: return @"3x1";
        case A2HomeCardSizeThreeByTwo: return @"3x2";
    }
    return @"1x1";
}

BOOL A2HomeCardSizeFromToken(NSString *token, A2HomeCardSize *out) {
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSInteger s = A2HomeCardSizeOneByOne; s <= A2HomeCardSizeThreeByTwo; s++) {
            d[A2HomeCardSizeToken((A2HomeCardSize)s)] = @(s);
        }
        map = d.copy;
    });
    NSNumber *n = map[token];
    if (!n) return NO;
    if (out) *out = (A2HomeCardSize)n.integerValue;
    return YES;
}

A2HomeSpan A2HomeSpanForSize(A2HomeCardSize size) {
    switch (size) {
        case A2HomeCardSizeOneByOne:   return (A2HomeSpan){1, 1};
        case A2HomeCardSizeTwoByOne:   return (A2HomeSpan){2, 1};
        case A2HomeCardSizeOneByTwo:   return (A2HomeSpan){1, 2};
        case A2HomeCardSizeTwoByTwo:   return (A2HomeSpan){2, 2};
        case A2HomeCardSizeThreeByOne: return (A2HomeSpan){3, 1};
        case A2HomeCardSizeThreeByTwo: return (A2HomeSpan){3, 2};
    }
    return (A2HomeSpan){1, 1};
}

NSArray<NSNumber *> *A2HomeSizesForKind(A2HomeCardKind kind) {
    switch (kind) {
        case A2HomeCardKindGreeting:
            return @[@(A2HomeCardSizeTwoByOne), @(A2HomeCardSizeThreeByOne)];
        case A2HomeCardKindRecent:
            return @[@(A2HomeCardSizeTwoByTwo), @(A2HomeCardSizeThreeByTwo)];
        case A2HomeCardKindCalendar:
            return @[@(A2HomeCardSizeOneByTwo), @(A2HomeCardSizeTwoByTwo)];
        case A2HomeCardKindPinnedVersions:
        case A2HomeCardKindPinnedWorlds:
        case A2HomeCardKindPinnedServers:
            return @[@(A2HomeCardSizeOneByOne), @(A2HomeCardSizeTwoByOne),
                     @(A2HomeCardSizeOneByTwo), @(A2HomeCardSizeTwoByTwo)];
        case A2HomeCardKindShortcutVersion:
        case A2HomeCardKindShortcutWorld:
        case A2HomeCardKindShortcutServer:
        case A2HomeCardKindShortcutCustom:
            return @[@(A2HomeCardSizeOneByOne), @(A2HomeCardSizeTwoByOne)];
    }
    return @[@(A2HomeCardSizeOneByOne)];
}

A2HomeCardSize A2HomeDefaultSizeForKind(A2HomeCardKind kind) {
    switch (kind) {
        case A2HomeCardKindGreeting:        return A2HomeCardSizeThreeByOne;
        case A2HomeCardKindRecent:          return A2HomeCardSizeTwoByTwo;
        case A2HomeCardKindCalendar:        return A2HomeCardSizeOneByTwo;
        case A2HomeCardKindPinnedVersions:  return A2HomeCardSizeTwoByTwo;
        case A2HomeCardKindPinnedWorlds:    return A2HomeCardSizeTwoByTwo;
        case A2HomeCardKindPinnedServers:   return A2HomeCardSizeTwoByTwo;
        case A2HomeCardKindShortcutVersion:
        case A2HomeCardKindShortcutWorld:
        case A2HomeCardKindShortcutServer:
        case A2HomeCardKindShortcutCustom:  return A2HomeCardSizeOneByOne;
    }
    return A2HomeCardSizeOneByOne;
}

BOOL A2HomeKindRequiresTarget(A2HomeCardKind kind) {
    return kind == A2HomeCardKindShortcutVersion
        || kind == A2HomeCardKindShortcutWorld
        || kind == A2HomeCardKindShortcutServer;
}

BOOL A2HomeKindIsSingleton(A2HomeCardKind kind) {
    return kind == A2HomeCardKindGreeting || kind == A2HomeCardKindCalendar;
}

/// 收藏存档 / 收藏服务器：Air2 目前只有「版本置顶」这一处钉选存储，
/// 存档与服务器还没有可被钉选的字段 ⇒ 这两种卡不提供新建入口
/// （已导入的旧卡片仍按模型保留，渲染为「暂不可用」，不静默删卡）。
BOOL A2HomeKindIsAvailable(A2HomeCardKind kind) {
    return kind != A2HomeCardKindPinnedWorlds && kind != A2HomeCardKindPinnedServers;
}

NSString *A2HomeKindDisplayName(A2HomeCardKind kind) {
    switch (kind) {
        case A2HomeCardKindGreeting:        return @"问候";
        case A2HomeCardKindRecent:          return @"最近游玩";
        case A2HomeCardKindCalendar:        return @"日历";
        case A2HomeCardKindPinnedVersions:  return @"收藏版本";
        case A2HomeCardKindPinnedWorlds:    return @"收藏存档";
        case A2HomeCardKindPinnedServers:   return @"收藏服务器";
        case A2HomeCardKindShortcutVersion: return @"版本快捷";
        case A2HomeCardKindShortcutWorld:   return @"存档快捷";
        case A2HomeCardKindShortcutServer:  return @"服务器快捷";
        case A2HomeCardKindShortcutCustom:  return @"自定义卡片";
    }
    return @"卡片";
}

NSString *A2HomeKindSummary(A2HomeCardKind kind) {
    switch (kind) {
        case A2HomeCardKindGreeting:        return @"按时段问候 + 一句话";
        case A2HomeCardKindRecent:          return @"最近玩过的版本，点一下就能启动";
        case A2HomeCardKindCalendar:        return @"今天的日期与本月";
        case A2HomeCardKindPinnedVersions:  return @"版本页里置顶过的版本";
        case A2HomeCardKindPinnedWorlds:    return @"此版本暂不可用（存档钉选未接入）";
        case A2HomeCardKindPinnedServers:   return @"此版本暂不可用（服务器钉选未接入）";
        case A2HomeCardKindShortcutVersion: return @"盯住一个版本，一键启动";
        case A2HomeCardKindShortcutWorld:   return @"盯住一个存档";
        case A2HomeCardKindShortcutServer:  return @"盯住一台服务器";
        case A2HomeCardKindShortcutCustom:  return @"自定图标与标题，跳到内置页或网址";
    }
    return @"";
}

NSString *A2HomeKindSymbolName(A2HomeCardKind kind) {
    switch (kind) {
        case A2HomeCardKindGreeting:        return @"hand.wave.fill";
        case A2HomeCardKindRecent:          return @"clock.arrow.circlepath";
        case A2HomeCardKindCalendar:        return @"calendar";
        case A2HomeCardKindPinnedVersions:  return @"pin.fill";
        case A2HomeCardKindPinnedWorlds:    return @"map.fill";
        case A2HomeCardKindPinnedServers:   return @"network";
        case A2HomeCardKindShortcutVersion: return @"cube.fill";
        case A2HomeCardKindShortcutWorld:   return @"globe";
        case A2HomeCardKindShortcutServer:  return @"server.rack";
        case A2HomeCardKindShortcutCustom:  return @"link";
    }
    return @"square.grid.2x2";
}

NSInteger A2HomeColumnCountForWidth(CGFloat width) {
    if (width <= 0) return 1;
    NSInteger n = (NSInteger)floor((width + A2HomeGridGap) / (A2HomeCardMinWidth + A2HomeGridGap));
    if (n < 1) n = 1;
    if (n > A2HomeMaxColumns) n = A2HomeMaxColumns;
    return n;
}

A2HomeSpan A2HomeSpanCompressedToColumns(A2HomeSpan span, NSInteger columns) {
    NSInteger maxCols = MAX((NSInteger)1, columns);
    A2HomeSpan out = span;
    // 只压列、不压行：窄屏下 2x1 变「1 宽 × 1 高」，行数保持档位值。
    out.columns = MIN(MAX((NSInteger)1, span.columns), maxCols);
    out.rows = MAX((NSInteger)1, span.rows);
    return out;
}

NSString *A2HomeNormalizedServerAddress(NSString *address) {
    NSString *s = [(address ?: @"") stringByTrimmingCharactersInSet:
                   NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if (s.length == 0) return @"";
    // 去掉默认端口（"host:25565" 与 "host" 视为同一台）。
    if ([s hasSuffix:@":25565"]) s = [s substringToIndex:s.length - 6];
    return s;
}

#pragma mark - 自定义卡片的跳转目标

NSInteger const A2HomeCustomTitleMaxLength = 24;

NSString *A2HomeJumpKindToken(A2HomeJumpKind kind) {
    return (kind == A2HomeJumpKindURL) ? @"url" : @"page";
}

A2HomeJumpKind A2HomeJumpKindFromToken(NSString *token) {
    return [token isEqualToString:@"url"] ? A2HomeJumpKindURL : A2HomeJumpKindPage;
}

NSArray<NSNumber *> *A2HomeJumpPagesAll(void) {
    static NSArray<NSNumber *> *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[@(A2HomeJumpPageVersions), @(A2HomeJumpPageVersionSettings), @(A2HomeJumpPageDownload),
                 @(A2HomeJumpPageAccount), @(A2HomeJumpPageMultiplayer), @(A2HomeJumpPageFiles),
                 @(A2HomeJumpPageSettings)];
    });
    return list;
}

NSString *A2HomeJumpPageToken(A2HomeJumpPage page) {
    switch (page) {
        case A2HomeJumpPageVersions:        return @"versions";
        case A2HomeJumpPageVersionSettings: return @"versionSettings";
        case A2HomeJumpPageDownload:        return @"download";
        case A2HomeJumpPageAccount:         return @"account";
        case A2HomeJumpPageMultiplayer:     return @"multiplayer";
        case A2HomeJumpPageFiles:           return @"files";
        case A2HomeJumpPageSettings:        return @"settings";
        case A2HomeJumpPageUnknown:         break;
    }
    // Unknown 没有 token：写出时留给规范化处理后回默认（不写 @"unknown" 这种伪 token）。
    return @"";
}

A2HomeJumpPage A2HomeJumpPageFromToken(NSString *token) {
    for (NSNumber *number in A2HomeJumpPagesAll()) {
        A2HomeJumpPage page = (A2HomeJumpPage)number.integerValue;
        if ([A2HomeJumpPageToken(page) isEqualToString:token]) return page;
    }
    return A2HomeJumpPageUnknown;
}

NSString *A2HomeJumpPageDisplayName(A2HomeJumpPage page) {
    switch (page) {
        case A2HomeJumpPageVersions:        return @"版本列表";
        case A2HomeJumpPageVersionSettings: return @"版本设置";
        case A2HomeJumpPageDownload:        return @"下载";
        case A2HomeJumpPageAccount:         return @"账户";
        case A2HomeJumpPageMultiplayer:     return @"联机";
        case A2HomeJumpPageFiles:           return @"文件";
        case A2HomeJumpPageSettings:        return @"设置";
        case A2HomeJumpPageUnknown:         break;
    }
    return @"未知页面";
}

NSString *A2HomeJumpPageSymbolName(A2HomeJumpPage page) {
    switch (page) {
        case A2HomeJumpPageVersions:        return @"cube.fill";
        case A2HomeJumpPageVersionSettings: return @"slider.horizontal.3";
        case A2HomeJumpPageDownload:        return @"arrow.down.circle.fill";
        case A2HomeJumpPageAccount:         return @"person.crop.circle.fill";
        case A2HomeJumpPageMultiplayer:     return @"network";
        case A2HomeJumpPageFiles:           return @"folder.fill";
        case A2HomeJumpPageSettings:        return @"gearshape.fill";
        case A2HomeJumpPageUnknown:         break;
    }
    return @"questionmark.circle";
}

NSArray<NSString *> *A2HomeCustomSymbolChoices(void) {
    static NSArray<NSString *> *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 只收 iOS 15+ 都存在的符号；新增符号追加在末尾，不动已有顺序。
        list = @[@"link", @"arrow.down.circle.fill", @"cube.fill", @"person.crop.circle.fill",
                 @"network", @"folder.fill", @"gearshape.fill", @"globe",
                 @"star.fill", @"book.fill", @"gamecontroller.fill", @"map.fill"];
    });
    return list;
}

NSString *A2HomeCustomDefaultSymbol(void) {
    return @"link";
}

NSURL *A2HomeWebURLFromString(NSString *string) {
    NSString *trimmed = [(string ?: @"") stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return nil;
    NSURL *url = [NSURL URLWithString:trimmed];
    if (!url) return nil;
    NSString *scheme = url.scheme.lowercaseString;
    // 只放 http/https：自定义卡片是用户手写的跳转口，不许变成任意 scheme 的调用面。
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) return nil;
    if (url.host.length == 0) return nil;
    return url;
}


#pragma mark - 目标

@implementation A2HomeCardTarget

+ (instancetype)targetWithGameHome:(NSString *)gameHome
                       versionName:(NSString *)versionName
                         worldPath:(nullable NSString *)worldPath
                           address:(nullable NSString *)address
                     fallbackLabel:(NSString *)fallbackLabel {
    A2HomeCardTarget *t = [[A2HomeCardTarget alloc] init];
    t.gameHome = gameHome ?: @"";
    t.versionName = versionName ?: @"";
    t.worldPath = worldPath;
    t.address = address;
    t.fallbackLabel = fallbackLabel ?: versionName ?: @"";
    return t;
}

+ (nullable instancetype)targetFromJSONObject:(nullable id)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *d = json;
    NSString *gameHome = [d[@"gameHome"] isKindOfClass:NSString.class] ? d[@"gameHome"] : nil;
    NSString *versionName = [d[@"versionName"] isKindOfClass:NSString.class] ? d[@"versionName"] : nil;
    NSString *fallback = [d[@"fallbackLabel"] isKindOfClass:NSString.class] ? d[@"fallbackLabel"] : nil;
    // 三条都是必填：没有兜底名的引用不允许存在（实体没了就没法显示「它本来是什么」）。
    if (gameHome.length == 0 || versionName.length == 0 || fallback.length == 0) return nil;

    A2HomeCardTarget *t = [[A2HomeCardTarget alloc] init];
    t.gameHome = gameHome;
    t.versionName = versionName;
    t.fallbackLabel = fallback;
    NSString *worldPath = [d[@"worldPath"] isKindOfClass:NSString.class] ? d[@"worldPath"] : nil;
    t.worldPath = worldPath.length ? worldPath : nil;
    NSString *address = [d[@"address"] isKindOfClass:NSString.class] ? d[@"address"] : nil;
    t.address = address.length ? A2HomeNormalizedServerAddress(address) : nil;
    return t;
}

- (NSDictionary *)JSONObject {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"gameHome"] = self.gameHome ?: @"";
    d[@"versionName"] = self.versionName ?: @"";
    d[@"fallbackLabel"] = self.fallbackLabel ?: @"";
    if (self.worldPath.length) d[@"worldPath"] = self.worldPath;
    if (self.address.length) d[@"address"] = self.address;
    return d.copy;
}

- (id)copyWithZone:(nullable NSZone *)zone {
    A2HomeCardTarget *t = [[A2HomeCardTarget allocWithZone:zone] init];
    t.gameHome = self.gameHome;
    t.versionName = self.versionName;
    t.worldPath = self.worldPath;
    t.address = self.address;
    t.fallbackLabel = self.fallbackLabel;
    return t;
}

@end

#pragma mark - 选项

static NSString *const kOptMode = @"mode";
static NSString *const kOptText = @"text";
static NSString *const kOptFontSize = @"fontSize";
static NSString *const kOptLimit = @"limit";
/// 自定义卡片（shortcutCustom）。
static NSString *const kOptTitle = @"title";
static NSString *const kOptSymbol = @"symbol";
static NSString *const kOptJumpKind = @"jumpKind";
static NSString *const kOptJumpTarget = @"jumpTarget";

@implementation A2HomeCardOptions

- (instancetype)init {
    self = [super init];
    if (self) {
        _greetingMode = A2HomeGreetingModeAuto;
        _greetingText = @"";
        _greetingFontSize = 22;
        _recentLimit = 4;
        _customTitle = @"";
        _customSymbol = A2HomeCustomDefaultSymbol();
        _jumpKind = A2HomeJumpKindPage;
        _jumpPage = A2HomeJumpPageVersions;
        _jumpURLString = @"";
    }
    return self;
}

+ (instancetype)optionsFromJSONObject:(nullable id)json kind:(A2HomeCardKind)kind {
    A2HomeCardOptions *o = [[A2HomeCardOptions alloc] init];
    NSDictionary *d = [json isKindOfClass:NSDictionary.class] ? json : @{};

    NSMutableDictionary *unknown = [NSMutableDictionary dictionary];
    for (NSString *key in d) {
        BOOL known = NO;
        switch (kind) {
            case A2HomeCardKindGreeting:
                known = [key isEqualToString:kOptMode] || [key isEqualToString:kOptText]
                     || [key isEqualToString:kOptFontSize];
                break;
            case A2HomeCardKindRecent:
                known = [key isEqualToString:kOptLimit];
                break;
            case A2HomeCardKindShortcutCustom:
                known = [key isEqualToString:kOptTitle] || [key isEqualToString:kOptSymbol]
                     || [key isEqualToString:kOptJumpKind] || [key isEqualToString:kOptJumpTarget];
                break;
            default:
                known = NO;
                break;
        }
        if (!known) unknown[key] = d[key];   // 未识别参数原样保留，写回时合并
    }
    o.unknownOptions = unknown.count ? unknown.copy : nil;

    if (d[kOptMode] && [d[kOptMode] isKindOfClass:NSString.class]) {
        o.greetingMode = [d[kOptMode] isEqualToString:@"text"] ? A2HomeGreetingModeText
                                                              : A2HomeGreetingModeAuto;
    }
    if (d[kOptText] && [d[kOptText] isKindOfClass:NSString.class]) {
        NSString *t = [d[kOptText] stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length > 120) t = [t substringToIndex:120];
        o.greetingText = t;
    }
    NSNumber *fs = [d[kOptFontSize] isKindOfClass:NSNumber.class] ? d[kOptFontSize] : nil;
    if (fs) {
        NSInteger v = fs.integerValue;
        o.greetingFontSize = MIN(MAX(v, (NSInteger)16), (NSInteger)32);
    }
    NSNumber *limit = [d[kOptLimit] isKindOfClass:NSNumber.class] ? d[kOptLimit] : nil;
    if (limit) {
        NSInteger v = limit.integerValue;
        // 只接受 2/4/6/8，其余回默认 4（不做四舍五入，避免「用户没选过的档」出现）。
        o.recentLimit = (v == 2 || v == 4 || v == 6 || v == 8) ? v : 4;
    }

    // ---- 自定义卡片：标题 / 图标 / 跳转目标 ----
    if ([d[kOptTitle] isKindOfClass:NSString.class]) {
        NSString *t = [d[kOptTitle] stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length > (NSUInteger)A2HomeCustomTitleMaxLength) {
            t = [t substringToIndex:(NSUInteger)A2HomeCustomTitleMaxLength];
        }
        o.customTitle = t;
    }
    if ([d[kOptSymbol] isKindOfClass:NSString.class]) {
        NSString *symbol = d[kOptSymbol];
        // 白名单之外回默认：不让手改 JSON 写进任意字符串当符号名。
        o.customSymbol = [A2HomeCustomSymbolChoices() containsObject:symbol] ? symbol
                                                                            : A2HomeCustomDefaultSymbol();
    }
    if ([d[kOptJumpKind] isKindOfClass:NSString.class]) {
        o.jumpKind = A2HomeJumpKindFromToken(d[kOptJumpKind]);
    }
    if ([d[kOptJumpTarget] isKindOfClass:NSString.class]) {
        NSString *target = [d[kOptJumpTarget] stringByTrimmingCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (o.jumpKind == A2HomeJumpKindURL) {
            // 非法网址**不修不删**：留原串，渲染期按「跳转目标已失效」软失败。
            o.jumpURLString = target;
        } else {
            o.jumpPage = A2HomeJumpPageFromToken(target);
        }
    }
    return o;
}

- (NSDictionary *)JSONObjectForKind:(A2HomeCardKind)kind {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    switch (kind) {
        case A2HomeCardKindGreeting:
            d[kOptMode] = (self.greetingMode == A2HomeGreetingModeText) ? @"text" : @"auto";
            if (self.greetingText.length) d[kOptText] = self.greetingText;
            d[kOptFontSize] = @(self.greetingFontSize);
            break;
        case A2HomeCardKindRecent:
            d[kOptLimit] = @(self.recentLimit);
            break;
        case A2HomeCardKindShortcutCustom: {
            if (self.customTitle.length) d[kOptTitle] = self.customTitle;
            d[kOptSymbol] = self.customSymbol.length ? self.customSymbol : A2HomeCustomDefaultSymbol();
            d[kOptJumpKind] = A2HomeJumpKindToken(self.jumpKind);
            NSString *target = (self.jumpKind == A2HomeJumpKindURL) ? self.jumpURLString
                                                                    : A2HomeJumpPageToken(self.jumpPage);
            if (target.length) d[kOptJumpTarget] = target;
            break;
        }
        default:
            break;
    }
    for (NSString *key in self.unknownOptions) {
        if (d[key]) continue;          // 已知键以本版解释为准
        d[key] = self.unknownOptions[key];
    }
    return d.copy;
}

- (id)copyWithZone:(nullable NSZone *)zone {
    A2HomeCardOptions *o = [[A2HomeCardOptions allocWithZone:zone] init];
    o.greetingMode = self.greetingMode;
    o.greetingText = self.greetingText;
    o.greetingFontSize = self.greetingFontSize;
    o.recentLimit = self.recentLimit;
    o.unknownOptions = self.unknownOptions;
    o.customTitle = self.customTitle;
    o.customSymbol = self.customSymbol;
    o.jumpKind = self.jumpKind;
    o.jumpPage = self.jumpPage;
    o.jumpURLString = self.jumpURLString;
    return o;
}

- (BOOL)isJumpUsableWithReason:(NSString *_Nullable *_Nullable)outReason {
    if (self.jumpKind == A2HomeJumpKindURL) {
        if (A2HomeWebURLFromString(self.jumpURLString)) return YES;
        if (outReason) {
            *outReason = self.jumpURLString.length
                ? @"网址无效（只支持 http / https）"
                : @"还没设置网址";
        }
        return NO;
    }
    if (self.jumpPage != A2HomeJumpPageUnknown) return YES;
    if (outReason) *outReason = @"跳转目标已失效";
    return NO;
}

@end

#pragma mark - 卡片

@implementation A2HomeCard

- (instancetype)init {
    self = [super init];
    if (self) {
        _cardID = NSUUID.UUID.UUIDString;
        _options = [[A2HomeCardOptions alloc] init];
        _kind = A2HomeCardKindGreeting;
        _size = A2HomeCardSizeOneByOne;
    }
    return self;
}

+ (instancetype)cardWithKind:(A2HomeCardKind)kind {
    A2HomeCard *c = [[A2HomeCard alloc] init];
    c.kind = kind;
    c.size = A2HomeDefaultSizeForKind(kind);
    return c;
}

+ (nullable instancetype)cardFromJSONObject:(nullable id)json reason:(NSString *_Nullable *_Nullable)reason {
    void (^fail)(NSString *) = ^(NSString *why) {
        if (reason) *reason = why;
    };
    if (![json isKindOfClass:NSDictionary.class]) { fail(@"不是对象"); return nil; }
    NSDictionary *d = json;

    A2HomeCardKind kind = A2HomeCardKindGreeting;
    NSString *kindToken = [d[@"kind"] isKindOfClass:NSString.class] ? d[@"kind"] : @"";
    if (!A2HomeCardKindFromToken(kindToken, &kind)) { fail([NSString stringWithFormat:@"未知 kind『%@』", kindToken]); return nil; }

    A2HomeCard *c = [A2HomeCard cardWithKind:kind];

    NSString *cid = [d[@"id"] isKindOfClass:NSString.class] ? d[@"id"] : nil;
    if (cid.length) c.cardID = cid;   // 重复 id 由上层（方案级）重发

    // ---- target：引用类卡片逐项校验，缺一项就丢这张卡 ----
    if (A2HomeKindRequiresTarget(kind)) {
        A2HomeCardTarget *t = [A2HomeCardTarget targetFromJSONObject:d[@"target"]];
        if (!t) { fail(@"引用缺少 gameHome/versionName/fallbackLabel"); return nil; }
        if (kind == A2HomeCardKindShortcutWorld && t.worldPath.length == 0) {
            fail(@"存档卡缺少 worldPath"); return nil;
        }
        if (kind == A2HomeCardKindShortcutServer && t.address.length == 0) {
            fail(@"服务器卡缺少 address"); return nil;
        }
        c.target = t;
    }

    // ---- size：不在白名单就回该类型默认档（保卡）----
    A2HomeCardSize size = A2HomeDefaultSizeForKind(kind);
    NSString *sizeToken = [d[@"size"] isKindOfClass:NSString.class] ? d[@"size"] : @"";
    A2HomeCardSize parsed = size;
    if (A2HomeCardSizeFromToken(sizeToken, &parsed) && [A2HomeSizesForKind(kind) containsObject:@(parsed)]) {
        size = parsed;
    }
    c.size = size;

    // ---- options：按 kind 分支规范化，未知键保留 ----
    c.options = [A2HomeCardOptions optionsFromJSONObject:d[@"options"] kind:kind];

    // ---- position：非法则「丢坐标保卡」----
    id pos = d[@"position"];
    if ([pos isKindOfClass:NSDictionary.class]) {
        NSNumber *col = [((NSDictionary *)pos)[@"column"] isKindOfClass:NSNumber.class] ? ((NSDictionary *)pos)[@"column"] : nil;
        NSNumber *row = [((NSDictionary *)pos)[@"row"] isKindOfClass:NSNumber.class] ? ((NSDictionary *)pos)[@"row"] : nil;
        NSInteger columnValue = col.integerValue;
        NSInteger rowValue = row.integerValue;
        // 列上界用「起手列数的两倍」，行上界 512（坐标只用于自由布局，取值域要收得住）。
        if (col && row && columnValue >= 0 && columnValue <= A2HomeMaxColumns * 2
            && rowValue >= 0 && rowValue <= A2HomeMaxPositionRow) {
            c.hasPosition = YES;
            c.column = columnValue;
            c.row = rowValue;
        }
    }
    return c;
}

- (NSDictionary *)JSONObjectIncludingPosition:(BOOL)includePosition {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = self.cardID ?: NSUUID.UUID.UUIDString;
    d[@"kind"] = A2HomeCardKindToken(self.kind);
    d[@"size"] = A2HomeCardSizeToken(self.size);
    if (self.target) d[@"target"] = [self.target JSONObject];
    NSDictionary *opts = [self.options JSONObjectForKind:self.kind];
    if (opts.count) d[@"options"] = opts;
    if (includePosition && self.hasPosition) {
        d[@"position"] = @{@"column": @(self.column), @"row": @(self.row)};
    }
    return d.copy;
}

- (A2HomeSpan)span {
    return A2HomeSpanForSize(self.size);
}

- (id)copyWithZone:(nullable NSZone *)zone {
    A2HomeCard *c = [[A2HomeCard allocWithZone:zone] init];
    c.cardID = self.cardID;
    c.kind = self.kind;
    c.size = self.size;
    c.target = [self.target copy];
    c.options = [self.options copy];
    c.hasPosition = self.hasPosition;
    c.column = self.column;
    c.row = self.row;
    return c;
}

@end

#pragma mark - 方案

@implementation A2HomeProfile

+ (instancetype)defaultProfileWithID:(NSString *)profileID name:(NSString *)name {
    A2HomeProfile *p = [[A2HomeProfile alloc] init];
    p.profileID = profileID.length ? profileID : NSUUID.UUID.UUIDString;
    p.name = name.length ? name : @"默认";
    p.layout = A2HomeLayoutModeGrid;
    p.cards = [NSMutableArray array];

    // 顺序即布局：这里就是默认主页的视觉顺序。
    // 把 1x2 的日历排在 2x1 的收藏版本之前 —— 3 列下正好填满最近游玩右侧的空档
    // （见 docs/HOME-DESIGN.md §5.1 的装箱说明，别引 dense 回填）。
    A2HomeCard *greeting = [A2HomeCard cardWithKind:A2HomeCardKindGreeting];
    A2HomeCard *recent = [A2HomeCard cardWithKind:A2HomeCardKindRecent];
    A2HomeCard *calendar = [A2HomeCard cardWithKind:A2HomeCardKindCalendar];
    A2HomeCard *pinned = [A2HomeCard cardWithKind:A2HomeCardKindPinnedVersions];
    pinned.size = A2HomeCardSizeTwoByOne;
    [p.cards addObjectsFromArray:@[greeting, recent, calendar, pinned]];
    return p;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _profileID = NSUUID.UUID.UUIDString;
        _name = @"默认";
        _cards = [NSMutableArray array];
    }
    return self;
}

- (nullable A2HomeCard *)cardWithID:(NSString *)cardID {
    if (cardID.length == 0) return nil;
    for (A2HomeCard *c in self.cards) {
        if ([c.cardID isEqualToString:cardID]) return c;
    }
    return nil;
}

- (BOOL)containsKind:(A2HomeCardKind)kind {
    for (A2HomeCard *c in self.cards) {
        if (c.kind == kind) return YES;
    }
    return NO;
}

- (void)resetContentToDefaultCards {
    A2HomeProfile *fresh = [A2HomeProfile defaultProfileWithID:self.profileID name:self.name];
    self.layout = fresh.layout;
    self.cards = [NSMutableArray arrayWithArray:fresh.cards];
}

- (NSDictionary *)JSONObject {
    BOOL free = (self.layout == A2HomeLayoutModeFree);
    NSMutableArray *cards = [NSMutableArray arrayWithCapacity:self.cards.count];
    for (A2HomeCard *c in self.cards) {
        [cards addObject:[c JSONObjectIncludingPosition:free]];
    }
    return @{
        @"id": self.profileID ?: NSUUID.UUID.UUIDString,
        @"name": self.name ?: @"默认",
        @"layout": free ? @"free" : @"grid",
        @"cards": cards,
    };
}

- (id)copyWithZone:(nullable NSZone *)zone {
    A2HomeProfile *p = [[A2HomeProfile allocWithZone:zone] init];
    p.profileID = self.profileID;
    p.name = self.name;
    p.layout = self.layout;
    p.cards = [NSMutableArray arrayWithCapacity:self.cards.count];
    for (A2HomeCard *c in self.cards) [p.cards addObject:[c copy]];
    return p;
}

@end

#pragma mark - 文档

@implementation A2HomeDocument

+ (instancetype)defaultDocument {
    A2HomeDocument *doc = [[A2HomeDocument alloc] init];
    doc.schema = A2HomeSchemaVersion;
    NSString *pid = NSUUID.UUID.UUIDString;
    A2HomeProfile *p = [A2HomeProfile defaultProfileWithID:pid name:@"默认"];
    doc.profiles = [NSMutableArray arrayWithObject:p];
    doc.activeProfileID = pid;
    return doc;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _schema = A2HomeSchemaVersion;
        _activeProfileID = @"";
        _profiles = [NSMutableArray array];
    }
    return self;
}

+ (nullable instancetype)documentFromJSONObject:(nullable id)json readOnly:(BOOL *)outReadOnly {
    if (outReadOnly) *outReadOnly = NO;
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *root = json;

    // ---- 整篇门槛①：schema ----
    NSInteger schema = A2HomeSchemaVersion;
    id rawSchema = root[@"schema"];
    if ([rawSchema isKindOfClass:NSNumber.class]) {
        schema = [rawSchema integerValue];
        if (schema < 1) schema = A2HomeSchemaVersion;   // 缺失/非法 → 视为当前版本
    }
    if (schema > A2HomeSchemaVersion) {
        // ★更高版本 ⇒ 只读★：渲染默认，不解释、不覆盖、不静默重置。
        // 原文件由 A2HomeStore 备份为 home-layout.readonly.json（见 docs/HOME-DESIGN.md §4.5）。
        if (outReadOnly) *outReadOnly = YES;
        [A2Log log:@"[A2-HOME] 文档 schema=%ld 高于本版支持(%ld)：进入只读模式，不覆盖原文件",
              (long)schema, (long)A2HomeSchemaVersion];
        return [self defaultDocument];
    }

    // ---- 整篇门槛②：profiles ----
    id rawProfiles = root[@"profiles"];
    if (rawProfiles && ![rawProfiles isKindOfClass:NSArray.class]) {
        [A2Log log:@"[A2-HOME] profiles 不是数组：整篇作废"];
        return nil;
    }

    A2HomeDocument *doc = [[A2HomeDocument alloc] init];
    doc.schema = A2HomeSchemaVersion;
    doc.profiles = [NSMutableArray array];

    NSInteger dropped = 0;
    for (id rawProfile in (NSArray *)rawProfiles) {
        if (![rawProfile isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *pd = rawProfile;
        A2HomeProfile *p = [[A2HomeProfile alloc] init];
        NSString *pid = [pd[@"id"] isKindOfClass:NSString.class] ? pd[@"id"] : nil;
        p.profileID = pid.length ? pid : NSUUID.UUID.UUIDString;
        NSString *pname = [pd[@"name"] isKindOfClass:NSString.class] ? pd[@"name"] : nil;
        p.name = pname.length ? pname : [NSString stringWithFormat:@"方案 %lu", (unsigned long)doc.profiles.count + 1];
        NSString *layout = [pd[@"layout"] isKindOfClass:NSString.class] ? pd[@"layout"] : @"grid";
        p.layout = [layout isEqualToString:@"free"] ? A2HomeLayoutModeFree : A2HomeLayoutModeGrid;

        id rawCards = pd[@"cards"];
        p.cards = [NSMutableArray array];
        if ([rawCards isKindOfClass:NSArray.class]) {
            NSMutableSet<NSString *> *seenIDs = [NSMutableSet set];
            for (id rawCard in (NSArray *)rawCards) {
                NSString *why = nil;
                A2HomeCard *c = [A2HomeCard cardFromJSONObject:rawCard reason:&why];
                if (!c) {
                    dropped++;
                    [A2Log log:@"[A2-HOME] 丢一张卡：%@", why ?: @"未知原因"];
                    continue;
                }
                if ([seenIDs containsObject:c.cardID]) {
                    // id 重复：重发 UUID，两条都留（不丢卡）。
                    NSString *old = c.cardID;
                    c.cardID = NSUUID.UUID.UUIDString;
                    [A2Log log:@"[A2-HOME] 卡片 id 重复(%@)：已重发", old];
                }
                [seenIDs addObject:c.cardID];
                [p.cards addObject:c];
            }
        }
        [doc.profiles addObject:p];
    }

    if (doc.profiles.count == 0) {
        [A2Log log:@"[A2-HOME] profiles 为空：造一个默认方案"];
        A2HomeProfile *p = [A2HomeProfile defaultProfileWithID:NSUUID.UUID.UUIDString name:@"默认"];
        [doc.profiles addObject:p];
    }

    NSString *active = [root[@"activeProfile"] isKindOfClass:NSString.class] ? root[@"activeProfile"] : nil;
    if (active.length && [doc profileWithID:active]) {
        doc.activeProfileID = active;
    } else {
        doc.activeProfileID = doc.profiles.firstObject.profileID;
        if (active.length) [A2Log log:@"[A2-HOME] activeProfile『%@』不在列表里：回落到第一个方案", active];
    }

    [A2Log log:@"[A2-HOME] 读取方案：%lu 个方案 / 当前『%@』/ 丢卡 %ld 张",
          (unsigned long)doc.profiles.count, doc.activeProfile.name, (long)dropped];
    return doc;
}

- (A2HomeProfile *)activeProfile {
    A2HomeProfile *p = [self profileWithID:self.activeProfileID];
    if (p) return p;
    if (self.profiles.count == 0) {
        A2HomeProfile *fresh = [A2HomeProfile defaultProfileWithID:NSUUID.UUID.UUIDString name:@"默认"];
        [self.profiles addObject:fresh];
        self.activeProfileID = fresh.profileID;
        return fresh;
    }
    self.activeProfileID = self.profiles.firstObject.profileID;
    return self.profiles.firstObject;
}

- (nullable A2HomeProfile *)profileWithID:(NSString *)profileID {
    if (profileID.length == 0) return nil;
    for (A2HomeProfile *p in self.profiles) {
        if ([p.profileID isEqualToString:profileID]) return p;
    }
    return nil;
}

- (A2HomeProfile *)addProfileNamed:(NSString *)name {
    A2HomeProfile *p = [[A2HomeProfile alloc] init];
    p.profileID = NSUUID.UUID.UUIDString;
    p.name = name.length ? name : [NSString stringWithFormat:@"方案 %lu", (unsigned long)self.profiles.count + 1];
    // 新方案从当前方案复制（用户的心智是「在现有基础上改一版」）。
    A2HomeProfile *src = [self activeProfile];
    p.layout = src.layout;
    p.cards = [NSMutableArray arrayWithCapacity:src.cards.count];
    for (A2HomeCard *c in src.cards) {
        A2HomeCard *copy = [c copy];
        copy.cardID = NSUUID.UUID.UUIDString;
        [p.cards addObject:copy];
    }
    [self.profiles addObject:p];
    return p;
}

- (BOOL)removeProfileWithID:(NSString *)profileID {
    A2HomeProfile *p = [self profileWithID:profileID];
    if (!p) return NO;
    if (self.profiles.count <= 1) return NO;   // 最后一个方案不可删
    [self.profiles removeObject:p];
    if ([self.activeProfileID isEqualToString:profileID]) {
        self.activeProfileID = self.profiles.firstObject.profileID;
    }
    return YES;
}

- (NSDictionary *)JSONObject {
    NSMutableArray *profiles = [NSMutableArray arrayWithCapacity:self.profiles.count];
    for (A2HomeProfile *p in self.profiles) [profiles addObject:[p JSONObject]];
    NSString *active = self.activeProfileID;
    if (![self profileWithID:active]) active = self.profiles.firstObject.profileID ?: @"";
    return @{
        @"schema": @(A2HomeSchemaVersion),
        @"activeProfile": active ?: @"",
        @"profiles": profiles,
    };
}

@end

#pragma mark - 落位

@implementation A2HomePlacement
@end

@implementation A2HomePacker

/// 矩形是否与已占格冲突。
+ (BOOL)rectAtColumn:(NSInteger)column
                 row:(NSInteger)row
                span:(A2HomeSpan)span
             columns:(NSInteger)columns
            occupied:(NSSet<NSNumber *> *)occupied {
    for (NSInteger r = row; r < row + span.rows; r++) {
        for (NSInteger c = column; c < column + span.columns; c++) {
            if ([occupied containsObject:@(r * columns + c)]) return YES;
        }
    }
    return NO;
}

+ (void)occupyAtColumn:(NSInteger)column
                   row:(NSInteger)row
                  span:(A2HomeSpan)span
               columns:(NSInteger)columns
                 into:(NSMutableSet<NSNumber *> *)occupied {
    for (NSInteger r = row; r < row + span.rows; r++) {
        for (NSInteger c = column; c < column + span.columns; c++) {
            [occupied addObject:@(r * columns + c)];
        }
    }
}

+ (NSArray<A2HomePlacement *> *)gridPlacementsForCards:(NSArray<A2HomeCard *> *)cards
                                               columns:(NSInteger)columns {
    NSInteger cols = MAX((NSInteger)1, columns);
    NSMutableSet<NSNumber *> *occupied = [NSMutableSet set];
    NSMutableArray<A2HomePlacement *> *out = [NSMutableArray arrayWithCapacity:cards.count];

    for (A2HomeCard *card in cards) {
        A2HomeSpan span = A2HomeSpanCompressedToColumns(card.span, cols);
        NSInteger row = 0;
        NSInteger column = 0;
        BOOL placed = NO;
        // 从左上角逐格找空位（行优先）。卡片数很少，O(卡数 × 格数) 足够。
        while (!placed) {
            for (NSInteger c = 0; c + span.columns <= cols; c++) {
                if (![self rectAtColumn:c row:row span:span columns:cols occupied:occupied]) {
                    column = c;
                    placed = YES;
                    break;
                }
            }
            if (!placed) row++;
            if (row > 4096) { column = 0; placed = YES; }   // 安全阀，绝不因脏数据死循环
        }
        [self occupyAtColumn:column row:row span:span columns:cols into:occupied];

        A2HomePlacement *pl = [[A2HomePlacement alloc] init];
        pl.cardID = card.cardID;
        pl.column = column;
        pl.row = row;
        pl.columnSpan = span.columns;
        pl.rowSpan = span.rows;
        [out addObject:pl];
    }
    return out;
}

+ (NSArray<A2HomeCard *> *)cardsByMovingCardID:(NSString *)movingCardID
                                            in:(NSArray<A2HomeCard *> *)cards
                                    placements:(NSArray<A2HomePlacement *> *)placements
                                      toColumn:(NSInteger)targetColumn
                                           row:(NSInteger)targetRow {
    NSMutableArray<A2HomeCard *> *out = [cards mutableCopy] ?: [NSMutableArray array];
    if (cards.count == 0 || movingCardID.length == 0) return out;

    NSUInteger from = NSNotFound;
    for (NSUInteger i = 0; i < cards.count; i++) {
        if ([cards[i].cardID isEqualToString:movingCardID]) { from = i; break; }
    }
    if (from == NSNotFound) return out;

    // 落点压在哪张卡上？跨列/跨行要按区间判断，只比左上角会把宽卡判错。
    NSInteger insertIndex = NSNotFound;
    for (NSUInteger i = 0; i < placements.count && i < cards.count; i++) {
        A2HomePlacement *p = placements[i];
        if ([p.cardID isEqualToString:movingCardID]) continue;   // 自己不算「压到别人」
        BOOL inside = targetColumn >= p.column && targetColumn < p.column + p.columnSpan
                   && targetRow >= p.row && targetRow < p.row + p.rowSpan;
        if (inside) { insertIndex = (NSInteger)i; break; }
    }
    if (insertIndex == NSNotFound) {
        // 空格：插到「行优先严格排在落点之前」的张数处。
        NSInteger before = 0;
        for (NSUInteger i = 0; i < placements.count && i < cards.count; i++) {
            A2HomePlacement *p = placements[i];
            if ([p.cardID isEqualToString:movingCardID]) continue;
            if (p.row < targetRow || (p.row == targetRow && p.column < targetColumn)) before++;
        }
        insertIndex = before;
    }

    if ((NSUInteger)insertIndex == from) return out;   // 没动：不产生一次无意义的写盘

    A2HomeCard *moving = out[from];
    [out removeObjectAtIndex:from];
    // 被拖的卡自己的槽位总是够的：移除后长度是 count-1，落到末尾也不会越界。
    NSUInteger target = (NSUInteger)MAX((NSInteger)0, MIN(insertIndex, (NSInteger)out.count));
    [out insertObject:moving atIndex:target];
    return out;
}

+ (void)nearestFreeColumn:(NSInteger *)column
                      row:(NSInteger *)row
                  forSpan:(A2HomeSpan)span
                  columns:(NSInteger)columns
                 occupied:(NSSet<NSNumber *> *)occupied {
    NSInteger cols = MAX((NSInteger)1, columns);
    A2HomeSpan compressed = A2HomeSpanCompressedToColumns(span, cols);
    NSInteger maxColumn = MAX((NSInteger)0, cols - compressed.columns);
    NSInteger desiredColumn = MIN(MAX((NSInteger)0, column ? *column : 0), maxColumn);
    NSInteger desiredRow = MAX((NSInteger)0, row ? *row : 0);
    if (desiredRow > A2HomeMaxPositionRow) desiredRow = A2HomeMaxPositionRow;

    if (![self rectAtColumn:desiredColumn row:desiredRow span:compressed columns:cols occupied:occupied]) {
        if (column) *column = desiredColumn;
        if (row) *row = desiredRow;
        return;
    }

    // 被占：按曼哈顿距离由近到远扫全画布，取第一个放得下的格（只动自己，不推动别人）。
    NSInteger maxRow = MIN(desiredRow + 64, A2HomeMaxPositionRow);
    for (NSInteger distance = 1; distance <= maxRow + maxColumn; distance++) {
        for (NSInteger r = 0; r <= maxRow; r++) {
            for (NSInteger c = 0; c <= maxColumn; c++) {
                if (labs((long)(r - desiredRow)) + labs((long)(c - desiredColumn)) != distance) continue;
                if (![self rectAtColumn:c row:r span:compressed columns:cols occupied:occupied]) {
                    if (column) *column = c;
                    if (row) *row = r;
                    return;
                }
            }
        }
    }
    // 兜底：贴到最底一行的第一列（理论上不会走到）。
    if (column) *column = 0;
    if (row) *row = maxRow + 1;
}

+ (NSArray<A2HomePlacement *> *)freeDisplayPlacementsForCards:(NSArray<A2HomeCard *> *)cards
                                                      columns:(NSInteger)columns {
    NSInteger cols = MAX((NSInteger)1, columns);
    NSMutableSet<NSNumber *> *occupied = [NSMutableSet set];
    NSMutableArray<A2HomePlacement *> *out = [NSMutableArray arrayWithCapacity:cards.count];
    NSInteger bottomRow = 0;

    for (A2HomeCard *card in cards) {
        A2HomeSpan span = A2HomeSpanCompressedToColumns(card.span, cols);
        NSInteger column = card.hasPosition ? card.column : 0;
        NSInteger row = card.hasPosition ? card.row : bottomRow;
        [self nearestFreeColumn:&column row:&row forSpan:span columns:cols occupied:occupied];
        [self occupyAtColumn:column row:row span:span columns:cols into:occupied];
        bottomRow = MAX(bottomRow, row + span.rows);

        A2HomePlacement *pl = [[A2HomePlacement alloc] init];
        pl.cardID = card.cardID;
        pl.column = column;
        pl.row = row;
        pl.columnSpan = span.columns;
        pl.rowSpan = span.rows;
        [out addObject:pl];
    }
    return out;
}

+ (void)seedFreePositionsForCards:(NSArray<A2HomeCard *> *)cards columns:(NSInteger)columns {
    // 起手坐标按**最宽列数**算，保证位置的语义与设备无关：
    // 在 iPhone（1 列）上切到自由布局也不会把布局压成一列后再落盘。
    NSInteger cols = MAX((NSInteger)A2HomeMaxColumns, columns);
    NSArray<A2HomePlacement *> *placements = [self gridPlacementsForCards:cards columns:cols];
    for (NSUInteger i = 0; i < cards.count && i < placements.count; i++) {
        A2HomeCard *card = cards[i];
        A2HomePlacement *pl = placements[i];
        card.hasPosition = YES;
        card.column = pl.column;
        card.row = pl.row;
    }
}

+ (NSSet<NSNumber *> *)occupiedIndexesForPlacements:(NSArray<A2HomePlacement *> *)placements
                                        excludingID:(nullable NSString *)cardID
                                            columns:(NSInteger)columns {
    NSInteger cols = MAX((NSInteger)1, columns);
    NSMutableSet<NSNumber *> *set = [NSMutableSet set];
    for (A2HomePlacement *pl in placements) {
        if (cardID.length && [pl.cardID isEqualToString:cardID]) continue;
        for (NSInteger r = pl.row; r < pl.row + pl.rowSpan; r++) {
            for (NSInteger c = pl.column; c < pl.column + pl.columnSpan; c++) {
                [set addObject:@(r * cols + c)];
            }
        }
    }
    return set.copy;
}

@end
