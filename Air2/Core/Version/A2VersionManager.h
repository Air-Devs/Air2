//
//  A2VersionManager.h
//  Air2
//
//  已安装版本的管理 —— 扫描、选择、删除、重命名。
//
//  与 ZL2 的 VersionsManager 对应。
//  职责：
//    · 扫描 {gameHome}/versions/ 下的所有版本
//    · 读取每个版本的 {name}.json 与 .air_version/config.json
//    · 维护「当前选中版本」
//    · 提供删除/重命名/复制等操作
//

#import <Foundation/Foundation.h>
#import "A2VersionIsolation.h"

NS_ASSUME_NONNULL_BEGIN

/// 版本类型
typedef NS_ENUM(NSInteger, A2VersionType) {
    A2VersionTypeUnknown = 0,
    A2VersionTypeRelease,      ///< 正式版
    A2VersionTypeSnapshot,     ///< 快照
    A2VersionTypeOldBeta,      ///< 旧版 Beta
    A2VersionTypeOldAlpha,     ///< 旧版 Alpha
};

/// 一个已安装的版本
@interface A2Version : NSObject

@property (nonatomic, copy, readonly) NSString *name;
/// 版本所在的游戏根目录
@property (nonatomic, copy, readonly) NSString *gameHome;
/// 版本隔离配置
@property (nonatomic, strong, readonly) A2VersionIsolation *isolation;
/// 版本类型
@property (nonatomic, assign, readonly) A2VersionType type;
/// 客户端 jar 是否存在
@property (nonatomic, assign, readonly, getter=isValid) BOOL valid;
/// 上次游玩时间（用于排序）
@property (nonatomic, strong, nullable) NSDate *lastPlayed;
/// 加载器信息（从 json 里解析出来的展示文本）
@property (nonatomic, copy, nullable) NSString *loaderInfo;

- (instancetype)initWithName:(NSString *)name gameHome:(NSString *)gameHome;

/// 版本文件夹  {gameHome}/versions/{name}
- (NSString *)versionPath;
/// 版本 json 路径
- (NSString *)jsonPath;
/// 启动器私有数据目录
- (NSString *)launcherDataPath;
/// 该版本实际使用的游戏目录（隔离逻辑在这里生效）
- (NSString *)gameDirectory;

- (void)loadConfig;
- (void)saveConfig;

@end

/// 版本列表变更通知
extern NSNotificationName const A2VersionsDidChangeNotification;

@interface A2VersionManager : NSObject

+ (instancetype)shared;

/// 当前游戏根目录
@property (nonatomic, copy) NSString *gameHome;
/// 所有已安装版本
@property (nonatomic, copy, readonly) NSArray<A2Version *> *versions;
/// 当前选中的版本
@property (nonatomic, strong, nullable) A2Version *currentVersion;

/// 重新扫描版本目录
- (void)reload;

/// 设置当前版本
- (BOOL)setCurrentVersion:(A2Version *)version;

/// 删除版本
- (BOOL)deleteVersion:(A2Version *)version error:(NSError **)error;
/// 重命名版本
- (BOOL)renameVersion:(A2Version *)version to:(NSString *)newName error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
