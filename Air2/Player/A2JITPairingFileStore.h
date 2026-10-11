//
//  A2JITPairingFileStore.h
//  Air2
//
//  Player —— 【导入配对文件】的落盘与记录（App 容器内约定位置）。
//
//  职责边界（★严格★）：
//    · 只做「校验 → 原子写盘 → 记录来源/时间/校验和」；
//    · ★不解析一整套 RPPairing 协议、不联网、不建隧道、不附加调试器★
//      （那些是后续阶段：Bridge → Natives/Support）；
//    · 纯 Foundation（NSFileManager / NSPropertyListSerialization / CommonCrypto），
//      目录可注入 ⇒ 可脱离真机单测。
//
//  为什么需要「约定位置」：A2JITLocalFactsSource.candidatePairingFilePaths 用一组
//  候选路径探测「沙盒内是否已有可用配对文件」。本类的默认目录与写入文件名必须落在
//  那组候选里，否则「导入了但事实探测说没有」——两处漂移就会让状态机永远停在
//  「等待配对」。故默认目录 = Library/Application Support/Pairing，
//  默认文件名 = pairingFile.plist（两者都在候选表里）。
//
//  与 A2PairingFile 的分工：A2PairingFile 只做「字节 → 已校验对象」（旧件，本单不改）；
//  本类做「对象/字节 → 落盘 + 元数据」。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const A2JITPairingFileStoreErrorDomain;

/// 导入失败的原因（供 UI 分流文案；不与判据 verdict 混用）。
typedef NS_ENUM(NSInteger, A2JITPairingFileStoreError) {
    A2JITPairingFileStoreErrorInvalidPairingFile = 1,  ///< 内容不是可识别的配对文件（A2PairingFile 校验不过）
    A2JITPairingFileStoreErrorWriteFailed        = 2,  ///< 目录创建 / 原子写盘 / 写元数据失败
    A2JITPairingFileStoreErrorNoStoredFile       = 3,  ///< 没有已导入的文件（重试 / 删除时）
};

// ---------------------------------------------------------------------------
// 元数据字段名（写进 <目录>/pairingFile.meta.plist；也暴露给 UI / 单测）
// ---------------------------------------------------------------------------
FOUNDATION_EXPORT NSString *const A2JITPairingFileStoreSourceNameKey;        ///< 来源文件名（如 StikDebug 导出的 xx.mobiledevicepairing）
FOUNDATION_EXPORT NSString *const A2JITPairingFileStoreImportedAtKey;        ///< 导入时间（NSDate）
FOUNDATION_EXPORT NSString *const A2JITPairingFileStoreChecksumKey;          ///< SHA-256（十六进制小写）
FOUNDATION_EXPORT NSString *const A2JITPairingFileStoreByteSizeKey;          ///< 字节数（NSNumber）
FOUNDATION_EXPORT NSString *const A2JITPairingFileStoreFormatKey;            ///< 识别出的格式（RemotePairing / LockdownPairRecord）
FOUNDATION_EXPORT NSString *const A2JITPairingFileStoreDeviceIdentifierKey;  ///< 设备标识（identifier / UDID）

/// 配对文件的本地暂存与记录。
@interface A2JITPairingFileStore : NSObject

/// 约定目录（App 容器内）：Library/Application Support/Pairing。
+ (NSString *)defaultDirectory;
/// 约定文件名（写入用）：pairingFile.plist。
+ (NSString *)canonicalFileName;
/// 元数据文件名：pairingFile.meta.plist。
+ (NSString *)metadataFileName;
/// 会被【识别】为已导入文件的候选名（探测面宽、写入面窄）。
+ (NSArray<NSString *> *)candidateFileNames;

/// 注入目录（单测用临时目录；真机用 defaultDirectory）。
- (instancetype)initWithDirectory:(NSString *)directory;
/// 默认实例（真机路径）。
+ (instancetype)defaultStore;

/// 存放目录。
@property (nonatomic, readonly, copy) NSString *directory;
/// 元数据文件路径。
@property (nonatomic, readonly, copy) NSString *metadataFilePath;

/// ★导入★：先按 A2PairingFile 校验（本地、不联网），通过后原子写盘 + 写元数据。
/// @param sourceName 来源文件名（可空；仅作记录）。
/// @return 写入的绝对路径；失败返回 nil 并回填 error（domain = A2JITPairingFileStoreErrorDomain）。
- (nullable NSString *)importData:(NSData *)data
                       sourceName:(nullable NSString *)sourceName
                            error:(NSError *_Nullable *_Nullable)error;

/// 当前是否有一份【可解析】的已导入配对文件（真探测，不是查缓存）。
- (BOOL)hasUsablePairingFile;
/// 已导入文件的绝对路径（无则 nil）。
- (nullable NSString *)importedFilePath;
/// 已导入文件的元数据（无则 nil）。
- (nullable NSDictionary<NSString *, id> *)importedMetadata;
/// 移除已导入文件与元数据（「重试」用）。
- (BOOL)removeImportedPairingFileWithError:(NSError *_Nullable *_Nullable)error;

/// SHA-256（十六进制小写）；空数据返回 nil。暴露给单测 / 诊断。
+ (nullable NSString *)sha256HexOfData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
