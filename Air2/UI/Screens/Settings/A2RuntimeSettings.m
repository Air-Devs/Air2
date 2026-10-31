//
//  A2RuntimeSettings.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  设置 · 游戏 —— ★运行环境分组：渲染器 + Java 运行时两张列表★。
//
//  为什么现在才有：A2SettingsSections.h 的「宁缺毋滥」教训 —— 这两个设置项此前
//  只有壳（渲染层没实现、JRE 只有一档），点下去不会发生任何事。本分组是**接线之后的入口**：
//    · 渲染器 → `Natives/Renderer/a2_renderer.*`（启动链显式加载所选 dylib）
//    · Java 运行时 → 启动计划的 `javaHome`（Player 的启动会话 → Bridge 的启动执行器）
//
//  ★持久化★：Air2 自己的 `NSUserDefaults`，键是 `A2LaunchContract.h` 里的两个跨层契约常量
//  （`A2SelectedRendererPrefKey` / `A2SelectedJavaRuntimePrefKey`）—— ★不是老线 `$POJAV_HOME`
//  下的 plist★。值 = dylib 文件名 / `java_runtimes` 下的目录名；键缺失 = 未选择 ⇒ 用主推项。
//  ★写入点只有本文件★（读取点在 Player 层的启动会话里，见 docs/ARCHITECTURE.md [RENDER-SEL]）。
//
//  ★「未内置」的项照列不误★（老线是直接隐藏）：用户口径是「缺的也入表、标出来」，
//  选中未内置项 ⇒ 启动时**如实阻断并给出确切缺什么**，不静默回退到别的渲染器/JRE。
//
//  ★分层★：本文件只依赖 Core（候选表）+ Player（四语文案）—— ★不 import Bridge / Natives★
//  （Bridge 才会碰 Natives；UI 碰它就是越层，见 docs/ARCHITECTURE.md §依赖方向）。
//

#import "A2SettingsSections.h"
#import "A2SettingsSection.h"
#import "A2SettingsRow.h"
#import "A2Renderer.h"            // 候选值对象的类型（A2RendererCatalog 的属性/返回值用）
#import "A2RendererCatalog.h"
#import "A2RenderScaleCatalog.h"  // 渲染分辨率倍率候选表（[FRAME-PERF]）
#import "A2JavaRuntimeCatalog.h"
#import "A2RuntimeStrings.h"
#import "A2LaunchContract.h"      // 两个偏好键（跨层契约常量）
#import "A2Log.h"
#import "A2Toast.h"
#import "A2OptionSheet.h"
#import "A2RendererPluginViewController.h"   // 「导入渲染器…」的去处（导入 / 卸载管理页）

#import <math.h>   // fabs（倍率比较）

// 四语文案取词（本文件的唯一入口；缺 key 时 A2RuntimeStrings 会回吐 key，便于一眼看出漏配）。
static NSString *A2RS(NSString *key) {
    return [A2RuntimeStrings stringForKey:key];
}

/// 包内目录（frameworksPath / javaRuntimesPath 各只算一次）。
static NSString *A2BundleFrameworksPath(void) {
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
}

static NSString *A2BundleJavaRuntimesPath(void) {
    return [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:[A2JavaRuntimeCatalog javaRuntimesDirectoryName]];
}

/// 当前选择的渲染器标识（未选择 / 选了个不在表里的旧值时 ⇒ 主推）。
static A2Renderer *A2CurrentRenderer(void) {
    NSString *sel = [NSUserDefaults.standardUserDefaults stringForKey:A2SelectedRendererPrefKey];
    A2Renderer *cand = [A2RendererCatalog candidateForIdentifier:sel ?: @""];
    return cand ?: A2RendererCatalog.defaultCandidate;
}

/// 当前选择的 Java 运行时目录名（未选择 / 旧值时 ⇒ 主推档）。
static NSString *A2CurrentJavaRuntimeDirectory(void) {
    NSString *sel = [NSUserDefaults.standardUserDefaults stringForKey:A2SelectedJavaRuntimePrefKey];
    if (sel.length > 0 && [[A2JavaRuntimeCatalog allDirectoryNames] containsObject:sel]) return sel;
    return [A2JavaRuntimeCatalog defaultDirectoryName];
}

/// 当前选择的渲染分辨率倍率（未设置 / 非受支持值 ⇒ 默认档；归一化唯一实现在 Core 的候选表）。
static double A2CurrentRenderScale(void) {
    NSString *sel = [NSUserDefaults.standardUserDefaults stringForKey:A2SelectedRenderScalePrefKey];
    return [A2RenderScaleCatalog normalizedScaleForStoredString:sel];
}

/// 倍率行的显示值：百分比 +（原生档额外标「原生」）。
static NSString *A2RenderScaleDisplayText(double scale) {
    NSString *percent = [A2RenderScaleCatalog displayPercentForScale:scale];
    if (![A2RenderScaleCatalog isSupportedScale:scale]) return percent;   // 不该发生（已归一化）
    if (scale >= [A2RenderScaleCatalog defaultScale] - 0.001) {
        return [NSString stringWithFormat:@"%@ · %@", percent, A2RS(@"runtime.scale.native")];
    }
    return percent;
}

@implementation A2RuntimeSettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:A2RS(@"runtime.section.title")];
    section.footerText = A2RS(@"runtime.section.footer");

    [section addRow:[self rendererRowWithHost:host]];
    [section addRow:[self rendererImportRowWithHost:host]];
    [section addRow:[self javaRuntimeRowWithHost:host]];
    [section addRow:[self renderScaleRowWithHost:host]];
    return section;
}

#pragma mark - 渲染器

+ (A2SettingsRow *)rendererRowWithHost:(UIViewController *)host {
    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = @"cube.transparent.fill";
    row.title = A2RS(@"runtime.row.renderer");
    row.accessory = A2SettingsRowAccessoryDisclosure;

    __weak A2SettingsRow *weakRow = row;
    void (^refresh)(void) = ^{
        A2Renderer *cur = A2CurrentRenderer();
        BOOL bundled = [A2RendererCatalog isBundled:cur frameworksPath:A2BundleFrameworksPath()];
        A2RendererTier tier = [A2RendererCatalog tierForIdentifier:cur.identifier];
        weakRow.valueText = cur.displayName;   // 技术名（语言中立），中文全名在选择器里给
        weakRow.subtitle = [NSString stringWithFormat:@"%@ · %@ · %@",
                            A2RS([A2RendererCatalog tierLocalizationKeyForTier:tier]),
                            A2RS(bundled ? @"runtime.bundled" : @"runtime.notBundled"),
                            cur.identifier];
    };
    refresh();

    __weak UIViewController *weakHost = host;
    row.onTap = ^{
        UIViewController *hostVC = weakHost;
        if (hostVC == nil) return;

        A2OptionSheet *sheet =
            [A2OptionSheet sheetWithTitle:A2RS(@"runtime.pick.renderer.title")
                                  message:A2RS(@"runtime.pick.renderer.message")];

        A2Renderer *cur = A2CurrentRenderer();
        NSString *frameworks = A2BundleFrameworksPath();
        for (A2Renderer *cand in [A2RendererCatalog allCandidates]) {
            BOOL bundled = [A2RendererCatalog isBundled:cand frameworksPath:frameworks];
            A2RendererTier tier = [A2RendererCatalog tierForIdentifier:cand.identifier];
            NSString *nameKey = [A2RendererCatalog nameLocalizationKeyForIdentifier:cand.identifier];
            NSString *name = A2RS(nameKey);
            if ([name isEqualToString:nameKey]) name = cand.displayName;   // 缺 key ⇒ 技术名兜底
            NSString *title = [NSString stringWithFormat:@"%@ · %@ · %@",
                               name, A2RS([A2RendererCatalog tierLocalizationKeyForTier:tier]),
                               A2RS(bundled ? @"runtime.bundled" : @"runtime.notBundled")];
            __weak A2SettingsRow *wRow = weakRow;
            // 当前项的标记由行上的 MD3 选中勾承担（不再往标题里塞「✓ 」前缀）
            [sheet addOptionWithTitle:title
                             selected:[cand.identifier isEqualToString:cur.identifier]
                          destructive:NO
                              handler:^{
                [NSUserDefaults.standardUserDefaults setObject:cand.identifier
                                                        forKey:A2SelectedRendererPrefKey];
                // 设置侧只记「用户改成了什么」；启动侧的判据行 chosen= 由 Player 的启动会话打
                // （那里才知道这一档到底有没有被真正采用）。两处不重复记同一件事。
                [A2Log log:@"settings: 渲染器 → %@（%@）", cand.identifier,
                 bundled ? @"包内已有" : @"★包内未内置：启动会如实阻断★"];
                A2SettingsRow *r = wRow;
                r.valueText = cand.displayName;
                r.subtitle = [NSString stringWithFormat:@"%@ · %@ · %@",
                              A2RS([A2RendererCatalog tierLocalizationKeyForTier:tier]),
                              A2RS(bundled ? @"runtime.bundled" : @"runtime.notBundled"),
                              cand.identifier];
                [A2Toast show:[NSString stringWithFormat:A2RS(@"runtime.toast.selected"), cand.displayName]
                       inView:hostVC.view];
            }];
        }
        [sheet presentFrom:hostVC];
    };
    return row;
}

#pragma mark - 渲染器插件（导入 / 卸载）

/// 「导入渲染器…」入口 —— 打开 `A2RendererPluginViewController`。
///
/// ★为什么不把导入项塞进上面的渲染器候选表★：启动链只从 `<App>/Frameworks/`
/// 加载（`Natives/Renderer/a2_renderer.h`），而导入的库装在 Documents 下，
/// 在签名环境里根本加载不了 —— 列进选择器就是「选了必定失败」的假选项。
/// 所以这里是**管理入口**，不是第二个「选哪个渲染器」的入口。
+ (A2SettingsRow *)rendererImportRowWithHost:(UIViewController *)host {
    A2SettingsRow *importRow = [[A2SettingsRow alloc] init];
    importRow.symbolName = @"square.and.arrow.down";
    importRow.title = @"导入渲染器…";
    importRow.subtitle = @"导入 .air2plugin（zip）并管理已装的渲染器插件";
    importRow.accessory = A2SettingsRowAccessoryDisclosure;

    __weak UIViewController *weakHost = host;
    importRow.onTap = ^{
        UIViewController *hostVC = weakHost;
        if (hostVC == nil) return;
        A2RendererPluginViewController *vc = [[A2RendererPluginViewController alloc] init];
        [hostVC.navigationController pushViewController:vc animated:YES];
        [A2Log log:@"settings: 打开渲染器插件管理页（导入 / 卸载）"];
    };
    return importRow;
}

#pragma mark - Java 运行时

+ (A2SettingsRow *)javaRuntimeRowWithHost:(UIViewController *)host {
    A2SettingsRow *row = [[A2SettingsRow alloc] init];
    row.symbolName = @"cup.and.saucer.fill";
    row.title = A2RS(@"runtime.row.jre");
    row.accessory = A2SettingsRowAccessoryDisclosure;

    __weak A2SettingsRow *weakRow = row;
    void (^refresh)(void) = ^{
        NSString *dir = A2CurrentJavaRuntimeDirectory();
        NSInteger major = [A2JavaRuntimeCatalog majorVersionForDirectoryName:dir];
        NSString *javaHome = [A2BundleJavaRuntimesPath() stringByAppendingPathComponent:dir];
        BOOL usable = [A2JavaRuntimeCatalog isUsableJavaHome:javaHome];
        weakRow.valueText = [NSString stringWithFormat:@"Java %ld", (long)major];
        weakRow.subtitle = [NSString stringWithFormat:@"%@ · %@ · %@",
                            A2RS([A2JavaRuntimeCatalog mcRangeLocalizationKeyForMajorVersion:major]),
                            A2RS(usable ? @"runtime.bundled" : @"runtime.notBundled"),
                            dir];
    };
    refresh();

    __weak UIViewController *weakHost = host;
    row.onTap = ^{
        UIViewController *hostVC = weakHost;
        if (hostVC == nil) return;

        A2OptionSheet *sheet =
            [A2OptionSheet sheetWithTitle:A2RS(@"runtime.pick.jre.title")
                                  message:A2RS(@"runtime.pick.jre.message")];

        NSString *cur = A2CurrentJavaRuntimeDirectory();
        NSString *runtimesDir = A2BundleJavaRuntimesPath();
        for (NSString *dir in [A2JavaRuntimeCatalog allDirectoryNames]) {
            NSInteger major = [A2JavaRuntimeCatalog majorVersionForDirectoryName:dir];
            NSString *javaHome = [runtimesDir stringByAppendingPathComponent:dir];
            BOOL usable = [A2JavaRuntimeCatalog isUsableJavaHome:javaHome];
            NSString *nameKey = [A2JavaRuntimeCatalog nameLocalizationKeyForDirectoryName:dir];
            NSString *name = A2RS(nameKey);
            if ([name isEqualToString:nameKey]) name = dir;                 // 缺 key ⇒ 目录名兜底
            NSString *title = [NSString stringWithFormat:@"%@ · %@ · %@",
                               name, A2RS([A2JavaRuntimeCatalog mcRangeLocalizationKeyForMajorVersion:major]),
                               A2RS(usable ? @"runtime.bundled" : @"runtime.notBundled")];
            __weak A2SettingsRow *wRow = weakRow;
            [sheet addOptionWithTitle:title
                             selected:[dir isEqualToString:cur]
                          destructive:NO
                              handler:^{
                [NSUserDefaults.standardUserDefaults setObject:dir
                                                        forKey:A2SelectedJavaRuntimePrefKey];
                [A2Log log:@"settings: Java 运行时 → %@（%@）", dir,
                 usable ? @"包内已有" : @"★包内未内置/不完整：启动会如实阻断★"];
                A2SettingsRow *r = wRow;
                r.valueText = [NSString stringWithFormat:@"Java %ld", (long)major];
                r.subtitle = [NSString stringWithFormat:@"%@ · %@ · %@",
                              A2RS([A2JavaRuntimeCatalog mcRangeLocalizationKeyForMajorVersion:major]),
                              A2RS(usable ? @"runtime.bundled" : @"runtime.notBundled"),
                              dir];
                [A2Toast show:[NSString stringWithFormat:A2RS(@"runtime.toast.selected"),
                               [NSString stringWithFormat:@"Java %ld", (long)major]]
                       inView:hostVC.view];
            }];
        }
        [sheet presentFrom:hostVC];
    };
    return row;
}

#pragma mark - 渲染分辨率（[FRAME-PERF]）

+ (A2SettingsRow *)renderScaleRowWithHost:(UIViewController *)host {
    // ★局部名用 scaleRow（而非 row）★：本行文案 key 形如 `runtime.row.scale.*`，
    // 若局部名叫 row，scripts/lint_objc.py 的「block 循环引用」启发式会把字面量里的
    // `row.` 误判成对 row 自身的强引用（假阳性）。换个名字即可，语义不变。
    A2SettingsRow *scaleRow = [[A2SettingsRow alloc] init];
    scaleRow.symbolName = @"rectangle.compress.vertical";
    scaleRow.title = A2RS(@"runtime.row.scale");
    scaleRow.accessory = A2SettingsRowAccessoryDisclosure;

    __weak A2SettingsRow *weakRow = scaleRow;
    void (^refresh)(void) = ^{
        double cur = A2CurrentRenderScale();
        weakRow.valueText = A2RenderScaleDisplayText(cur);
        weakRow.subtitle = A2RS(@"runtime.row.scale.detail");
    };
    refresh();

    __weak UIViewController *weakHost = host;
    scaleRow.onTap = ^{
        UIViewController *hostVC = weakHost;
        if (hostVC == nil) return;

        A2OptionSheet *sheet =
            [A2OptionSheet sheetWithTitle:A2RS(@"runtime.pick.scale.title")
                                  message:A2RS(@"runtime.pick.scale.message")];

        double cur = A2CurrentRenderScale();
        for (NSNumber *cand in [A2RenderScaleCatalog allScales]) {
            double scale = cand.doubleValue;
            __weak A2SettingsRow *wRow = weakRow;
            [sheet addOptionWithTitle:A2RenderScaleDisplayText(scale)
                             selected:(fabs(scale - cur) < 0.001)
                          destructive:NO
                              handler:^{
                // ★写入点唯一★（读取点 = Player 的启动会话；键见 A2LaunchContract.h）。
                NSString *stored = [NSString stringWithFormat:@"%.2f", scale];
                [NSUserDefaults.standardUserDefaults setObject:stored
                                                        forKey:A2SelectedRenderScalePrefKey];
                [A2Log log:@"settings: 渲染分辨率 → %@（%@；下一帧起按缩放后的 drawable 尺寸清屏/呈现）",
                      stored, [A2RenderScaleCatalog displayPercentForScale:scale]];
                A2SettingsRow *r = wRow;
                r.valueText = A2RenderScaleDisplayText(scale);
                r.subtitle = A2RS(@"runtime.row.scale.detail");
                [A2Toast show:[NSString stringWithFormat:A2RS(@"runtime.toast.selected"),
                               [A2RenderScaleCatalog displayPercentForScale:scale]]
                       inView:hostVC.view];
            }];
        }
        [sheet presentFrom:hostVC];
    };
    return scaleRow;
}

@end
