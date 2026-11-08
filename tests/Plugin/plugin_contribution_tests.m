//
//  plugin_contribution_tests.m
//  Air2 —— tests/Plugin：★P2 贡献点（manifest v2 纯 JSON 声明 + 注册表）单测★
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（直接链接真实实现，不是文本镜像）：
//    Air2/Core/Plugin/A2PluginContribution.m ← 贡献点深校验 / 词表 / 注册表去重与排序
//    另外链 A2PluginManifest.m —— 只为复用它的语义化版本比较、插件 id 判定与错误构造，
//    本文件不重复造那三样东西（口径只能有一处）。
//
//  为什么每一条都要有：
//    「未知 slot 拒装」「type:js 拒装」「卸载后回到接入前」这些都是**行为**，
//    源码扫描只能证明文字在文件里。下面每条反例对应 docs 里的一条硬约束：
//      · slot / component 词表  → ADR-018 决策 2、PLUGIN-COMPAT.md 2.2 / 2.3
//      · 未知 token 降级不拒装  → ADR-018 决策 5
//      · type:js 在 P2 拒装     → ADR-019、PLUGIN-COMPAT.md 第六节
//      · 顺序键三元组 + pluginId → PLUGIN-SYSTEM.md 5.2
//      · 独占 slot 安装期拒装   → ADR-018 决策 6
//
//  运行：python3 tests/Plugin/run_plugin_tests.py
//

#import <Foundation/Foundation.h>

#import "A2PluginContribution.h"
#import "A2PluginManifest.h"

static int gPass = 0;
static int gFail = 0;

static void ok(BOOL condition, NSString *what) {
    if (condition) {
        gPass++;
        printf("PASS  %s\n", what.UTF8String);
    } else {
        gFail++;
        printf("FAIL  %s\n", what.UTF8String);
    }
}

static void eqStr(NSString *got, NSString *want, NSString *what) {
    NSString *gotText = got ?: @"(nil)";
    NSString *wantText = want ?: @"(nil)";
    ok([gotText isEqualToString:wantText],
       [NSString stringWithFormat:@"%@（得到 %@，期望 %@）", what, gotText, wantText]);
}

static void eqInt(NSInteger got, NSInteger want, NSString *what) {
    ok(got == want, [NSString stringWithFormat:@"%@（得到 %ld，期望 %ld）",
                     what, (long)got, (long)want]);
}

/// 失败时断言「码 + 字段」两件都对：只断码会让「报对了码但指错字段」蒙混过关，
/// 而字段路径正是作者改了半天的那个东西。
static void expectError(NSString *code, NSString *field, NSError *error, NSString *what) {
    if (error == nil) {
        ok(NO, [NSString stringWithFormat:@"%@（没有报错）", what]);
        return;
    }
    NSString *gotCode = [error.userInfo objectForKey:A2PluginErrorCodeKey];
    NSString *gotField = [error.userInfo objectForKey:A2PluginErrorFieldKey];
    NSString *summary = [NSString stringWithFormat:@"%@（码 %@／字段 %@）",
                         what, gotCode ?: @"(无码)", gotField ?: @"(无字段)"];
    if (![gotCode isEqualToString:code]) {
        ok(NO, [NSString stringWithFormat:@"%@（期望码 %@）", summary, code]);
        return;
    }
    if (field != nil && ![gotField isEqualToString:field]) {
        ok(NO, [NSString stringWithFormat:@"%@（期望字段 %@）", summary, field]);
        return;
    }
    ok(YES, summary);
}

#pragma mark - 素材

/// 合法的最小 manifest：type=json、申请 ui.contribute、无 ui / contributes。
/// 所有反例都在它上面改**一处** —— 这样「为什么被拒」只可能来自那一处改动。
static NSMutableDictionary *BaseManifest(void) {
    return [NSMutableDictionary dictionaryWithDictionary:@{
        @"formatVersion": @2,
        @"id": @"top.example.hello",
        @"name": @"Hello",
        @"version": @"1.0.0",
        @"type": @"json",
        @"air2": @{ @"host": @{ @"apiVersion": @1, @"minHostVersion": @"0.1.0" } },
        @"platforms": @[ @"ios" ],
        @"permissions": @[ @"ui.contribute", @"version.decorate" ],
        @"files": @[],
    }];
}

static NSDictionary *SlotItem(NSString *slot, NSString *component, NSString *identifier,
                             NSInteger priority) {
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    [item setObject:slot forKey:@"slot"];
    [item setObject:component forKey:@"component"];
    if (identifier != nil) [item setObject:identifier forKey:@"id"];
    [item setObject:[NSNumber numberWithInteger:priority] forKey:@"priority"];
    [item setObject:@{ @"text": @"示例" } forKey:@"label"];
    return item;
}

/// 一份「什么都用上」的 manifest：slot + theme + versionDecorate + 设置项。
static NSMutableDictionary *FullManifest(void) {
    NSMutableDictionary *manifest = BaseManifest();
    [manifest setObject:@{
        @"priority": @0,
        @"slots": @[
            SlotItem(@"home.card.badge", @"badge.status", nil, 10),
            SlotItem(@"settings.section", @"switch.toggle", @"hello.enabled", 0),
        ],
        @"theme": @{ @"tokens": @{ @"color.accent": @"#7C4DFF" } },
    } forKey:@"ui"];
    [manifest setObject:@{
        @"versionDecorate": @{
            @"subtitleTemplate": @"由 Hello 插件标注",
            @"badge": @{ @"i18n": @"badge.example" },
        },
    } forKey:@"contributes"];
    return manifest;
}

static A2PluginContributionSet *Parse(NSDictionary *manifest, NSError **error) {
    return [A2PluginContributionSet setWithManifestDictionary:manifest
                                                  hostVersion:@"0.1.0"
                                                    milestone:A2PluginHostMilestoneP2
                                                        error:error];
}

static A2PluginContributionSet *ParseWithHost(NSDictionary *manifest, NSString *hostVersion,
                                              A2PluginHostMilestone milestone, NSError **error) {
    return [A2PluginContributionSet setWithManifestDictionary:manifest
                                                  hostVersion:hostVersion
                                                    milestone:milestone
                                                        error:error];
}

#pragma mark - ① 正常包

static void testHappyPath(void) {
    printf("\n--- 正常包：一份 manifest 把四类贡献都声明了 ---\n");
    NSError *error = nil;
    A2PluginContributionSet *set = Parse(FullManifest(), &error);
    ok(set != nil, [NSString stringWithFormat:@"完整 manifest 应校验通过（%@）",
                    error.localizedDescription ?: @"无错误"]);
    if (set == nil) return;

    eqStr(set.pluginId, @"top.example.hello", @"贡献集带上插件 id");
    eqStr(set.pluginVersion, @"1.0.0", @"贡献集带上插件版本");
    eqInt(set.layer, A2PluginContributionLayerDecor, @"申请了 ui.contribute ⇒ L1");
    eqInt((NSInteger)set.slotContributions.count, 2, @"两条 slot 贡献都在");
    eqStr([[set slotContributions][0] slot], @"home.card.badge", @"第一条的 slot");
    eqStr([[set slotContributions][0] component], @"badge.status", @"第一条的 component");
    eqInt([[set slotContributions][0] priority], 10, @"条目自己的 priority 覆盖插件级默认值");

    eqInt((NSInteger)set.themeTokens.count, 1, @"一个主题 token 通过校验");
    eqStr([set.themeTokens objectForKey:@"color.accent"], @"#7C4DFF", @"token 值原样保留");

    ok(set.versionDecoration != nil, @"版本行装饰解出来了");
    eqStr(set.versionDecoration.subtitleTemplate, @"由 Hello 插件标注", @"副标题模板");
    eqStr(set.versionDecoration.badgeI18n, @"badge.example", @"徽标走 i18n 而不是字面量");
    ok(set.versionDecoration.badgeText == nil, @"badge 只允许 i18n / text 二选一");
    eqInt(set.versionDecoration.layer, A2PluginContributionLayerDecor, @"装饰的层跟随插件");

    NSArray<A2PluginSlotContribution *> *settings = [set settingsItems];
    eqInt((NSInteger)settings.count, 1, @"settings.section 的条目被识别成设置项");
    eqStr([settings[0] identifier], @"hello.enabled", @"设置项的键就是条目的 id");
    eqInt((NSInteger)set.diagnostics.count, 0, @"正常包没有降级诊断");

    // 条目没写 priority ⇒ 按 schema 的默认值 0（不是跟随 ui.priority，那是插件级排序键）。
    NSMutableDictionary *noEntryPriority = BaseManifest();
    [noEntryPriority setObject:@{ @"priority": @50,
                                  @"slots": @[ @{ @"slot": @"home.card.badge",
                                                  @"component": @"badge.status" } ] }
                        forKey:@"ui"];
    error = nil;
    A2PluginContributionSet *noEntryPrioritySet = Parse(noEntryPriority, &error);
    ok(noEntryPrioritySet != nil, @"最简 slot 条目（只有 slot + component）应合法");
    eqInt(noEntryPrioritySet.slotContributions[0].priority, 0, @"条目 priority 默认 0");
    eqInt(noEntryPrioritySet.slotContributions[0].pluginPriority, 50,
          @"插件级 ui.priority 单独保存（排序第一级）");

    // 原始字节入口（安装链实际走的那条）也要给出同样的结果。
    NSData *data = [NSJSONSerialization dataWithJSONObject:FullManifest() options:0 error:NULL];
    NSError *dataError = nil;
    A2PluginContributionSet *fromData =
        [A2PluginContributionSet setWithManifestData:data
                                         hostVersion:@"0.1.0"
                                           milestone:A2PluginHostMilestoneP2
                                               error:&dataError];
    ok(fromData != nil, [NSString stringWithFormat:@"从 manifest.json 原始字节能构造（%@）",
                         dataError.localizedDescription ?: @"无错误"]);
    eqInt((NSInteger)fromData.slotContributions.count, 2, @"字节入口与字典入口结果一致");

    NSError *badDataError = nil;
    A2PluginContributionSet *badData =
        [A2PluginContributionSet setWithManifestData:[@"{not json" dataUsingEncoding:NSUTF8StringEncoding]
                                         hostVersion:@"0.1.0"
                                           milestone:A2PluginHostMilestoneP2
                                               error:&badDataError];
    ok(badData == nil, @"坏 JSON 构造失败");
    expectError(@"E_FORMAT", nil, badDataError, @"坏 JSON 报 E_FORMAT");
}

#pragma mark - ② 缺字段 / 类型错

static void testMissingAndTypedFields(void) {
    printf("\n--- 缺字段 / 类型错：每种都要给码 + 字段路径 ---\n");

    // 缺 component（slot 是已知的，条目里少了必填的 component）
    NSMutableDictionary *missingComponent = BaseManifest();
    [missingComponent setObject:@{ @"slots": @[ @{ @"slot": @"home.toolbar.action" } ] }
                         forKey:@"ui"];
    NSError *error = nil;
    ok(Parse(missingComponent, &error) == nil, @"ui.slots 缺 component 应被拒");
    expectError(@"E_FIELD", @"ui.slots[0].component", error, @"缺 component 指向具体条目字段");

    // ui 不是对象
    NSMutableDictionary *uiNotObject = BaseManifest();
    [uiNotObject setObject:@"bad" forKey:@"ui"];
    error = nil;
    ok(Parse(uiNotObject, &error) == nil, @"ui 不是对象应被拒");
    expectError(@"E_FIELD", @"ui", error, @"ui 类型错指向 ui");

    // priority 越界
    NSMutableDictionary *priorityRange = BaseManifest();
    [priorityRange setObject:@{ @"priority": @1001 } forKey:@"ui"];
    error = nil;
    ok(Parse(priorityRange, &error) == nil, @"ui.priority 超出 -1000…1000 应被拒");
    expectError(@"E_FIELD", @"ui.priority", error, @"priority 越界指向 ui.priority");

    // label 既没有 i18n 也没有 text
    NSMutableDictionary *badLabel = BaseManifest();
    NSMutableDictionary *item = [NSMutableDictionary dictionaryWithDictionary:
                                 SlotItem(@"home.card.badge", @"badge.status", nil, 0)];
    [item setObject:@{} forKey:@"label"];
    [badLabel setObject:@{ @"slots": @[ item ] } forKey:@"ui"];
    error = nil;
    ok(Parse(badLabel, &error) == nil, @"label 为空对象应被拒");
    expectError(@"E_FIELD", @"ui.slots[0].label", error, @"label 形状错指向 label");

    // slot 条目里的未知字段
    NSMutableDictionary *unknownField = BaseManifest();
    NSMutableDictionary *extra = [NSMutableDictionary dictionaryWithDictionary:
                                  SlotItem(@"home.card.badge", @"badge.status", nil, 0)];
    [extra setObject:@"x" forKey:@"colour"];
    [unknownField setObject:@{ @"slots": @[ extra ] } forKey:@"ui"];
    error = nil;
    ok(Parse(unknownField, &error) == nil, @"slot 条目出现未知字段应被拒");
    expectError(@"E_FIELD", @"ui.slots[0]", error, @"未知字段报出所在条目");

    // 设置项缺 id
    NSMutableDictionary *settingsNoId = BaseManifest();
    [settingsNoId setObject:@{ @"slots": @[ SlotItem(@"settings.section", @"switch.toggle", nil, 0) ] }
                     forKey:@"ui"];
    error = nil;
    ok(Parse(settingsNoId, &error) == nil, @"settings.section 的条目没写 id 应被拒");
    expectError(@"E_FIELD", @"ui.slots[0].id", error,
                @"设置项缺 id 报「宿主没法持久化」那条");

    // 主题 token 的值类型错
    NSMutableDictionary *tokenValue = BaseManifest();
    [tokenValue setObject:@{ @"theme": @{ @"tokens": @{ @"color.accent": @7 } } } forKey:@"ui"];
    error = nil;
    ok(Parse(tokenValue, &error) == nil, @"token 值是数字应被拒");
    expectError(@"E_FIELD", @"ui.theme.tokens.color.accent", error, @"token 值类型错指向具体 token");

    // 已知 token 但颜色格式不对
    NSMutableDictionary *badColor = BaseManifest();
    [badColor setObject:@{ @"theme": @{ @"tokens": @{ @"color.accent": @"purple" } } } forKey:@"ui"];
    error = nil;
    ok(Parse(badColor, &error) == nil, @"已知 token 的颜色不是 #RRGGBB 应被拒");
    expectError(@"E_FIELD", @"ui.theme.tokens.color.accent", error, @"颜色格式错报得出来");

    // versionDecorate 空对象（等于什么都没装饰）
    NSMutableDictionary *emptyDecorate = BaseManifest();
    [emptyDecorate setObject:@{ @"versionDecorate": @{} } forKey:@"contributes"];
    error = nil;
    ok(Parse(emptyDecorate, &error) == nil, @"空的 versionDecorate 应被拒");
    expectError(@"E_FIELD", @"contributes.versionDecorate", error, @"空装饰对象给出明确原因");
}

#pragma mark - ③ 未知贡献点 / slot / component

static void testUnknownContributionPoints(void) {
    printf("\n--- 未知贡献点：白名单之外的键一律拒 ---\n");

    NSMutableDictionary *unknownUI = BaseManifest();
    [unknownUI setObject:@{ @"footer": @{} } forKey:@"ui"];
    NSError *error = nil;
    ok(Parse(unknownUI, &error) == nil, @"ui.footer 应被拒");
    expectError(@"E_CONTRIB_UNKNOWN", @"ui.footer", error, @"未知 ui 贡献点报 E_CONTRIB_UNKNOWN");

    NSMutableDictionary *unknownContributes = BaseManifest();
    [unknownContributes setObject:@{ @"badge": @{} } forKey:@"contributes"];
    error = nil;
    ok(Parse(unknownContributes, &error) == nil, @"contributes.badge 应被拒");
    expectError(@"E_CONTRIB_UNKNOWN", @"contributes.badge", error,
                @"未知数据层贡献点报 E_CONTRIB_UNKNOWN");

    // P4 的贡献点：是「认识的、但本阶段不支持」—— 报的码相同，原因要说得更具体。
    NSMutableDictionary *p4 = BaseManifest();
    [p4 setObject:@{ @"downloadSources": @[] } forKey:@"contributes"];
    error = nil;
    ok(Parse(p4, &error) == nil, @"contributes.downloadSources 在 P2 应被拒");
    expectError(@"E_CONTRIB_UNKNOWN", @"contributes.downloadSources", error,
                @"P4 贡献点报 E_CONTRIB_UNKNOWN 并说明阶段");

    // v3 字段：P1 也会拦，但本层不能靠 P1 —— 这里再拦一次。
    NSMutableDictionary *v3Field = BaseManifest();
    [v3Field setObject:@{ @"pages": @[] } forKey:@"ui"];
    error = nil;
    ok(Parse(v3Field, &error) == nil, @"ui.pages 在 P2 应被拒");
    expectError(@"E_CONTRIB_UNKNOWN", @"ui.pages", error, @"v3 贡献点在本阶段被拒");

    printf("\n--- slot / component 词表 ---\n");
    NSMutableDictionary *badSlot = BaseManifest();
    [badSlot setObject:@{ @"slots": @[ SlotItem(@"home.footer.action", @"text.label", nil, 0) ] }
                forKey:@"ui"];
    error = nil;
    ok(Parse(badSlot, &error) == nil, @"白名单外的 slot 应被拒");
    expectError(@"E_SLOT_UNKNOWN", @"ui.slots[0].slot", error,
                @"未知 slot 报 E_SLOT_UNKNOWN（不是笼统的 E_FIELD）");

    NSMutableDictionary *v3Slot = BaseManifest();
    [v3Slot setObject:@{ @"slots": @[ SlotItem(@"home.page", @"text.label", nil, 0) ] } forKey:@"ui"];
    error = nil;
    ok(Parse(v3Slot, &error) == nil, @"v3 的 home.page 在 v2 包应被拒");
    expectError(@"E_SLOT_UNKNOWN", @"ui.slots[0].slot", error,
                @"v3 slot 报 E_SLOT_UNKNOWN 并说明属 v3");

    NSMutableDictionary *badComponent = BaseManifest();
    [badComponent setObject:@{ @"slots": @[ SlotItem(@"home.toolbar.action", @"UIButton", nil, 0) ] }
                     forKey:@"ui"];
    error = nil;
    ok(Parse(badComponent, &error) == nil, @"平台控件名当 component 应被拒");
    expectError(@"E_COMPONENT_UNKNOWN", @"ui.slots[0].component", error,
                @"平台控件名（UIButton）报 E_COMPONENT_UNKNOWN");

    NSMutableDictionary *containerComponent = BaseManifest();
    [containerComponent setObject:@{ @"slots": @[ SlotItem(@"home.section", @"column", nil, 0) ] }
                           forKey:@"ui"];
    error = nil;
    ok(Parse(containerComponent, &error) == nil, @"容器组件放 slot 应被拒（容器属页面模型）");
    expectError(@"E_COMPONENT_UNKNOWN", @"ui.slots[0].component", error,
                @"容器组件在 v2 slot 里报 E_COMPONENT_UNKNOWN");
}

#pragma mark - ④ 重复贡献

static void testDuplicates(void) {
    printf("\n--- 重复贡献：相同合并、不同拒装 ---\n");

    // 完全重复（同 slot、同 id、同内容）⇒ 合并成一条 + 诊断，不拒装。
    NSMutableDictionary *identical = BaseManifest();
    NSDictionary *item = SlotItem(@"home.toolbar.action", @"button.primary", @"hello.run", 5);
    [identical setObject:@{ @"slots": @[ item, item ] } forKey:@"ui"];
    NSError *error = nil;
    A2PluginContributionSet *set = Parse(identical, &error);
    ok(set != nil, [NSString stringWithFormat:@"完全重复的声明应合并而不是拒装（%@）",
                    error.localizedDescription ?: @"无错误"]);
    eqInt((NSInteger)set.slotContributions.count, 1, @"两条完全相同的声明合并成一条");
    ok(set.diagnostics.count == 1, @"合并要留一条诊断（用户/作者能看见发生了什么）");

    // 同 slot 同 id、内容不同 ⇒ 拒装：宿主无法替作者选。
    NSMutableDictionary *conflict = BaseManifest();
    NSMutableDictionary *second = [NSMutableDictionary dictionaryWithDictionary:
                                   SlotItem(@"home.toolbar.action", @"button.primary", @"hello.run", 5)];
    [second setObject:@{ @"text": @"另一个" } forKey:@"label"];   // 同 id、内容不同
    [conflict setObject:@{ @"slots": @[
                        SlotItem(@"home.toolbar.action", @"button.primary", @"hello.run", 5), second ] }
                 forKey:@"ui"];
    error = nil;
    ok(Parse(conflict, &error) == nil, @"同 id 内容不同应被拒");
    expectError(@"E_CONTRIB_DUPLICATE", @"ui.slots[1]", error,
                @"同 id 冲突报 E_CONTRIB_DUPLICATE 并指出后一条");

    // 同 slot 但不同 id / 不同内容 ⇒ 合法（一个 slot 可以放两个按钮）。
    NSMutableDictionary *siblings = BaseManifest();
    [siblings setObject:@{ @"slots": @[
                        SlotItem(@"home.toolbar.action", @"button.primary", @"hello.a", 0),
                        SlotItem(@"home.toolbar.action", @"button.secondary", @"hello.b", 0) ] }
                 forKey:@"ui"];
    error = nil;
    A2PluginContributionSet *siblingSet = Parse(siblings, &error);
    ok(siblingSet != nil, @"同 slot 的两条不同贡献应合法");
    eqInt((NSInteger)siblingSet.slotContributions.count, 2, @"两条都保留");
}

#pragma mark - ⑤ 版本不兼容

static void testHostVersion(void) {
    printf("\n--- 版本区间：minHostVersion / maxHostVersion / formatVersion ---\n");

    NSMutableDictionary *tooNew = BaseManifest();
    [tooNew setObject:@{ @"host": @{ @"apiVersion": @1, @"minHostVersion": @"9.0.0" } } forKey:@"air2"];
    NSError *error = nil;
    ok(Parse(tooNew, &error) == nil, @"minHostVersion 高于宿主应被拒");
    expectError(@"E_HOST_VERSION_MIN", @"air2.host.minHostVersion", error,
                @"下限不满足报 E_HOST_VERSION_MIN");

    NSMutableDictionary *tooOld = BaseManifest();
    [tooOld setObject:@{ @"host": @{ @"apiVersion": @1, @"maxHostVersion": @"0.0.9" } } forKey:@"air2"];
    error = nil;
    ok(Parse(tooOld, &error) == nil, @"maxHostVersion 低于宿主应被拒");
    expectError(@"E_HOST_VERSION_MAX", @"air2.host.maxHostVersion", error,
                @"上限不满足报 E_HOST_VERSION_MAX");

    // 边界含等号：minHostVersion == 宿主版本要放行（文档写的是「含」）。
    NSMutableDictionary *equalMin = BaseManifest();
    [equalMin setObject:@{ @"host": @{ @"apiVersion": @1, @"minHostVersion": @"0.1.0" } } forKey:@"air2"];
    error = nil;
    ok(Parse(equalMin, &error) != nil, @"minHostVersion 等于宿主版本应通过（含等号）");
    ok(error == nil, @"通过时不应该留下错误");

    // 0.1.10 vs 0.1.9：字符串比大小会判错，这里必须按语义化版本比。
    NSMutableDictionary *semantics = BaseManifest();
    [semantics setObject:@{ @"host": @{ @"apiVersion": @1, @"minHostVersion": @"0.1.10" } }
                  forKey:@"air2"];
    error = nil;
    ok(ParseWithHost(semantics, @"0.1.9", A2PluginHostMilestoneP2, &error) == nil,
       @"宿主 0.1.9 < 要求 0.1.10 应被拒");
    expectError(@"E_HOST_VERSION_MIN", @"air2.host.minHostVersion", error,
                @"版本比较必须是语义化版本，不是字符串");

    // formatVersion 3 在 P2 宿主上拒装（P3b 之前没有页面模型）。
    NSMutableDictionary *v3Package = FullManifest();
    [v3Package setObject:@3 forKey:@"formatVersion"];
    [v3Package removeObjectForKey:@"ui"];
    [v3Package removeObjectForKey:@"contributes"];
    error = nil;
    ok(Parse(v3Package, &error) == nil, @"v3 包在 P2 宿主上应被拒");
    expectError(@"E_FORMAT_VERSION", @"formatVersion", error,
                @"v3 包在 P2 报 E_FORMAT_VERSION（复用 P1 的码）");
    ok([error.userInfo objectForKey:A2PluginErrorFieldKey] != nil, @"E_FORMAT_VERSION 也带字段路径");
}

#pragma mark - ⑥ type:js 拒装

static void testJSTypeRejected(void) {
    printf("\n--- type:js：P2 宿主拒装，P3a 才收 ---\n");

    NSMutableDictionary *jsManifest = BaseManifest();
    [jsManifest setObject:@"js" forKey:@"type"];
    [jsManifest setObject:@"entry.js" forKey:@"entry"];

    NSError *error = nil;
    ok(Parse(jsManifest, &error) == nil, @"P2 宿主读到 type: js 应拒装");
    expectError(@"E_TYPE_UNSUPPORTED", @"type", error,
                @"报 E_TYPE_UNSUPPORTED（与 P1 同一个码字符串）");
    NSString *message = error.localizedDescription ?: @"";
    ok([message rangeOfString:@"JSCore"].location != NSNotFound,
       @"原因必须说清「没有 JSCore，装上也永远不执行」");

    // 同一个包在 P3a 宿主上应放行 —— 说明门是「宿主阶段」而不是「写死了拒 js」。
    error = nil;
    A2PluginContributionSet *set = ParseWithHost(jsManifest, @"0.1.0",
                                                 A2PluginHostMilestoneP3a, &error);
    ok(set != nil, [NSString stringWithFormat:@"P3a 宿主接受 type: js（%@）",
                    error.localizedDescription ?: @"无错误"]);

    // 未知 type（native 不是 v2 的 type 值）沿用 P1 的码。
    NSMutableDictionary *nativeType = BaseManifest();
    [nativeType setObject:@"native" forKey:@"type"];
    error = nil;
    ok(Parse(nativeType, &error) == nil, @"type: native 应拒装");
    expectError(@"E_TYPE_UNSUPPORTED", @"type", error, @"type: native 也是 E_TYPE_UNSUPPORTED");
}

#pragma mark - ⑦ 主题 token 降级与别名

static void testThemeTokens(void) {
    printf("\n--- 主题 token：未知降级、别名、词表 → MD3 角色 ---\n");

    NSMutableDictionary *unknownToken = BaseManifest();
    [unknownToken setObject:@{ @"theme": @{ @"tokens": @{
                              @"color.accent": @"#7C4DFF",
                              @"color.brandmagic": @"#112233" } } } forKey:@"ui"];
    NSError *error = nil;
    A2PluginContributionSet *set = Parse(unknownToken, &error);
    ok(set != nil, [NSString stringWithFormat:@"未知 token 不应导致拒装（%@）",
                    error.localizedDescription ?: @"无错误"]);
    eqInt((NSInteger)set.themeTokens.count, 1, @"未知 token 被丢弃，已知的留下");
    eqInt((NSInteger)set.diagnostics.count, 1, @"被丢弃的未知 token 必须留诊断");
    ok([set.diagnostics[0] rangeOfString:@"color.brandmagic"].location != NSNotFound,
       @"诊断里点名那个 token");

    // 把 MD3 角色原样搬过来（全小写、没按词拆点）是最常见的写法错误：诊断要给出正确写法，
    // 而不是只说「未知」让作者自己猜。
    NSMutableDictionary *typoToken = BaseManifest();
    [typoToken setObject:@{ @"theme": @{ @"tokens": @{
                             @"color.surfacecontainerhigh": @"#112233" } } } forKey:@"ui"];
    error = nil;
    A2PluginContributionSet *typoSet = Parse(typoToken, &error);
    ok(typoSet != nil, @"形状合法但词表里没有的 token 不拒装");
    ok(typoSet.diagnostics.count == 1 &&
       [typoSet.diagnostics[0] rangeOfString:@"color.surface.container.high"].location != NSNotFound,
       @"诊断给出正确的点分写法（color.surface.container.high）");

    ok(A2PluginIsKnownThemeToken(@"color.accent"), @"文档示例的 color.accent 在词表里");
    ok(A2PluginIsKnownThemeToken(@"color.surface.container.high"),
       @"MD3 角色用小写点分写法（schema 的 propertyNames 只允许小写与点）");
    ok(!A2PluginIsKnownThemeToken(@"color.surfaceContainerHigh"),
       @"驼峰写法不是合法 token（会先被形状校验拒掉）");
    eqStr(A2PluginThemeTokenRole(@"color.accent"), @"primary", @"color.accent 是 primary 的别名");
    eqStr(A2PluginThemeTokenRole(@"color.surface.container.high"), @"surfaceContainerHigh",
          @"token 落到 A2ColorScheme 的属性名");
    ok(A2PluginThemeTokenRole(@"color.nope") == nil, @"未知 token 没有角色（调用方据此降级）");

    NSMutableDictionary *badShape = BaseManifest();
    [badShape setObject:@{ @"theme": @{ @"tokens": @{ @"ColorAccent": @"#7C4DFF" } } } forKey:@"ui"];
    error = nil;
    ok(Parse(badShape, &error) == nil, @"token 名形状不对应被拒（不是「未知」而是「非法」）");
    expectError(@"E_FIELD", @"ui.theme.tokens", error, @"非法 token 名报 E_FIELD");
}

#pragma mark - ⑧ 权限与贡献点的一致性

static void testPermissionConsistency(void) {
    printf("\n--- 声明了贡献点却没申请权限 ⇒ 作者错误 ---\n");

    NSMutableDictionary *noPermission = BaseManifest();
    [noPermission setObject:@[ @"version.decorate" ] forKey:@"permissions"];
    [noPermission setObject:@{ @"slots": @[
                            SlotItem(@"home.card.badge", @"badge.status", nil, 0) ] } forKey:@"ui"];
    NSError *error = nil;
    ok(Parse(noPermission, &error) == nil, @"有 ui.slots 但没申请 ui.contribute 应被拒");
    expectError(@"E_CONTRIB_PERM", @"permissions", error,
                @"报 E_CONTRIB_PERM 并指向 permissions");

    NSMutableDictionary *noDecoratePermission = BaseManifest();
    [noDecoratePermission setObject:@[ @"ui.contribute" ] forKey:@"permissions"];
    [noDecoratePermission setObject:@{ @"versionDecorate": @{ @"subtitleTemplate": @"x" } }
                             forKey:@"contributes"];
    error = nil;
    ok(Parse(noDecoratePermission, &error) == nil,
       @"有 versionDecorate 但没申请 version.decorate 应被拒");
    expectError(@"E_CONTRIB_PERM", @"permissions", error,
                @"版本装饰缺 version.decorate 权限也报 E_CONTRIB_PERM");

    // 只申请 version.decorate（L0）＋ 只做装饰 ⇒ 合法。
    NSMutableDictionary *l0Only = BaseManifest();
    [l0Only setObject:@[ @"version.decorate" ] forKey:@"permissions"];
    [l0Only setObject:@{ @"versionDecorate": @{ @"badge": @{ @"text": @"示例" } } }
               forKey:@"contributes"];
    error = nil;
    A2PluginContributionSet *set = Parse(l0Only, &error);
    ok(set != nil, [NSString stringWithFormat:@"纯 L0 装饰插件应合法（%@）",
                    error.localizedDescription ?: @"无错误"]);
    eqInt(set.layer, A2PluginContributionLayerData, @"只申请 version.decorate ⇒ L0");
}

#pragma mark - ⑨ 注册表：排序 / 容量 / token 归属

static A2PluginContributionSet *SetFor(NSString *pluginId, NSArray<NSString *> *permissions,
                                       NSDictionary *ui, NSDictionary *contributes) {
    NSMutableDictionary *manifest = BaseManifest();
    [manifest setObject:pluginId forKey:@"id"];
    // 素材便利：声明了 versionDecorate 就自动补上 version.decorate 权限 ——
    // 「权限与贡献点一致」本身由 testPermissionConsistency 单独测，不在这里重复制造噪声。
    NSMutableArray<NSString *> *effectivePermissions = [NSMutableArray arrayWithArray:permissions];
    if ([contributes objectForKey:@"versionDecorate"] != nil &&
        ![effectivePermissions containsObject:@"version.decorate"]) {
        [effectivePermissions addObject:@"version.decorate"];
    }
    [manifest setObject:effectivePermissions forKey:@"permissions"];
    if (ui != nil) [manifest setObject:ui forKey:@"ui"];
    if (contributes != nil) [manifest setObject:contributes forKey:@"contributes"];
    return Parse(manifest, NULL);
}

static void testRegistryOrderingAndCapacity(void) {
    printf("\n--- 注册表：排序键 / 容量截断 / token 归属 ---\n");

    A2PluginContributionRegistry *registry = [[A2PluginContributionRegistry alloc] init];
    ok(registry != nil, @"注册表能建出来");
    eqInt((NSInteger)registry.attachedPluginIds.count, 0, @"新注册表是空的");

    A2PluginContributionSet *alpha = SetFor(@"app.alpha", @[ @"ui.contribute" ], @{
        @"priority": @0,
        @"slots": @[ SlotItem(@"home.toolbar.action", @"button.primary", @"alpha.run", 0) ],
        @"theme": @{ @"tokens": @{ @"color.accent": @"#111111" } },
    }, nil);
    A2PluginContributionSet *bravo = SetFor(@"app.bravo", @[ @"ui.contribute" ], @{
        @"priority": @(-5),
        @"slots": @[ SlotItem(@"home.toolbar.action", @"button.secondary", @"bravo.run", 0) ],
        @"theme": @{ @"tokens": @{ @"color.accent": @"#222222" } },
    }, nil);
    A2PluginContributionSet *charlie = SetFor(@"app.charlie", @[ @"ui.contribute", @"ui.override" ], @{
        @"priority": @(-5),
        @"slots": @[ SlotItem(@"home.toolbar.action", @"text.label", nil, 0) ],
    }, nil);

    NSError *error = nil;
    ok([registry applyContributionSet:alpha error:&error], @"接入 alpha");
    ok([registry applyContributionSet:bravo error:&error], @"接入 bravo");
    ok([registry applyContributionSet:charlie error:&error], @"接入 charlie");
    eqInt((NSInteger)registry.attachedPluginIds.count, 3, @"三个插件都在册");

    NSArray<A2PluginSlotContribution *> *entries =
        [registry slotEntriesForSlot:@"home.toolbar.action"];
    eqInt((NSInteger)entries.count, 3, @"同一 slot 的贡献共存（L1 不互相排斥）");
    // 排序键 (priority ↑, layer ↑, pluginId ↑)：
    //   bravo(-5, L1) → charlie(-5, L2) → alpha(0, L1)
    eqStr(entries[0].pluginId, @"app.bravo", @"priority 小的排前面");
    eqStr(entries[1].pluginId, @"app.charlie", @"priority 相同按层：L1 在 L2 前");
    eqStr(entries[2].pluginId, @"app.alpha", @"priority 与层都大的排最后");
    eqInt(entries[0].pluginPriority, -5, @"跨插件排序第一级是插件级 ui.priority");
    eqInt(entries[2].pluginPriority, 0, @"alpha 的插件级 priority 是 0");

    // token 归属：priority 最小的插件胜出，且能回传 owner。
    NSString *owner = nil;
    NSString *value = [registry themeTokenValue:@"color.accent" ownerPluginId:&owner];
    eqStr(value, @"#222222", @"多插件覆盖同一 token 时取排序键最靠前的那个");
    eqStr(owner, @"app.bravo", @"token 归属能回传（诊断/UI 要用）");
    eqInt((NSInteger)registry.resolvedThemeTokens.count, 1, @"解析结果里一个 token");

    // 容量：home.card.badge 只留 1 个，取 priority 最小的。
    A2PluginContributionRegistry *badges = [[A2PluginContributionRegistry alloc] init];
    A2PluginContributionSet *low = SetFor(@"app.low", @[ @"ui.contribute" ], @{
        @"slots": @[ SlotItem(@"home.card.badge", @"badge.status", nil, 100) ],
    }, nil);
    A2PluginContributionSet *high = SetFor(@"app.high", @[ @"ui.contribute" ], @{
        @"slots": @[ SlotItem(@"home.card.badge", @"badge.status", nil, -100) ],
    }, nil);
    [badges applyContributionSet:low error:NULL];
    [badges applyContributionSet:high error:NULL];
    eqInt((NSInteger)[badges slotEntriesForSlot:@"home.card.badge"].count, 2,
          @"全量查询不截断（诊断要看得到全部）");
    NSArray<A2PluginSlotContribution *> *effective = [badges effectiveEntriesForSlot:@"home.card.badge"];
    eqInt((NSInteger)effective.count, 1, @"有效条目按容量截断到 1 个");
    eqStr(effective[0].pluginId, @"app.high", @"截断留下 priority 最小的那个");
    eqInt((NSInteger)A2PluginSlotCapacity(@"home.toolbar.action"), 4, @"工具栏容量 4");
    eqInt((NSInteger)A2PluginSlotCapacity(@"home.section"), 0, @"home.section 不限（0 = 不限）");

    // 同一插件重复接入 = 幂等替换，不叠加。
    NSDictionary *before = [registry stateSnapshot];
    ok([registry applyContributionSet:alpha error:&error], @"同一插件再接入一次");
    ok([[registry stateSnapshot] isEqualToDictionary:before], @"重复接入后状态不变（幂等替换）");
    eqInt((NSInteger)registry.attachedPluginIds.count, 3, @"仍然只有三个插件");
}

#pragma mark - ⑩ 设置项与独占键

static void testSettingsRegistry(void) {
    printf("\n--- settings.section：设置项跨插件汇总 + 独占键冲突 ---\n");

    A2PluginContributionRegistry *registry = [[A2PluginContributionRegistry alloc] init];
    A2PluginContributionSet *one = SetFor(@"app.one", @[ @"ui.contribute" ], @{
        @"slots": @[ SlotItem(@"settings.section", @"switch.toggle", @"one.debug", 0) ],
    }, nil);
    A2PluginContributionSet *two = SetFor(@"app.two", @[ @"ui.contribute" ], @{
        @"slots": @[ SlotItem(@"settings.section", @"switch.toggle", @"two.debug", 0) ],
    }, nil);
    NSError *error = nil;
    ok([registry applyContributionSet:one error:&error], @"接入 one 的设置项");
    ok([registry applyContributionSet:two error:&error], @"接入 two 的设置项（键不同，无冲突）");
    NSArray<A2PluginSlotContribution *> *items = [registry settingsItems];
    eqInt((NSInteger)items.count, 2, @"两个插件的设置项都汇总出来");
    eqStr(items[0].identifier, @"one.debug", @"设置项按 pluginId 字典序排列");
    eqStr(items[1].identifier, @"two.debug", @"第二个设置项在后");

    // 同一个设置键被另一个插件占用 ⇒ 安装期拒装（同 L2 独占 slot 的道理）。
    A2PluginContributionSet *clash = SetFor(@"app.clash", @[ @"ui.contribute" ], @{
        @"slots": @[ SlotItem(@"settings.section", @"switch.toggle", @"one.debug", 0) ],
    }, nil);
    error = nil;
    ok(![registry applyContributionSet:clash error:&error], @"设置键重复应被拒");
    expectError(@"E_SLOT_CONFLICT", @"ui.slots.one.debug", error,
                @"设置键冲突报 E_SLOT_CONFLICT 并点名那个键");
    ok(![registry isPluginAttached:@"app.clash"], @"拒装后注册表里没有它（先检查后写入）");
    eqInt((NSInteger)[registry settingsItems].count, 2, @"被拒的接入没有留下半条贡献");
}

#pragma mark - ⑪ 卸载幂等 + 回到接入前

static void testRemovalRestoresState(void) {
    printf("\n--- 卸载：把状态还原到接入之前（快照逐字比） ---\n");

    A2PluginContributionRegistry *registry = [[A2PluginContributionRegistry alloc] init];
    NSDictionary *empty = [registry stateSnapshot];

    A2PluginContributionSet *alpha = SetFor(@"app.alpha", @[ @"ui.contribute" ], @{
        @"priority": @3,
        @"slots": @[
            SlotItem(@"home.toolbar.action", @"button.primary", @"alpha.run", 0),
            SlotItem(@"settings.section", @"switch.toggle", @"alpha.debug", 0),
        ],
        @"theme": @{ @"tokens": @{ @"color.accent": @"#101010" } },
    }, @{ @"versionDecorate": @{ @"badge": @{ @"text": @"A" } } });

    A2PluginContributionSet *bravo = SetFor(@"app.bravo", @[ @"ui.contribute" ], @{
        @"priority": @7,
        @"slots": @[ SlotItem(@"versions.list.badge", @"badge.status", nil, 0) ],
        @"theme": @{ @"tokens": @{ @"color.error": @"#AA0000" } },
    }, nil);

    NSError *error = nil;
    [registry applyContributionSet:alpha error:&error];
    NSDictionary *afterAlpha = [registry stateSnapshot];
    [registry applyContributionSet:bravo error:&error];
    NSDictionary *afterBoth = [registry stateSnapshot];
    ok(![afterAlpha isEqualToDictionary:empty], @"接入后状态必须与空注册表不同（否则这个测试没意义）");
    ok(![afterBoth isEqualToDictionary:afterAlpha], @"接入第二个插件后状态再变一次");

    // 条数口径 = slot 条目 + 主题 token + 版本装饰 —— 安装器那三行判据日志就靠它，
    // 所以这里钉住「怎么数」：设置项本来就是 slot 条目（ADR-023），不能算两次。
    eqInt((NSInteger)[registry contributionCountForPlugin:@"app.alpha"], 4,
          @"alpha 在册 4 条（2 slot/设置项 + 1 token + 1 版本装饰）");
    eqInt((NSInteger)[registry contributionCountForPlugin:@"app.bravo"], 2,
          @"bravo 在册 2 条（1 slot + 1 token）");
    eqInt((NSInteger)[registry contributionCountForPlugin:@"app.never-seen"], 0,
          @"从未接入的插件条数是 0");

    ok([registry removeContributionsForPlugin:@"app.bravo"], @"移除 bravo 返回 YES");
    ok([[registry stateSnapshot] isEqualToDictionary:afterAlpha],
       @"移除一个插件后状态回到「它接入之前」");
    ok(![registry removeContributionsForPlugin:@"app.bravo"], @"重复移除返回 NO（幂等）");
    ok([[registry stateSnapshot] isEqualToDictionary:afterAlpha], @"重复移除不改任何状态");

    ok([registry removeContributionsForPlugin:@"app.alpha"], @"移除 alpha 返回 YES");
    eqInt((NSInteger)[registry contributionCountForPlugin:@"app.alpha"], 0,
          @"全摘之后条数归零（安装器日志里那句「已移除 N 条」的判据）");
    ok([[registry stateSnapshot] isEqualToDictionary:empty],
       @"全摘之后状态与最初的空注册表逐字相同");
    eqInt((NSInteger)registry.diagnostics.count, 0, @"卸载后没有残留诊断");
    eqInt((NSInteger)[registry slotEntriesForSlot:@"home.toolbar.action"].count, 0,
          @"卸载后该 slot 一条都不剩");
    ok([registry resolvedThemeTokens].count == 0, @"卸载后主题 token 也清干净");
    ok(registry.versionDecorations.count == 0, @"卸载后版本装饰也清干净");

    // 禁用 = 移除；再启用 = 重新接入，拿到的是同一份内容。
    [registry applyContributionSet:alpha error:&error];
    NSDictionary *enabled = [registry stateSnapshot];
    [registry removeContributionsForPlugin:@"app.alpha"];
    [registry applyContributionSet:alpha error:&error];
    ok([[registry stateSnapshot] isEqualToDictionary:enabled],
       @"禁用再启用回到同一状态（不是「又多了一份」）");
    ok(![registry removeContributionsForPlugin:@"app.never-seen"], @"移除从未接入的插件返回 NO");
    A2PluginContributionSet *nothing = nil;
    ok([registry applyContributionSet:nothing error:&error] == NO, @"接入 nil 应失败而不是崩");
    expectError(@"E_FIELD", nil, error, @"nil 贡献集报 E_FIELD");
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        printf("=== P2 贡献点：manifest v2 纯 JSON 声明 + 注册表 ===\n");
        testHappyPath();
        testMissingAndTypedFields();
        testUnknownContributionPoints();
        testDuplicates();
        testHostVersion();
        testJSTypeRejected();
        testThemeTokens();
        testPermissionConsistency();
        testRegistryOrderingAndCapacity();
        testSettingsRegistry();
        testRemovalRestoresState();
        printf("\n--- 合计 ---\n");
        printf("PASS=%d FAIL=%d\n", gPass, gFail);
    }
    return gFail == 0 ? 0 : 1;
}
