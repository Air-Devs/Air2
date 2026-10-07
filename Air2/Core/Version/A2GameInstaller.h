//
//  A2GameInstaller.h
//  Air2
//
//  版本安装器 —— 把「下载版本本体 + 安装加载器 + 补全资源」串成一个流程。
//
//  安装流程（对应 ZL2 的分阶段任务）：
//    1. 获取版本清单（version manifest）
//    2. 下载版本 json
//    3. 下载客户端 jar
//    4. 下载依赖库（libraries）
//    5. 下载资源文件（assets）
//    6. 安装模组加载器（可选）
//    7. 写入版本图标与配置
//
//  每个阶段都上报进度，可中断、可续传。
//

#import <Foundation/Foundation.h>
#import "A2DownloadEngine.h"
#import "A2ModLoaderAPI.h"

NS_ASSUME_NONNULL_BEGIN

/// 安装阶段（与 UI 的分步清单一一对应）
typedef NS_ENUM(NSInteger, A2InstallStage) {
    A2InstallStageFetchManifest = 0,   ///< 获取版本清单
    A2InstallStageDownloadJSON,        ///< 下载版本 json
    A2InstallStageDownloadJar,         ///< 下载客户端
    A2InstallStageDownloadLibraries,   ///< 下载依赖库
    A2InstallStageDownloadAssets,      ///< 下载资源文件
    A2InstallStageInstallLoader,       ///< 安装模组加载器
    A2InstallStageFinalize,            ///< 收尾
    A2InstallStageCount,
};

/// 安装请求
@interface A2InstallRequest : NSObject
/// 要安装的 MC 版本（如 1.21.5）
@property (nonatomic, copy) NSString *mcVersion;
/// 目标版本名（默认与 mcVersion 相同；带加载器时建议带后缀）
@property (nonatomic, copy, nullable) NSString *versionName;
/// 模组加载器类型，nil 表示原版
@property (nonatomic, strong, nullable) NSNumber *loaderType;
/// 加载器版本，nil 表示自动选最新稳定版
@property (nonatomic, copy, nullable) NSString *loaderVersion;
/// 游戏根目录
@property (nonatomic, copy) NSString *gameHome;
@end

/// 安装器
@interface A2GameInstaller : NSObject

/// 开始安装。
/// @param progress 阶段进度（stage, 该阶段进度 0~1, 说明文字）
/// @param completion 完成回调
- (void)install:(A2InstallRequest *)request
       progress:(void (^)(A2InstallStage stage, double progress, NSString *message))progress
     completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// 取消安装
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
