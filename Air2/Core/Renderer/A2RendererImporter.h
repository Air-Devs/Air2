//
//  A2RendererImporter.h
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
//  A2RendererImporter.h
//  Air2
//
//  渲染器插件导入器 —— 从 .air2plugin（zip）导入一个渲染器。
//
//  流程（每步都可能失败，失败原因要具体到「哪个文件、为什么不合法」）：
//    1. 解压到 **staging**（Documents/Air2/Renderers/.staging/<uuid>）
//       —— 逐条校验 zip 条目路径（拒绝 `..` / 绝对路径 / 反斜杠 / 控制字符）
//    2. 落盘复核：符号链接、特殊文件、多份 manifest 一律拒装
//    3. 读 manifest.json 并校验必填字段（`A2RendererPlugin` 的静态校验）
//    4. 静态校验每个库：普通文件 + 在包内 + Mach-O arm64 dylib + 导出符号
//    5. 算包摘要（sha256），与已装同 id 同版本比对 —— 内容不同则拒装
//    6. **原子换目录**：staging → .incoming → 目录名（旧目录先挪到 .trash，
//       任一步失败都把旧目录挪回来），并写入 install.json
//    7. 更新内存列表 + 发通知让 UI 刷新
//
//  ★为什么先解压到临时目录★
//    导入中途失败（manifest 不合法、缺库、架构不对）不应该留下半成品目录。
//    全部检查通过才换目录 —— 目录名换一次是原子的，用户要么看到旧版、要么看到新版，
//    不会看到「一半新一半旧」的插件。
//
//  ★安装记录 install.json★
//    记 rendererId / version / packageHash / sourceFileName / installedAt。
//    它的唯一用途是「同 id 同版本、内容不同」的判定与来源取证；
//    不是授权、不是签名：它就在被记录的目录里，谁都能改 —— 改它不改变任何判定，
//    只把「同版本同内容」与「从哪个文件装的」变成可核对的事实。
//

#import <Foundation/Foundation.h>
#import "A2RendererPlugin.h"

NS_ASSUME_NONNULL_BEGIN

/// 导入结果
@interface A2RendererImportResult : NSObject
@property (nonatomic, assign) BOOL success;
@property (nonatomic, strong, nullable) A2RendererPlugin *plugin;
@property (nonatomic, copy, nullable) NSString *errorMessage;
/// 是否覆盖了同 ID 的旧版本
@property (nonatomic, assign) BOOL replacedExisting;
/// 同 id 同版本同内容（幂等命中，磁盘没动）
@property (nonatomic, assign) BOOL alreadyInstalled;
@end

/// 渲染器目录变化通知 —— 设置页与本页据此刷新列表
extern NSNotificationName const A2RendererPluginsDidChangeNotification;

@interface A2RendererImporter : NSObject

+ (instancetype)shared;

/// 已安装的导入插件（按 displayName 排序）
- (NSArray<A2RendererPlugin *> *)installedPlugins;

/// 从 zip 导入（异步；progress 与 completion 都在主线程回调）。
///
/// @param zipPath .air2plugin（或 zip）文件路径
/// @param progress 进度回调（解压大包时有用）
- (void)importPluginAtPath:(NSString *)zipPath
                  progress:(nullable void (^)(double progress, NSString *message))progress
                completion:(void (^)(A2RendererImportResult *result))completion;

/// 卸载导入的插件（内置插件会被拒绝：内置的库在 App 包里，删不掉也不该删）
- (BOOL)removePlugin:(A2RendererPlugin *)plugin error:(NSError **)error;

/// 重新扫描并校验全部插件（App 启动时调用一次，见 A2AppDelegate）
- (void)reloadAll;

/// 正式的插件目录（Documents/Air2/Renderers）
@property (nonatomic, copy, readonly) NSString *pluginsDirectory;

@end

NS_ASSUME_NONNULL_END
