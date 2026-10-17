//
//  A2RendererImporter.h
//  Air2
//
//  渲染器插件导入器 —— 从 .air2plugin（zip）导入一个渲染器。
//
//  流程（四步，每步都可能失败且失败原因要具体）：
//    1. 解压到临时目录（先不污染正式目录）
//    2. 读 manifest.json 并校验字段
//    3. 检查是否需要覆盖已存在的同 ID 插件
//    4. 移入正式目录 Documents/Air2/Renderers/{rendererId}/
//       → 校验（文件存在 / 架构 / dlopen 探测）
//       → 写入索引
//       → 发通知让 UI 刷新
//
//  为什么先解压到临时目录：
//    导入中途失败（manifest 不合法、缺库）不应该留下半成品目录。
//    全部检查通过才原子移动过去。
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
@end

/// 渲染器目录变化通知 —— 设置页据此刷新列表
extern NSNotificationName const A2RendererPluginsDidChangeNotification;

@interface A2RendererImporter : NSObject

+ (instancetype)shared;

/// 已安装的导入插件（按 displayName 排序）
- (NSArray<A2RendererPlugin *> *)installedPlugins;

/// 从 zip 导入。
///
/// @param zipPath .air2plugin（或 zip）文件路径
/// @param progress 进度回调（解压大包时有用）
- (void)importPluginAtPath:(NSString *)zipPath
                  progress:(nullable void (^)(double progress, NSString *message))progress
                completion:(void (^)(A2RendererImportResult *result))completion;

/// 卸载导入的插件
- (BOOL)removePlugin:(A2RendererPlugin *)plugin error:(NSError **)error;

/// 重新扫描并校验全部插件（App 启动时调用）
- (void)reloadAll;

/// 正式的插件目录
@property (nonatomic, copy, readonly) NSString *pluginsDirectory;

@end

NS_ASSUME_NONNULL_END
