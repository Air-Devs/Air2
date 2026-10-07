// ============================================================================
// Natives/runtime/a2_resourcepaths.h
// ★ [RT-P1] R4 —— ResourcePathInjector：资源/库/JRE 路径单点拼装与注入项产出
//                      （Air2 命名：A2*/a2_*）
// ----------------------------------------------------------------------------
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.4（资源路径注入）
//
// 单一职责：本文件【只做原生层资源路径的拼装与「注入项」产出】。
//   · 不依赖 R3/R2/R7（只依赖 Foundation）—— 注入项以「有序的 -D 字符串数组」返回，
//     由 facade 交给 R3 `addRawOption:` 注入 ⇒ 依赖单向：facade → {R3,R4,R7,R2}。
//   · 不读偏好、不判版本、不感知业务；assets/资源包/数据 的解析在 Java 侧（PojavLauncher），
//     原生层不下发对应 -D（避免把业务概念带进原生层）。
//
// §3.4「路径只由一处拼装」：本文件是运行时层里**唯一**拼装
//   Frameworks / libraries / classpath / user.dir / user.home / tmp / java.home 的地方。
// ============================================================================
#ifndef A2_RESOURCEPATHS_H
#define A2_RESOURCEPATHS_H

#import <Foundation/Foundation.h>

// ----------------------------------------------------------------------------
// 输入：全部来自 facade（launchJVM）已有的原始量（本层不再自行探测）
// ----------------------------------------------------------------------------
typedef struct {
    NSString *bundlePath;     ///< .app 根（NSBundle.mainBundle.bundlePath）
    NSString *gameDir;        ///< 实例游戏目录 → -Duser.dir
    NSString *userHome;       ///< POJAV_HOME → -Duser.home
    NSString *tmpDir;         ///< 实例 tmp → -Djava.io.tmpdir
    NSString *javaHome;       ///< 选中 JRE home → -Djava.home
    NSString *librariesPath;  ///< <...>/libraries（classpath 扫 *.jar 的目录）
    NSString *lwjglDir;       ///< <libraries>/lwjgl-<ver>（classpath 尾项）
    NSString *frontJar;       ///< launchJar 时置于 classpath 最前的 jar
    NSString *frameworksPath; ///< <bundle>/Frameworks（缺则本层由 bundlePath 推）
} A2PathsInput;

// ----------------------------------------------------------------------------
// 产物：组装好的资源路径（§3.4「路径只由一处拼装」）
// ----------------------------------------------------------------------------
typedef struct {
    NSString *frameworksPath; ///< -Djava.library.path（对齐 _JNA_CHAINED.md 的 INBUNDLE 结论）
    NSString *classpath;      ///< libs/*.jar + lwjgl 尾项 + frontJar
    NSString *userDir;        ///< -Duser.dir
    NSString *userHome;       ///< -Duser.home
    NSString *tmpDir;         ///< -Djava.io.tmpdir
    NSString *javaHome;       ///< -Djava.home
} A2Paths;

/// 单一拼装点：由输入产出全部资源路径。空输入字段产出空字符串（调用方据此跳过注入）。
A2Paths a2_paths_resolve(A2PathsInput input);

/// classpath 拼装（单点）：可选前置 jar + librariesPath 下 *.jar + lwjgl 尾项。
/// 与旧链 JavaLauncher.m 内联拼装同语义（供 runtime 链与漂移对照共用）。
NSString *a2_paths_build_classpath(NSString *librariesPath,
                                  NSString *lwjglDir,
                                  NSString *frontJar);

/// 把资源路径转成有序的 -D 注入项（形如 "-Djava.library.path=…"）。
/// 只产出非空项；调用方用 R3 的 addRawOption: 注入（R3 按 key 去重 ⇒ 与旧 margv 重复注入安全）。
NSArray<NSString *> *a2_paths_injection_items(A2Paths paths);

#endif /* A2_RESOURCEPATHS_H */
