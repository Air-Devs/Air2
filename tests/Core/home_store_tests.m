//
//  home_store_tests.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  主页落盘层（A2HomeStore）的**行为**单测：跑真实实现，落在临时 HOME 里的 Documents。
//  由 tests/Core/run_home_store_tests.py 编译运行（runner 会把 HOME 指向临时目录）。
//
//  钉住的四条（本单验收项 4 / 9，docs/HOME-DESIGN.md §4.2 / §4.5）：
//    ① 写盘是原子替换 + 轮转 .bak；主文件坏了能从 .bak 恢复；
//    ② 主文件完全不可解析 ⇒ 回默认且**不覆盖**原文件（保留 home-layout.corrupt.json）；
//    ③ 导入：版本更高 ⇒ 只读提示、不覆盖；结构损坏 ⇒ 明确报错、现有配置一动不动；
//              通过校验 ⇒ 导入前先备份 .bak，再追加方案（不覆盖同名方案）；
//    ④ 只读文档：loadDocument 后 isReadOnly，saveDocument 一律拒绝。
//

#import <Foundation/Foundation.h>

#import "A2HomeLayout.h"
#import "A2HomeStore.h"

static NSInteger gChecks = 0;
static NSInteger gFailures = 0;

// CHECK 内部用 stringWithFormat（断言消息里有 %@ 打对象）。
#define CHECK(cond, fmt, ...)                                                      \
    do {                                                                           \
        gChecks++;                                                                 \
        if (!(cond)) {                                                             \
            gFailures++;                                                           \
            NSString *a2_msg = [NSString stringWithFormat:(fmt), ##__VA_ARGS__];    \
            printf("FAIL %s:%d  %s\n", __func__, __LINE__, a2_msg.UTF8String);      \
        }                                                                          \
    } while (0)

static NSString *DocumentsPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

static NSString *LayoutPath(void) {
    return [DocumentsPath() stringByAppendingPathComponent:@"home-layout.json"];
}

static NSString *BackupPath(void) {
    return [DocumentsPath() stringByAppendingPathComponent:@"home-layout.bak.json"];
}

static NSString *CorruptPath(void) {
    return [DocumentsPath() stringByAppendingPathComponent:@"home-layout.corrupt.json"];
}

static NSString *ReadOnlyPath(void) {
    return [DocumentsPath() stringByAppendingPathComponent:@"home-layout.readonly.json"];
}

static void WriteString(NSString *text, NSString *path) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static NSString *ReadString(NSString *path) {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
}

static void RemoveIfExists(NSString *path) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static BOOL Exists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

/// 写一个合法的最小方案文档到主文件（不经 store，模拟「用户盘上已经有一份」）。
static void SeedValidLayout(NSString *profileName) {
    NSString *json = [NSString stringWithFormat:
        @"{\"schema\":1,\"activeProfile\":\"seed-p\",\"profiles\":[{"
        @"\"id\":\"seed-p\",\"name\":\"%@\",\"layout\":\"grid\",\"cards\":["
        @"{\"id\":\"seed-c1\",\"kind\":\"calendar\",\"size\":\"1x2\"}]}]}", profileName];
    WriteString(json, LayoutPath());
}

// 导入用的临时文件（放在 HOME 下的 tmp/，不是 Documents）。
static NSURL *ImportFileWithContents(NSString *text, NSString *name) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"imports"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:name];
    WriteString(text, path);
    return [NSURL fileURLWithPath:path];
}

#pragma mark - ① 写盘 / 备份轮转

static void testFreshInstallDoesNotWriteUntilEdited(void) {
    RemoveIfExists(LayoutPath());
    RemoveIfExists(BackupPath());
    RemoveIfExists(CorruptPath());

    A2HomeStore *store = A2HomeStore.shared;
    A2HomeDocument *doc = [store loadDocument];
    CHECK(doc != nil, @"loadDocument 返回 nil（约定永不返回 nil）");
    CHECK([doc activeProfile].cards.count > 0, @"出厂默认方案没有卡片");
    CHECK(store.isReadOnly == NO, @"全新安装不该是只读");
    CHECK(store.loadedFromCorrupt == NO, @"全新安装不该判「损坏」");
    CHECK(!Exists(LayoutPath()), @"★读取就写盘了★：默认方案应等用户第一次编辑才落盘");

    NSError *error = nil;
    CHECK([store saveDocument:doc error:&error], @"保存失败：%@", error.localizedDescription);
    CHECK(Exists(LayoutPath()), @"保存后主文件不存在");
}

static void testSaveRotatesBackup(void) {
    RemoveIfExists(BackupPath());
    A2HomeStore *store = A2HomeStore.shared;
    A2HomeDocument *doc = [store loadDocument];
    [doc activeProfile].name = @"改过一次";
    NSError *error = nil;
    CHECK([store saveDocument:doc error:&error], @"第二次保存失败：%@", error.localizedDescription);
    CHECK(Exists(BackupPath()), @"第二次保存没有轮转出 .bak");
    NSString *backup = ReadString(BackupPath());
    CHECK(backup.length > 0, @".bak 是空的");
}

#pragma mark - ② 坏文件处理

static void testCorruptMainFallsBackToBackup(void) {
    // 先确保有一份可用备份（上一次保存会轮转出来）。
    A2HomeStore *store = A2HomeStore.shared;
    A2HomeDocument *doc = [store loadDocument];
    [store saveDocument:doc error:NULL];
    CHECK(Exists(BackupPath()), @"前置条件不成立：没有 .bak");

    WriteString(@"{" , LayoutPath());          // 语法坏
    A2HomeDocument *loaded = [store loadDocument];
    CHECK(loaded != nil, @"主文件坏了不该返回 nil");
    CHECK(store.loadedFromBackup == YES, @"主文件坏了没有回落到 .bak");
    CHECK([loaded activeProfile].cards.count > 0, @"从备份恢复出来的方案是空的");
    CHECK(ReadString(LayoutPath()).length == 1, @"★坏文件被覆盖了★（应当原样保留）");
}

/// ★从 .bak 恢复之后的第一次保存，不许拿坏主文件把好备份顶掉★（否则回滚能力就没了）。
static void testSaveAfterBackupRecoveryKeepsGoodBackup(void) {
    RemoveIfExists(CorruptPath());
    SeedValidLayout(@"恢复前的方案");

    A2HomeStore *store = A2HomeStore.shared;
    A2HomeDocument *seeded = [store loadDocument];
    CHECK([store saveDocument:seeded error:NULL], @"前置条件不成立：第一次保存失败");
    CHECK([store saveDocument:seeded error:NULL], @"前置条件不成立：第二次保存失败");
    CHECK(Exists(BackupPath()), @"前置条件不成立：没有 .bak");

    WriteString(@"{ 坏掉的主文件", LayoutPath());       // 主文件损坏
    A2HomeDocument *recovered = [store loadDocument];
    CHECK(store.loadedFromBackup == YES, @"前置条件不成立：没有从 .bak 恢复");

    [recovered activeProfile].name = @"恢复之后改过";
    NSError *error = nil;
    CHECK([store saveDocument:recovered error:&error], @"恢复后保存失败：%@", error.localizedDescription);

    NSString *backup = ReadString(BackupPath());
    CHECK([backup containsString:@"profiles"],
          @"★.bak 被坏主文件顶掉了（回滚能力丢失）★ 实际内容=%@", backup);
    id parsed = [NSJSONSerialization JSONObjectWithData:[backup dataUsingEncoding:NSUTF8StringEncoding]
                                               options:0 error:NULL];
    CHECK([parsed isKindOfClass:NSDictionary.class], @".bak 已不是合法 JSON");

    NSString *main = ReadString(LayoutPath());
    CHECK([main containsString:@"恢复之后改过"], @"新的主文件没有写进去");
}

static void testCorruptWithoutBackupKeepsOriginalFile(void) {
    RemoveIfExists(BackupPath());
    RemoveIfExists(CorruptPath());
    WriteString(@"not json at all", LayoutPath());

    A2HomeStore *store = A2HomeStore.shared;
    A2HomeDocument *loaded = [store loadDocument];
    CHECK(loaded != nil, @"无可恢复数据时也应给出默认方案");
    CHECK(store.loadedFromCorrupt == YES, @"没有标记「主文件不可解析」");
    CHECK(Exists(CorruptPath()), @"原件没有保留为 .corrupt.json");
    CHECK([ReadString(LayoutPath()) isEqualToString:@"not json at all"],
          @"★不可解析的原文件被就地覆盖了★");
}

#pragma mark - ③ 导入

static void testImportHigherSchemaDoesNotTouchFile(void) {
    SeedValidLayout(@"原样方案");
    NSString *before = ReadString(LayoutPath());
    NSString *future = @"{\"schema\":99,\"activeProfile\":\"p\",\"profiles\":[{"
                       @"\"id\":\"p\",\"name\":\"来自未来\",\"layout\":\"grid\",\"cards\":[]}]}";

    NSString *message = nil;
    A2HomeDocument *updated = nil;
    A2HomeImportOutcome outcome =
        [A2HomeStore.shared importFromURL:ImportFileWithContents(future, @"future.json")
                                  message:&message
                                 document:&updated];
    CHECK(outcome == A2HomeImportOutcomeHigherSchema, @"高版本导入没被判成 HigherSchema（%ld）", (long)outcome);
    CHECK(updated == nil, @"高版本导入不该产出新文档");
    CHECK([ReadString(LayoutPath()) isEqualToString:before], @"★高版本导入覆盖了现有配置★");
    CHECK(message.length > 0, @"高版本导入没有给用户说明");
}

static void testImportMalformedKeepsConfigIntact(void) {
    SeedValidLayout(@"原样方案");
    NSString *before = ReadString(LayoutPath());

    NSString *message = nil;
    A2HomeDocument *updated = nil;
    A2HomeImportOutcome outcome =
        [A2HomeStore.shared importFromURL:ImportFileWithContents(@"{ 坏掉的", @"broken.json")
                                  message:&message
                                 document:&updated];
    CHECK(outcome == A2HomeImportOutcomeMalformed, @"坏 JSON 没被判成 Malformed（%ld）", (long)outcome);
    CHECK(updated == nil, @"坏 JSON 不该产出新文档");
    CHECK(message.length > 0, @"坏 JSON 没有明确报错文案");
    CHECK([ReadString(LayoutPath()) isEqualToString:before], @"★坏 JSON 改动了现有配置★");

    // 结构合法、但里面没有可用卡片 ⇒ Empty，同样不动配置。
    NSString *emptyJSON = @"{\"schema\":1,\"activeProfile\":\"p\",\"profiles\":[{"
                          @"\"id\":\"p\",\"name\":\"空\",\"layout\":\"grid\",\"cards\":[]}]}";
    A2HomeImportOutcome emptyOutcome =
        [A2HomeStore.shared importFromURL:ImportFileWithContents(emptyJSON, @"empty.json")
                                  message:&message
                                 document:&updated];
    CHECK(emptyOutcome == A2HomeImportOutcomeEmpty, @"空方案文件没被判成 Empty（%ld）", (long)emptyOutcome);
    CHECK([ReadString(LayoutPath()) isEqualToString:before], @"空方案导入改动了现有配置");
}

static void testImportOKBacksUpThenAppendsProfiles(void) {
    SeedValidLayout(@"原样方案");
    NSString *before = ReadString(LayoutPath());
    RemoveIfExists(BackupPath());

    NSString *incoming = @"{\"schema\":1,\"activeProfile\":\"q\",\"profiles\":[{"
                         @"\"id\":\"q\",\"name\":\"原样方案\",\"layout\":\"grid\",\"cards\":["
                         @"{\"id\":\"q-c1\",\"kind\":\"shortcutCustom\",\"size\":\"1x1\","
                         @"\"options\":{\"title\":\"官网\",\"jumpKind\":\"url\","
                         @"\"jumpTarget\":\"https://air-devs.top\"}}]}]}";
    NSString *message = nil;
    A2HomeDocument *updated = nil;
    A2HomeImportOutcome outcome =
        [A2HomeStore.shared importFromURL:ImportFileWithContents(incoming, @"ok.json")
                                  message:&message
                                 document:&updated];
    CHECK(outcome == A2HomeImportOutcomeOK, @"正常导入失败（%ld）：%@", (long)outcome, message);
    CHECK(updated != nil, @"导入成功却没给出新文档");

    // ★导入前先备份★：.bak 必须是导入前那一份。
    CHECK(Exists(BackupPath()), @"导入前没有备份 .bak");
    CHECK([ReadString(BackupPath()) isEqualToString:before], @"★.bak 不是导入前的配置★");

    // 追加而不是覆盖；同名方案要改名，不顶掉用户的。
    CHECK(updated.profiles.count == 2, @"导入后方案数应 2，实际 %lu", (unsigned long)updated.profiles.count);
    BOOL namesDistinct = ![updated.profiles[0].name isEqualToString:updated.profiles[1].name];
    CHECK(namesDistinct, @"导入方案与现有方案重名（没有去重）");
    A2HomeCard *imported = updated.profiles.lastObject.cards.firstObject;
    CHECK(imported != nil && imported.kind == A2HomeCardKindShortcutCustom, @"导入的自定义卡片丢了");
    CHECK([imported.options isJumpUsableWithReason:NULL], @"导入的网址跳转不可用");
    CHECK(updated.activeProfileID != nil &&
          [[updated profileWithID:updated.activeProfileID] name] != nil, @"导入后 activeProfile 落空");

    // 落盘过：主文件里应能看到两个方案。
    A2HomeDocument *reloaded = [A2HomeStore.shared loadDocument];
    CHECK(reloaded.profiles.count == 2, @"重新读盘后方案数不对（%lu）",
          (unsigned long)reloaded.profiles.count);
}

#pragma mark - ④ 只读

static void testHigherSchemaDocumentIsReadOnlyAndRefusesSave(void) {
    RemoveIfExists(ReadOnlyPath());
    NSString *future = @"{\"schema\":42,\"activeProfile\":\"p\",\"profiles\":[{"
                       @"\"id\":\"p\",\"name\":\"来自未来\",\"layout\":\"grid\",\"cards\":[]}]}";
    WriteString(future, LayoutPath());

    A2HomeStore *store = A2HomeStore.shared;
    A2HomeDocument *doc = [store loadDocument];
    CHECK(store.isReadOnly == YES, @"schema 42 没进只读模式");
    CHECK(Exists(ReadOnlyPath()), @"只读时没有把原文件备份为 .readonly.json");
    CHECK([ReadString(ReadOnlyPath()) isEqualToString:future], @"只读备份内容不对");

    NSError *error = nil;
    CHECK(![store saveDocument:doc error:&error], @"★只读模式居然写盘成功了★");
    CHECK(error != nil, @"只读拒绝写盘却没给 error");
    CHECK([ReadString(LayoutPath()) isEqualToString:future], @"只读模式下原文件被改写了");

    CHECK(![A2HomeStore.shared restoreDefaultContentOfProfile:doc.activeProfileID
                                                   inDocument:doc
                                                        error:&error],
          @"只读模式居然允许恢复默认（会覆盖新版布局）");

    // 收尾：把文件恢复成合法内容，避免污染后续用例。
    SeedValidLayout(@"恢复");
}

#pragma mark - 导出

static void testExportContainsSchemaProfilesAndTimestamp(void) {
    SeedValidLayout(@"导出用");
    A2HomeDocument *doc = [A2HomeStore.shared loadDocument];
    NSError *error = nil;
    NSURL *url = [A2HomeStore.shared exportDocument:doc error:&error];
    CHECK(url != nil, @"导出失败：%@", error.localizedDescription);
    CHECK(Exists(url.path), @"导出的文件不存在");

    NSString *text = ReadString(url.path);
    CHECK([text containsString:@"\"schema\""], @"导出缺 schema");
    CHECK([text containsString:@"\"profiles\""], @"导出缺 profiles");
    CHECK([text containsString:@"\"exportedAt\""], @"导出缺 exportedAt");
    CHECK([text containsString:@"\"app\" : \"Air2\""] || [text containsString:@"\"app\":\"Air2\""],
          @"导出缺 app 标记");
    CHECK([url.lastPathComponent hasSuffix:@".json"], @"导出文件名不是 .json：%@", url.lastPathComponent);

    // 导出的东西必须能被自己再导入（自洽性）。
    NSString *message = nil;
    A2HomeDocument *updated = nil;
    A2HomeImportOutcome outcome =
        [A2HomeStore.shared importFromURL:url message:&message document:&updated];
    CHECK(outcome == A2HomeImportOutcomeOK, @"自己导出的文件导不回来（%ld）：%@", (long)outcome, message);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:DocumentsPath()
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:NULL];
        printf("HOME=%s\n", NSHomeDirectory().UTF8String);

        testFreshInstallDoesNotWriteUntilEdited();
        testSaveRotatesBackup();
        testCorruptMainFallsBackToBackup();
        testSaveAfterBackupRecoveryKeepsGoodBackup();
        testCorruptWithoutBackupKeepsOriginalFile();
        testImportHigherSchemaDoesNotTouchFile();
        testImportMalformedKeepsConfigIntact();
        testImportOKBacksUpThenAppendsProfiles();
        testExportContainsSchemaProfilesAndTimestamp();
        testHigherSchemaDocumentIsReadOnlyAndRefusesSave();

        printf("\n__HOME_STORE_CHECKS=%ld\n", (long)gChecks);
        printf("__HOME_STORE_FAILURES=%ld\n", (long)gFailures);
        printf("__HOME_STORE_EXIT=%d\n", gFailures == 0 ? 0 : 1);
    }
    return gFailures == 0 ? 0 : 1;
}
