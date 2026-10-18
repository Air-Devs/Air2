#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 整合包导出格式（参照 FCL/HMCL/ZL2）
typedef NS_ENUM(NSInteger, ModpackExportFormat) {
    ModpackExportFormatModrinth = 0,   // Modrinth .mrpack 格式
    ModpackExportFormatCurseForge = 1, // CurseForge .zip 格式（manifest.json）
    ModpackExportFormatMMC = 2,        // MMC (MultiMC/Prism) .zip 格式（mmc-pack.json + instance.cfg）
    ModpackExportFormatPlainZip = 3,   // 纯 .zip 格式（直接打包 .minecraft 目录，HMCL 兼容）
    ModpackExportFormatLinkList = 4,   // 链接列表 .txt 格式（FCL 支持的简单格式）
};

/// 导出时可选包含的文件类型（位掩码）
/// 注意：枚举值名称不能与 typedef 名 `ModpackExportFileOptions` 冲突，
/// 因此表示 options.txt 的标志位使用 `ModpackExportFileGameSettings`。
typedef NS_OPTIONS(NSInteger, ModpackExportFileOptions) {
    ModpackExportFileNone           = 0,
    ModpackExportFileMods           = 1 << 0,  // mods/ 目录
    ModpackExportFileConfigs        = 1 << 1,  // config/ + defaultconfigs/
    ModpackExportFileResourcePacks  = 1 << 2,  // resourcepacks/
    ModpackExportFileShaderPacks    = 1 << 3,  // shaderpacks/
    ModpackExportFileSaves          = 1 << 4,  // saves/（默认不包含）
    ModpackExportFileGameSettings   = 1 << 5,  // options.txt/optionsof.txt/optionsshaders.txt
    ModpackExportFileServers        = 1 << 6,  // servers.dat（默认不包含，含敏感信息）
    ModpackExportFileScripts        = 1 << 7,  // kubejs/scripts/localization/patchouli_books
    ModpackExportFileDefault        = ModpackExportFileMods | ModpackExportFileConfigs |
                                      ModpackExportFileResourcePacks | ModpackExportFileShaderPacks |
                                      ModpackExportFileGameSettings | ModpackExportFileScripts,
    ModpackExportFileAll            = ModpackExportFileMods | ModpackExportFileConfigs |
                                      ModpackExportFileResourcePacks | ModpackExportFileShaderPacks |
                                      ModpackExportFileSaves | ModpackExportFileGameSettings |
                                      ModpackExportFileServers | ModpackExportFileScripts,
};

/// 整合包导出服务（参照 FCL ExportModpackViewModel.kt / HMCL ModpackHelper / ZL2 ExportModpackHelper）
@interface ModpackExportService : NSObject

+ (instancetype)sharedService;

/// 取消信号：外部置为 YES 后，正在进行的导出会在下一个检查点停止
@property (nonatomic, assign, getter=isCancelled) BOOL cancelled;

/// 重置取消状态（在开始新导出前调用）
- (void)resetCancelState;

/// 导出整合包（基础版，使用默认文件选项）
/// @param profileName profile 名称（从 PLProfiles.current.profiles 获取 gameDir/lastVersionId）
/// @param destPath 目标文件路径（.mrpack / .zip / .txt）
/// @param name 整合包名称
/// @param version 整合包版本
/// @param author 作者
/// @param format 导出格式
/// @param includeOverrides 是否包含 overrides（config/options.txt 等），等价于 ModpackExportFileDefault
/// @param progress 进度回调（0.0-1.0）
/// @param error 错误信息
/// @return 是否成功
- (BOOL)exportModpackForProfile:(NSString *)profileName
                         toPath:(NSString *)destPath
                            name:(NSString *)name
                         version:(NSString *)version
                          author:(NSString *)author
                         format:(ModpackExportFormat)format
                includeOverrides:(BOOL)includeOverrides
                       progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                          error:(NSError **)error;

/// 导出整合包（高级版，支持文件类型过滤）
/// @param fileOptions 文件类型位掩码，决定哪些目录/文件被包含到 overrides
- (BOOL)exportModpackForProfile:(NSString *)profileName
                         toPath:(NSString *)destPath
                            name:(NSString *)name
                         version:(NSString *)version
                          author:(NSString *)author
                         format:(ModpackExportFormat)format
                     fileOptions:(ModpackExportFileOptions)fileOptions
                       progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                          error:(NSError **)error;

/// 从 lastVersionId 反解 loader 和 minecraft 版本
/// 例如 "fabric-loader-0.15.7-1.20.1" → loader="fabric", loaderVersion="0.15.7", mcVersion="1.20.1"
/// "1.20.1-forge-47.3.0" → loader="forge", loaderVersion="47.3.0", mcVersion="1.20.1"
/// "1.20.1-neoforge-47.1.0" → loader="neoforge", loaderVersion="47.1.0", mcVersion="1.20.1"
+ (NSDictionary *)parseVersionId:(NSString *)versionId;

/// 根据 fileOptions 返回需要打包的目录列表（不含 "overrides/" 前缀）
+ (NSArray<NSString *> *)overrideDirectoriesForOptions:(ModpackExportFileOptions)options;

/// 根据 fileOptions 返回需要打包的文件列表（顶层文件名）
+ (NSArray<NSString *> *)overrideFilesForOptions:(ModpackExportFileOptions)options;

@end

NS_ASSUME_NONNULL_END
