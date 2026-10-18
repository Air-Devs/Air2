#import <Foundation/Foundation.h>

// 下载源偏好键（按资源类型独立）
extern NSString *const PREF_DOWNLOAD_SOURCE_MOD;
extern NSString *const PREF_DOWNLOAD_SOURCE_SHADER;
extern NSString *const PREF_DOWNLOAD_SOURCE_RESOURCEPACK;
extern NSString *const PREF_DOWNLOAD_SOURCE_DATAPACK;
extern NSString *const PREF_DOWNLOAD_SOURCE_MODPACK;
extern NSString *const PREF_DOWNLOAD_SOURCE_WORLD;
extern NSString *const PREF_DOWNLOAD_SOURCE_SERVER;
// CurseForge API Key 偏好键
extern NSString *const PREF_CURSEFORGE_API_KEY;
// Mod 更新时是否保留旧文件
extern NSString *const PREF_MOD_UPDATE_KEEP_OLD;
// 模组镜像源（official / mcim）
extern NSString *const PREF_MOD_MIRROR;

@interface PLPreferences : NSObject

@property(nonatomic) NSString *globalPath, *instancePath;
@property(nonatomic) NSMutableDictionary<NSString *, NSMutableDictionary *> *globalPref, *instancePref;

- (id)initWithGlobalPath:(NSString *)path;
- (id)initWithAutomaticMigrator;

- (void)toggleIsolationForced:(BOOL)forced;
- (id)getObject:(NSString *)key;
- (BOOL)setObject:(NSString *)key value:(id)value;
- (void)reset;

// 下载源管理（按类型独立）
+ (NSString *)currentDownloadSourceForType:(NSString *)type;
+ (void)setDownloadSource:(NSString *)source forType:(NSString *)type;
// CurseForge API Key
+ (NSString *)curseForgeAPIKey;
+ (void)setCurseForgeAPIKey:(NSString *)key;
// Mod 更新旧文件保留
+ (BOOL)modUpdateKeepOld;
+ (void)setModUpdateKeepOld:(BOOL)keepOld;

@end
