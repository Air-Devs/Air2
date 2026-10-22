//
//  A2JREManager.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
//
//  A2JREManager.h
//  Air2
//
//  JRE（Java 运行时）管理 —— 参考 ZL2 的 Java 管理。
//
//  ## 为什么需要
//
//  Minecraft 各版本对 Java 版本有硬性要求：
//    1.16 及以前 → Java 8
//    1.17 ~ 1.20 → Java 17
//    1.21+       → Java 21
//    26.x        → Java 25
//
//  ZL2 的做法：允许用户装多个 JRE，每个版本可以指定用哪个，
//  也可以设「自动选择」（按 MC 版本推断）。
//
//  ## 我们的 JRE 从哪来
//
//  make jre 已经下载好 4 个版本，打包进 App 的 java_runtimes/ 目录。
//  用户也可以从外部导入自己的 JRE（比如自定义构建）。
//
//  ## 目录结构（与 Air1 一致）
//
//    java_runtimes/
//      java-8-openjdk/
//        lib/server/libjvm.dylib     ← 判断有效性的关键文件
//        release                      ← 版本信息
//      java-17-openjdk/
//      java-21-openjdk/
//      java-25-openjdk/
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一个 JRE
@interface A2JRE : NSObject
@property (nonatomic, copy) NSString *identifier;    ///< 目录名，如 java-17-openjdk
@property (nonatomic, copy) NSString *displayName;   ///< "Java 17"
@property (nonatomic, assign) NSInteger majorVersion;///< 17
@property (nonatomic, copy) NSString *path;          ///< 绝对路径
@property (nonatomic, copy, nullable) NSString *arch; ///< arm64 / x86_64
@property (nonatomic, assign) BOOL builtin;          ///< 随 App 打包的（不可删）
@property (nonatomic, assign, readonly) BOOL valid;  ///< libjvm.dylib 存在
/// 无效时的原因
@property (nonatomic, copy, nullable, readonly) NSString *invalidReason;
@end

extern NSNotificationName const A2JREsDidChangeNotification;

@interface A2JREManager : NSObject

+ (instancetype)shared;

/// 全部 JRE（内置 + 用户导入）
@property (nonatomic, copy, readonly) NSArray<A2JRE *> *allJREs;

/// 按 MC 版本自动选择最合适的 JRE
- (nullable A2JRE *)jreForMCVersion:(NSString *)mcVersion;

/// 某个版本指定的 JRE（用户手动指定优先，否则自动）
- (nullable A2JRE *)jreForVersionName:(NSString *)versionName mcVersion:(NSString *)mcVersion;

/// 为某版本指定 JRE（写进该版本的配置）。nil 表示恢复自动。
- (BOOL)assignJRE:(nullable A2JRE *)jre forVersionName:(NSString *)versionName error:(NSError **)error;

/// 重新扫描
- (void)reload;

/// 导入外部 JRE（用户从文件 App 选的目录）
- (BOOL)importJREFromURL:(NSURL *)url error:(NSError **)error;

/// 删除导入的 JRE（内置不可删）
- (BOOL)removeJRE:(A2JRE *)jre error:(NSError **)error;

/// MC 版本 → 需要的 Java 主版本
- (NSInteger)requiredJavaVersionForMC:(NSString *)mcVersion;

@end

NS_ASSUME_NONNULL_END
