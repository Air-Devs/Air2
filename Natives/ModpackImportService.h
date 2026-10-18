//
//  ModpackImportService.h
//  Amethyst
//
//  整合包导入服务 - 支持 .zip 和 .mrpack 格式
//
//  支持的格式：
//    1. Modrinth (.mrpack)       - modrinth.index.json
//    2. CurseForge (.zip)         - manifest.json
//    3. MMC (.zip)                - mmc-pack.json + instance.cfg
//    4. Plain ZIP (.zip)          - 直接含 .minecraft 目录结构（HMCL/FCL 导出格式）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 整合包格式（导入用）
typedef NS_ENUM(NSInteger, ModpackImportFormat) {
    ModpackImportFormatUnknown = 0,
    ModpackImportFormatModrinth,   // .mrpack
    ModpackImportFormatCurseForge, // .zip + manifest.json
    ModpackImportFormatMMC,        // .zip + mmc-pack.json + instance.cfg
    ModpackImportFormatPlainZip,   // .zip + 直接 .minecraft 目录
};

@interface ModpackImportService : NSObject

/// 取消信号：外部置为 YES 后，正在进行的 importModpack 会在下一个检查点停止
@property (nonatomic, assign, getter=isCancelled) BOOL cancelled;

/// 阶段5修复（参照 FCL DownloadList）：上次导入过程中下载失败的文件列表
/// 每条记录格式：@{@"fileName":NSString, @"url":NSString, @"reason":NSString}
/// 即使 importModpack: 返回 YES，也可能存在部分失败文件，调用方可读取此属性展示给用户。
@property (nonatomic, copy, readonly) NSArray<NSDictionary *> *failedFiles;

/// 解析整合包文件并返回信息字典
- (nullable NSDictionary *)parseModpackAtURL:(NSURL *)fileURL error:(NSError **)error;

/// 导入整合包到游戏目录
- (BOOL)importModpack:(NSDictionary *)modpackInfo error:(NSError **)error;

/// 导入整合包到游戏目录 (带进度回调)
/// progress: 0.0 ~ 1.0, stageMessage 是当前阶段的描述文案
- (BOOL)importModpack:(NSDictionary *)modpackInfo
             progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                error:(NSError **)error;

/// 获取已导入的整合包列表
- (NSArray<NSDictionary *> *)getImportedModpacks;

/// 删除已导入的整合包
- (BOOL)deleteModpack:(NSDictionary *)modpackInfo error:(NSError **)error;

/// 重置取消状态（在开始新导入前调用）
- (void)resetCancelState;

/// Phase 3（Task 3.2）：本次导入中下载失败的 mod 文件只读列表（仅 modrinth/curseforge 格式，
/// 不含 version 加载器/游戏文件条目），每条含 fileName/url/reason/format（curseforge 另含
/// projectID/fileID），供 UI 阶段展示与单独重试。
- (NSArray<NSDictionary *> *)failedDownloadFiles;

/// Phase 3（Task 3.2）：本次导入中因 404/NotFound（资源在源上不存在）被跳过的文件只读列表。
/// 跳过是警告而非失败：不计入 failedFiles，也不会让 importModpack: 返回 NO。
- (NSArray<NSDictionary *> *)skippedDownloadFiles;

@end

NS_ASSUME_NONNULL_END
