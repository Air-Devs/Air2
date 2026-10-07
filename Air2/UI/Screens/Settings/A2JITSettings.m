//
//  A2JITSettings.m
//  Air2
//
//  运行环境分组 —— JIT 供给面板（最小可跑骨架）。
//
//  [JIT-IMPL] 组成：
//    · 状态行：A2JITStateMachine 的当前状态 + 说明（原因分流，不写万能文案）；
//    · 策略行：A2JITStrategySelector 选出的分级策略 + iOS 版本；
//    · 「导入配对文件」按钮：★按策略启用/禁用★（内核档无需配对文件 ⇒ 禁用）；
//    · 「开启 JIT」按钮：★按策略启用/禁用★（走 A2JITCoordinator.enableJITWithError:）。
//  ★边界★：本骨架不实现真实的 UIDocumentPicker 落盘入库、也不实现 XPC / RPPairing 隧道
//  （第二阶段）；开启会如实走到「等待开启 + 原因」，并据此提示，不假装成功。
//

#import "A2SettingsSections.h"
#import "A2SettingsRow.h"
#import "A2JITFacts.h"
#import "A2JITLocalFactsSource.h"
#import "A2JITCoordinator.h"
#import "A2JITStateMachine.h"
#import "A2JITStrategySelector.h"
#import "A2Toast.h"

@implementation A2JITSettings

+ (A2SettingsSection *)buildWithHost:(UIViewController *)host {
    // 本机事实 + 四路 Provider + 编排器（★非单例★：随分组构建即时构造）。
    A2JITFacts *facts = [A2JITFacts factsWithSource:[A2JITLocalFactsSource new]];
    A2JITCoordinator *coordinator =
        [[A2JITCoordinator alloc] initWithFacts:facts
                                      providers:[A2JITCoordinator defaultProvidersWithFacts:facts]];
    return [self buildWithHost:host facts:facts coordinator:coordinator];
}

/// 可注入重载（单测 / 装配处可传自制事实与编排器）。
+ (A2SettingsSection *)buildWithHost:(UIViewController *)host
                               facts:(A2JITFacts *)facts
                         coordinator:(A2JITCoordinator *)coordinator {
    A2JITStrategyDecision *decision = [A2JITStrategySelector decisionForFacts:facts];

    A2SettingsSection *section = [[A2SettingsSection alloc] initWithTitle:@"运行环境 · JIT"];
    section.footerText = [NSString stringWithFormat:
        @"当前策略：%@。配对文件仅在本机解析校验（不联网）；真实隧道 / 开启机制属下一阶段。",
        [A2JITStrategySelector displayNameForStrategy:decision.strategy]];

    // ---- 状态 ----
    A2SettingsRow *statusRow = [[A2SettingsRow alloc] init];
    statusRow.symbolName = @"bolt.horizontal.circle.fill";
    statusRow.title = @"JIT 状态";
    statusRow.valueText = [A2JITStateMachine displayNameForState:coordinator.state];
    statusRow.subtitle = coordinator.statusDetail.length > 0
        ? coordinator.statusDetail
        : [A2JITStateMachine displayNameForFailureReason:coordinator.failureReason];
    [section addRow:statusRow];

    // ---- 分级策略 ----
    A2SettingsRow *strategyRow = [[A2SettingsRow alloc] init];
    strategyRow.symbolName = @"slider.horizontal.3";
    strategyRow.title = @"分级策略";
    strategyRow.subtitle = [NSString stringWithFormat:@"iOS %ld.%ld", (long)facts.osMajorVersion,
                            (long)facts.osMinorVersion];
    strategyRow.valueText = [A2JITStrategySelector displayNameForStrategy:decision.strategy];
    [section addRow:strategyRow];

    // ---- 导入配对文件（按策略启用/禁用）----
    BOOL needsPairingFile = (decision.strategy == A2JITStrategyBuiltInManual ||
                             decision.strategy == A2JITStrategyAutomatic ||
                             decision.strategy == A2JITStrategyImportedExternal);
    A2SettingsRow *importRow = [[A2SettingsRow alloc] init];
    importRow.symbolName = @"doc.badge.plus";
    importRow.title = @"导入配对文件";
    importRow.subtitle = needsPairingFile ? @"支持 .plist / .mobiledevicepairing（本机校验）"
                                          : @"本策略不需要配对文件";
    importRow.accessory = A2SettingsRowAccessoryDisclosure;
    importRow.enabled = needsPairingFile;
    importRow.onTap = ^{
        [A2Toast show:@"选择 .plist / .mobiledevicepairing（导入 UI 属下一阶段）" inView:host.view];
    };
    [section addRow:importRow];

    // ---- 开启 JIT（按策略启用/禁用）----
    BOOL canEnable = coordinator.hasActiveProvider && decision.strategy != A2JITStrategyUnavailable;
    A2SettingsRow *enableRow = [[A2SettingsRow alloc] init];
    enableRow.symbolName = @"play.circle.fill";
    enableRow.title = @"开启 JIT";
    enableRow.subtitle = canEnable ? @"按策略在 App 内开启" : @"当前环境无可用路径";
    enableRow.accessory = A2SettingsRowAccessoryNone;
    enableRow.enabled = canEnable;
    enableRow.showsBottomSeparator = NO;
    enableRow.onTap = ^{
        NSError *err = nil;
        BOOL ok = [coordinator enableJITWithError:&err];
        NSString *text = ok ? @"JIT 已启用"
                            : [NSString stringWithFormat:@"%@（%@）",
                               coordinator.statusDetail,
                               [A2JITStateMachine displayNameForFailureReason:coordinator.failureReason]];
        [A2Toast show:text inView:host.view];
    };
    [section addRow:enableRow];

    return section;
}

@end
