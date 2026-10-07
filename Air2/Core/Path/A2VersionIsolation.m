//
//  A2VersionIsolation.m
//  Air2
//

#import "A2VersionIsolation.h"

NSString *A2VersionFolderName(A2VersionFolder folder) {
    switch (folder) {
        case A2VersionFolderMods:          return @"mods";
        case A2VersionFolderResourcePacks: return @"resourcepacks";
        case A2VersionFolderSaves:         return @"saves";
        case A2VersionFolderShaderPacks:   return @"shaderpacks";
        case A2VersionFolderScreenshots:   return @"screenshots";
        default:                           return @"";
    }
}

NSString *A2VersionFolderDisplayName(A2VersionFolder folder) {
    switch (folder) {
        case A2VersionFolderMods:          return @"模组";
        case A2VersionFolderResourcePacks: return @"资源包";
        case A2VersionFolderSaves:         return @"存档";
        case A2VersionFolderShaderPacks:   return @"光影包";
        case A2VersionFolderScreenshots:   return @"截图";
        default:                           return @"";
    }
}

/// 解析 SettingState 的字符串表示（磁盘格式与 ZL2 保持一致，便于后续互操作）
static A2SettingState A2SettingStateFromString(NSString *s) {
    if ([s isEqualToString:@"ENABLE"])  return A2SettingStateEnable;
    if ([s isEqualToString:@"DISABLE"]) return A2SettingStateDisable;
    return A2SettingStateFollowGlobal;
}

static NSString *A2SettingStateToString(A2SettingState state) {
    switch (state) {
        case A2SettingStateEnable:  return @"ENABLE";
        case A2SettingStateDisable: return @"DISABLE";
        default:                    return @"FOLLOW_GLOBAL";
    }
}

#pragma mark - A2VersionIsolation

@implementation A2VersionIsolation

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _isolationType = A2SettingStateFollowGlobal;
    _skipGameIntegrityCheck = A2SettingStateFollowGlobal;
    _pinned = NO;
    _ramAllocation = -1;
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    A2VersionIsolation *c = [[A2VersionIsolation allocWithZone:zone] init];
    c.isolationType = self.isolationType;
    c.skipGameIntegrityCheck = self.skipGameIntegrityCheck;
    c.customPath = self.customPath;
    c.pinned = self.pinned;
    c.ramAllocation = self.ramAllocation;
    c.renderer = self.renderer;
    c.javaRuntime = self.javaRuntime;
    c.jvmArgs = self.jvmArgs;
    c.gameArgs = self.gameArgs;
    return c;
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    A2VersionIsolation *iso = [A2VersionIsolation new];
    if (![dict isKindOfClass:NSDictionary.class]) return iso;

    iso.isolationType = A2SettingStateFromString(dict[@"isolationType"]);
    iso.skipGameIntegrityCheck = A2SettingStateFromString(dict[@"skipGameIntegrityCheck"]);
    iso.customPath = [dict[@"customPath"] isKindOfClass:NSString.class] ? dict[@"customPath"] : nil;
    iso.pinned = [dict[@"pinned"] boolValue];
    iso.ramAllocation = [dict[@"ramAllocation"] integerValue] ?: -1;
    iso.renderer = [dict[@"renderer"] isKindOfClass:NSString.class] ? dict[@"renderer"] : nil;
    iso.javaRuntime = [dict[@"javaRuntime"] isKindOfClass:NSString.class] ? dict[@"javaRuntime"] : nil;
    iso.jvmArgs = [dict[@"jvmArgs"] isKindOfClass:NSString.class] ? dict[@"jvmArgs"] : nil;
    iso.gameArgs = [dict[@"gameArgs"] isKindOfClass:NSString.class] ? dict[@"gameArgs"] : nil;
    return iso;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"isolationType"] = A2SettingStateToString(self.isolationType);
    d[@"skipGameIntegrityCheck"] = A2SettingStateToString(self.skipGameIntegrityCheck);
    d[@"pinned"] = @(self.pinned);
    d[@"ramAllocation"] = @(self.ramAllocation);
    if (self.customPath)   d[@"customPath"]   = self.customPath;
    if (self.renderer)     d[@"renderer"]     = self.renderer;
    if (self.javaRuntime)  d[@"javaRuntime"]  = self.javaRuntime;
    if (self.jvmArgs)      d[@"jvmArgs"]      = self.jvmArgs;
    if (self.gameArgs)     d[@"gameArgs"]     = self.gameArgs;
    return d;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<A2VersionIsolation isolation=%@ pinned=%@ customPath=%@>",
            A2SettingStateToString(self.isolationType),
            self.pinned ? @"Y" : @"N",
            self.customPath ?: @"(default)"];
}

@end

#pragma mark - A2GamePath

@interface A2GamePath ()
@property (nonatomic, copy) NSString *gameHome;
@end

@implementation A2GamePath

+ (instancetype)pathWithGameHome:(NSString *)gameHome {
    A2GamePath *p = [A2GamePath new];
    // 去掉尾部斜杠，避免拼出 "//versions"
    NSString *trimmed = gameHome;
    while (trimmed.length > 1 && [trimmed hasSuffix:@"/"]) {
        trimmed = [trimmed substringToIndex:trimmed.length - 1];
    }
    p.gameHome = trimmed;
    return p;
}

- (NSString *)versionsHome   { return [self.gameHome stringByAppendingPathComponent:@"versions"]; }
- (NSString *)librariesHome  { return [self.gameHome stringByAppendingPathComponent:@"libraries"]; }
- (NSString *)assetsHome     { return [self.gameHome stringByAppendingPathComponent:@"assets"]; }

- (NSString *)versionPath:(NSString *)versionName {
    return [[self versionsHome] stringByAppendingPathComponent:versionName];
}

- (NSString *)versionJSONPath:(NSString *)versionName {
    return [[self versionPath:versionName] stringByAppendingPathComponent:
            [versionName stringByAppendingPathExtension:@"json"]];
}

- (NSString *)versionJarPath:(NSString *)versionName {
    return [[self versionPath:versionName] stringByAppendingPathComponent:
            [versionName stringByAppendingPathExtension:@"jar"]];
}

/// 启动器私有数据目录名。前面加点避免和游戏自身的目录混淆。
static NSString *const kLauncherDataDirName = @".air_version";

- (NSString *)launcherDataPath:(NSString *)versionName {
    return [[self versionPath:versionName] stringByAppendingPathComponent:kLauncherDataDirName];
}

- (NSString *)versionIconPath:(NSString *)versionName {
    return [[self launcherDataPath:versionName] stringByAppendingPathComponent:@"VersionIcon.png"];
}

- (NSString *)gameDirectoryForVersion:(NSString *)versionName
                            isolation:(A2VersionIsolation *)isolation {
    // 隔离开启 → 版本文件夹独立成家
    if (isolation.isolationType == A2SettingStateEnable) {
        return [self versionPath:versionName];
    }

    // 未开启隔离 → 可用自定义路径，否则回落到默认游戏根目录
    if (isolation.customPath.length > 0) {
        return isolation.customPath;
    }
    return self.gameHome;
}

- (NSString *)directoryForFolder:(A2VersionFolder)folder
                     versionName:(NSString *)versionName
                       isolation:(A2VersionIsolation *)isolation {
    NSString *gameDir = [self gameDirectoryForVersion:versionName isolation:isolation];
    return [gameDir stringByAppendingPathComponent:A2VersionFolderName(folder)];
}

@end
