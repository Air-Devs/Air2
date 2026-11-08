//
//  home_layout_tests.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  自定义主页 Core 层的**行为**单测：跑的是仓内真实实现（A2HomeLayout.m），
//  不是源码扫描、也不是 Python 复刻。由 tests/Core/run_home_layout_tests.py 编译运行。
//
//  钉住的不变式（docs/HOME-DESIGN.md §4.1 / §4.3 / §4.5 + 本单四条验收）：
//    ① 顺序即布局：网格模式不存坐标，装箱不重叠、不越界；
//    ② 显示位置 ≠ 存储位置：自由布局的显示坐标重算后，存储坐标一个字节都不变；
//    ③ 窄屏只压列不压行：3x2 在一列下是 1x2，档位值不变；
//    ④ 逐卡容错：坏卡丢一张、好卡照留；id 重复重发；尺寸越界回该类型默认档；
//    ⑤ schema 更高 ⇒ 只读，且不静默重置；
//    ⑥ 自定义卡片（本单新增）：图标白名单、标题截断、内置页 token 往返、
//       非法网址 / 未知页面**软失败**（卡片留着，只是跳不动）。
//

#import <Foundation/Foundation.h>

#import "A2HomeLayout.h"

static NSInteger gChecks = 0;
static NSInteger gFailures = 0;

// CHECK 内部用 stringWithFormat 而不是直接 printf：断言消息里大量用 %@ 打对象，
// printf 不认 %@（-Wformat-invalid-specifier 会警告，失败时还会打出垃圾）。
#define CHECK(cond, fmt, ...)                                                      \
    do {                                                                           \
        gChecks++;                                                                 \
        if (!(cond)) {                                                             \
            gFailures++;                                                           \
            NSString *a2_msg = [NSString stringWithFormat:(fmt), ##__VA_ARGS__];    \
            printf("FAIL %s:%d  %s\n", __func__, __LINE__, a2_msg.UTF8String);      \
        }                                                                          \
    } while (0)

static A2HomeDocument *DocFromJSONString(NSString *json, BOOL *readOnly) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [A2HomeDocument documentFromJSONObject:object readOnly:readOnly];
}

static NSString *JSONString(NSDictionary *dictionary) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary
                                                   options:NSJSONWritingSortedKeys
                                                     error:NULL];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

/// 两张卡是否在网格上重叠（0 基）。
static BOOL PlacementsOverlap(A2HomePlacement *a, A2HomePlacement *b) {
    BOOL columnsApart = (a.column + a.columnSpan <= b.column) || (b.column + b.columnSpan <= a.column);
    BOOL rowsApart = (a.row + a.rowSpan <= b.row) || (b.row + b.rowSpan <= a.row);
    return !(columnsApart || rowsApart);
}

#pragma mark - ① 顺序即布局 / 装箱

static void testGridPackingHasNoOverlapAndNoOverflow(void) {
    A2HomeDocument *doc = [A2HomeDocument defaultDocument];
    NSArray<A2HomeCard *> *cards = [doc activeProfile].cards;
    CHECK(cards.count >= 4, @"默认方案应有 4 张卡，实际 %lu", (unsigned long)cards.count);

    for (NSInteger columns = 1; columns <= A2HomeMaxColumns; columns++) {
        NSArray<A2HomePlacement *> *placements = [A2HomePacker gridPlacementsForCards:cards columns:columns];
        CHECK(placements.count == cards.count, @"%ld 列：落位数与卡数不一致（%lu vs %lu）",
              (long)columns, (unsigned long)placements.count, (unsigned long)cards.count);

        // 顺序即布局：落位顺序必须与卡片顺序一一对应。
        for (NSUInteger i = 0; i < placements.count && i < cards.count; i++) {
            CHECK([placements[i].cardID isEqualToString:cards[i].cardID],
                  @"落位顺序与卡片顺序脱节（第 %lu 张）", (unsigned long)i);
            CHECK(placements[i].column + placements[i].columnSpan <= columns,
                  @"%ld 列：第 %lu 张越界（col=%ld span=%ld）", (long)columns, (unsigned long)i,
                  (long)placements[i].column, (long)placements[i].columnSpan);
            CHECK(placements[i].row >= 0 && placements[i].column >= 0, @"落位坐标为负");
        }
        for (NSUInteger i = 0; i < placements.count; i++) {
            for (NSUInteger j = i + 1; j < placements.count; j++) {
                CHECK(!PlacementsOverlap(placements[i], placements[j]),
                      @"%ld 列：第 %lu 与第 %lu 张重叠", (long)columns, (unsigned long)i, (unsigned long)j);
            }
        }
    }
}

/// 网格模式不存坐标：写出 JSON 时 position 必须缺席（顺序即布局）。
static void testGridModeNeverWritesCoordinates(void) {
    A2HomeDocument *doc = [A2HomeDocument defaultDocument];
    [doc activeProfile].layout = A2HomeLayoutModeGrid;
    NSDictionary *json = [doc JSONObject];
    NSArray *cards = json[@"profiles"][0][@"cards"];
    CHECK(cards.count > 0, @"写出的卡片列表为空");
    for (NSDictionary *card in cards) {
        CHECK(card[@"position"] == nil, @"网格模式写出了 position：%@", card[@"kind"]);
    }
    CHECK([json[@"schema"] integerValue] == A2HomeSchemaVersion, @"写出的 schema 不是当前版本");
}

#pragma mark - ② 显示位置 ≠ 存储位置

static void testFreeDisplayDoesNotMutateStoredPositions(void) {
    // 两张卡故意挤在同一格：显示层必须把它们分开，但存储坐标一动不动。
    A2HomeDocument *doc = [A2HomeDocument defaultDocument];
    A2HomeProfile *profile = [doc activeProfile];
    profile.layout = A2HomeLayoutModeFree;
    A2HomeCard *first = profile.cards.firstObject;
    A2HomeCard *second = profile.cards.count > 1 ? profile.cards[1] : nil;
    CHECK(second != nil, @"默认方案卡数不足");
    for (A2HomeCard *card in @[first, second]) {
        card.hasPosition = YES;
        card.column = 0;
        card.row = 0;
    }
    NSInteger storedColumn = second.column;
    NSInteger storedRow = second.row;

    NSArray<A2HomePlacement *> *wide = [A2HomePacker freeDisplayPlacementsForCards:profile.cards
                                                                           columns:A2HomeMaxColumns];
    CHECK(wide.count == profile.cards.count, @"自由布局显示落位数不对");
    for (NSUInteger i = 0; i < wide.count; i++) {
        for (NSUInteger j = i + 1; j < wide.count; j++) {
            CHECK(!PlacementsOverlap(wide[i], wide[j]), @"自由布局显示落位重叠");
        }
    }
    CHECK(second.column == storedColumn && second.row == storedRow,
          @"显示落位写回了存储坐标（%ld,%ld → %ld,%ld）",
          (long)storedColumn, (long)storedRow, (long)second.column, (long)second.row);

    // 窄屏只是一次**重算**：再算一遍宽屏必须还原成同样的结果（没有残留状态）。
    NSArray<A2HomePlacement *> *narrow = [A2HomePacker freeDisplayPlacementsForCards:profile.cards columns:1];
    CHECK(narrow.count == profile.cards.count, @"窄屏落位数不对");
    for (A2HomePlacement *p in narrow) {
        CHECK(p.column + p.columnSpan <= 1, @"窄屏落位越界（col=%ld span=%ld）",
              (long)p.column, (long)p.columnSpan);
    }
    NSArray<A2HomePlacement *> *again = [A2HomePacker freeDisplayPlacementsForCards:profile.cards
                                                                            columns:A2HomeMaxColumns];
    for (NSUInteger i = 0; i < again.count; i++) {
        CHECK(again[i].column == wide[i].column && again[i].row == wide[i].row,
              @"回宽屏后落位没有复原（第 %lu 张）", (unsigned long)i);
    }
    CHECK(second.column == storedColumn && second.row == storedRow, @"窄屏重算污染了存储坐标");
}

#pragma mark - ③ 窄屏只压列不压行

static void testNarrowCompressionKeepsRows(void) {
    A2HomeSpan twoByTwo = A2HomeSpanForSize(A2HomeCardSizeTwoByTwo);
    A2HomeSpan compressed = A2HomeSpanCompressedToColumns(twoByTwo, 1);
    CHECK(compressed.columns == 1, @"2x2 在一列下应压成 1 列，实际 %ld", (long)compressed.columns);
    CHECK(compressed.rows == 2, @"2x2 在一列下不该压行，实际 %ld 行", (long)compressed.rows);

    A2HomeSpan threeByOne = A2HomeSpanForSize(A2HomeCardSizeThreeByOne);
    A2HomeSpan c31 = A2HomeSpanCompressedToColumns(threeByOne, 2);
    CHECK(c31.columns == 2 && c31.rows == 1, @"3x1 在 2 列下应为 2x1，实际 %ldx%ld",
          (long)c31.columns, (long)c31.rows);

    // 档位值本身不变（压的是显示跨度，不是 size）。
    A2HomeCard *card = [A2HomeCard cardWithKind:A2HomeCardKindRecent];
    card.size = A2HomeCardSizeThreeByTwo;
    CHECK(A2HomeSpanForSize(card.size).columns == 3, @"档位被压列改写了");
}

#pragma mark - ④ 逐卡容错

static void testBadCardDroppedGoodCardKept(void) {
    NSString *json = @"{\"schema\":1,\"activeProfile\":\"p1\",\"profiles\":[{"
                     @"\"id\":\"p1\",\"name\":\"默认\",\"layout\":\"grid\",\"cards\":["
                     @"{ \"id\":\"c1\", \"kind\":\"不存在的类型\", \"size\":\"1x1\" },"
                     @"{ \"id\":\"c2\", \"kind\":\"calendar\", \"size\":\"1x2\" }"
                     @"]}]}";
    BOOL readOnly = YES;
    A2HomeDocument *doc = DocFromJSONString(json, &readOnly);
    CHECK(doc != nil, @"整篇被判作废（坏卡不该拖累整篇）");
    CHECK(readOnly == NO, @"正常版本被判只读");
    CHECK([doc activeProfile].cards.count == 1, @"应丢 1 张、留 1 张，实际 %lu",
          (unsigned long)[doc activeProfile].cards.count);
    CHECK([doc activeProfile].cards.firstObject.kind == A2HomeCardKindCalendar, @"留下的不是好卡");
}

static void testDuplicateCardIDsGetNewUUIDs(void) {
    NSString *json = @"{\"schema\":1,\"activeProfile\":\"p1\",\"profiles\":[{"
                     @"\"id\":\"p1\",\"name\":\"默认\",\"layout\":\"grid\",\"cards\":["
                     @"{ \"id\":\"dup\", \"kind\":\"calendar\", \"size\":\"1x2\" },"
                     @"{ \"id\":\"dup\", \"kind\":\"recent\", \"size\":\"2x2\" }"
                     @"]}]}";
    A2HomeDocument *doc = DocFromJSONString(json, NULL);
    NSArray<A2HomeCard *> *cards = [doc activeProfile].cards;
    CHECK(cards.count == 2, @"重复 id 不该丢卡（应两条都留），实际 %lu", (unsigned long)cards.count);
    CHECK(![cards[0].cardID isEqualToString:cards[1].cardID], @"重复 id 没有被重发");
}

static void testSizeOutOfWhitelistFallsBackToDefault(void) {
    // 日历只允许 1x2 / 2x2；写 3x1 应回默认档（保卡，不丢）。
    NSString *json = @"{\"schema\":1,\"activeProfile\":\"p1\",\"profiles\":[{"
                     @"\"id\":\"p1\",\"name\":\"默认\",\"layout\":\"grid\",\"cards\":["
                     @"{ \"id\":\"c1\", \"kind\":\"calendar\", \"size\":\"3x1\" }"
                     @"]}]}";
    A2HomeDocument *doc = DocFromJSONString(json, NULL);
    A2HomeCard *card = [doc activeProfile].cards.firstObject;
    CHECK(card != nil, @"尺寸越界把卡丢了");
    CHECK(card.size == A2HomeDefaultSizeForKind(A2HomeCardKindCalendar),
          @"尺寸越界没回默认档（实际 %@）", A2HomeCardSizeToken(card.size));
    CHECK(![A2HomeSizesForKind(A2HomeCardKindCalendar) containsObject:@(A2HomeCardSizeThreeByOne)],
          @"日历的白名单里不该有 3x1");
}

static void testCardMissingTargetIsDropped(void) {
    NSString *json = @"{\"schema\":1,\"activeProfile\":\"p1\",\"profiles\":[{"
                     @"\"id\":\"p1\",\"name\":\"默认\",\"layout\":\"grid\",\"cards\":["
                     @"{ \"id\":\"c1\", \"kind\":\"shortcutVersion\", \"size\":\"1x1\" }"
                     @"]}]}";
    A2HomeDocument *doc = DocFromJSONString(json, NULL);
    CHECK([doc activeProfile].cards.count == 0,
          @"缺 target 的引用卡应被丢弃，实际留了 %lu 张",
          (unsigned long)[doc activeProfile].cards.count);
}

#pragma mark - ⑤ schema 更高 ⇒ 只读

static void testHigherSchemaIsReadOnlyAndNotReset(void) {
    NSString *json = @"{\"schema\":99,\"activeProfile\":\"p9\",\"profiles\":[{"
                     @"\"id\":\"p9\",\"name\":\"来自未来\",\"layout\":\"grid\",\"cards\":[]}]}";
    BOOL readOnly = NO;
    A2HomeDocument *doc = DocFromJSONString(json, &readOnly);
    CHECK(doc != nil, @"高版本文档不该让读取失败（要能只读渲染）");
    CHECK(readOnly == YES, @"schema 99 没判成只读");
    CHECK(doc.schema == A2HomeSchemaVersion, @"只读文档的 schema 应被标成本版");
}

static void testProfilesCannotBeRemovedBelowOne(void) {
    A2HomeDocument *doc = [A2HomeDocument defaultDocument];
    NSString *firstID = doc.activeProfileID;
    A2HomeProfile *added = [doc addProfileNamed:@"儿童机"];
    CHECK(doc.profiles.count == 2, @"新建方案失败（%lu）", (unsigned long)doc.profiles.count);
    CHECK(added.cards.count == [doc profileWithID:firstID].cards.count, @"新方案没有复制当前方案的卡片");
    CHECK(![added.profileID isEqualToString:firstID], @"新方案复用了旧 id");

    doc.activeProfileID = added.profileID;
    CHECK([doc removeProfileWithID:added.profileID], @"删除非最后一个方案应成功");
    CHECK(doc.profiles.count == 1, @"删除后方案数不对");
    CHECK([doc profileWithID:doc.activeProfileID] != nil, @"删掉当前方案后 activeProfile 落空");
    CHECK(![doc removeProfileWithID:doc.activeProfileID], @"最后一个方案不该允许删除");
}

#pragma mark - ⑤b 拖拽排序（网格：只改顺序，不存坐标）

static A2HomeCard *CardWithID(NSString *cardID, A2HomeCardKind kind, A2HomeCardSize size) {
    A2HomeCard *card = [A2HomeCard cardWithKind:kind];
    card.cardID = cardID;
    card.size = size;
    return card;
}

static NSString *OrderOf(NSArray<A2HomeCard *> *cards) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (A2HomeCard *c in cards) [ids addObject:c.cardID ?: @"?"];
    return [ids componentsJoinedByString:@","];
}

/// 松手压在某张卡上 ⇒ 自己顶到那张卡的位置（其余卡的相对次序不变）。
static void testGridReorderDropsOntoHoveredCard(void) {
    NSArray<A2HomeCard *> *cards = @[ CardWithID(@"a", A2HomeCardKindRecent, A2HomeCardSizeOneByOne),
                                      CardWithID(@"b", A2HomeCardKindCalendar, A2HomeCardSizeOneByOne),
                                      CardWithID(@"c", A2HomeCardKindPinnedVersions, A2HomeCardSizeOneByOne),
                                      CardWithID(@"d", A2HomeCardKindShortcutVersion, A2HomeCardSizeOneByOne) ];
    NSArray<A2HomePlacement *> *placements = [A2HomePacker gridPlacementsForCards:cards columns:2];

    // d（行 1、列 1）拖到 a 的格子（行 0、列 0）。
    NSArray<A2HomeCard *> *moved = [A2HomePacker cardsByMovingCardID:@"d" in:cards
                                                          placements:placements
                                                            toColumn:0 row:0];
    CHECK([OrderOf(moved) isEqualToString:@"d,a,b,c"], @"拖到 a 的格子上顺序不对：%@", OrderOf(moved));

    // c（行 1、列 0）拖到 a 的格子：c 顶掉 a。
    NSArray<A2HomeCard *> *second = [A2HomePacker cardsByMovingCardID:@"c" in:cards
                                                           placements:placements
                                                             toColumn:0 row:0];
    CHECK([OrderOf(second) isEqualToString:@"c,a,b,d"], @"把 c 拖到 a 上顺序不对：%@", OrderOf(second));

    // 落点是空格（末行之后）⇒ 排到最后。
    NSArray<A2HomeCard *> *appended = [A2HomePacker cardsByMovingCardID:@"a" in:cards
                                                             placements:placements
                                                               toColumn:0 row:6];
    CHECK([OrderOf(appended) isEqualToString:@"b,c,d,a"], @"拖到空白处没排到最后：%@", OrderOf(appended));

    // ★一次都不许写坐标★：网格模式的顺序是唯一布局来源。
    for (A2HomeCard *card in moved) {
        CHECK(card.hasPosition == NO, @"排序给卡片写了坐标（顺序即布局被破坏）");
    }
    // 入参数组不被就地修改（纯函数）。
    CHECK([OrderOf(cards) isEqualToString:@"a,b,c,d"], @"排序函数就地改了入参");
    CHECK(placements.count == cards.count, @"落位数与卡数不一致");
}

/// 落点就是自己 / id 不存在 ⇒ 原序返回（不产生一次无意义的写盘）。
static void testGridReorderNoOpKeepsOrder(void) {
    NSArray<A2HomeCard *> *cards = @[ CardWithID(@"a", A2HomeCardKindRecent, A2HomeCardSizeOneByOne),
                                      CardWithID(@"b", A2HomeCardKindCalendar, A2HomeCardSizeOneByOne),
                                      CardWithID(@"c", A2HomeCardKindPinnedVersions, A2HomeCardSizeOneByOne) ];
    NSArray<A2HomePlacement *> *placements = [A2HomePacker gridPlacementsForCards:cards columns:3];
    CHECK(placements.count == 3, @"前置条件不成立：落位数 %lu", (unsigned long)placements.count);
    CHECK(placements[1].column == 1 && placements[1].row == 0, @"前置条件不成立：b 不在 (1,0)");

    NSArray<A2HomeCard *> *same = [A2HomePacker cardsByMovingCardID:@"b" in:cards
                                                         placements:placements
                                                           toColumn:1 row:0];
    CHECK([OrderOf(same) isEqualToString:@"a,b,c"], @"落在自己格子上却改了顺序：%@", OrderOf(same));

    NSArray<A2HomeCard *> *unknown = [A2HomePacker cardsByMovingCardID:@"nope" in:cards
                                                            placements:placements
                                                              toColumn:0 row:0];
    CHECK([OrderOf(unknown) isEqualToString:@"a,b,c"], @"未知 id 却改了顺序：%@", OrderOf(unknown));

    NSArray<A2HomeCard *> *empty = [A2HomePacker cardsByMovingCardID:@"" in:cards
                                                          placements:placements
                                                            toColumn:0 row:0];
    CHECK([OrderOf(empty) isEqualToString:@"a,b,c"], @"空 id 却改了顺序：%@", OrderOf(empty));
}

/// 宽卡（跨列）也要能用区间判定命中：落点落在宽卡的右半格，仍算压在它身上。
static void testGridReorderHandlesWideCardTarget(void) {
    NSArray<A2HomeCard *> *cards = @[ CardWithID(@"wide", A2HomeCardKindGreeting, A2HomeCardSizeTwoByOne),
                                      CardWithID(@"x", A2HomeCardKindRecent, A2HomeCardSizeOneByOne),
                                      CardWithID(@"y", A2HomeCardKindCalendar, A2HomeCardSizeOneByOne) ];
    NSArray<A2HomePlacement *> *placements = [A2HomePacker gridPlacementsForCards:cards columns:2];
    CHECK(placements[0].columnSpan == 2, @"2x1 在 2 列下应跨两列（span=%ld）",
          (long)placements[0].columnSpan);

    NSArray<A2HomeCard *> *moved = [A2HomePacker cardsByMovingCardID:@"y" in:cards
                                                          placements:placements
                                                            toColumn:1 row:0];   // 宽卡的右半格
    CHECK([OrderOf(moved) isEqualToString:@"y,wide,x"], @"拖到宽卡右半格没顶到它前面：%@", OrderOf(moved));
}

#pragma mark - ⑤c 同类多卡 / 恢复默认

/// 同类多卡：按 id 定位，每张都能拿到自己（按 kind 找第一张是参考实现的 bug，Air2 不许复刻）。
static void testSameKindCardsAreAddressableByID(void) {
    A2HomeProfile *profile = [[A2HomeProfile alloc] init];
    profile.name = @"同类多卡";
    A2HomeCard *first = [A2HomeCard cardWithKind:A2HomeCardKindRecent];
    first.options.recentLimit = 2;
    A2HomeCard *second = [A2HomeCard cardWithKind:A2HomeCardKindRecent];
    second.options.recentLimit = 8;
    second.size = A2HomeCardSizeThreeByTwo;
    profile.cards = [@[first, second] mutableCopy];

    CHECK(profile.cards.count == 2, @"同类多卡被去重了");
    CHECK([profile cardWithID:second.cardID] == second, @"按 id 没拿到第二张卡");
    CHECK([profile cardWithID:second.cardID].options.recentLimit == 8,
          @"按 id 拿到了错的那张（limit=%ld）",
          (long)[profile cardWithID:second.cardID].options.recentLimit);
    CHECK([profile cardWithID:first.cardID].options.recentLimit == 2, @"第一张卡的选项被串了");
    CHECK([profile containsKind:A2HomeCardKindRecent], @"containsKind 该是 YES");
}

/// 恢复默认只重置当前方案的内容：方案 id / 名字保留，其它方案一动不动。
static void testResetContentKeepsProfileIdentityAndSiblings(void) {
    A2HomeDocument *doc = [A2HomeDocument defaultDocument];
    A2HomeProfile *keep = [doc activeProfile];
    NSString *keepName = keep.name;
    A2HomeProfile *sibling = [doc addProfileNamed:@"儿童机"];
    A2HomeCard *onlyCard = [A2HomeCard cardWithKind:A2HomeCardKindCalendar];
    sibling.cards = [@[onlyCard] mutableCopy];

    keep.name = @"我的方案";
    keep.layout = A2HomeLayoutModeFree;
    keep.cards = [@[[A2HomeCard cardWithKind:A2HomeCardKindRecent]] mutableCopy];
    NSString *keepID = keep.profileID;

    [keep resetContentToDefaultCards];

    CHECK([keep.profileID isEqualToString:keepID], @"恢复默认把方案 id 换了");
    CHECK([keep.name isEqualToString:@"我的方案"], @"恢复默认把方案名换了：%@", keep.name);
    CHECK(keep.cards.count >= 4, @"恢复默认后卡片数不对（%lu）", (unsigned long)keep.cards.count);
    CHECK(keep.layout == A2HomeLayoutModeGrid, @"恢复默认应回到网格布局");
    CHECK(![keep.cards containsObject:onlyCard], @"恢复默认没换掉旧卡片");
    CHECK(sibling.cards.count == 1 && sibling.cards.firstObject == onlyCard,
          @"恢复当前方案时动了别的方案（数据丢失）");
    CHECK([sibling.name isEqualToString:@"儿童机"], @"别的方案名字被改了");
    CHECK(![keepName isEqualToString:keep.name], @"前置条件不成立：方案名没改成自定义的");
}

#pragma mark - ⑥ 自定义卡片（图标 / 标题 / 跳转）

static void testCustomCardJumpPageRoundTrip(void) {
    NSString *json = @"{\"schema\":1,\"activeProfile\":\"p1\",\"profiles\":[{"
                     @"\"id\":\"p1\",\"name\":\"默认\",\"layout\":\"grid\",\"cards\":[{"
                     @"\"id\":\"custom-1\",\"kind\":\"shortcutCustom\",\"size\":\"2x1\","
                     @"\"options\":{\"title\":\"下载中心\",\"symbol\":\"arrow.down.circle.fill\","
                     @"\"jumpKind\":\"page\",\"jumpTarget\":\"download\"}}]}]}";
    A2HomeDocument *doc = DocFromJSONString(json, NULL);
    A2HomeCard *card = [doc activeProfile].cards.firstObject;
    CHECK(card != nil, @"自定义卡片被丢弃");
    CHECK(card.kind == A2HomeCardKindShortcutCustom, @"kind 不是 shortcutCustom");
    CHECK(card.size == A2HomeCardSizeTwoByOne, @"自定义卡片 2x1 档位没认出来");
    CHECK([card.options.customTitle isEqualToString:@"下载中心"], @"标题没读出来：%@", card.options.customTitle);
    CHECK([card.options.customSymbol isEqualToString:@"arrow.down.circle.fill"], @"图标没读出来");
    CHECK(card.options.jumpKind == A2HomeJumpKindPage, @"跳转类型不是 page");
    CHECK(card.options.jumpPage == A2HomeJumpPageDownload, @"内置页 token download 没解析对（%ld）",
          (long)card.options.jumpPage);
    CHECK([card.options isJumpUsableWithReason:NULL], @"合法内置页被判成不可用");

    NSString *written = JSONString([card JSONObjectIncludingPosition:NO]);
    CHECK([written containsString:@"\"jumpTarget\":\"download\""], @"写回丢了 jumpTarget：%@", written);
    CHECK([written containsString:@"\"jumpKind\":\"page\""], @"写回丢了 jumpKind：%@", written);
    CHECK([written containsString:@"\"title\":\"下载中心\""], @"写回丢了标题：%@", written);

    // 再读一遍必须等价（规范化是幂等的）。
    // ★这里必须把「单卡 JSON」包成整篇文档再读★：把卡片直接喂给 documentFromJSONObject:
    //   会因为缺 profiles 落成默认方案，读回来的根本不是这张卡（上一轮的两个 FAIL 就是这个）。
    NSString *docJSON = [NSString stringWithFormat:
        @"{\"schema\":1,\"activeProfile\":\"p1\",\"profiles\":[{\"id\":\"p1\",\"name\":\"默认\","
        @"\"layout\":\"grid\",\"cards\":[%@]}]}", written];
    A2HomeDocument *again = DocFromJSONString(docJSON, NULL);
    A2HomeCard *reloaded = [again activeProfile].cards.firstObject;
    CHECK(reloaded != nil && reloaded.kind == A2HomeCardKindShortcutCustom,
          @"往返后卡片类型变了（读回来的不是自定义卡片）");
    CHECK(reloaded != nil && reloaded.options.jumpPage == A2HomeJumpPageDownload, @"往返后跳转目标变了");
    CHECK([reloaded.options.customSymbol isEqualToString:@"arrow.down.circle.fill"], @"往返后图标变了");
}

static void testCustomCardURLJump(void) {
    NSString *json = @"{\"schema\":1,\"activeProfile\":\"p1\",\"profiles\":[{"
                     @"\"id\":\"p1\",\"name\":\"默认\",\"layout\":\"grid\",\"cards\":[{"
                     @"\"id\":\"custom-2\",\"kind\":\"shortcutCustom\",\"size\":\"1x1\","
                     @"\"options\":{\"title\":\"官网\",\"jumpKind\":\"url\","
                     @"\"jumpTarget\":\"https://air-devs.top/downloads\"}}]}]}";
    A2HomeDocument *doc = DocFromJSONString(json, NULL);
    A2HomeCard *card = [doc activeProfile].cards.firstObject;
    CHECK(card != nil, @"网址型自定义卡片被丢弃");
    CHECK(card.options.jumpKind == A2HomeJumpKindURL, @"跳转类型不是 url");
    CHECK([card.options isJumpUsableWithReason:NULL], @"合法 https 网址被判不可用");
    NSURL *url = A2HomeWebURLFromString(card.options.jumpURLString);
    CHECK([url.host isEqualToString:@"air-devs.top"], @"网址 host 解析错：%@", url.host);
    CHECK(card.options.jumpPage == A2HomeJumpPageVersions, @"换 type 后残留了旧 page 语义");
}

/// 软失败：非法网址 / 未知内置页**不丢卡**，只是跳不动（与引用类卡片同一口径）。
static void testInvalidCustomJumpIsSoftFailure(void) {
    NSString *json = @"{\"schema\":1,\"activeProfile\":\"p1\",\"profiles\":[{"
                     @"\"id\":\"p1\",\"name\":\"默认\",\"layout\":\"grid\",\"cards\":["
                     @"{ \"id\":\"c1\", \"kind\":\"shortcutCustom\", \"size\":\"1x1\","
                     @"  \"options\":{\"title\":\"坏网址\",\"jumpKind\":\"url\",\"jumpTarget\":\"ftp://x.example\"} },"
                     @"{ \"id\":\"c2\", \"kind\":\"shortcutCustom\", \"size\":\"1x1\","
                     @"  \"options\":{\"title\":\"未来页面\",\"jumpKind\":\"page\",\"jumpTarget\":\"futurePage\"} }"
                     @"]}]}";
    A2HomeDocument *doc = DocFromJSONString(json, NULL);
    NSArray<A2HomeCard *> *cards = [doc activeProfile].cards;
    CHECK(cards.count == 2, @"软失败却丢了卡（实际留 %lu 张）", (unsigned long)cards.count);

    NSString *reason = nil;
    CHECK(![cards[0].options isJumpUsableWithReason:&reason], @"ftp 网址不该被判可用");
    CHECK(reason.length > 0, @"不可用却没给原因");

    NSString *pageReason = nil;
    CHECK(![cards[1].options isJumpUsableWithReason:&pageReason], @"未知内置页不该被判可用");
    CHECK(pageReason.length > 0, @"未知内置页不可用却没给原因");
    CHECK(cards[1].options.jumpPage == A2HomeJumpPageUnknown, @"未知 token 应解析成 Unknown");
    CHECK([cards[0].options.jumpURLString isEqualToString:@"ftp://x.example"], @"非法网址被就地改写了");
}

static void testCustomCardTitleTruncatedAndSymbolWhitelisted(void) {
    NSMutableString *longTitle = [NSMutableString string];
    for (NSInteger i = 0; i < 60; i++) [longTitle appendString:@"字"];
    NSString *json = [NSString stringWithFormat:
        @"{\"schema\":1,\"activeProfile\":\"p1\",\"profiles\":[{\"id\":\"p1\",\"name\":\"默认\","
        @"\"layout\":\"grid\",\"cards\":[{\"id\":\"c1\",\"kind\":\"shortcutCustom\",\"size\":\"1x1\","
        @"\"options\":{\"title\":\"%@\",\"symbol\":\"任意乱写的符号\",\"jumpKind\":\"page\","
        @"\"jumpTarget\":\"settings\"}}]}]}", longTitle];
    A2HomeDocument *doc = DocFromJSONString(json, NULL);
    A2HomeCard *card = [doc activeProfile].cards.firstObject;
    CHECK(card != nil, @"自定义卡片被丢弃");
    CHECK((NSInteger)card.options.customTitle.length == A2HomeCustomTitleMaxLength,
          @"标题没按 %ld 字截断（实际 %lu）",
          (long)A2HomeCustomTitleMaxLength, (unsigned long)card.options.customTitle.length);
    CHECK([card.options.customSymbol isEqualToString:A2HomeCustomDefaultSymbol()],
          @"白名单外的符号没有回默认（实际 %@）", card.options.customSymbol);
    CHECK([A2HomeCustomSymbolChoices() containsObject:A2HomeCustomDefaultSymbol()],
          @"默认符号不在白名单里（会导致往返不稳定）");
}

static void testWebURLValidatorRejectsDangerousSchemes(void) {
    CHECK(A2HomeWebURLFromString(@"https://example.com/a?b=1") != nil, @"https 应放行");
    CHECK(A2HomeWebURLFromString(@"http://example.com") != nil, @"http 应放行");
    CHECK(A2HomeWebURLFromString(@"HTTPS://EXAMPLE.COM") != nil, @"大小写 scheme 应放行");
    CHECK(A2HomeWebURLFromString(@"javascript:alert(1)") == nil, @"javascript: 不该放行");
    CHECK(A2HomeWebURLFromString(@"file:///etc/passwd") == nil, @"file: 不该放行");
    CHECK(A2HomeWebURLFromString(@"minecraft://connect") == nil, @"自定义 scheme 不该放行");
    CHECK(A2HomeWebURLFromString(@"https://") == nil, @"没有 host 不该放行");
    CHECK(A2HomeWebURLFromString(@"   ") == nil, @"空白不算网址");
    CHECK(A2HomeWebURLFromString(nil) == nil, @"nil 不算网址");
}

static void testCustomCardSizesAndTargetRules(void) {
    NSArray<NSNumber *> *sizes = A2HomeSizesForKind(A2HomeCardKindShortcutCustom);
    CHECK([sizes containsObject:@(A2HomeCardSizeOneByOne)], @"自定义卡片应支持 1x1");
    CHECK([sizes containsObject:@(A2HomeCardSizeTwoByOne)], @"自定义卡片应支持 2x1");
    CHECK(![sizes containsObject:@(A2HomeCardSizeThreeByTwo)], @"自定义卡片不该支持 3x2");
    CHECK(A2HomeKindRequiresTarget(A2HomeCardKindShortcutCustom) == NO,
          @"自定义卡片不需要 target（它跳的是页面/网址，不是实体）");
    CHECK(A2HomeKindIsSingleton(A2HomeCardKindShortcutCustom) == NO,
          @"自定义卡片要能放多张（同类多卡时任意一张都可编辑）");
    CHECK(A2HomeKindIsAvailable(A2HomeCardKindShortcutCustom), @"自定义卡片应可用");
    A2HomeCardKind kind = A2HomeCardKindGreeting;
    CHECK(A2HomeCardKindFromToken(@"shortcutCustom", &kind) && kind == A2HomeCardKindShortcutCustom,
          @"shortcutCustom token 解析错");
    CHECK([A2HomeCardKindToken(A2HomeCardKindShortcutCustom) isEqualToString:@"shortcutCustom"],
          @"shortcutCustom token 写出错");
}

/// 内置页 token 是契约：每个枚举值都必须能往返，且 Unknown 没有 token。
static void testJumpPageTokensAreStable(void) {
    NSArray<NSString *> *expected = @[@"versions", @"versionSettings", @"download",
                                      @"account", @"multiplayer", @"files", @"settings"];
    NSArray<NSNumber *> *all = A2HomeJumpPagesAll();
    CHECK(all.count == expected.count, @"内置页数量变了（%lu）", (unsigned long)all.count);
    for (NSUInteger i = 0; i < all.count && i < expected.count; i++) {
        A2HomeJumpPage page = (A2HomeJumpPage)all[i].integerValue;
        CHECK([A2HomeJumpPageToken(page) isEqualToString:expected[i]],
              @"内置页 token 被改名：第 %lu 个应为 %@，实际 %@",
              (unsigned long)i, expected[i], A2HomeJumpPageToken(page));
        CHECK(A2HomeJumpPageFromToken(expected[i]) == page, @"token %@ 反解不回同一个值", expected[i]);
        CHECK(A2HomeJumpPageDisplayName(page).length > 0, @"内置页没有显示名");
        CHECK(A2HomeJumpPageSymbolName(page).length > 0, @"内置页没有图标");
    }
    CHECK([A2HomeJumpPageToken(A2HomeJumpPageUnknown) isEqualToString:@""], @"Unknown 不该有 token");
    CHECK(A2HomeJumpPageFromToken(@"nope") == A2HomeJumpPageUnknown, @"未知 token 应回 Unknown");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        testGridPackingHasNoOverlapAndNoOverflow();
        testGridModeNeverWritesCoordinates();
        testFreeDisplayDoesNotMutateStoredPositions();
        testNarrowCompressionKeepsRows();
        testBadCardDroppedGoodCardKept();
        testDuplicateCardIDsGetNewUUIDs();
        testSizeOutOfWhitelistFallsBackToDefault();
        testCardMissingTargetIsDropped();
        testHigherSchemaIsReadOnlyAndNotReset();
        testProfilesCannotBeRemovedBelowOne();
        testGridReorderDropsOntoHoveredCard();
        testGridReorderNoOpKeepsOrder();
        testGridReorderHandlesWideCardTarget();
        testSameKindCardsAreAddressableByID();
        testResetContentKeepsProfileIdentityAndSiblings();
        testCustomCardJumpPageRoundTrip();
        testCustomCardURLJump();
        testInvalidCustomJumpIsSoftFailure();
        testCustomCardTitleTruncatedAndSymbolWhitelisted();
        testWebURLValidatorRejectsDangerousSchemes();
        testCustomCardSizesAndTargetRules();
        testJumpPageTokensAreStable();

        printf("\n__HOME_LAYOUT_CHECKS=%ld\n", (long)gChecks);
        printf("__HOME_LAYOUT_FAILURES=%ld\n", (long)gFailures);
        printf("__HOME_LAYOUT_EXIT=%d\n", gFailures == 0 ? 0 : 1);
    }
    return gFailures == 0 ? 0 : 1;
}
