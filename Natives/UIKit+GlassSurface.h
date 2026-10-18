//
//  UIKit+GlassSurface.h —— 液态玻璃外观助手(纯头文件,不新增 .m ⇒ 不改 CMake 源列表)
//
//  ★ CI 用 Xcode 15.4(iOS 17 SDK)⇒ UIGlassEffect(iOS 26)在 SDK 里无声明,
//    所以这里【不用编译期符号】,走 NSClassFromString + objc_msgSend 的运行时调用。
//  ★ 带探针:每次第一次解析材质时打一行日志,明确告知"玻璃生效"还是"回退常规材质",
//    免得再靠肉眼猜。日志 tag:[glass]
//
//  ★ [E3|2026-10-02] 落地 SPEC §2 设计令牌:颜色 / 圆角 / 玻璃四要素。
//    令牌来源:D:\hermes workplace\amethyst-air\_uiwork\D\SPEC.md §2.1 / §2.2 / §2.5。
//    改动逐处标注「原值 → 新值」。仅动参数,不动结构/布局。
//
//  ★ [GLASS-STYLE|2026-10-03] 界面风格分层(上游群主要求):
//    · iOS >= 26 ⇒ 默认液态玻璃:材质走系统 UIGlassEffect(不是纯代码实现);
//      纯代码部分默认【不参与】(群主口径「纯液态」),仅设置页「自绘高光」显式打开时才叠加。
//    · iOS <  26 ⇒ 走系统原生风格:本文件的「纯代码玻璃」助手(描边/内高光/外阴影、
//      私有 backdrop 调参、自绘玻璃底填充)全部短路;材质用系统 UIBlurEffect 常规材质。
//    · 判定与解析全部来自 AMEGlassStyle.h(单一真相源,见该文件判定矩阵)。
//  ★ [GLASS-LIQUID|2026-10-03] 群主口径更正:很多组件原先直接 `[UIBlurEffect effectWithStyle:]`
//    绕过了风格层 ⇒ iOS≥26 上没走系统液态玻璃。统一改走 AmeGlassEffect(fallback)/
//    AmeApplyGlassChipStyle / AmeInstallGlassBackdrop 三个入口。
//
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
// ★ [GLASS-STYLE] 界面风格解析层(单一真相源:auto / native / liquid)。
//   本文件所有「纯代码玻璃」助手(描边/内高光/外阴影/私有 backdrop 调参/玻璃底填充)
//   都按它收敛:iOS<26 ⇒ 原生(全部失效);iOS>=26 且非「原生」设置 ⇒ 液态玻璃(系统 UIGlassEffect)。
#import "AMEGlassStyle.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 设计令牌 · 玻璃参数(SPEC §2.5 ★核心)

/// 标准玻璃(卡片 .glass):blur(26px) + saturate(180%)
static const CGFloat AmeGlassBlurRadius          = 26.0;  // SPEC §2.5 .glass
static const CGFloat AmeGlassSaturate            = 1.80;  // SPEC §2.5 saturate(180%)
/// 强玻璃(面板/栏 .glass2):blur(30px) + saturate(200%)
static const CGFloat AmeGlassStrongBlurRadius    = 30.0;  // SPEC §2.5 .glass2
static const CGFloat AmeGlassStrongSaturate      = 2.00;  // SPEC §2.5 saturate(200%)
/// 高光描边宽度:1px(SPEC §2.5 "border 1px solid var(--rim)")
static const CGFloat AmeGlassBorderWidth         = 1.0;
/// 外阴影:0 8px 24px shade(SPEC §2.5 标准玻璃)
static const CGFloat AmeGlassShadowOffsetY       = 8.0;
static const CGFloat AmeGlassShadowRadius        = 24.0;
/// 外阴影:0 10px 30px shade(SPEC §2.5 .glass2 强玻璃)
static const CGFloat AmeGlassStrongShadowOffsetY = 10.0;
static const CGFloat AmeGlassStrongShadowRadius  = 30.0;

#pragma mark - 设计令牌 · 圆角(SPEC §2.2)

typedef NS_ENUM(NSInteger, AmeGlassRadius) {
    AmeGlassRadiusSmall = 13,   // 图标块 40(SPEC §2.2)
    AmeGlassRadiusRow   = 16,   // ★[E3] 新增:普通实例卡 / 列表行玻璃卡 / 弹出菜单(SPEC §2.2)
    AmeGlassRadiusCard  = 22,   // 大卡 / 面板卡 glass(SPEC §2.2)
    AmeGlassRadiusPanel = 26,   // 面板卡 glass2 / 竖屏底部标签栏(SPEC §2.2)
};

/// 控件圆角:按钮 / 胶囊 / 分段 / 输入框 / 开关 一律 100(SPEC §2.2)
static const CGFloat AmeRadiusPill = 100.0;

#pragma mark - 设计令牌 · 颜色(SPEC §2.1)

/// 便捷:0-255 RGB + alpha
static inline UIColor *AmeRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

/// 深浅色动态色工厂(SPEC §2.1:深/浅两套变量表)
static inline UIColor *AmeDynamicColor(UIColor *dark, UIColor *light) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return (tc.userInterfaceStyle == UIUserInterfaceStyleDark) ? dark : light;
        }];
    }
    return light;
}

/// ★ 强调色(统一系统蓝):深 #0A84FF / 浅 #007AFF(SPEC §2.1 accent)
///   供各处导航选中态 / 主按钮 / 圆形启动键 / 开关旋钮引用。
static inline UIColor *AmeAccentColor(void) {
    return AmeDynamicColor(AmeRGBA(0x0A, 0x84, 0xFF, 1.0),
                           AmeRGBA(0x00, 0x7A, 0xFF, 1.0));
}

/// 主文字 fg:深 #FFFFFF / 浅 #0B0B0C(SPEC §2.1)
static inline UIColor *AmeTextPrimaryColor(void) {
    return AmeDynamicColor([UIColor whiteColor], AmeRGBA(0x0B, 0x0B, 0x0C, 1.0));
}
/// 次要文字 dim:深 rgba(255,255,255,.58) / 浅 rgba(0,0,0,.55)(SPEC §2.1)
static inline UIColor *AmeTextSecondaryColor(void) {
    return AmeDynamicColor([[UIColor whiteColor] colorWithAlphaComponent:0.58],
                           [[UIColor blackColor] colorWithAlphaComponent:0.55]);
}
/// 成功 / 已启用:#34C759(深浅同,SPEC §2.1)
static inline UIColor *AmeSuccessColor(void) {
    return AmeRGBA(0x34, 0xC7, 0x59, 1.0);
}

/// glass 普通卡底:深 rgba(255,255,255,.10) / 浅 rgba(255,255,255,.55)(SPEC §2.1)
static inline UIColor *AmeGlassFillColor(void) {
    return AmeDynamicColor([[UIColor whiteColor] colorWithAlphaComponent:0.10],
                           [[UIColor whiteColor] colorWithAlphaComponent:0.55]);
}
/// glass2 强卡/栏底:深 .16 / 浅 .68(SPEC §2.1)
static inline UIColor *AmeGlassStrongFillColor(void) {
    return AmeDynamicColor([[UIColor whiteColor] colorWithAlphaComponent:0.16],
                           [[UIColor whiteColor] colorWithAlphaComponent:0.68]);
}
/// rim 高光描边:深 rgba(255,255,255,.28) / 浅 rgba(255,255,255,.85)(SPEC §2.1 + §2.5)
static inline UIColor *AmeGlassRimColor(void) {
    return AmeDynamicColor([[UIColor whiteColor] colorWithAlphaComponent:0.28],
                           [[UIColor whiteColor] colorWithAlphaComponent:0.85]);
}
/// shade 外阴影:深 rgba(0,0,0,.35) / 浅 rgba(0,0,0,.06)(SPEC §2.1)
static inline UIColor *AmeGlassShadeColor(void) {
    return AmeDynamicColor([[UIColor blackColor] colorWithAlphaComponent:0.35],
                           [[UIColor blackColor] colorWithAlphaComponent:0.06]);
}
/// 内高光(顶):rgba(255,255,255,.45)(SPEC §2.5,标准玻璃)
static inline UIColor *AmeGlassInnerHighlightColor(void) {
    return [[UIColor whiteColor] colorWithAlphaComponent:0.45];
}
/// 内高光(顶,强):rgba(255,255,255,.55)(SPEC §2.5,.glass2)
static inline UIColor *AmeGlassStrongInnerHighlightColor(void) {
    return [[UIColor whiteColor] colorWithAlphaComponent:0.55];
}
/// 面板底(横屏卡):深 rgba(28,28,30,.55) / 浅 rgba(255,255,255,.68)(SPEC §2.1 panel)
static inline UIColor *AmePanelColor(void) {
    return AmeDynamicColor(AmeRGBA(28, 28, 30, 0.55), AmeRGBA(255, 255, 255, 0.68));
}
/// 分隔线:深 rgba(84,84,88,.45) / 浅 rgba(60,60,67,.16)(SPEC §2.1 separator)
static inline UIColor *AmeSeparatorColor(void) {
    return AmeDynamicColor(AmeRGBA(84, 84, 88, 0.45), AmeRGBA(60, 60, 67, 0.16));
}
/// 左栏材质:深 rgba(18,18,20,.55) / 浅 rgba(242,242,247,.6)(SPEC §2.1 side)
static inline UIColor *AmeSideColor(void) {
    return AmeDynamicColor(AmeRGBA(18, 18, 20, 0.55), AmeRGBA(242, 242, 247, 0.6));
}
/// 分段 / 标签底:深 rgba(118,118,128,.28) / 浅 rgba(118,118,128,.12)(SPEC §2.1 seg)
static inline UIColor *AmeSegColor(void) {
    return AmeDynamicColor(AmeRGBA(118, 118, 128, 0.28), AmeRGBA(118, 118, 128, 0.12));
}

#pragma mark - ★ [GLASS-STYLE] 玻璃底填充按风格收敛

/// 标记「这层玻璃的底填充归我们管」(风格切换时要能精确定位重铺;
/// 背景壁纸容器的模糊层不打这个标记 ⇒ 永远保持系统原样,不被我们叠白底)。
static inline void AmeMarkManagedGlass(UIVisualEffectView *vev) {
    if (vev == nil) { return; }
    objc_setAssociatedObject(vev, "ameManagedGlassFill", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static inline BOOL AmeIsManagedGlass(UIVisualEffectView *vev) {
    if (vev == nil) { return NO; }
    return [objc_getAssociatedObject(vev, "ameManagedGlassFill") boolValue];
}

/// 按当前风格设置玻璃底填充:
///   液态玻璃 ⇒ SPEC §2.1 的白填充(.10 深 / .55 浅),作为系统玻璃之上的补充;
///   原生     ⇒ 不加任何填充,让系统材质原样呈现(这正是旧设备要的「与系统一致」)。
static inline void AmeApplyGlassFillForCurrentStyle(UIVisualEffectView *vev) {
    if (vev == nil) { return; }
    AmeMarkManagedGlass(vev);
    if (AMEGlassStyleAllowsHandDrawnGlass()) {
        vev.contentView.backgroundColor = AmeGlassFillColor();
    } else {
        vev.contentView.backgroundColor = [UIColor clearColor];
    }
}

#pragma mark - ★ [GLASS-LIQUID] 系统材质背景(任意宿主:胶囊 / 芯片 / 卡片 / 面板)

// 前向声明:统一材质入口在本文件后半段定义(胶囊/材质助手要用到它)
static inline UIVisualEffect *AmeGlassEffect(UIBlurEffectStyle fallbackStyle);

static const NSInteger kAmeGlassBackdropTag = 0x4D474C52;   // 'MGLR'

/// ★ [GLASS-LIQUID] 给任意宿主铺一层【当前风格的系统材质】背景。
///   · iOS ≥ 26(系统支持液态玻璃)⇒ 材质 = 系统 UIGlassEffect(不是自绘);
///   · iOS <  26 ⇒ 系统 UIBlurEffect 常规材质(受 @available 守护);
///   · 两者都拿不到时才回退调用方给的自绘样式(由调用方决定)。
///   幂等:同一宿主重复调用复用已挂的材质层;宿主自身圆角/裁剪同步设置。
///   用 frame + autoresizingMask 挂载 ⇒ 不干扰宿主自己的 Auto Layout。
static inline UIVisualEffectView * _Nullable AmeInstallGlassBackdrop(UIView *host, CGFloat radius, BOOL strong) {
    if (host == nil) { return nil; }
    UIVisualEffectView *vev = objc_getAssociatedObject(host, "ameGlassBackdrop");
    if (vev != nil && ![vev isKindOfClass:[UIVisualEffectView class]]) { vev = nil; }
    UIVisualEffect *eff = AmeGlassEffect(strong ? UIBlurEffectStyleSystemMaterial : UIBlurEffectStyleSystemThinMaterial);
    if (vev == nil) {
        vev = [[UIVisualEffectView alloc] initWithEffect:eff];
        vev.tag = kAmeGlassBackdropTag;
        vev.userInteractionEnabled = NO;
        vev.translatesAutoresizingMaskIntoConstraints = YES;
        vev.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host insertSubview:vev atIndex:0];
        objc_setAssociatedObject(host, "ameGlassBackdrop", vev, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        vev.effect = eff;   // 换 effect ⇒ UIKit 重建 backdrop
    }
    vev.frame = host.bounds;
    vev.layer.cornerRadius = radius;
    vev.layer.cornerCurve = kCACornerCurveContinuous;
    vev.layer.masksToBounds = YES;
    // 系统材质路径:不叠任何白底(纯系统玻璃)
    if (!AMEGlassStyleAllowsHandDrawnGlass()) { vev.contentView.backgroundColor = [UIColor clearColor]; }
    return vev;
}

/// ★ [HOST-BUG-A] 摘掉 AmeInstallGlassBackdrop 铺过的系统材质层。
///   用途:风格从「液态(≥26)」切到「原生(<26 / 用户选原生)」时,宿主上那层毛玻璃材质必须卸掉,
///   否则旧系统上会残留一颗"仿液态玻璃"的胶囊(见 AmeApplyGlassChipStyle 的原生分支)。
static inline void AmeRemoveGlassBackdrop(UIView *host) {
    if (host == nil) { return; }
    UIVisualEffectView *vev = objc_getAssociatedObject(host, "ameGlassBackdrop");
    if ([vev isKindOfClass:[UIVisualEffectView class]] && vev.superview == host) {
        [vev removeFromSuperview];
    }
    objc_setAssociatedObject(host, "ameGlassBackdrop", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (UIView *sub in [host.subviews copy]) {
        if (sub.tag == kAmeGlassBackdropTag) { [sub removeFromSuperview]; }
    }
}

/// ★ [GLASS-LIQUID] 「胶囊 / 芯片」的按风格外观(顶栏 pill、底部启动胶囊、状态药丸…)。
///   · 系统材质路径(默认,iOS≥26 系统 UIGlassEffect / iOS<26 系统材质)⇒ 宿主清透 + 系统材质背景,不自绘描边;
///   · 自绘路径(仅用户显式打开「自绘高光」)⇒ SPEC §2.1 白填充 + 1px rim 描边(旧观感)。
static inline void AmeApplyGlassChipStyle(UIView *host, CGFloat radius, BOOL strong) {
    if (host == nil) { return; }
    host.layer.cornerRadius = radius;
    host.layer.cornerCurve = kCACornerCurveContinuous;
    if (AMEGlassStyleAllowsHandDrawnGlass()) {
        host.backgroundColor = strong ? AmeGlassStrongFillColor() : AmeGlassFillColor();
        host.layer.borderWidth = AmeGlassBorderWidth;
        host.layer.borderColor = AmeGlassRimColor().CGColor;
        return;
    }
    // 系统路径
    host.backgroundColor = [UIColor clearColor];
    host.layer.borderWidth = 0.0;
    host.layer.borderColor = [UIColor clearColor].CGColor;
    // ★ [HOST-BUG-A] iOS<26(原生风格)⇒ 走【系统控件默认外观】:纯系统填充色,不铺 UIVisualEffectView 材质。
    //   旧实现无条件 AmeInstallGlassBackdrop(铺一层 SystemThinMaterial)⇒ 旧系统上一颗毛玻璃胶囊
    //   就是群主报的「主页组件仍是仿液态玻璃」。本助手【只被主页】用到
    //   (LauncherNewsViewController 的顶栏胶囊/动作 pill + 主页骨架 LauncherSkeletonView)
    //   ⇒ 现象只出现在主页,其它页无此问题。≥26(液态)才铺系统 UIGlassEffect。
    if (!AMEGlassStyleUsesLiquidGlass()) {
        AmeRemoveGlassBackdrop(host);   // 运行期从液态切回原生时,卸掉残留的材质层
        UIColor *ameChipFill = nil;
        if (@available(iOS 13.0, *)) {
            ameChipFill = [UIColor secondarySystemFillColor];
        } else {
            ameChipFill = [[UIColor blackColor] colorWithAlphaComponent:0.08];
        }
        host.backgroundColor = ameChipFill;
        return;
    }
    if (AmeGlassEffect(UIBlurEffectStyleSystemThinMaterial) != nil) {
        AmeInstallGlassBackdrop(host, radius, strong);
    }
}

/// 胶囊/芯片的底填充(旧 API 的按风格替代:系统路径 ⇒ 透明,交给系统材质)
static inline UIColor *AmeGlassChipFillColorForCurrentStyle(void) {
    return AMEGlassStyleAllowsHandDrawnGlass() ? AmeGlassFillColor() : [UIColor clearColor];
}
/// 胶囊/芯片的描边色(系统路径 ⇒ 透明)
static inline UIColor *AmeGlassChipBorderColorForCurrentStyle(void) {
    return AMEGlassStyleAllowsHandDrawnGlass() ? AmeGlassRimColor() : [UIColor clearColor];
}

#pragma mark - 玻璃四要素 · 描边 / 内高光 / 外阴影

/// 外阴影(SPEC §2.5:0 8px 24px shade;强玻璃 0 10px 30px)。
/// 注意:阴影需要溢出宿主边界 ⇒ 宿主 layer.masksToBounds 必须为 NO(见 AmeAttachGlassRim)。
static inline void AmeApplyGlassShadow(UIView *host, CGFloat radius, BOOL strong) {
    if (host == nil) { return; }
    // ★ [GLASS-LIQUID] 系统材质路径(默认)⇒ 不自绘外阴影(阴影是"纯代码玻璃"的一部分)
    if (!AMEGlassStyleAllowsHandDrawnGlass()) {
        host.layer.shadowOpacity = 0.0;
        return;
    }
    host.layer.shadowColor   = (AmeGlassShadeColor()).CGColor;
    host.layer.shadowOpacity = 1.0;
    host.layer.shadowOffset  = CGSizeMake(0.0, strong ? AmeGlassStrongShadowOffsetY : AmeGlassShadowOffsetY);
    host.layer.shadowRadius  = strong ? AmeGlassStrongShadowRadius : AmeGlassShadowRadius;
    // bounds 为空时不设 shadowPath(留 nil 让 CA 自行按内容计算),避免零尺寸路径把阴影"打死"
    if (!CGRectIsEmpty(host.bounds)) {
        host.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:host.bounds
                                                          cornerRadius:radius].CGPath;
    }
}

/// ★ [RIM-UI] 高光强度(0…1;由 BackgroundManager 按用户设置写入,1.0 = SPEC 原值)。
///   0 ⇒ 完全不刷(用户:"要不就别亮");>0 ⇒ 描边与内高光按比例缩放。
static CGFloat gAmeGlassRimStrength = 1.0;
static inline void AmeSetGlassRimStrength(CGFloat s) { gAmeGlassRimStrength = MAX(0.0, MIN(1.0, s)); }
static inline CGFloat AmeGlassRimStrengthValue(void) { return gAmeGlassRimStrength; }

/// ★ [RIM-STATE] 「高光载体」标记。
///   高光是「只加不删就残留 / 只在已有时才刷新就永远加不回来」的典型受害者 ⇒ 需要一个
///   【与开关无关】的持久标记:凡是曾经被当作玻璃载体贴过高光的视图都打上它。
///   于是「开关 关→开」时,视图树重刷能凭标记【补上】高光(原先只看有没有高光子层,没有就跳过 ⇒
///   开关开着也没高光 = 用户说的"随机");「开→关 / 玻璃→原生」时能被精确摘除、不留残余。
///   注意:AmeDetachGlassRim【不清】这个标记(它只摘图层)。
static inline void AmeMarkGlassRimHost(UIView *host) {
    if (host == nil) { return; }
    objc_setAssociatedObject(host, "ameGlassRimHost", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static inline BOOL AmeIsGlassRimHost(UIView *host) {
    if (host == nil) { return NO; }
    return [objc_getAssociatedObject(host, "ameGlassRimHost") boolValue];
}

/// 摘掉已存在的高光(改强度后要重刷,否则旧图层还挂着)
static inline void AmeDetachGlassRim(UIView *host) {
    if (host == nil) return;
    static const NSInteger kAmeRimTag2 = 0x4D52494D;
    for (UIView *sub in [host.subviews copy]) { if (sub.tag == kAmeRimTag2) [sub removeFromSuperview]; }
    host.layer.borderWidth = 0;
    host.layer.shadowOpacity = 0;
    // ★ [GLASS-STYLE] 卸 rim 时把裁剪还回来:AmeAttachGlassRim 为画外阴影会把宿主设成 masksToBounds=NO,
    //   而原生风格 / 强度 0 都没有外阴影 ⇒ 不还回来,运行期从液态切到原生后圆角会失效(内容溢出)。
    host.layer.masksToBounds = YES;
}

/// ★ 玻璃质感(不依赖 iOS 26 SDK):给载体加「1px 高光描边 + 上/下缘内高光 + 外阴影」。
/// 为什么要它:真系统液态玻璃需要 iOS 26 SDK 构建(CI 现已换到 Xcode 26.3/iOS 26.2 SDK,
/// 那时系统会自动接管;此外这里作叠层仍然成立)。旧 SDK 下它是主要观感来源。
/// 幂等:用一个 tag 去重,重复调用不会叠加。
static inline void AmeAttachGlassRim(UIView *host, CGFloat radius) {
    if (host == nil) return;
    // ★ [RIM-STATE] 打「高光载体」标记(在风格/强度判定【之前】,所以关闭期间也记得谁是载体)⇒
    //   之后「关→开」才能凭标记把高光补回来,而不是像原先一样"没有高光子层就永远不再加"。
    AmeMarkGlassRimHost(host);
    // ★ [GLASS-STYLE] 原生风格(iOS<26,或用户在 iOS>=26 上显式选「原生」):
    //   不绘制任何纯代码玻璃质感(1px 描边 / 上缘内高光 / 外阴影)⇒ 观感收敛到系统材质。
    if (!AMEGlassStyleAllowsHandDrawnGlass()) { AmeDetachGlassRim(host); return; }
    CGFloat ameStrength = AmeGlassRimStrengthValue();
    if (ameStrength <= 0.001) { AmeDetachGlassRim(host); return; }   // ★ 强度 0 ⇒ 一条都不刷
    static const NSInteger kAmeRimTag = 0x4D52494D;   // 'MRIM'
    // ★ [RIM-STATE] 幂等 + remove-then-apply(单一入口):
    //   · 已挂且【圆角未变】⇒ 直接复用(避免每次调用都重建图层);
    //   · 圆角变了(卡片/胶囊在旋转、改档位、进编辑)或本来就挂着旧图层 ⇒ 先摘旧的再重贴,
    //     保证【任何时刻只存在一层高光】、且圆角永远与当前尺寸一致(旧的"只加不删"会叠加/残留)。
    BOOL ameHasRim = NO;
    for (UIView *sub in host.subviews) {
        if (sub.tag == kAmeRimTag) { ameHasRim = YES; break; }
    }
    if (ameHasRim && fabs(host.layer.cornerRadius - radius) < 0.5) { return; }
    AmeDetachGlassRim(host);        // ★ 先摘后贴:不允许叠加/残留
    host.layer.cornerRadius = radius;
    host.layer.cornerCurve = kCACornerCurveContinuous;
    // 原值:masksToBounds = YES(外阴影被裁掉 ⇒ 观感"没落地")
    // 新值:masksToBounds = NO —— SPEC §2.5 要求外阴影 0 8px 24px 溢出宿主边界;
    //       圆角裁剪改由 blur 子视图 / shine 子视图各自 masksToBounds 保证。
    host.layer.masksToBounds = NO;

    // 玻璃描边:深浅色都给亮边(SPEC §2.1 深 .28 / 浅 .85)
    UIColor *rim = AmeGlassRimColor();   // 原:深 0.22 / 浅 0.75 → 新:深 0.28 / 浅 0.85
    rim = [rim colorWithAlphaComponent:CGColorGetAlpha(rim.CGColor) * ameStrength];   // ★ [RIM-UI] 按强度缩放
    host.layer.borderWidth = AmeGlassBorderWidth;   // 原:1.0/screen.scale(≈0.33pt) → 新:1.0pt(SPEC 1px)
    host.layer.borderColor = rim.CGColor;

    // 外阴影 0 8px 24px(原:无 → 新:有)
    AmeApplyGlassShadow(host, radius, NO);

    // 上缘内高光 + 下缘微高光:inset 0 1px 0 rgba(255,255,255,.45) + inset 0 -1px 0 rgba(255,255,255,.10)
    // 原渐变: [.20, .05, clear] @ [0, .28, .62] → 新: [.45, clear, .10] @ [0, .50, 1.0]
    UIView *shine = [[UIView alloc] initWithFrame:CGRectZero];
    shine.tag = kAmeRimTag;
    shine.userInteractionEnabled = NO;
    shine.translatesAutoresizingMaskIntoConstraints = NO;
    shine.backgroundColor = [UIColor clearColor];
    CAGradientLayer *g = [CAGradientLayer layer];
    UIColor *ameTopHl = AmeGlassInnerHighlightColor();
    ameTopHl = [ameTopHl colorWithAlphaComponent:CGColorGetAlpha(ameTopHl.CGColor) * ameStrength];  // ★ [RIM-UI]
    g.colors = @[(id)ameTopHl.CGColor,      // 顶 .45(SPEC)
                 (id)[UIColor clearColor].CGColor,
                 (id)[UIColor colorWithWhite:1.0 alpha:0.10 * ameStrength].CGColor]; // 底 .10(SPEC)
    g.locations = @[@0.0, @0.50, @1.0];
    g.startPoint = CGPointMake(0.5, 0.0);
    g.endPoint   = CGPointMake(0.5, 1.0);
    g.cornerRadius = radius;
    if (@available(iOS 13.0, *)) { g.cornerCurve = kCACornerCurveContinuous; }
    [shine.layer addSublayer:g];
    shine.clipsToBounds = YES;
    shine.layer.cornerRadius = radius;
    [host addSubview:shine];
    [NSLayoutConstraint activateConstraints:@[
        [shine.leadingAnchor  constraintEqualToAnchor:host.leadingAnchor],
        [shine.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [shine.topAnchor      constraintEqualToAnchor:host.topAnchor],
        [shine.bottomAnchor   constraintEqualToAnchor:host.bottomAnchor],
    ]];
    objc_setAssociatedObject(shine, "ameRimGradient", g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// 载体尺寸变化时刷新高光渐变与阴影路径(布局后调用;找不到就什么也不做)
static inline void AmeRefreshGlassRim(UIView *host) {
    if (host == nil) return;
    if (!AMEGlassStyleAllowsHandDrawnGlass()) { return; }   // ★ [GLASS-STYLE] 原生风格下没有 rim 可刷新
    static const NSInteger kAmeRimTag = 0x4D52494D;   // 'MRIM'
    for (UIView *sub in host.subviews) {
        if (sub.tag != kAmeRimTag) { continue; }
        // host 是玻璃载体:尺寸变后重设阴影路径,深浅色切换后刷新描边/阴影色
        if (!CGRectIsEmpty(host.bounds)) {
            host.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:host.bounds
                                                               cornerRadius:host.layer.cornerRadius].CGPath;
        }
        host.layer.borderColor = (AmeGlassRimColor()).CGColor;
        host.layer.shadowColor = (AmeGlassShadeColor()).CGColor;
        CAGradientLayer *g = (CAGradientLayer *)objc_getAssociatedObject(sub, "ameRimGradient");
        if (g != nil) { g.frame = sub.bounds; }
    }
}

#pragma mark - 统一材质(iOS 26 液态玻璃优先 / 旧系统回退)

/// 统一材质:iOS 26+ 尝试液态玻璃;失败/旧系统回退 fallbackStyle。
static inline UIVisualEffect *AmeGlassEffect(UIBlurEffectStyle fallbackStyle) {
    // ★ [GLASS-STYLE] 原生风格 ⇒ 明确返回系统常规材质(UIBlurEffect),不调用 UIGlassEffect。
    //   (iOS<26 由 AMEGlassStyleResolved() 强制 native;iOS>=26 用户也可显式选原生。)
    if (!AMEGlassStyleUsesLiquidGlass()) {
        static int s_ameGlassNativeMaterialLogged = 0;
        if (s_ameGlassNativeMaterialLogged++ == 0) {
            NSLog(@"[glass] 原生风格 ⇒ 材质用系统 UIBlurEffect(style=%ld),不调用 UIGlassEffect", (long)fallbackStyle);
        }
        return [UIBlurEffect effectWithStyle:fallbackStyle];
    }
    static Class glassCls = Nil;
    static BOOL probed = NO;
    static BOOL glassOK = NO;
    static NSString *probeWhy = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        glassCls = NSClassFromString(@"UIGlassEffect");
        if (glassCls == Nil) {
            probeWhy = @"UIGlassEffect 类不存在(系统 < iOS 26 或未链接)";
        } else {
            SEL sel = @selector(effectWithStyle:);
            if ([glassCls respondsToSelector:sel]) {
                id g = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassCls, sel, 0);
                if (g != nil && [g isKindOfClass:[UIVisualEffect class]]) {
                    glassOK = YES;
                    probeWhy = [NSString stringWithFormat:@"UIGlassEffect 生效(sdk=%s)", __VERSION__];
                } else {
                    probeWhy = @"UIGlassEffect.effectWithStyle: 返回空/类型不符 ⇒ 回退";
                }
            } else {
                probeWhy = @"UIGlassEffect 无 effectWithStyle: 方法 ⇒ 回退";
            }
        }
        NSLog(@"[glass] 材质解析:%@ ⇒ %@", glassOK ? @"玻璃" : @"常规材质(回退)", probeWhy ?: @"?");
        probed = YES;
    });
    (void)probed;

    if (glassOK && glassCls != Nil) {
        id g = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassCls, @selector(effectWithStyle:), 0);
        if (g != nil && [g isKindOfClass:[UIVisualEffect class]]) {
            return (UIVisualEffect *)g;
        }
    }
    return [UIBlurEffect effectWithStyle:fallbackStyle];
}

/// ★ [E3] 尽力把 SPEC §2.5 的 blur / saturate 落到系统材质上。
/// 系统没有公开 API 控制系统材质的模糊半径/饱和度 ⇒ 走私有 backdrop 滤镜通道(GaussianBlur.inputRadius /
/// ColorControls.inputSaturation / Vibrance.inputAmount),全程 @try 包裹,失败即回退系统默认并打日志(自证)。
/// 返回 YES 表示已按 SPEC 应用。
static inline BOOL AmeTuneGlassBackdrop(UIVisualEffectView *vev, CGFloat blurRadius, CGFloat saturation) {
    if (vev == nil) { return NO; }
    // ★ [GLASS-STYLE] 原生风格:不碰私有 backdrop 通道(那是纯代码玻璃的一部分,旧系统上本就违和)。
    if (!AMEGlassStyleAllowsHandDrawnGlass()) {
        static int s_ameGlassTuneNativeLogged = 0;
        if (s_ameGlassTuneNativeLogged++ == 0) {
            NSLog(@"[glass] 原生风格 ⇒ 跳过私有 backdrop 调参(blur=%.0f saturate=%.0f%% 不应用)",
                  blurRadius, saturation * 100.0);
        }
        return NO;
    }
    id backdrop = nil, layer = nil;
    @try { backdrop = [vev valueForKey:@"backdropView"]; } @catch (__unused NSException *e) { backdrop = nil; }
    @try { if (backdrop) { layer = [backdrop valueForKey:@"backdropLayer"]; } } @catch (__unused NSException *e) { layer = nil; }
    if (layer == nil) {
        // ★ [LOG-CLEAN] 原每次贴玻璃都打(同句 20+ 次 ⇒ 刷屏)。只报第一次。
        static int s_ameGlassNoBackdropLogged = 0;
        if (s_ameGlassNoBackdropLogged++ == 0) {
            NSLog(@"[glass] blur=%.0f saturate=%.0f%% 未应用(系统材质默认:私有 backdrop 通道不可用)", blurRadius, saturation * 100.0);
        }
        return NO;
    }
    BOOL ok = NO;
    @try {
        NSArray *filters = [layer valueForKey:@"filters"];
        for (id f in filters) {
            NSString *name = nil;
            @try { name = [f valueForKey:@"name"]; } @catch (__unused NSException *e) { name = nil; }
            if (name.length == 0) { continue; }
            if ([name containsString:@"GaussianBlur"]) {
                [f setValue:@(blurRadius) forKey:@"inputRadius"];      ok = YES;
            } else if ([name containsString:@"ColorControls"]) {
                [f setValue:@(saturation) forKey:@"inputSaturation"];  ok = YES;
            } else if ([name containsString:@"Vibrance"]) {
                [f setValue:@(saturation - 1.0) forKey:@"inputAmount"]; ok = YES;
            }
        }
        [layer setValue:filters forKey:@"filters"];
    } @catch (__unused NSException *e) { ok = NO; }
    // ★ [LOG-CLEAN] 原每次调用都打一行 ⇒ 只报第一次(已应用/未应用任一路径)。
    static int s_ameGlassTuneLogged = 0;
    if (s_ameGlassTuneLogged++ == 0) {
        NSLog(@"[glass] blur=%.0f saturate=%.0f%% %@", blurRadius, saturation * 100.0,
              ok ? @"已应用(SPEC §2.5)" : @"未应用(回退系统默认)");
    }
    return ok;
}

/// 给 view 贴一层玻璃并设圆角(卡片/面板/列表行用)。返回承载视图,插在最底层。
/// ★ [E3] 补齐四要素:blur(AmeGlassEffect)+ saturate/blur 调参 + 1px 描边 + 内高光 + 外阴影。
static inline UIVisualEffectView * _Nullable AmeApplyGlassSurface(UIView *view, AmeGlassRadius radius) {
    if (view == nil) { return nil; }
    UIVisualEffect *effect = AmeGlassEffect(UIBlurEffectStyleSystemMaterial);
    if (effect == nil) { return nil; }
    view.backgroundColor = [UIColor clearColor];
    view.layer.cornerRadius = (CGFloat)radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.masksToBounds = YES;
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:effect];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.userInteractionEnabled = NO;
    blur.layer.cornerRadius = (CGFloat)radius;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.layer.masksToBounds = YES;
    // ★ [GLASS-STYLE] 玻璃底填充按风格(液体=SPEC 白填充;原生=不加,保持系统材质原样)
    AmeApplyGlassFillForCurrentStyle(blur);
    [view insertSubview:blur atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [blur.leadingAnchor  constraintEqualToAnchor:view.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [blur.topAnchor      constraintEqualToAnchor:view.topAnchor],
        [blur.bottomAnchor   constraintEqualToAnchor:view.bottomAnchor],
    ]];
    // ★ [E3] blur 26 / saturate 180% + 描边 + 内高光 + 外阴影
    AmeTuneGlassBackdrop(blur, AmeGlassBlurRadius, AmeGlassSaturate);
    AmeAttachGlassRim(view, (CGFloat)radius);   // 会把 view.layer.masksToBounds 置 NO(为外阴影)
    return blur;
}

/// 灵动岛/刘海安全区(横屏有岛那侧 ≈59pt、另一侧 0;iPad 两者皆 0)
static inline UIEdgeInsets AmeSafeInsets(UIView *view) {
    if (@available(iOS 11.0, *)) { return view.safeAreaInsets; }
    return UIEdgeInsetsZero;
}

NS_ASSUME_NONNULL_END
