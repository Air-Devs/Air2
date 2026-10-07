// ============================================================================
// Natives/runtime/a2_argbuilder.h
// ★ [RT-P1] R3 —— ArgBuilder：JVM 参数结构化拼装（Air2 命名：A2*/a2_*）
// ----------------------------------------------------------------------------
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.3（JVM 参数拼装）
//
// 单一职责：本文件【只拼装 JVM 参数】，不碰资源路径（R4）、不碰 VM 加载（R2）、不写日志（R7）。
//
// 设计（对齐 §3.3「结构化 builder + 动态数组 → JavaVMInitArgs.options」）：
//   · 原始选项（-X*/-XX*/-D*/-javaagent: 等）原样保序；`-D<key>=` 按 key 去重（后注覆盖值、位置不变）；
//   · classpath 单一来源，构建时按【显式传入】的 A2ClasspathForm 决定注入形态；
//   · 主类与程序参数单独持有（JNI_CreateJavaVM 不跑 main，由调用方 dispatch）。
//
// ★ 单一事实源：本层不复制任何业务参数清单。`ingestArgv:count:` 直接解析 launchJVM 既有的
//   最终 margv（argv[0]=java 可执行被丢弃，-cp/-jar 被识别）⇒ 旧链与 runtime 链共用同一份来源。
// ★ 开关显式：classpathForm 由调用方显式设置（不读环境变量 —— 环境读取收在 facade 边界）。
// ============================================================================
#ifndef A2_ARGBUILDER_H
#define A2_ARGBUILDER_H

#import <Foundation/Foundation.h>
#include "jni.h"   // JavaVMInitArgs / JavaVMOption（include_directories 含 Natives/）

// ----------------------------------------------------------------------------
// classpath 注入形态（★ §3.3：A/B 待真机确定 ⇒ 做成显式可切换 ★）
// ----------------------------------------------------------------------------
typedef NS_ENUM(NSInteger, A2ClasspathForm) {
    /// A（默认，JNI 文档口径）：合并为单个 `-Djava.class.path=<cp>` 选项。
    A2ClasspathFormProperty = 0,
    /// B（真机 A/B 对照）：保留 launcher 风格 `-cp` + 路径两个独立选项条目。
    A2ClasspathFormOption   = 1,
};

/// 纯函数：配置名字 → 形态（"option"/"b"/"1" ⇒ Option；其它 ⇒ Property）。
/// 不读环境变量；环境读取由 facade 边界完成后再显式传入。
A2ClasspathForm a2_classpath_form_from_name(NSString *name);

/// 构建产物：持有 JavaVMInitArgs 及其 optionString 的稳定存储。
/// ★ 调用方须在 JNI_CreateJavaVM 返回前保持本对象存活（optionString 指向其内部拷贝）。
@interface A2VMArgsBundle : NSObject

/// 构建好的 JavaVMInitArgs（值语义；options 指向 bundle 内部存储）。
- (JavaVMInitArgs)initArgs;

/// 内部 optionString 数组（长度 = optionCount；生命周期同 bundle）。供 R2 组装 JavaVMOption。
- (const char *const *)optionStrings;

/// 实际生效的 option 条目数。
@property (nonatomic, readonly) int optionCount;

@end

// ----------------------------------------------------------------------------
// A2ArgBuilder
// ----------------------------------------------------------------------------
@interface A2ArgBuilder : NSObject

+ (instancetype)builder;

// —— classpath 形态：显式设置（默认 A2ClasspathFormProperty）——
@property (nonatomic) A2ClasspathForm classpathForm;

// —— 原始选项（原样保序；-D 走按 key 去重）——
- (void)addRawOption:(NSString *)option;

// —— classpath：单一来源 ——
- (void)setClasspath:(NSString *)classpath;
- (NSString *)classpath;

// —— 主类 / 程序参数（由 ingestArgv: 填充；读取供 dispatch 用）——
- (NSString *)mainClass;
- (NSArray<NSString *> *)programArgs;

// —— 旧 margv 摄取（单一事实源；解析规则见 .m 头）——
// 返回 YES = 可走 runtime 链；NO = 须回退旧链（-jar 形态，或未解析出主类）。
- (BOOL)ingestArgv:(const char *const *)argv count:(int)count;

/// 是否检测到 `-jar`（runtime 层暂不支持 ⇒ 须回退）。摄取后有效。
@property (nonatomic, readonly) BOOL jarMode;

// —— 构建 JavaVMInitArgs ——
- (A2VMArgsBundle *)buildInitArgsWithVersion:(jint)jniVersion
                          ignoreUnrecognized:(BOOL)ignoreUnrecognized;

/// 多行摘要（供 A/B 对照日志）。
- (NSString *)summary;

@end

#endif /* A2_ARGBUILDER_H */
