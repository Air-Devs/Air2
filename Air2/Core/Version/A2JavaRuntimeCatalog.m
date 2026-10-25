//
//  A2JavaRuntimeCatalog.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  实现见头文件。★只用 Foundation★（Core 不得 import UIKit）。
//
//  ★为什么「未内置」的档位也留在候选表里★：用户要的是「看得见全表、选到没用要如实报」。
//  是否内置由调用方拿 bundle 现算（`+isUsableJavaHome:`），不在这里缓存、不静默删项。
//

#import "A2JavaRuntimeCatalog.h"

@implementation A2JavaRuntimeCatalog

+ (NSString *)javaRuntimesDirectoryName {
    return @"java_runtimes";
}

+ (NSArray<NSString *> *)allDirectoryNames {
    // 与老线本机产物 `b12/artifacts/java_runtimes/` 的四档逐字一致（同一份血统）。
    return @[ @"java-25-openjdk", @"java-21-openjdk", @"java-17-openjdk", @"java-8-openjdk" ];
}

+ (NSString *)defaultDirectoryName {
    return [self allDirectoryNames].firstObject;
}

+ (NSInteger)majorVersionForDirectoryName:(NSString *)directoryName {
    // 只认 `java-<n>-openjdk` 这一种形态（老线同款目录名）；别的形态返回 0，不猜。
    if (directoryName.length == 0) return 0;
    NSArray<NSString *> *parts = [directoryName componentsSeparatedByString:@"-"];
    if (parts.count != 3) return 0;
    if (![parts[0] isEqualToString:@"java"] || ![parts[2] isEqualToString:@"openjdk"]) return 0;
    NSString *n = parts[1];
    if (n.length == 0) return 0;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([n rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return 0;
    return n.integerValue;
}

+ (NSString *)nameLocalizationKeyForDirectoryName:(NSString *)directoryName {
    NSInteger major = [self majorVersionForDirectoryName:directoryName];
    if (major <= 0) return @"";
    return [NSString stringWithFormat:@"runtime.jre.%ld", (long)major];
}

+ (NSString *)mcRangeLocalizationKeyForMajorVersion:(NSInteger)majorVersion {
    switch (majorVersion) {
        case 8:  return @"runtime.jre.mc.8";
        case 17: return @"runtime.jre.mc.17";
        case 21: return @"runtime.jre.mc.21";
        case 25: return @"runtime.jre.mc.25";
        default: return @"runtime.jre.mc.unknown";
    }
}

+ (NSArray<NSString *> *)libjvmRelativePaths {
    // ★唯一一份表★：与 `Natives/Context/a2_vmloader.m` 的 `a2_vm_resolve_libjvm()`
    // 三项逐字一致（tests/Runtime 断言两处都认这三种布局）。
    // 为什么不能只认第一种：官方/Amethyst 的 java-8 是经典 JDK 8 布局
    // `jre/lib/server/libjvm.dylib` ⇒ 只认 `lib/server` 会把「真的能启动的 java-8」
    // 判成「未内置/不完整」，用户永远进不去（矩阵 §4-⑤）。
    return @[ @"lib/server/libjvm.dylib",
              @"jre/lib/server/libjvm.dylib",
              @"lib/hotspot/libjvm.dylib" ];
}

+ (BOOL)isUsableJavaHome:(nullable NSString *)javaHome {
    // 判据 = 启动链真正要 dlopen 的那个文件，且**与 vmloader 同一份相对路径表**，
    // 不是「目录存在」——目录在而 libjvm 缺正是「看着内置、一启动就失败」的形态。
    if (javaHome.length == 0) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *rel in [self libjvmRelativePaths]) {
        NSString *libjvm = [javaHome stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:libjvm isDirectory:&isDir] && !isDir) return YES;
    }
    return NO;
}

@end
