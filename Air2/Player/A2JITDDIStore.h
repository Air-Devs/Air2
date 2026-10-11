//
//  A2JITDDIStore.h
//  Air2
//
//  Player —— 【本地 DDI 镜像】的发现 / 校验 / 手动导入 / 落盘记录。
//
//  职责边界（★严格★，与 A2JITPairingFileStore 同构）：
//    · 只做「本地发现 → 校验（是不是一份磁盘镜像）→ 原子写盘 → 记录来源/时间/校验和/声明版本」；
//    · ★不联网、不发个性化请求、不挂载、不碰设备服务★
//      （那些是设备侧机制：A2JITDDIDeviceQuery → Bridge → Natives）；
//    · 纯 Foundation（NSFileManager / NSData / NSPropertyListSerialization / CommonCrypto），
//      目录可注入 ⇒ 可脱离真机单测。
//
//  ★为什么必须落在一个「约定位置」★：判定要能脱离 UI 复现 ——
//  目录固定 = Library/Application Support/DDI；镜像名固定 = DeveloperDiskImage.dmg；
//  元数据 = ddi.meta.plist。探测面宽（Documents/DDI 等也认），写入面窄（只写约定名）。
//
//  许可：零第三方；★只参考公开文档与公开实现的行为描述，未搬运任何第三方代码★。
//

#import <Foundation/Foundation.h>
#import "A2JITDDI.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const A2JITDDIStoreErrorDomain;

/// 导入 / 校验失败的原因（供 UI 分流文案；不与判定 verdict 混用）。
typedef NS_ENUM(NSInteger, A2JITDDIStoreError) {
    A2JITDDIStoreErrorInvalidImage = 1,  ///< 内容不是一份可识别的磁盘镜像（UDIF 尾标校验不过）
    A2JITDDIStoreErrorWriteFailed  = 2,  ///< 目录创建 / 原子写盘 / 写元数据失败
};

// ---------------------------------------------------------------------------
// 元数据字段名（写进 <目录>/ddi.meta.plist；也暴露给 UI / 单测）
// ---------------------------------------------------------------------------
FOUNDATION_EXPORT NSString *const A2JITDDIStoreSourceNameKey;        ///< 来源文件名
FOUNDATION_EXPORT NSString *const A2JITDDIStoreImportedAtKey;        ///< 导入时间（NSDate）
FOUNDATION_EXPORT NSString *const A2JITDDIStoreChecksumKey;          ///< SHA-256（十六进制小写）
FOUNDATION_EXPORT NSString *const A2JITDDIStoreByteSizeKey;          ///< 字节数（NSNumber）
FOUNDATION_EXPORT NSString *const A2JITDDIStoreKindKey;              ///< 形态（Legacy / Personalized）
FOUNDATION_EXPORT NSString *const A2JITDDIStoreDeclaredBuildKey;     ///< 镜像声明的构建号
FOUNDATION_EXPORT NSString *const A2JITDDIStoreDeclaredOSVersionKey; ///< 镜像声明的系统版本串
FOUNDATION_EXPORT NSString *const A2JITDDIStoreTrustcacheNameKey;    ///< 配套 trustcache 文件名

/// 本地 DDI 镜像的暂存与记录。
@interface A2JITDDIStore : NSObject

/// 约定目录（App 容器内）：Library/Application Support/DDI。
+ (NSString *)defaultDirectory;
/// 约定镜像文件名（写入用）：DeveloperDiskImage.dmg。
+ (NSString *)canonicalImageName;
/// 约定 trustcache 文件名：DeveloperDiskImage.trustcache。
+ (NSString *)canonicalTrustcacheName;
/// 元数据文件名：ddi.meta.plist。
+ (NSString *)metadataFileName;

/// 会被【识别】为已就位镜像的候选文件名（探测面宽、写入面窄）。
+ (NSArray<NSString *> *)candidateImageNames;

/// 注入目录（单测用临时目录；真机用 defaultDirectory）。
- (instancetype)initWithDirectory:(NSString *)directory;
/// 默认实例（真机路径）。
+ (instancetype)defaultStore;

/// 存放目录。
@property (nonatomic, readonly, copy) NSString *directory;
/// 元数据文件路径。
@property (nonatomic, readonly, copy) NSString *metadataFilePath;

/// 目录当前是否【可读】（不可读 ⇒ 判定只能报「无法确认」，不许报「缺失」）。
- (BOOL)isStoreReadable;

/// ★真探测★：当前可用的本地镜像（约定目录 → Documents/DDI → Documents；找到并校验过才算）。
- (nullable A2JITDDIImage *)currentImage;

/// ★手动导入★（真机走这一步：★不把数 GB 镜像读进内存★，直接拷贝文件）。
/// 会先就地校验（UDIF 尾标 `koly`）再落盘 + 写元数据；同名镜像会被覆盖。
- (nullable NSString *)importImageFromURL:(NSURL *)url
                               sourceName:(nullable NSString *)sourceName
                                    error:(NSError *_Nullable *_Nullable)error;

/// 从文件名推断【声明】的系统版本串（如 "27.2"）；推断不出 ⇒ nil。
+ (nullable NSString *)osVersionFromFileName:(NSString *)fileName;
/// 从文件名推断【声明】的构建号（如 "24B5084k"）；推断不出 ⇒ nil。
+ (nullable NSString *)buildFromFileName:(NSString *)fileName;

@end

NS_ASSUME_NONNULL_END
