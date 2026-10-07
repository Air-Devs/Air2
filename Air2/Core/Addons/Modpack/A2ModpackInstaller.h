//
//  A2ModpackInstaller.h
//  Air2
//
//  整合包安装总编排 —— 对齐 ZL2 的 ModPackInstaller + ModpackImporter。
//
//  把「整合包」装成本地可启动的版本，要做的是一整条流水线：
//    清缓存 → 下载/导入整合包 zip → 解压 → 识别格式 →
//    铺 overrides → 下载模组文件 → 装 MC 本体与加载器 → 收尾合并
//
//  四种来源格式（Modrinth / CurseForge / MultiMC / MCBBS）在
//  A2ModpackParser 里被统一成 A2ModpackInfo，本类只面对统一模型。
//
//  与 A2GameInstaller 的分工：那个负责「MC 本体 + 加载器」，
//  本类负责整合包特有的一切，并把本体安装委托给它。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 整合包安装阶段，与 UI 的分步清单一一对应
typedef NS_ENUM(NSInteger, A2ModpackInstallStage) {
    A2ModpackInstallStageClearTemp = 0,   ///< 清理临时目录
    A2ModpackInstallStageDownloadPack,    ///< 下载或导入整合包
    A2ModpackInstallStageExtractPack,     ///< 解压整合包
    A2ModpackInstallStageParsePack,       ///< 识别并解析格式
    A2ModpackInstallStageExtractOverrides,///< 铺开 overrides
    A2ModpackInstallStageDownloadMods,    ///< 下载模组文件
    A2ModpackInstallStageInstallGame,     ///< 安装游戏本体与加载器
    A2ModpackInstallStageFinalize,        ///< 收尾
    A2ModpackInstallStageCount,
};

/// 安装请求
@interface A2ModpackInstallRequest : NSObject

/// 在线整合包下载地址；导入本地包时可为空
@property (nonatomic, copy, nullable) NSString *packURL;
/// 整合包 SHA1；无则跳过校验
@property (nonatomic, copy, nullable) NSString *packSHA1;
/// 整合包大小，0 表示未知
@property (nonatomic, assign) long long packSize;
/// 本地整合包 zip 路径；非空时优先于 packURL
@property (nonatomic, copy, nullable) NSString *localPackPath;
/// 版本图标地址，可为空
@property (nonatomic, copy, nullable) NSString *iconURL;
/// 目标版本名；为空时用整合包名
@property (nonatomic, copy, nullable) NSString *versionName;
/// 游戏根目录
@property (nonatomic, copy) NSString *gameHome;

@end

@interface A2ModpackInstaller : NSObject

/// 开始安装。
/// @param progress 阶段进度（stage，该阶段进度 0~1，说明文字）
/// @param completion 完成回调
- (void)install:(A2ModpackInstallRequest *)request
       progress:(void (^)(A2ModpackInstallStage stage, double progress, NSString *message))progress
     completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

- (void)cancel;

@end

NS_ASSUME_NONNULL_END
