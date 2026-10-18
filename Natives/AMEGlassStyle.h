//
//  AMEGlassStyle.h —— ★ [GLASS-STYLE] 界面风格解析层(单一真相源)
//
//  背景(上游群主需求):
//    主页/设置等处原先【用纯代码实现 LiquidGlass】(blur + 高光描边 + 内高光 + 外阴影 +
//    私有 backdrop 调参),旧系统也能"体验"液态玻璃,但观感违和。要求分层:
//      ① iOS < 26  ⇒ 走系统原生风格(系统色 / 系统材质 / 系统控件默认外观),不再纯代码画玻璃;
//      ② iOS >= 26 ⇒ 默认调用【系统液态玻璃 API】(UIGlassEffect),而不是纯代码实现;
//      ③ iOS >= 26 用户可在设置里选「原生风格 / 液态玻璃风格」;iOS < 26 因系统限制仅支持原生。
//
//  设计:本头文件是【唯一真相源】,同时被 UI(设置页)与材质层(BackgroundManager /
//        UIKit+GlassSurface)引用。纯头文件、全 static inline / #define ⇒ 不新增 .m、不改 CMake 源列表。
//
//  ★ [GLASS-LIQUID|2026-10-03] 群主口径更正:「纯液态」= iOS≥26 只走【系统 UIGlassEffect】,
//    **不再**用代码画玻璃;iOS<26 只走【系统原生材质】。自绘玻璃质感(描边/内高光/外阴影/白底/
//    私有 backdrop 调参)默认【全局关闭】,仅当用户在同一设置页显式打开「自绘高光」开关时才叠加。
//
//  判定矩阵(见 _GLASS_STYLE.md §② / _GLASS_LIQUID_FIX.md):
//    ┌───────────┬──────────────┬──────────────┬──────────────┐
//    │ 设置值     │ iOS < 26     │ iOS == 26    │ 说明          │
//    ├───────────┼──────────────┼──────────────┼──────────────┤
//    │ auto      │ native       │ liquid       │ 默认值        │
//    │ native    │ native       │ native       │ 用户显式选原生 │
//    │ liquid    │ native(强制) │ liquid       │ <26 置灰不可选 │
//    └───────────┴──────────────┴──────────────┴──────────────┘
//    · 材质:liquid ⇒ 系统 UIGlassEffect;native ⇒ 系统 UIBlurEffect 常规材质。
//    · 自绘:默认关(AMEGlassStyleAllowsHandDrawnGlass()==NO);显式开「自绘高光」才叠加。
//
//  兼容:最低 iOS 14.0;iPhone / iPad;竖屏 / 横屏(本层不含任何布局,天然无关方向)。
//
#ifndef AME_GLASS_STYLE_H
#define AME_GLASS_STYLE_H

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// 界面风格(用户可配)
typedef NS_ENUM(NSInteger, AMEGlassStyle) {
    AMEGlassStyleAuto   = 0,   // 自动:iOS>=26 ⇒ 液态玻璃;iOS<26 ⇒ 原生
    AMEGlassStyleNative = 1,   // 原生:系统原生控件/材质,不再纯代码画玻璃
    AMEGlassStyleLiquid = 2,   // 液态玻璃:系统 UIGlassEffect(iOS 26+)
};

/// 偏好键:与同 section 的「高光开关 / 强度」同库同前缀(BackgroundManager 的 NSUserDefaults 键
/// background_glass_*),不占用启动器 launcher_preferences.plist 的 general.* 命名空间
/// (那一族走 PLPreferences/getPrefObject,不是 NSUserDefaults;混用会让人以为能在设置重置里清掉)。
#define AMEGlassStylePrefKey                @"background_glass_style"
/// ★ [GLASS-LIQUID] 自绘玻璃质感(描边 / 内高光 / 外阴影 / 白底填充 / 私有 backdrop 调参)的可选开关。
///   默认 **NO** —— 群主口径「纯液态」:iOS≥26 只走系统 UIGlassEffect,不叠任何自绘;iOS<26 只走系统原生。
///   仅在用户【显式】打开时才叠加自绘(属于叠加在系统玻璃之上的额外装饰,不是"用代码冒充液体玻璃")。
#define AMEGlassStyleHandDrawnPrefKey       @"background_glass_handdrawn"
/// 风格 / 自绘开关切换通知(BackgroundManager 监听后立即按新风格重刷)
#define AMEGlassStyleChangedNotification    @"AMEGlassStyleChanged"

#pragma mark - 枚举 <-> 字符串

static inline NSString *AMEGlassStyleStringFromEnum(AMEGlassStyle s) {
    switch (s) {
        case AMEGlassStyleNative: return @"native";
        case AMEGlassStyleLiquid: return @"liquid";
        case AMEGlassStyleAuto:
        default:                  return @"auto";
    }
}

static inline AMEGlassStyle AMEGlassStyleEnumFromString(NSString * _Nullable v) {
    if ([v isKindOfClass:[NSString class]]) {
        if ([v isEqualToString:@"native"]) return AMEGlassStyleNative;
        if ([v isEqualToString:@"liquid"]) return AMEGlassStyleLiquid;
    }
    return AMEGlassStyleAuto;
}

#pragma mark - 系统能力探测(双重守门)

/// ① 系统版本守门:运行在 iOS 26 及以上。
/// ★ 只用 @available 做【运行时】判定 —— 它不是 iOS 26 的编译期符号,
///   所以在旧 SDK(Xcode 15.x / iOS 17 SDK)下同样能编过。
static inline BOOL AMEGlassStyleSystemVersionIs26OrLater(void) {
    if (@available(iOS 26.0, *)) { return YES; }
    return NO;
}

/// 系统是否支持【系统】液态玻璃(iOS 26+ 且 UIGlassEffect 真的可用)。
/// ★ 双重守门:① 运行时系统版本 ≥ 26(@available,不是编译期符号)
///             ② UIGlassEffect 类存在 + effectWithStyle: 返回的对象确实是 UIVisualEffect。
///   不使用任何 iOS 26 编译期符号 ⇒ Xcode 15.x(iOS 17 SDK)也能编译。
/// dispatch_once 缓存结果。
static inline BOOL AMEGlassStyleSystemSupportsLiquid(void) {
    static BOOL sSupports = NO;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
        // ★ 双重守门①:系统版本 < 26 ⇒ 一律不支持(此时系统根本不给新外观,拿了类也没用)
        if (!AMEGlassStyleSystemVersionIs26OrLater()) {
            NSLog(@"[glass] 界面风格探测:系统 < iOS 26 ⇒ 仅原生风格可用");
            sSupports = NO;
            return;
        }
        // ★ 双重守门②:类存在 + 能真的造出 UIVisualEffect(拿不到就回退 native)
        Class cls = NSClassFromString(@"UIGlassEffect");
        if (cls != Nil && [cls respondsToSelector:@selector(effectWithStyle:)]) {
            id eff = ((id (*)(id, SEL, NSInteger))objc_msgSend)(cls, @selector(effectWithStyle:), 0); // Regular == 0
            sSupports = (eff != nil && [eff isKindOfClass:[UIVisualEffect class]]);
        }
        NSLog(@"[glass] 界面风格探测:系统 ≥ iOS 26 · UIGlassEffect %@ ⇒ 液态玻璃%@",
              (cls != Nil) ? @"存在" : @"不存在", sSupports ? @"可用" : @"不可用(回退原生)");
    });
    return sSupports;
}

#pragma mark - 配置读写

/// 用户配置值(未设置 ⇒ auto)
static inline AMEGlassStyle AMEGlassStyleConfigured(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:AMEGlassStylePrefKey];
    return AMEGlassStyleEnumFromString([v isKindOfClass:[NSString class]] ? v : nil);
}

/// ★ 判定矩阵:得到【实际生效】的风格。
///   iOS < 26:无论配置为何,一律强制 native(系统限制,UI 上 liquid 亦置灰)。
static inline AMEGlassStyle AMEGlassStyleResolved(void) {
    if (!AMEGlassStyleSystemSupportsLiquid()) {
        return AMEGlassStyleNative;   // ★ 系统限制 ⇒ 强制原生
    }
    // 到这里系统一定支持液态玻璃(iOS >= 26)
    return (AMEGlassStyleConfigured() == AMEGlassStyleNative) ? AMEGlassStyleNative : AMEGlassStyleLiquid;
}

/// 实际生效 = 液态玻璃?
static inline BOOL AMEGlassStyleUsesLiquidGlass(void) {
    return AMEGlassStyleResolved() == AMEGlassStyleLiquid;
}

/// 实际生效 = 原生?
static inline BOOL AMEGlassStyleUsesNativeAppearance(void) {
    return AMEGlassStyleResolved() == AMEGlassStyleNative;
}

/// 是否允许绘制【纯代码玻璃质感】(高光描边 / 内高光 / 外阴影 / 私有 backdrop 调参 / 白底填充)。
/// ★ [GLASS-LIQUID] 群主口径 = 「纯液态」:iOS≥26 走【系统】UIGlassEffect、iOS<26 走【系统原生材质】,
///   两者都**不再**用代码画玻璃。因此这里默认返回 NO(自绘全局关闭)。
///   仅当用户在同一设置页【显式】打开「自绘高光」开关时,才在【系统玻璃之上】叠加旧观感(OPT-IN)。
static inline BOOL AMEGlassStyleHandDrawnOverlayEnabled(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:AMEGlassStyleHandDrawnPrefKey];
    return v ? [[NSUserDefaults standardUserDefaults] boolForKey:AMEGlassStyleHandDrawnPrefKey] : NO;   // 默认关
}

/// ★ [GLASS-LIQUID] 总闸:当前是否允许"用代码画玻璃"。
///   = 系统确实提供了 UIGlassEffect(iOS≥26)【且】用户显式打开了自绘开关。
///   iOS<26 一律 NO(系统根本没有新外观,老老实实用系统材质)。
static inline BOOL AMEGlassStyleAllowsHandDrawnGlass(void) {
    return AMEGlassStyleUsesLiquidGlass() && AMEGlassStyleHandDrawnOverlayEnabled();
}

/// ★ [GLASS-LIQUID] 当前是否走"系统材质"路径(材质由系统给,不自绘)。
///   iOS≥26 ⇒ 系统 UIGlassEffect;iOS<26 ⇒ 系统 UIBlurEffect 常规材质。两者都为 YES。
static inline BOOL AMEGlassStyleUsesSystemMaterial(void) {
    return !AMEGlassStyleAllowsHandDrawnGlass();
}

/// 写入自绘开关并广播(设置页 action 调用)
static inline void AMEGlassStyleSetHandDrawnOverlayEnabled(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:AMEGlassStyleHandDrawnPrefKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:AMEGlassStyleChangedNotification object:nil];
    NSLog(@"[glass] 自绘玻璃质感开关 = %@(群主口径:默认关;iOS≥26 只走系统 UIGlassEffect)", on ? @"开(叠加在系统玻璃之上)" : @"关");
}

/// 写入配置并广播(设置页 action 调用;实际持久化由通用偏好存储负责,这里再兜一次)
static inline void AMEGlassStyleSetConfigured(AMEGlassStyle s) {
    [[NSUserDefaults standardUserDefaults] setObject:AMEGlassStyleStringFromEnum(s) forKey:AMEGlassStylePrefKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:AMEGlassStyleChangedNotification object:nil];
    NSLog(@"[glass] 界面风格设置为 %@(系统支持液态玻璃=%d ⇒ 实际生效=%@)",
          AMEGlassStyleStringFromEnum(s),
          (int)AMEGlassStyleSystemSupportsLiquid(),
          AMEGlassStyleStringFromEnum(AMEGlassStyleResolved()));
}

/// 启动时打一行可判读自证(风格判定矩阵现场可判)
static inline void AMEGlassStyleLogResolvedOnce(void) {
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
        NSLog(@"[glass] 风格判定: 配置=%@ · 系统支持液态玻璃=%@ · 实际生效=%@ · 自绘玻璃=%@ (SDK=%s)",
              AMEGlassStyleStringFromEnum(AMEGlassStyleConfigured()),
              AMEGlassStyleSystemSupportsLiquid() ? @"是" : @"否",
              AMEGlassStyleStringFromEnum(AMEGlassStyleResolved()),
              AMEGlassStyleAllowsHandDrawnGlass() ? @"开(可选)" : @"关(纯系统)",
              __VERSION__);
    });
}

NS_ASSUME_NONNULL_END
#endif /* AME_GLASS_STYLE_H */
