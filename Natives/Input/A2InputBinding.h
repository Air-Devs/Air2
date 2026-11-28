// ============================================================================
//  Natives/Input/A2InputBinding.h
//  Air2 —— 统一输入映射层 [INPUT-MAP-1] · 绑定表（三种源 → 键盘所有键 / 手柄任何键）
// ----------------------------------------------------------------------------
//  用户要的那句「allow（虚拟按钮，键盘，手柄）映射到键盘所有按键/手柄任何按键」，
//  数据形态就是本文件的 A2InputBinding：一条 = 「某个源的某个触发」→「某个落点」。
//
//  ★为什么绑定表不放在 Natives 之外★
//    映射发生在事件投递前（源 → 绑定 → 汇），必须在原生层内完成；
//    而「用户改了什么绑定」的持久化属于 App 层（A2Settings / NSUserDefaults），
//    所以本层只提供 dictionaryRepresentation / tableWithDictionaries: 这对
//    纯数据出入口，不认识任何存储位置 —— 原生层不感知业务（ARCHITECTURE 约束）。
//
//  ★键盘为什么默认「直通」★
//    用户没改过绑定时，按 A 就该出 A。若默认表为空且不直通，外接键盘会「全哑」，
//    而这类回归只在真机上才暴露。直通只在「没有显式绑定」时生效：
//    用户把 W 改成 S 之后，W 走显式绑定、不再直通 —— 否则一个触发会落两次。
// ============================================================================
#ifndef A2_INPUT_BINDING_H
#define A2_INPUT_BINDING_H

#import <Foundation/Foundation.h>

#import "A2InputTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// 一条绑定：源侧触发 → 目标侧落点。
@interface A2InputBinding : NSObject

/// 源种类。
@property (nonatomic, readonly) A2InputSourceKind sourceKind;

/// 虚拟按钮的控件 id（键盘/手柄为 nil）。
@property (nonatomic, copy, readonly, nullable) NSString *triggerIdentifier;

/// 触发编号（键盘 = GLFW 键码；手柄 = A2GamepadButton；虚拟按钮 = 0）。
@property (nonatomic, readonly) int triggerCode;

/// 落点空间。
@property (nonatomic, readonly) A2InputTargetKind targetKind;

/// 落点编号（键盘 = GLFW 键码；手柄 = A2GamepadButton）。
@property (nonatomic, readonly) int targetCode;

/// 日志用一句话描述（"keyboard A → key SPACE"）。
@property (nonatomic, copy, readonly) NSString *displayDescription;

+ (instancetype)bindingFromSource:(A2InputSourceKind)sourceKind
                triggerIdentifier:(nullable NSString *)triggerIdentifier
                      triggerCode:(int)triggerCode
                       targetKind:(A2InputTargetKind)targetKind
                       targetCode:(int)targetCode;

/// 这条绑定是否命中该触发（虚拟按钮按 id 比，键盘/手柄按编号比）。
- (BOOL)matchesTrigger:(A2InputTrigger)trigger;

/// 纯数据出口（可直接进 NSJSONSerialization）。
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;

/// 纯数据入口。字段不全/取值不认识时返回 nil（★不猜、不补默认值★）。
+ (nullable instancetype)bindingFromDictionary:(NSDictionary<NSString *, id> *)dictionary;

@end

/// 一张绑定表：按源分表 + 键盘直通开关。
/// ★NSCopying★：映射层持有的是「copy」。表是可变的（addBinding 用于改绑），
/// 若映射层直接持有调用方那张表，用户下次改绑就会绕过 setBindings: 的「先抬键」，
/// 卡键立刻回来。copy 让「交给映射层的表」与「编辑器在改的表」是两份。
@interface A2InputBindingTable : NSObject <NSCopying>

/// 默认表：键盘直通 + 手柄出厂映射（见 .m 里的表与理由）+ 虚拟按钮无绑定。
+ (instancetype)defaultTable;

/// 指定内容建表。keyboardPassthrough 见文件头「键盘为什么默认直通」。
- (instancetype)initWithBindings:(NSArray<A2InputBinding *> *)bindings
              keyboardPassthrough:(BOOL)keyboardPassthrough NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// 当前全部绑定（插入顺序，便于「先加的先生效」的直觉与稳定序列化）。
@property (nonatomic, copy, readonly) NSArray<A2InputBinding *> *bindings;

/// 键盘无显式绑定时的直通开关。
@property (nonatomic, assign, readonly) BOOL keyboardPassthrough;

/// 加一条绑定。★同源同触发后者覆盖前者★（改绑就是这么实现的）。
- (void)addBinding:(A2InputBinding *)binding;

/// 查这个触发对应的绑定；没有返回 nil（调用方再决定是否直通/丢弃）。
- (nullable A2InputBinding *)bindingForTrigger:(A2InputTrigger)trigger;

/// 序列化 / 反序列化（数组元素 = 单条绑定的 dictionaryRepresentation）。
- (NSArray<NSDictionary<NSString *, id> *> *)dictionaryRepresentation;
+ (nullable instancetype)tableWithDictionaries:(NSArray<NSDictionary<NSString *, id> *> *)dictionaries
                            keyboardPassthrough:(BOOL)keyboardPassthrough;

@end

NS_ASSUME_NONNULL_END

#endif /* A2_INPUT_BINDING_H */
