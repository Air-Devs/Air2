//
//  input_mapping_tests.m
//  Air2 —— tests/Input：统一输入映射层 [INPUT-MAP-1] 的纯逻辑单测
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  测什么（★直接链接真实实现，不是文本镜像★）：
//    Natives/Input/A2InputTypes.m            ← 键位目录 / 稳定键
//    Natives/Input/A2InputBinding.m          ← 绑定表（默认表、改绑覆盖、JSON 往返、严格解析）
//    Natives/Input/A2InputRouter.m           ← 唯一入口（直通、引用计数、防卡键、拒绝计数）
//    Natives/Input/A2KeyboardInputSource.m   ← HID→GLFW 全表（键盘实现的判据）
//
//  为什么必须真跑而不是源码扫描：
//    「按下 → 解算 → 投递 → 松开」是一条状态机；卡键、双触发、改绑后抬不起来
//    这三类 bug 只有把状态机真的跑一遍才看得见。源码扫描连「引用计数对不对」都答不了。
//
//  运行：python3 tests/Input/run_input_mapping_tests.py
//        （需 macOS + clang；UIKit 不在本测试范围内，见 runner 说明）
//

#import <Foundation/Foundation.h>

#import "A2InputBinding.h"
#import "A2InputRouter.h"
#import "A2InputTypes.h"
#import "A2GamepadInputSource.h"
#import "A2KeyboardInputSource.h"
#import "A2VirtualButtonInputSource.h"

static int gPass = 0;
static int gFail = 0;

static void ok(BOOL cond, NSString *what) {
    if (cond) {
        gPass++;
        printf("PASS  %s\n", what.UTF8String);
    } else {
        gFail++;
        printf("FAIL  %s\n", what.UTF8String);
    }
}

static void eqInt(long got, long want, NSString *what) {
    ok(got == want, [NSString stringWithFormat:@"%@（得到 %ld，期望 %ld）", what, got, want]);
}

#pragma mark - 假件（只实现协议，不碰 UIKit / JVM）

/// 记录一次投递（值类型不方便进数组，落成对象）。
@interface A2RecordedEvent : NSObject
@property (nonatomic, assign) A2InputTargetKind targetKind;
@property (nonatomic, assign) int code;
@property (nonatomic, assign) A2InputAction action;
@property (nonatomic, assign) int mods;
@property (nonatomic, assign) int scancode;
@end

@implementation A2RecordedEvent
@end

@interface A2FakeSink : NSObject <A2InputSink>
@property (nonatomic, copy) NSString *sinkIdentifier;
@property (nonatomic, assign) BOOL isAvailable;
@property (nonatomic, assign) BOOL acceptsGamepadTargets;
@property (nonatomic, strong) NSMutableArray<A2RecordedEvent *> *events;
@end

@implementation A2FakeSink

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _sinkIdentifier = @"fake-sink";
        _isAvailable = YES;
        _acceptsGamepadTargets = NO;
        _events = [NSMutableArray array];
    }
    return self;
}

- (BOOL)emitEvent:(A2InputEvent)event {
    if (event.targetKind == A2InputTargetKindGamepadButton && !self.acceptsGamepadTargets) {
        return NO;   // 模拟「当前内核没有手柄通道」
    }
    A2RecordedEvent *record = [[A2RecordedEvent alloc] init];
    record.targetKind = event.targetKind;
    record.code = event.code;
    record.action = event.action;
    record.mods = event.mods;
    record.scancode = event.scancode;
    [self.events addObject:record];
    return YES;
}

- (NSUInteger)pressCountForCode:(int)code {
    NSUInteger n = 0;
    for (A2RecordedEvent *e in self.events) {
        if (e.code == code && e.action == A2InputActionPress) n++;
    }
    return n;
}

- (NSUInteger)releaseCountForCode:(int)code {
    NSUInteger n = 0;
    for (A2RecordedEvent *e in self.events) {
        if (e.code == code && e.action == A2InputActionRelease) n++;
    }
    return n;
}

@end

/// 假源：直接按种类吐触发，用来同时扮演「虚拟按钮」「键盘」「手柄」三种源。
@interface A2FakeSource : NSObject <A2InputSource>
@property (nonatomic, assign) A2InputSourceKind sourceKind;
@property (nonatomic, copy) NSString *sourceIdentifier;
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@property (nonatomic, weak) id<A2InputSourceDelegate> delegate;
@property (nonatomic, assign) BOOL startSucceeds;
@end

@implementation A2FakeSource

- (instancetype)initWithKind:(A2InputSourceKind)kind name:(NSString *)name {
    self = [super init];
    if (self != nil) {
        _sourceKind = kind;
        _sourceIdentifier = [name copy];
        _enabled = YES;
        _startSucceeds = YES;
    }
    return self;
}

- (BOOL)startWithError:(NSError *_Nullable *_Nullable)error {
    (void) error;
    return self.startSucceeds;
}

- (void)stop {
    self.enabled = NO;
}

- (void)emit:(A2InputTrigger)trigger {
    [self.delegate inputSource:self didProduceTrigger:trigger];
}

@end

#pragma mark - ① 键位目录

static void TestKeyCatalog(void) {
    printf("\n-- ① 键盘空间目录（GLFW 键码）--\n");
    NSArray<NSNumber *> *codes = A2InputAllKeyCodes();
    ok(codes.count >= 130,
       [NSString stringWithFormat:@"键位目录覆盖完整（%lu 个）", (unsigned long) codes.count]);

    NSArray<NSNumber *> *expected = @[@32, @65, @90, @161, @256, @265, @280, @290,
                                      @301, @313, @320, @335, @340, @348];
    for (NSNumber *code in expected) {
        ok([codes containsObject:code],
           [NSString stringWithFormat:@"目录含键码 %@（%@）", code, A2InputKeyDisplayName(code.intValue)]);
    }

    // 名字唯一 + 往返：目录是映射编辑器与日志的共同口径，重名会让「选键」出现两个同选项。
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    BOOL unique = YES;
    BOOL roundTrip = YES;
    for (NSNumber *code in codes) {
        NSString *name = A2InputKeyDisplayName(code.intValue);
        if ([names containsObject:name.lowercaseString]) {
            unique = NO;
            printf("      重名：%s\n", name.UTF8String);
        }
        [names addObject:name.lowercaseString];
        if (A2InputKeyCodeForDisplayName(name) != code.intValue) {
            roundTrip = NO;
            printf("      往返失败：%d <-> %s\n", code.intValue, name.UTF8String);
        }
    }
    ok(unique, @"键名互不重复");
    ok(roundTrip, @"键名 ↔ 键码 往返一致");
    eqInt(A2InputKeyCodeForDisplayName(@"space"), 32, @"键名查码大小写不敏感（space → 32）");
    eqInt(A2InputKeyCodeForDisplayName(@"NOT_A_KEY"), -1, @"未知键名返回 -1（不猜）");
    ok([A2InputKeyDisplayName(9999) isEqualToString:@"KEY_9999"], @"越界键码有可读兜底名");
}

#pragma mark - ② HID → GLFW（键盘实现的判据）

static void TestKeyboardHIDTable(void) {
    printf("\n-- ② 外接键盘 HID → GLFW 键码 --\n");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0x04], 65, @"HID 0x04 → A");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0x1D], 90, @"HID 0x1D → Z");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0x1E], 49, @"HID 0x1E → 1");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0x27], 48, @"HID 0x27 → 0");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0x28], 257, @"HID 0x28 → ENTER");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0x2C], 32, @"HID 0x2C → SPACE");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0x3A], 290, @"HID 0x3A → F1");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0x68], 302, @"HID 0x68 → F13（本迭代补的段）");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0x59], 321, @"HID 0x59 → KP_1（小键盘段）");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0x62], 320, @"HID 0x62 → KP_0");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0x58], 335, @"HID 0x58 → KP_ENTER");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0xE0], 341, @"HID 0xE0 → LEFT_CONTROL");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0xE1], 340, @"HID 0xE1 → LEFT_SHIFT");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0x99], -1, @"未覆盖的 HID usage → -1");
    eqInt([A2KeyboardInputSource glfwKeyForHIDUsage:0x66], -1, @"电源键不映射（GLFW 无对应键码）");
}

#pragma mark - ③ 绑定表

static void TestBindings(void) {
    printf("\n-- ③ 绑定表（默认表 / 改绑覆盖 / 严格解析）--\n");
    A2InputBindingTable *table = [A2InputBindingTable defaultTable];
    ok(table.keyboardPassthrough, @"默认表：键盘直通开启（没改绑的键就是它自己）");

    A2InputTrigger gamepadA = A2InputTriggerMake(A2InputSourceKindGamepad, A2GamepadButtonA, nil,
                                                 A2InputActionPress, 0);
    A2InputBinding *jump = [table bindingForTrigger:gamepadA];
    ok(jump != nil, @"默认表含手柄 A 的出厂绑定");
    eqInt(jump.targetKind, A2InputTargetKindKey, @"手柄 A 的落点是键盘空间");
    eqInt(jump.targetCode, 32, @"手柄 A → SPACE（跳跃）");

    A2InputTrigger gamepadY = A2InputTriggerMake(A2InputSourceKindGamepad, A2GamepadButtonY, nil,
                                                 A2InputActionPress, 0);
    eqInt([table bindingForTrigger:gamepadY].targetCode, 'E', @"手柄 Y → E（背包）");

    // 改绑：同一个触发再绑一次 ⇒ 后者覆盖，表条数不变。
    NSUInteger before = table.bindings.count;
    [table addBinding:[A2InputBinding bindingFromSource:A2InputSourceKindGamepad
                                      triggerIdentifier:nil
                                            triggerCode:A2GamepadButtonA
                                             targetKind:A2InputTargetKindKey
                                             targetCode:340]];
    eqInt((long) table.bindings.count, (long) before, @"同触发改绑不增加条数（覆盖）");
    eqInt([table bindingForTrigger:gamepadA].targetCode, 340, @"改绑后手柄 A → LEFT_SHIFT");

    // 虚拟按钮按 id 匹配：改绑键位不改变「是同一个触发」。
    [table addBinding:[A2InputBinding bindingFromSource:A2InputSourceKindVirtualButton
                                      triggerIdentifier:@"attack"
                                            triggerCode:0
                                             targetKind:A2InputTargetKindKey
                                             targetCode:0]];
    A2InputTrigger attack = A2InputTriggerMake(A2InputSourceKindVirtualButton, 0, @"attack",
                                               A2InputActionPress, 0);
    ok([table bindingForTrigger:attack] != nil, @"虚拟按钮按控件 id 命中绑定");

    // JSON 往返
    NSArray<NSDictionary<NSString *, id> *> *json = [table dictionaryRepresentation];
    A2InputBindingTable *restored = [A2InputBindingTable tableWithDictionaries:json
                                                           keyboardPassthrough:table.keyboardPassthrough];
    ok(restored != nil, @"绑定表可序列化后读回");
    eqInt((long) restored.bindings.count, (long) table.bindings.count, @"读回条数一致");
    eqInt([restored bindingForTrigger:gamepadA].targetCode, 340, @"读回后改绑仍然生效");
    ok([restored bindingForTrigger:attack] != nil, @"读回后虚拟按钮绑定仍然生效");

    // 严格解析：缺字段 / 未知枚举 / 虚拟按钮用数字触发，一律 nil，不猜。
    ok([A2InputBinding bindingFromDictionary:@{@"source": @"keyboard", @"target": @"key"}] == nil,
       @"缺 code 的绑定读不进来");
    ok([A2InputBinding bindingFromDictionary:@{@"source": @"joystick", @"trigger": @1,
                                               @"target": @"key", @"code": @32}] == nil,
       @"未知 source 读不进来");
    ok([A2InputBinding bindingFromDictionary:@{@"source": @"virtual-button", @"trigger": @1,
                                               @"target": @"key", @"code": @32}] == nil,
       @"虚拟按钮的触发必须是 id 字符串");
    ok([A2InputBindingTable tableWithDictionaries:@[json.firstObject, @{@"source": @"?"}]
                              keyboardPassthrough:YES] == nil,
       @"一条坏 ⇒ 整表读不进来（不静默丢条）");
}

#pragma mark - ④ 键盘直通与改绑

static A2InputRouter *MakeRouter(A2InputBindingTable *table,
                                 A2FakeSink *sink,
                                 NSArray<A2FakeSource *> *sources) {
    A2InputRouter *router = [[A2InputRouter alloc] initWithBindings:table];
    [router addSink:sink];
    for (A2FakeSource *source in sources) {
        [router addSource:source];
    }
    return router;
}

static void TestRouterPassthrough(void) {
    printf("\n-- ④ 键盘直通与改绑 --\n");
    A2FakeSink *sink = [[A2FakeSink alloc] init];
    A2FakeSource *keyboard = [[A2FakeSource alloc] initWithKind:A2InputSourceKindKeyboard
                                                           name:@"keyboard"];
    A2InputRouter *router = MakeRouter([A2InputBindingTable defaultTable], sink, @[keyboard]);

    [keyboard emit:A2InputTriggerMake(A2InputSourceKindKeyboard, 'A', nil, A2InputActionPress, 0)];
    eqInt((long) sink.events.count, 1, @"没改绑时按键直通（投递 1 次）");
    eqInt(sink.events.firstObject.code, 'A', @"直通落点 = 原键码");
    ok([router isHeldKey:'A'], @"按下后记为「按着」");
    ok(![router isHeldKey:'B'], @"没按的键不记为按着");

    [keyboard emit:A2InputTriggerMake(A2InputSourceKindKeyboard, 'A', nil, A2InputActionRelease, 0)];
    eqInt((long) sink.events.count, 2, @"抬起也投递 1 次");
    eqInt(sink.events.lastObject.action, A2InputActionRelease, @"第二次是 RELEASE");
    ok(![router isHeldKey:'A'], @"抬起后不再记为按着");

    // 改绑：A → SPACE（显式绑定必须压过直通，否则一个触发会落两次）
    A2InputBindingTable *remapped = [A2InputBindingTable defaultTable];
    [remapped addBinding:[A2InputBinding bindingFromSource:A2InputSourceKindKeyboard
                                         triggerIdentifier:nil
                                               triggerCode:'A'
                                                targetKind:A2InputTargetKindKey
                                                targetCode:32]];
    [router setBindings:remapped];
    [keyboard emit:A2InputTriggerMake(A2InputSourceKindKeyboard, 'A', nil, A2InputActionPress, 0)];
    eqInt(sink.events.lastObject.code, 32, @"改绑后 A 落到 SPACE");
    eqInt([sink pressCountForCode:'A'], 1, @"改绑后原键码不再被直通投递（只此前的 1 次）");
}

#pragma mark - ⑤ 多源同落点（引用计数）

static void TestRouterRefCount(void) {
    printf("\n-- ⑤ 多源映射到同一个键（引用计数）--\n");
    A2InputBindingTable *table = [A2InputBindingTable defaultTable];
    // 虚拟按钮「跳跃」也绑到 SPACE，与手柄 A 同落点。
    [table addBinding:[A2InputBinding bindingFromSource:A2InputSourceKindVirtualButton
                                      triggerIdentifier:@"jump"
                                            triggerCode:0
                                             targetKind:A2InputTargetKindKey
                                             targetCode:32]];

    A2FakeSink *sink = [[A2FakeSink alloc] init];
    A2FakeSource *buttons = [[A2FakeSource alloc] initWithKind:A2InputSourceKindVirtualButton
                                                          name:@"virtual-button"];
    A2FakeSource *pad = [[A2FakeSource alloc] initWithKind:A2InputSourceKindGamepad name:@"gamepad"];
    A2InputRouter *router = MakeRouter(table, sink, @[buttons, pad]);

    [buttons emit:A2InputTriggerMake(A2InputSourceKindVirtualButton, 0, @"jump", A2InputActionPress, 0)];
    eqInt([sink pressCountForCode:32], 1, @"按钮按下 → SPACE 按下 1 次");

    [pad emit:A2InputTriggerMake(A2InputSourceKindGamepad, A2GamepadButtonA, nil, A2InputActionPress, 0)];
    eqInt([sink pressCountForCode:32], 1, @"第二个源压同一个键 → 不重复发 PRESS");

    [buttons emit:A2InputTriggerMake(A2InputSourceKindVirtualButton, 0, @"jump", A2InputActionRelease, 0)];
    eqInt([sink releaseCountForCode:32], 0, @"只松一个源 → 不能发 RELEASE（另一个还按着）");
    ok([router isHeldKey:32], @"仍记为按着");

    [pad emit:A2InputTriggerMake(A2InputSourceKindGamepad, A2GamepadButtonA, nil, A2InputActionRelease, 0)];
    eqInt([sink releaseCountForCode:32], 1, @"全部松开 → 才发 RELEASE");
    ok(![router isHeldKey:32], @"全部松开后不再记为按着");
}

#pragma mark - ⑥ 未映射 / 被拒 / 重复按下 / 未按先松

static void TestRouterEdges(void) {
    printf("\n-- ⑥ 边界（未映射 / 汇拒绝 / 重复按下 / 未按先松）--\n");
    A2FakeSink *sink = [[A2FakeSink alloc] init];
    A2FakeSource *pad = [[A2FakeSource alloc] initWithKind:A2InputSourceKindGamepad name:@"gamepad"];
    A2FakeSource *keyboard = [[A2FakeSource alloc] initWithKind:A2InputSourceKindKeyboard name:@"keyboard"];
    A2InputRouter *router = MakeRouter([A2InputBindingTable defaultTable], sink, @[pad, keyboard]);

    // 手柄 START 在出厂表里没有绑定 ⇒ 未映射：不投递、计数 +1。
    [pad emit:A2InputTriggerMake(A2InputSourceKindGamepad, A2GamepadButtonStart, nil,
                                 A2InputActionPress, 0)];
    eqInt((long) sink.events.count, 0, @"没有绑定的手柄键不投递");
    eqInt((long) router.unmappedTriggerCount, 1, @"未映射计数 +1");

    // 手柄落点投给「没有手柄通道」的汇 ⇒ 汇如实拒绝，映射层计数。
    A2InputBindingTable *toGamepad = [A2InputBindingTable defaultTable];
    [toGamepad addBinding:[A2InputBinding bindingFromSource:A2InputSourceKindGamepad
                                          triggerIdentifier:nil
                                                triggerCode:A2GamepadButtonB
                                                 targetKind:A2InputTargetKindGamepadButton
                                                 targetCode:A2GamepadButtonB]];
    [router setBindings:toGamepad];
    [pad emit:A2InputTriggerMake(A2InputSourceKindGamepad, A2GamepadButtonB, nil, A2InputActionPress, 0)];
    eqInt((long) sink.events.count, 0, @"汇拒绝的事件不落进记录");
    eqInt((long) router.rejectedEventCount, 1, @"被拒计数 +1（能回答「手柄为什么没反应」）");
    ok(![router isHeldKey:32], @"被拒的落点不记为按着");

    // 同一个触发重复按下（UIKit 重发 / 控件抖动）：只算一次。
    [router setBindings:[A2InputBindingTable defaultTable]];
    [keyboard emit:A2InputTriggerMake(A2InputSourceKindKeyboard, 'W', nil, A2InputActionPress, 0)];
    [keyboard emit:A2InputTriggerMake(A2InputSourceKindKeyboard, 'W', nil, A2InputActionPress, 0)];
    eqInt([sink pressCountForCode:'W'], 1, @"重复按下只投递 1 次");
    [keyboard emit:A2InputTriggerMake(A2InputSourceKindKeyboard, 'W', nil, A2InputActionRelease, 0)];
    eqInt([sink releaseCountForCode:'W'], 1, @"一次松开即可抬起（计数没被重复按下灌大）");

    // 没按下过就松开：不投递（否则 MC 的按键状态会从「没按」跳到「松开」）。
    NSUInteger beforeCount = sink.events.count;
    [keyboard emit:A2InputTriggerMake(A2InputSourceKindKeyboard, 'X', nil, A2InputActionRelease, 0)];
    eqInt((long) sink.events.count, (long) beforeCount, @"未按先松不投递");
}

#pragma mark - ⑦ 防卡键（releaseAll / 改绑时抬键 / 源禁用）

static void TestRouterStuckKeys(void) {
    printf("\n-- ⑦ 防卡键 --\n");
    A2FakeSink *sink = [[A2FakeSink alloc] init];
    A2FakeSource *keyboard = [[A2FakeSource alloc] initWithKind:A2InputSourceKindKeyboard name:@"keyboard"];
    A2InputRouter *router = MakeRouter([A2InputBindingTable defaultTable], sink, @[keyboard]);

    [keyboard emit:A2InputTriggerMake(A2InputSourceKindKeyboard, 'W', nil, A2InputActionPress, 0)];
    [keyboard emit:A2InputTriggerMake(A2InputSourceKindKeyboard, 'D', nil, A2InputActionPress, 0)];
    ok([router isHeldKey:'W'] && [router isHeldKey:'D'], @"两个键都记为按着");

    [router releaseAllHeldTargets];   // 退后台 / 窗口销毁时调用
    eqInt([sink releaseCountForCode:'W'], 1, @"releaseAll 抬起 W");
    eqInt([sink releaseCountForCode:'D'], 1, @"releaseAll 抬起 D");
    ok(![router isHeldKey:'W'] && ![router isHeldKey:'D'], @"releaseAll 后全部清零");

    // 改绑时先抬键：否则旧键永远抬不起来（真机表现：角色一直走）。
    [keyboard emit:A2InputTriggerMake(A2InputSourceKindKeyboard, 'W', nil, A2InputActionPress, 0)];
    A2InputBindingTable *remapped = [A2InputBindingTable defaultTable];
    [remapped addBinding:[A2InputBinding bindingFromSource:A2InputSourceKindKeyboard
                                         triggerIdentifier:nil
                                               triggerCode:'W'
                                                targetKind:A2InputTargetKindKey
                                                targetCode:'S']];
    [router setBindings:remapped];
    eqInt([sink releaseCountForCode:'W'], 2, @"改绑前把按着的 W 抬起来（第 2 次 RELEASE）");

    // 源禁用：事件被忽略（UI 上关掉某个输入源时就该这样）。
    keyboard.enabled = NO;
    NSUInteger beforeCount = sink.events.count;
    [keyboard emit:A2InputTriggerMake(A2InputSourceKindKeyboard, 'Q', nil, A2InputActionPress, 0)];
    eqInt((long) sink.events.count, (long) beforeCount, @"禁用的源不产生事件");
    keyboard.enabled = YES;

    // 汇不可用：不投递，计为被拒（窗口已销毁时不该往死句柄里投）。
    sink.isAvailable = NO;
    [keyboard emit:A2InputTriggerMake(A2InputSourceKindKeyboard, 'R', nil, A2InputActionPress, 0)];
    eqInt((long) sink.events.count, (long) beforeCount, @"不可用的汇收不到事件");
    ok(router.rejectedEventCount >= 1, @"不可用汇计入被拒");
}

#pragma mark - ⑧ 接口如实（虚拟按钮 / 手柄）

static void TestStubSourcesAreHonest(void) {
    printf("\n-- ⑧ 未实现的源如实报错 --\n");
    // 用真类（不是假件）：它们必须 start 失败并给出 NotImplemented，
    // 而不是「start 成功但什么都不做」——后者会让 UI 以为手柄能用了。
    id<A2InputSource> buttons = [[A2VirtualButtonInputSource alloc] init];
    id<A2InputSource> pad = [[A2GamepadInputSource alloc] init];

    NSError *error = nil;
    ok(![buttons startWithError:&error], @"虚拟按钮源 start 如实失败");
    eqInt(error.code, A2InputErrorCodeNotImplemented, @"虚拟按钮源给出 NotImplemented");
    error = nil;
    ok(![pad startWithError:&error], @"手柄源 start 如实失败");
    eqInt(error.code, A2InputErrorCodeNotImplemented, @"手柄源给出 NotImplemented");
}

int main(void) {
    @autoreleasepool {
        printf("== Air2 tests/Input · 统一输入映射层 [INPUT-MAP-1] ==\n");
        TestKeyCatalog();
        TestKeyboardHIDTable();
        TestBindings();
        TestRouterPassthrough();
        TestRouterRefCount();
        TestRouterEdges();
        TestRouterStuckKeys();
        TestStubSourcesAreHonest();
        printf("\n通过 %d，失败 %d\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
