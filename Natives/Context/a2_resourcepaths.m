// ============================================================================
// Natives/runtime/a2_resourcepaths.m
// ★ [RT-P1] R4 —— ResourcePathInjector（实现）
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.4
// ============================================================================
#import "a2_resourcepaths.h"

// ----------------------------------------------------------------------------
// classpath 拼装（单点）
// ----------------------------------------------------------------------------
// 与旧链 JavaLauncher.m 等价：frontJar（可选）最前 + librariesPath 下 *.jar + lwjgl 尾项。
// libs 项后跟 ':'、lwjgl 尾项不带尾 ':'；lwjgl 尾项形如 "<lwjglDir>/*"。
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
    return cp;
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
    if (paths.javaHome.length > 0)       [items addObject:[NSString stringWithFormat:@"-Djava.home=%@",          paths.javaHome]];
    return items;
}
