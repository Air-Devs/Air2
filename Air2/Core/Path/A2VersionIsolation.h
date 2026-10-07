//
//  A2VersionIsolation.h
//  Air2
//
//  版本隔离 —— 逻辑与 ZL2 对齐。
//
//  ZL2 的规则（已核对源码 game/version/installed/VersionConfig.kt、Version.kt）：
//
//    isolationType: FOLLOW_GLOBAL | ENABLE | DISABLE   —— 每个版本可覆盖全局设置
//
//    游戏目录 =
//      ENABLE  → {gameHome}/versions/{版本名}/
//      DISABLE → customPath 非空 ? customPath : {gameHome}/
//
//  隔离开启时，mods / saves / resourcepacks / shaderpacks / screenshots
//  都落在版本文件夹内，各版本互不干扰；libraries / assets 始终共用。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 单个模块的隔离开关状态。对应 ZL2 的 SettingState。
typedef NS_ENUM(NSInteger, A2SettingState) {
    A2SettingStateFollowGlobal = 0,  ///< 跟随全局设置
    A2SettingStateEnable,            ///< 强制开启
    A2SettingStateDisable,           ///< 强制关闭
};

/// 可隔离的模块。对应 ZL2 的 VersionFolders。
typedef NS_ENUM(NSInteger, A2VersionFolder) {
    A2VersionFolderMods = 0,
    A2VersionFolderResourcePacks,
    A2VersionFolderSaves,
    A2VersionFolderShaderPacks,
    A2VersionFolderScreenshots,
    A2VersionFolderCount
};

/// 文件夹枚举 → 实际目录名
FOUNDATION_EXPORT NSString *A2VersionFolderName(A2VersionFolder folder);

/// 文件夹枚举 → 本地化显示名
FOUNDATION_EXPORT NSString *A2VersionFolderDisplayName(A2VersionFolder folder);

/**
 * 版本隔离配置。挂在每个版本上，字段与 ZL2 的 VersionConfig 一一对应。
 */
@interface A2VersionIsolation : NSObject <NSCopying>

/// 是否开启版本隔离
@property (nonatomic, assign) A2SettingState isolationType;

/// 是否跳过游戏完整性检查
@property (nonatomic, assign) A2SettingState skipGameIntegrityCheck;

/// 未开启隔离时的自定义游戏目录。为空表示使用默认 .minecraft。
@property (nonatomic, copy, nullable) NSString *customPath;

/// 是否置顶
@property (nonatomic, assign, getter=isPinned) BOOL pinned;

/// 内存分配（MB），-1 表示跟随全局
@property (nonatomic, assign) NSInteger ramAllocation;

/// 渲染器标识，空串表示跟随全局
@property (nonatomic, copy, nullable) NSString *renderer;

/// Java 运行时标识
@property (nonatomic, copy, nullable) NSString *javaRuntime;

/// JVM 参数
@property (nonatomic, copy, nullable) NSString *jvmArgs;

/// 游戏参数
@property (nonatomic, copy, nullable) NSString *gameArgs;

/// 从字典还原（磁盘格式）
+ (instancetype)fromDictionary:(NSDictionary *)dict;
/// 序列化为字典
- (NSDictionary *)toDictionary;

@end

/**
 * 路径解析器 —— 所有游戏路径的唯一出口。
 *
 * 硬性约束：项目内任何地方要拼游戏路径，都必须走这里。
 * 禁止在业务代码里手写 [NSString stringWithFormat:@"%@/versions/..."]。
 *
 * 对应 ZL2 的 game/path/GamePathHome.kt。
 */
@interface A2GamePath : NSObject

/// 游戏根目录（.minecraft）
@property (nonatomic, copy, readonly) NSString *gameHome;

+ (instancetype)pathWithGameHome:(NSString *)gameHome;

/// versions 目录
- (NSString *)versionsHome;
/// libraries 目录
- (NSString *)librariesHome;
/// assets 目录
- (NSString *)assetsHome;
/// 某个版本的文件夹  {gameHome}/versions/{name}
- (NSString *)versionPath:(NSString *)versionName;
/// 版本 JSON  {versions}/{name}/{name}.json
- (NSString *)versionJSONPath:(NSString *)versionName;
/// 版本客户端 jar  {versions}/{name}/{name}.jar
- (NSString *)versionJarPath:(NSString *)versionName;
/// 启动器私有数据目录  {versions}/{name}/.air_version
- (NSString *)launcherDataPath:(NSString *)versionName;
/// 版本图标  {versions}/{name}/.air_version/VersionIcon.png
- (NSString *)versionIconPath:(NSString *)versionName;

/**
 * 该版本实际使用的游戏目录 —— 隔离逻辑的核心。
 *
 * @param versionName 版本名
 * @param isolation   该版本的隔离配置
 * @return 游戏目录。隔离开启返回版本文件夹，否则返回 customPath 或 gameHome。
 */
- (NSString *)gameDirectoryForVersion:(NSString *)versionName
                            isolation:(A2VersionIsolation *)isolation;

/**
 * 某个可隔离模块的实际目录。
 *
 * @param folder      模块
 * @param versionName 版本名
 * @param isolation   隔离配置
 * @return mods / saves / ... 的实际绝对路径
 */
- (NSString *)directoryForFolder:(A2VersionFolder)folder
                     versionName:(NSString *)versionName
                       isolation:(A2VersionIsolation *)isolation;

@end

NS_ASSUME_NONNULL_END
