// ============================================================================
// Natives/runtime/a2_resourcepaths.m
// ★ [RT-P1] R4 —— ResourcePathInjector（实现）
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.4
// ============================================================================
#import "a2_resourcepaths.h"

// ----------------------------------------------------------------------------
// ★ [RT-P1G] classpath 通配展开（单点）
// ----------------------------------------------------------------------------
// 真机根因（已实测复现，非推断）：
//   · 旧链走 JLI_Launch（真 · java 启动器）⇒ 会展开 "<dir>/*" 为目录内全部 .jar；
//   · runtime 链走 JNI_CreateJavaVM，classpath 以 "-Djava.class.path=<cp>" 传入 ⇒ HotSpot
//     把该属性【原样】收下，"*" 不被展开（AppClassLoader 也不展开）⇒ "<libs>/lwjgl-<ver>/*"
//     这个条目整条失效 ⇒ 目录里的 lwjgl.jar（iOS 定制 LWJGL，含 org.lwjgl.glfw.*）不可达
//     ⇒ 真机 NoClassDefFoundError: org/lwjgl/glfw/GLFWErrorCallbackI（阶段 7 主类抛异常）。
// 实测（Mac，JDK8，同款 JNI_CreateJavaVM；目录内放 lwjgl-341/lwjgl.jar + trivial.jar）：
//   -Djava.class.path="…/lwjgl-341/*"          ⇒ FindClass(Bar)=NOT-FOUND
//   -Djava.class.path="…/lwjgl-341/trivial.jar"⇒ FindClass(Bar)=FOUND
//   java -cp "…/lwjgl-341/*"                   ⇒ launcher 展开，类可加载
// ⇒ 结论：JNI 链必须在原生层显式展开通配，产出与旧链【生效后】逐项等价的 classpath。
// ----------------------------------------------------------------------------
// 语义：按 ':' 切分；每条以 "/*" 结尾者展开为 "<dir>/<每个 .jar>"（按名字排序，稳定）；
//       目录缺失/无 .jar ⇒ 原样保留该条目（不静默丢弃，便于真机诊断）。无 "/*" 时原样返回。
NSString *a2_paths_expand_classpath_wildcards(NSString *classpath) {
    if (classpath.length == 0) return classpath;
    if ([classpath rangeOfString:@"/*"].location == NSNotFound) return classpath;   // 无通配 ⇒ 快返

    NSArray<NSString *> *entries = [classpath componentsSeparatedByString:@":"];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:entries.count];
    NSFileManager *fm = NSFileManager.defaultManager;

    for (NSString *e in entries) {
        if (e.length == 0) continue;                 // 丢弃空条目（首尾/连续 ':' 产生）
        if ([e hasSuffix:@"/*"]) {
            NSString *dir = [e substringToIndex:(e.length - 2)];   // 去掉结尾 "/*"
            NSMutableArray<NSString *> *jars = [NSMutableArray array];
            for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                if ([f hasSuffix:@".jar"]) {
                    [jars addObject:[dir stringByAppendingPathComponent:f]];
                }
            }
            if (jars.count == 0) {
                [out addObject:e];                   // 目录缺失/无 jar：保留原条目
            } else {
                [jars sortUsingSelector:@selector(compare:)];
                [out addObjectsFromArray:jars];
            }
        } else {
            [out addObject:e];
        }
    }
    return [out componentsJoinedByString:@":"];
}

// ----------------------------------------------------------------------------
// classpath 拼装（单点）
// ----------------------------------------------------------------------------
// 与旧链 JavaLauncher.m 等价：frontJar（可选）最前 + librariesPath 下 *.jar + lwjgl 尾项。
// libs 项后跟 ':'、lwjgl 尾项不带尾 ':'；lwjgl 尾项形如 "<lwjglDir>/*"，随后【展开】为显式 jar。
// ★ [RT-P1G] 产出即「旧链 JLI 生效后」的等价形态（无未展开通配）⇒ 两条链逐项对齐。
// ----------------------------------------------------------------------------
NSString *a2_paths_build_classpath(NSString *librariesPath,
                                   NSString *lwjglDir,
                                   NSString *frontJar) {
    NSMutableString *cp = [NSMutableString string];

    if (frontJar.length > 0) {
        [cp appendFormat:@"%@:", frontJar];   // jar 最前，避免被 bundle libs 同名类遮蔽
    }
    if (librariesPath.length > 0) {
        NSArray<NSString *> *libs =
            [NSFileManager.defaultManager contentsOfDirectoryAtPath:librariesPath error:nil];
        for (NSString *f in libs) {
            // 只收 libs 下的 .jar；lwjgl-333/341 是目录（不以 .jar 结尾）不会误收
            if ([f hasSuffix:@".jar"]) {
                [cp appendFormat:@"%@/%@:", librariesPath, f];
            }
        }
    }
    if (lwjglDir.length > 0) {
        [cp appendFormat:@"%@/*", lwjglDir];
    }
    // ★ [RT-P1G] 展开 "<lwjglDir>/*"（JLI 会展开；JNI_CreateJavaVM 不会）
    return a2_paths_expand_classpath_wildcards(cp);
}

// ----------------------------------------------------------------------------
// 单一拼装点
// ----------------------------------------------------------------------------
A2Paths a2_paths_resolve(A2PathsInput in) {
    // 显式零初始化：A2Paths 含 __strong 成员（ARC）。
    A2Paths p = { nil, nil, nil, nil, nil, nil };
    p.userDir     = in.gameDir;
    p.userHome    = in.userHome;
    p.tmpDir      = in.tmpDir;
    p.javaHome    = in.javaHome;

    // Frameworks：§3.4「-Djava.library.path 指向包内 Frameworks」；缺省由 bundlePath 推。
    if (in.frameworksPath.length > 0) {
        p.frameworksPath = in.frameworksPath;
    } else if (in.bundlePath.length > 0) {
        p.frameworksPath = [in.bundlePath stringByAppendingPathComponent:@"Frameworks"];
    } else {
        p.frameworksPath = @"";
    }

    p.classpath = a2_paths_build_classpath(in.librariesPath, in.lwjglDir, in.frontJar);
    return p;
}

// ----------------------------------------------------------------------------
// 注入项产出（facade 交给 R3 addRawOption:；R3 按 key 去重）
// ----------------------------------------------------------------------------
NSArray<NSString *> *a2_paths_injection_items(A2Paths paths) {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    if (paths.frameworksPath.length > 0) [items addObject:[NSString stringWithFormat:@"-Djava.library.path=%@", paths.frameworksPath]];
    if (paths.userDir.length > 0)        [items addObject:[NSString stringWithFormat:@"-Duser.dir=%@",           paths.userDir]];
    if (paths.userHome.length > 0)       [items addObject:[NSString stringWithFormat:@"-Duser.home=%@",          paths.userHome]];
    if (paths.tmpDir.length > 0)         [items addObject:[NSString stringWithFormat:@"-Djava.io.tmpdir=%@",     paths.tmpDir]];
    // ★ [VS-GAP][G2] 不下发 -Djava.home：与旧链对齐。旧链只 setenv("JAVA_HOME")（见 JavaLauncher.m
    //   的 setenv("JAVA_HOME", …)，launch 与 headless 两处），从不下发 -Djava.home；
    //   新链一度多注入它 ⇒ 与旧链行为不一致（JVM 本会自行推导 java.home）。
    //   paths.javaHome 仍保留在 A2Paths 内（供日志/取证），但不再转成注入项。
    return items;
}
