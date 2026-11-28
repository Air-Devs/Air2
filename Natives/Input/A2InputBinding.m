// ============================================================================
//  Natives/Input/A2InputBinding.m
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 绑定表实现
// ----------------------------------------------------------------------------
//  两个实现要点（都不是随手写的）：
//
//  ① 查表用 A2InputTriggerKey 拼出的字符串索引，而不是「遍历数组比一遍」。
//     绑定量在真机上可能上百条（虚拟按钮布局 + 手柄 + 键盘改绑），而按键是
//     高频路径；线性扫会让每次按下都过一遍全表。索引与顺序数组并存：
//     顺序数组负责稳定序列化，索引负责 O(1) 查。
//
//  ② 反序列化**严格**：字段不认识就整条返回 nil，不猜、不补默认。
//     绑定表是「用户配置」，静默纠错会造出「我明明绑了跳跃，怎么在挖矿」这种
//     无法复现的问题；宁可让上层看到「这条读不进来」。
// ============================================================================
#import "A2InputBinding.h"

#pragma mark - 名字 ↔ 枚举（只认本层自己的名字，别处不许再写一套）

static A2InputSourceKind A2SourceKindFromName(NSString *name) {
    if ([name isEqualToString:@"virtual-button"]) return A2InputSourceKindVirtualButton;
    if ([name isEqualToString:@"keyboard"])       return A2InputSourceKindKeyboard;
    if ([name isEqualToString:@"gamepad"])        return A2InputSourceKindGamepad;
    return (A2InputSourceKind) -1;
}

static A2InputTargetKind A2TargetKindFromName(NSString *name) {
    if ([name isEqualToString:@"key"])            return A2InputTargetKindKey;
    if ([name isEqualToString:@"gamepad-button"]) return A2InputTargetKindGamepadButton;
    return (A2InputTargetKind) -1;
}

#pragma mark - A2InputBinding

@interface A2InputBinding ()
@property (nonatomic, assign, readwrite) A2InputSourceKind sourceKind;
@property (nonatomic, copy, readwrite, nullable) NSString *triggerIdentifier;
@property (nonatomic, assign, readwrite) int triggerCode;
@property (nonatomic, assign, readwrite) A2InputTargetKind targetKind;
@property (nonatomic, assign, readwrite) int targetCode;
@end

@implementation A2InputBinding

+ (instancetype)bindingFromSource:(A2InputSourceKind)sourceKind
                triggerIdentifier:(nullable NSString *)triggerIdentifier
                      triggerCode:(int)triggerCode
                       targetKind:(A2InputTargetKind)targetKind
                       targetCode:(int)targetCode {
    A2InputBinding *binding = [[self alloc] init];
    binding.sourceKind = sourceKind;
    binding.triggerIdentifier = triggerIdentifier;
    binding.triggerCode = triggerCode;
    binding.targetKind = targetKind;
    binding.targetCode = targetCode;
    return binding;
}

- (BOOL)matchesTrigger:(A2InputTrigger)trigger {
    if (trigger.sourceKind != self.sourceKind) {
        return NO;
    }
    // 虚拟按钮按 id 比：同一个控件改绑键位后仍然是「同一个触发」。
    if (self.triggerIdentifier != nil) {
        return trigger.identifier != nil && [trigger.identifier isEqualToString:self.triggerIdentifier];
    }
    return trigger.identifier == nil && trigger.code == self.triggerCode;
}

- (NSString *)displayDescription {
    NSString *from = nil;
    switch (self.sourceKind) {
        case A2InputSourceKindKeyboard:
            from = [NSString stringWithFormat:@"keyboard %@", A2InputKeyDisplayName(self.triggerCode)];
            break;
        case A2InputSourceKindGamepad:
            from = [NSString stringWithFormat:@"gamepad %@", A2GamepadButtonName((A2GamepadButton) self.triggerCode)];
            break;
        case A2InputSourceKindVirtualButton:
            from = [NSString stringWithFormat:@"button %@", self.triggerIdentifier ?: @"?"];
            break;
    }
    NSString *to = nil;
    switch (self.targetKind) {
        case A2InputTargetKindKey:
            to = [NSString stringWithFormat:@"key %@", A2InputKeyDisplayName(self.targetCode)];
            break;
        case A2InputTargetKindGamepadButton:
            to = [NSString stringWithFormat:@"gamepad %@", A2GamepadButtonName((A2GamepadButton) self.targetCode)];
            break;
    }
    return [NSString stringWithFormat:@"%@ → %@", from, to];
}

- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    // 触发字段刻意是「数字或字符串」：键盘/手柄是编号，虚拟按钮是 id。
    // 用两个字段（code / id）也行，但那样每条绑定都要带一个恒为空的字段，
    // 落盘后肉眼更难读 —— 这里选可读性。
    id trigger = (self.triggerIdentifier != nil) ? (id) self.triggerIdentifier : (id) @(self.triggerCode);
    return @{
        @"source": A2InputSourceKindName(self.sourceKind),
        @"trigger": trigger,
        @"target": A2InputTargetKindName(self.targetKind),
        @"code": @(self.targetCode),
    };
}

+ (nullable instancetype)bindingFromDictionary:(NSDictionary<NSString *, id> *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *sourceName = dictionary[@"source"];
    NSString *targetName = dictionary[@"target"];
    id trigger = dictionary[@"trigger"];
    NSNumber *code = dictionary[@"code"];
    if (![sourceName isKindOfClass:[NSString class]] ||
        ![targetName isKindOfClass:[NSString class]] ||
        ![code isKindOfClass:[NSNumber class]]) {
        return nil;
    }
    A2InputSourceKind sourceKind = A2SourceKindFromName(sourceName);
    A2InputTargetKind targetKind = A2TargetKindFromName(targetName);
    if ((NSInteger) sourceKind < 0 || (NSInteger) targetKind < 0) {
        return nil;
    }

    NSString *identifier = nil;
    int triggerCode = 0;
    if (sourceKind == A2InputSourceKindVirtualButton) {
        if (![trigger isKindOfClass:[NSString class]] || [trigger length] == 0) {
            return nil;
        }
        identifier = trigger;
    } else {
        if (![trigger isKindOfClass:[NSNumber class]]) {
            return nil;
        }
        triggerCode = [trigger intValue];
    }
    return [self bindingFromSource:sourceKind
                 triggerIdentifier:identifier
                       triggerCode:triggerCode
                        targetKind:targetKind
                        targetCode:[code intValue]];
}

@end

#pragma mark - A2InputBindingTable

@interface A2InputBindingTable ()
@property (nonatomic, assign, readwrite) BOOL keyboardPassthrough;
@end

@implementation A2InputBindingTable {
    NSMutableArray<A2InputBinding *> *_ordered;
    NSMutableDictionary<NSString *, A2InputBinding *> *_index;
}

+ (instancetype)defaultTable {
    NSMutableArray<A2InputBinding *> *bindings = [NSMutableArray array];

    // 手柄出厂映射：★刻意对齐 MC 默认键位★，让「插上手柄就能玩」成立，
    // 而不是让用户先去绑十几条才有反应。
    // 数值上 A/B/X/Y 与 GLFW_GAMEPAD_BUTTON_* 相同（见 A2GamepadButton 的说明）。
    // [INPUT-MAP-3] 接真机后按手感再调，调的是这张表，不是代码。
    struct { int button; int key; } defaults[] = {
        { A2GamepadButtonA,           32  },  // A  → SPACE   跳跃
        { A2GamepadButtonB,           340 },  // B  → LSHIFT  潜行
        { A2GamepadButtonX,           341 },  // X  → LCTRL   疾跑
        { A2GamepadButtonY,           'E' },  // Y  → E       背包
        { A2GamepadButtonLeftBumper,  'Q' },  // LB → Q       丢弃
        { A2GamepadButtonRightBumper, 258 },  // RB → TAB     玩家列表
        { A2GamepadButtonBack,        256 },  // BACK → ESC   暂停/菜单
        { A2GamepadButtonDPadUp,      265 },  // ↑ → UP
        { A2GamepadButtonDPadDown,    264 },  // ↓ → DOWN
        { A2GamepadButtonDPadLeft,    263 },  // ← → LEFT
        { A2GamepadButtonDPadRight,   262 },  // → → RIGHT
    };
    for (size_t i = 0; i < sizeof(defaults) / sizeof(defaults[0]); i++) {
        [bindings addObject:[A2InputBinding bindingFromSource:A2InputSourceKindGamepad
                                           triggerIdentifier:nil
                                                 triggerCode:defaults[i].button
                                                  targetKind:A2InputTargetKindKey
                                                  targetCode:defaults[i].key]];
    }

    // 虚拟按钮没有出厂绑定：控件的键位来自布局模型（每个控件自带 key），
    // 由 [INPUT-MAP-2] 接控件层时按布局灌进来 —— 在这里编一套默认只会和布局打架。
    return [[self alloc] initWithBindings:bindings keyboardPassthrough:YES];
}

- (instancetype)initWithBindings:(NSArray<A2InputBinding *> *)bindings
              keyboardPassthrough:(BOOL)keyboardPassthrough {
    self = [super init];
    if (self != nil) {
        _ordered = [NSMutableArray arrayWithCapacity:bindings.count];
        _index = [NSMutableDictionary dictionaryWithCapacity:bindings.count];
        _keyboardPassthrough = keyboardPassthrough;
        for (A2InputBinding *binding in bindings) {
            [self addBinding:binding];
        }
    }
    return self;
}

- (NSArray<A2InputBinding *> *)bindings {
    return [_ordered copy];
}

- (void)addBinding:(A2InputBinding *)binding {
    if (binding == nil) {
        return;
    }
    // 同源同触发覆盖：先摘掉旧的那条（顺序保持「原位置替换」更好读，
    // 但简单起见按追加处理也可以；这里选择原位替换，避免序列化顺序随改绑漂移）。
    A2InputTrigger trigger = A2InputTriggerMake(binding.sourceKind,
                                                binding.triggerCode,
                                                binding.triggerIdentifier,
                                                A2InputActionPress,
                                                0);
    NSString *key = A2InputTriggerKey(trigger);
    A2InputBinding *existing = _index[key];
    if (existing != nil) {
        NSUInteger idx = [_ordered indexOfObjectIdenticalTo:existing];
        if (idx != NSNotFound) {
            _ordered[idx] = binding;
        } else {
            [_ordered addObject:binding];
        }
    } else {
        [_ordered addObject:binding];
    }
    _index[key] = binding;
}

- (nullable A2InputBinding *)bindingForTrigger:(A2InputTrigger)trigger {
    return _index[A2InputTriggerKey(trigger)];
}

- (id)copyWithZone:(NSZone *)zone {
    (void) zone;
    // 深一层：绑定对象本身不可变（只有只读属性），共享它们是安全的；
    // 但顺序数组与索引必须新建，否则「改副本」会改到原表。
    return [[A2InputBindingTable alloc] initWithBindings:_ordered
                                    keyboardPassthrough:_keyboardPassthrough];
}

- (NSArray<NSDictionary<NSString *, id> *> *)dictionaryRepresentation {
    NSMutableArray<NSDictionary<NSString *, id> *> *array =
        [NSMutableArray arrayWithCapacity:_ordered.count];
    for (A2InputBinding *binding in _ordered) {
        [array addObject:[binding dictionaryRepresentation]];
    }
    return array;
}

+ (nullable instancetype)tableWithDictionaries:(NSArray<NSDictionary<NSString *, id> *> *)dictionaries
                            keyboardPassthrough:(BOOL)keyboardPassthrough {
    if (![dictionaries isKindOfClass:[NSArray class]]) {
        return nil;
    }
    NSMutableArray<A2InputBinding *> *bindings =
        [NSMutableArray arrayWithCapacity:dictionaries.count];
    for (id entry in dictionaries) {
        A2InputBinding *binding = [A2InputBinding bindingFromDictionary:entry];
        if (binding == nil) {
            return nil;   // 严格：一条读不进来就整表失败（见文件头 ②）
        }
        [bindings addObject:binding];
    }
    return [[self alloc] initWithBindings:bindings keyboardPassthrough:keyboardPassthrough];
}

@end
