//
//  home_card_source_tests.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  主页「卡片来源解析」的**行为**单测：跑的是仓内真实实现（A2HomeCardSource.m），
//  不是源码扫描、也不是 Python 复刻。由 tests/Core/run_home_card_source_tests.py 编译运行。
//
//  这也是 `A2HomeCardSourceResolver` 的**第一个调用方** ——
//  在主页 VC（Step 3）接线之前，用它证明三态判定成立、且不删卡。
//
//  钉住的东西（docs/PLUGIN-HOME-STATUS.md §3.3 / §4.5（软失败））：
//    ① 内置卡：kind 有效且已接通 ⇒ Builtin，标题/图标直接映射到现有卡片种类；
//    ② 内置但未接通（收藏存档 / 收藏服务器）⇒ Unavailable，原因与文案来自布局层同一处；
//    ③ 插件卡命中：已安装 + 已启用 + (pluginId, contributionId) 对得上 ⇒ Plugin；
//    ④ 插件被停用      ⇒ Unavailable + 原因「已停用」；
//    ⑤ 插件已卸载      ⇒ Unavailable + 原因「已卸载」（卸载优先于残留的停用标记）；
//    ⑥ 贡献被插件升级删掉 ⇒ Unavailable + 原因「不再提供」；
//    ⑦ 未知 kind / 引用不完整 / 插件目录未就绪 ⇒ Unavailable，不崩、不猜；
//    ⑧ 任何一态都**不改卡片**：卡片的 JSON 前后逐字相同（软失败 = 不删卡）。
//

#import <Foundation/Foundation.h>

#import "A2HomeCardSource.h"

static NSInteger gChecks = 0;
static NSInteger gFailures = 0;

#define CHECK(cond, fmt, ...)                                                      \
    do {                                                                           \
        gChecks++;                                                                 \
        if (!(cond)) {                                                             \
            gFailures++;                                                           \
            NSString *a2_msg = [NSString stringWithFormat:(fmt), ##__VA_ARGS__];    \
            printf("FAIL %s:%d  %s\n", __func__, __LINE__, a2_msg.UTF8String);      \
        }                                                                          \
    } while (0)

#pragma mark - 夹具

/// 一张带存卡名字快照的卡（内置种类）。
static A2HomeCard *CardWithKindAndLabel(A2HomeCardKind kind, NSString *label) {
    A2HomeCard *card = [A2HomeCard cardWithKind:kind];
    card.target = [A2HomeCardTarget targetWithGameHome:@"minecraft"
                                           versionName:@"1.20.1"
                                             worldPath:nil
                                               address:nil
                                         fallbackLabel:label];
    return card;
}

/// 一条插件卡片内容。
static A2HomePluginCardContent *Content(NSString *pluginId,
                                        NSString *contributionId,
                                        NSString *title) {
    return [A2HomePluginCardContent contentWithPluginId:pluginId
                                          pluginVersion:@"1.2.3"
                                         contributionId:contributionId
                                                   slot:@"home.section"
                                                  title:title
                                               subtitle:@"来自插件"
                                             symbolName:@"bolt.fill"];
}

/// 「装了 p.good，且它的 daily 贡献声明了卡片」的常态快照。
static A2HomePluginCardCatalog *GoodCatalog(void) {
    return [A2HomePluginCardCatalog catalogWithInstalledPluginIds:@[@"p.good"]
                                               disabledPluginIds:@[]
                                                        contents:@[Content(@"p.good", @"daily", @"每日挑战")]];
}

#pragma mark - ① 内置卡

static void testBuiltinCardResolvesToExistingKind(void) {
    A2HomeCard *card = CardWithKindAndLabel(A2HomeCardKindRecent, @"1.20.1");
    A2HomeCardSource *source = [A2HomeCardSourceResolver sourceForCard:card];

    CHECK(source.state == A2HomeCardSourceStateBuiltin, @"内置卡应为 Builtin，实际 %ld", (long)source.state);
    CHECK([source isBuiltin] && ![source isPlugin] && ![source isUnavailable], @"三态互斥判定错了");
    CHECK(source.kind == A2HomeCardKindRecent, @"kind 应原样带出");
    CHECK([source.cardID isEqualToString:card.cardID], @"cardID 应指回原卡");
    CHECK([source.title isEqualToString:A2HomeKindDisplayName(A2HomeCardKindRecent)],
          @"内置卡标题应等于类型名，实际 %@", source.title);
    CHECK([source.symbolName isEqualToString:A2HomeKindSymbolName(A2HomeCardKindRecent)],
          @"内置卡图标应等于类型图标，实际 %@", source.symbolName);
    CHECK(source.unavailableReason == nil, @"命中的内置卡不该有原因");
    CHECK(source.allowsRetarget == NO, @"命中的内置卡不该建议重指定");
}

static void testEveryAvailableKindIsBuiltin(void) {
    for (NSInteger raw = (NSInteger)A2HomeCardKindGreeting;
         raw <= (NSInteger)A2HomeCardKindShortcutCustom; raw++) {
        A2HomeCardKind kind = (A2HomeCardKind)raw;
        A2HomeCard *card = CardWithKindAndLabel(kind, @"x");
        A2HomeCardSource *source = [A2HomeCardSourceResolver sourceForCard:card];
        if (A2HomeKindIsAvailable(kind)) {
            CHECK(source.state == A2HomeCardSourceStateBuiltin, @"%@ 应解析为内置卡", A2HomeCardKindToken(kind));
        } else {
            CHECK(source.state == A2HomeCardSourceStateUnavailable, @"%@ 本版未接通，应为不可用",
                  A2HomeCardKindToken(kind));
        }
    }
}

#pragma mark - ② 内置但本版未接通

static void testBuiltinNotWiredIsUnavailableWithLayoutReason(void) {
    A2HomeCard *card = CardWithKindAndLabel(A2HomeCardKindPinnedWorlds, @"我的世界");
    A2HomeCardSource *source = [A2HomeCardSourceResolver sourceForCard:card];

    CHECK(source.isUnavailable, @"收藏存档本版未接通，应为不可用");
    // 文案只能有一处实现：直接引用布局层的摘要，而不是在这里再写一句。
    CHECK([source.unavailableReason isEqualToString:A2HomeKindSummary(A2HomeCardKindPinnedWorlds)],
          @"原因应复用布局层摘要，实际 %@", source.unavailableReason);
    CHECK([source.title isEqualToString:A2HomeKindDisplayName(A2HomeCardKindPinnedWorlds)],
          @"标题应是类型名，实际 %@", source.title);
    CHECK(source.allowsRetarget == NO, @"类型未接通不是用户指错了，不该建议重指定");
}

#pragma mark - ③ 插件卡命中

static void testPluginCardHit(void) {
    A2HomeCard *card = CardWithKindAndLabel(A2HomeCardKindShortcutCustom, @"存卡时的名字");
    A2HomeCardSource *source = [A2HomeCardSourceResolver sourceForCard:card
                                                              pluginId:@"p.good"
                                                        contributionId:@"daily"
                                                               catalog:GoodCatalog()];

    CHECK(source.state == A2HomeCardSourceStatePlugin, @"应对上插件贡献，实际 %ld", (long)source.state);
    CHECK([source isPlugin] && ![source isBuiltin] && ![source isUnavailable], @"三态互斥判定错了");
    CHECK([source.title isEqualToString:@"每日挑战"], @"插件卡标题应取贡献标题，实际 %@", source.title);
    CHECK([source.subtitle isEqualToString:@"来自插件"], @"副标题应取贡献副标题，实际 %@", source.subtitle);
    CHECK([source.symbolName isEqualToString:@"bolt.fill"], @"图标应取贡献图标，实际 %@", source.symbolName);
    CHECK([source.pluginId isEqualToString:@"p.good"], @"pluginId 应带出");
    CHECK([source.pluginVersion isEqualToString:@"1.2.3"], @"插件版本应带出（诊断用）");
    CHECK([source.contributionId isEqualToString:@"daily"], @"contributionId 应带出");
    CHECK([source.slot isEqualToString:@"home.section"], @"slot 应带出（诊断用）");
    CHECK(source.unavailableReason == nil, @"命中的插件卡不该有原因");
}

static void testPluginCardWithoutCardInstance(void) {
    // 编辑态「预览一张插件卡」时还没有卡片实例 —— 模型层不该要求卡片先存在。
    A2HomeCardSource *source = [A2HomeCardSourceResolver sourceForCard:nil
                                                              pluginId:@"p.good"
                                                        contributionId:@"daily"
                                                               catalog:GoodCatalog()];
    CHECK(source.isPlugin, @"卡片为 nil 也应能解析出插件内容");
    CHECK(source.cardID == nil, @"没有卡片时 cardID 应为 nil");
}

static void testPluginCardFallsBackToPluginIdWhenTitleMissing(void) {
    A2HomePluginCardCatalog *catalog =
        [A2HomePluginCardCatalog catalogWithInstalledPluginIds:@[@"p.good"]
                                            disabledPluginIds:@[]
                                                     contents:@[Content(@"p.good", @"daily", nil)]];
    A2HomeCardSource *source = [A2HomeCardSourceResolver sourceForCard:nil
                                                              pluginId:@"p.good"
                                                        contributionId:@"daily"
                                                               catalog:catalog];
    CHECK([source.title isEqualToString:@"p.good"], @"没有标题时应回落到 pluginId，实际 %@", source.title);
    CHECK(source.symbolName.length > 0, @"没有图标时也必须有兜底图标");
}

#pragma mark - ④ 插件被停用

static void testPluginDisabledIsPlaceholderNotDeletion(void) {
    A2HomeCard *card = CardWithKindAndLabel(A2HomeCardKindShortcutCustom, @"存卡时的名字");
    NSString *before = [[card JSONObjectIncludingPosition:YES] description];

    A2HomePluginCardCatalog *catalog =
        [A2HomePluginCardCatalog catalogWithInstalledPluginIds:@[@"p.good"]
                                            disabledPluginIds:@[@"p.good"]
                                                     contents:@[Content(@"p.good", @"daily", @"每日挑战")]];
    A2HomeCardSource *source = [A2HomeCardSourceResolver sourceForCard:card
                                                              pluginId:@"p.good"
                                                        contributionId:@"daily"
                                                               catalog:catalog];

    CHECK(source.isUnavailable, @"停用的插件卡应为不可用");
    CHECK(source.pluginAvailability == A2HomePluginCardAvailabilityPluginDisabled, @"原因细分应是 disabled");
    CHECK([source.unavailableReason containsString:@"已停用"], @"原因应说明已停用，实际 %@", source.unavailableReason);
    CHECK([source.title isEqualToString:@"存卡时的名字"], @"占位标题应回落到存卡名字，实际 %@", source.title);
    CHECK(source.allowsRetarget, @"插件侧不可用应允许用户重新指定");
    CHECK([before isEqualToString:[[card JSONObjectIncludingPosition:YES] description]],
          @"解析不得改动卡片（软失败 = 不删卡）");
}

#pragma mark - ⑤ 插件已卸载

static void testPluginUninstalledWinsOverStaleDisabledFlag(void) {
    A2HomeCard *card = CardWithKindAndLabel(A2HomeCardKindShortcutCustom, @"存卡时的名字");
    // 卸载后停用标记可能残留：判定顺序必须是「未安装」优先，否则会说成「已停用」。
    A2HomePluginCardCatalog *catalog =
        [A2HomePluginCardCatalog catalogWithInstalledPluginIds:@[]
                                            disabledPluginIds:@[@"p.gone"]
                                                     contents:@[]];
    A2HomeCardSource *source = [A2HomeCardSourceResolver sourceForCard:card
                                                              pluginId:@"p.gone"
                                                        contributionId:@"daily"
                                                               catalog:catalog];

    CHECK(source.isUnavailable, @"卸载的插件卡应为不可用");
    CHECK(source.pluginAvailability == A2HomePluginCardAvailabilityPluginMissing, @"原因细分应是 missing");
    CHECK([source.unavailableReason containsString:@"已卸载"], @"原因应说明已卸载，实际 %@", source.unavailableReason);
    CHECK([source.title isEqualToString:@"存卡时的名字"], @"占位仍要知道自己本来是什么");
}

#pragma mark - ⑥ 贡献没了

static void testContributionRemovedByUpgrade(void) {
    A2HomePluginCardCatalog *catalog =
        [A2HomePluginCardCatalog catalogWithInstalledPluginIds:@[@"p.good"]
                                            disabledPluginIds:@[]
                                                     contents:@[Content(@"p.good", @"other", @"别的卡")]];
    A2HomeCardSource *source = [A2HomeCardSourceResolver sourceForCard:nil
                                                              pluginId:@"p.good"
                                                        contributionId:@"daily"
                                                               catalog:catalog];
    CHECK(source.isUnavailable, @"贡献不在了应为不可用");
    CHECK(source.pluginAvailability == A2HomePluginCardAvailabilityContributionMissing,
          @"原因细分应是 contribution");
    CHECK([source.unavailableReason containsString:@"不再提供"], @"原因应说明贡献已撤，实际 %@", source.unavailableReason);
}

#pragma mark - ⑦ 未知 / 不完整 / 未就绪

static void testUnknownKindIsUnavailable(void) {
    A2HomeCard *card = CardWithKindAndLabel((A2HomeCardKind)99, @"未来版本的卡");
    A2HomeCardSource *source = [A2HomeCardSourceResolver sourceForCard:card];

    CHECK(source.isUnavailable, @"未知 kind 应为不可用，不能崩也不能猜");
    CHECK([source.unavailableReason containsString:@"未知的卡片类型"], @"原因应说明未知类型，实际 %@",
          source.unavailableReason);
    CHECK([source.title isEqualToString:@"未来版本的卡"], @"未知 kind 也要用名字快照做占位标题");
    CHECK(source.symbolName.length > 0, @"不可用态也要有图标");
}

static void testIncompletePluginReferenceIsUnavailable(void) {
    A2HomeCard *card = CardWithKindAndLabel(A2HomeCardKindShortcutCustom, @"存卡时的名字");

    A2HomeCardSource *emptyIds = [A2HomeCardSourceResolver sourceForCard:card
                                                                pluginId:@""
                                                          contributionId:@""
                                                                 catalog:GoodCatalog()];
    CHECK(emptyIds.isUnavailable, @"缺 pluginId/contributionId 应为不可用");

    A2HomeCardSource *halfIds = [A2HomeCardSourceResolver sourceForCard:card
                                                               pluginId:@"p.good"
                                                         contributionId:@""
                                                                catalog:GoodCatalog()];
    CHECK(halfIds.isUnavailable, @"只给一半标识也应为不可用");
    CHECK([halfIds.title isEqualToString:@"存卡时的名字"], @"不可用时标题仍是名字快照");
}

static void testMissingCatalogIsUnavailable(void) {
    A2HomeCardSource *source = [A2HomeCardSourceResolver sourceForCard:nil
                                                              pluginId:@"p.good"
                                                        contributionId:@"daily"
                                                               catalog:nil];
    CHECK(source.isUnavailable, @"插件目录还没装配时应占位，而不是画一张没有内容的卡");
    CHECK([source.title isEqualToString:@"p.good"], @"没有卡片也没有快照时，标题回落到 pluginId，实际 %@",
          source.title);
}

#pragma mark - ⑧ 快照规范化

static void testCatalogNormalizesInput(void) {
    A2HomePluginCardCatalog *catalog =
        [A2HomePluginCardCatalog catalogWithInstalledPluginIds:@[@"p.a", @"p.a", @"", @"p.b"]
                                            disabledPluginIds:@[@"p.b", @"p.b"]
                                                     contents:@[Content(@"p.a", @"one", @"第一条"),
                                                                Content(@"p.a", @"one", @"重复的那条"),
                                                                Content(@"", @"x", @"没有插件 id"),
                                                                Content(@"p.a", @"", @"没有贡献 id")]];

    CHECK(catalog.installedPluginIds.count == 2, @"已安装列表应去重并丢掉空值，实际 %lu",
          (unsigned long)catalog.installedPluginIds.count);
    CHECK(catalog.disabledPluginIds.count == 1, @"停用列表应去重，实际 %lu",
          (unsigned long)catalog.disabledPluginIds.count);
    CHECK(catalog.contents.count == 1, @"同一 (pluginId, contributionId) 只留第一条、空标识条目丢掉，实际 %lu",
          (unsigned long)catalog.contents.count);

    A2HomePluginCardContent *content = nil;
    A2HomePluginCardAvailability availability =
        [catalog availabilityForPluginId:@"p.a" contributionId:@"one" content:&content];
    CHECK(availability == A2HomePluginCardAvailabilityAvailable, @"去重后仍应命中");
    CHECK([content.title isEqualToString:@"第一条"], @"重复声明应保留先声明者，实际 %@", content.title);

    // 未命中时不能把 outContent 改成别的东西。
    A2HomePluginCardContent *untouched = content;
    [catalog availabilityForPluginId:@"p.a" contributionId:@"nope" content:&untouched];
    CHECK(untouched == content, @"未命中时不应改动 outContent");

    // 空标识在查表层也视为「对不上」。
    CHECK([catalog availabilityForPluginId:@"" contributionId:@"" content:NULL]
          == A2HomePluginCardAvailabilityContributionMissing, @"空标识应视为贡献对不上");
}

static void testAvailabilityNamesAreStable(void) {
    // 这几个字符串会进判据行，改了就断掉既有日志的检索。
    CHECK([A2HomePluginCardAvailabilityName(A2HomePluginCardAvailabilityAvailable) isEqualToString:@"available"],
          @"available 名字变了");
    CHECK([A2HomePluginCardAvailabilityName(A2HomePluginCardAvailabilityPluginDisabled) isEqualToString:@"disabled"],
          @"disabled 名字变了");
    CHECK([A2HomePluginCardAvailabilityName(A2HomePluginCardAvailabilityPluginMissing) isEqualToString:@"missing"],
          @"missing 名字变了");
    CHECK([A2HomePluginCardAvailabilityName(A2HomePluginCardAvailabilityContributionMissing) isEqualToString:@"contribution"],
          @"contribution 名字变了");
}

#pragma mark - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        testBuiltinCardResolvesToExistingKind();
        testEveryAvailableKindIsBuiltin();
        testBuiltinNotWiredIsUnavailableWithLayoutReason();
        testPluginCardHit();
        testPluginCardWithoutCardInstance();
        testPluginCardFallsBackToPluginIdWhenTitleMissing();
        testPluginDisabledIsPlaceholderNotDeletion();
        testPluginUninstalledWinsOverStaleDisabledFlag();
        testContributionRemovedByUpgrade();
        testUnknownKindIsUnavailable();
        testIncompletePluginReferenceIsUnavailable();
        testMissingCatalogIsUnavailable();
        testCatalogNormalizesInput();
        testAvailabilityNamesAreStable();

        printf("\n__HOME_CARD_SOURCE_CHECKS=%ld\n", (long)gChecks);
        printf("__HOME_CARD_SOURCE_FAILURES=%ld\n", (long)gFailures);
        printf("__HOME_CARD_SOURCE_EXIT=%d\n", gFailures == 0 ? 0 : 1);
    }
    return gFailures == 0 ? 0 : 1;
}
