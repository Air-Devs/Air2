//
//  A2PairingFile.h
//  Air2
//
//  Player —— 【配对文件】的解析与校验（`.mobiledevicepairing` / `.plist`）。
//
//  [JIT-IMPL] 职责边界（★严格★）：
//    · 只做【本地解析 + 基本校验 + 设备标识提取】；
//    · ★不联网、不建隧道、不附加调试器、不写盘★——那是第二阶段 Provider 的机制；
//    · 纯 Foundation（NSPropertyListSerialization），可脱离真机单测。
//
//  这是 iOS 26「内置手动」与 iOS 17.4–25「导入 + 外部」两条路径的公共前置：
//  没有一份【合法】的配对文件，后续 RPPairing 隧道/内置 helper 就无从谈起。
//  在导入 UI 里先用本类校验再入库（失败给可读原因），避免把垃圾文件带到第二阶段才炸。
//
//  两种被识别的格式（探测面宽，返回面窄）：
//    ① RemotePairing（RpPairingFile，SideStore / StikDebug 常用）：
//       `identifier`(string) + `public_key`(data) + `private_key`(data)。
//    ② Lockdown PairRecord（libimobiledevice 系）：
//       `DeviceCertificate` / `HostCertificate` / `HostPrivateKey` /
//       `RootCertificate` / `HostID` / `SystemBUID`。
//    文件本体可为原始 plist（XML / binary），也兼容【base64 包裹的 plist 文本】。
//
//  来源（格式核实）：docs/JIT-PROVISIONING.md §1、D:\CTF\_AIR2_JIT_BUILTIN.md §1.3
//  （PocketJ `StikDebugEngine.m:46-61` 以 NSPropertyListSerialization 校验为 NSDictionary）；
//  经典 PairRecord 字段同 libimobiledevice / ios-rs 源码。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 配对文件错误（带可读原因，供导入 UI 分流文案）。
typedef NS_ENUM(NSInteger, A2PairingFileError) {
    A2PairingFileErrorNone             = 0,  ///< 无错误
    A2PairingFileErrorEmpty            = 1,  ///< 文件为空 / 只有空白
    A2PairingFileErrorNotPropertyList  = 2,  ///< 不是 plist（或顶层不是字典）
    A2PairingFileErrorMalformedBase64  = 3,  ///< base64 包裹但解码失败
    A2PairingFileErrorMissingFields    = 4,  ///< 必填字段缺失
    A2PairingFileErrorInvalidField     = 5,  ///< 字段存在但类型/取值非法（基本合法性）
};

/// 配对文件的形态。
typedef NS_ENUM(NSInteger, A2PairingFileFormat) {
    A2PairingFileFormatUnknown            = 0,  ///< 未识别
    A2PairingFileFormatRemotePairing      = 1,  ///< RpPairingFile（identifier + Ed25519 密钥对）
    A2PairingFileFormatLockdownPairRecord = 2,  ///< 经典 lockdown 配对记录
};

FOUNDATION_EXPORT NSString *const A2PairingFileErrorDomain;

/// 一份已解析并校验通过的配对文件。
@interface A2PairingFile : NSObject

/// 识别出的格式。
@property (nonatomic, readonly) A2PairingFileFormat format;
/// 设备标识：RemotePairing 取 `identifier`；Lockdown 取 `UDID`（无则退 `HostID`）。
@property (nonatomic, readonly, copy, nullable) NSString *deviceIdentifier;
/// 解析出的原始字段（只读，供诊断/后续机制使用）。
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *fields;
/// 是否通过校验（与构造成功等价）。
@property (nonatomic, readonly) BOOL isValid;

/// 从内存数据解析并校验。失败返回 nil 并回填 error（domain=A2PairingFileErrorDomain）。
+ (nullable instancetype)pairingFileWithData:(NSData *)data
                                       error:(NSError *_Nullable *_Nullable)error;

/// 从文件读取后解析并校验（★只读文件，不写盘★）。
+ (nullable instancetype)pairingFileWithContentsOfFile:(NSString *)path
                                                 error:(NSError *_Nullable *_Nullable)error;

/// 仅解析为 plist 字典（含 base64 包裹兼容）；不做字段校验。暴露给单测/诊断。
+ (nullable NSDictionary<NSString *, id> *)propertyListFromData:(NSData *)data
                                                          error:(NSError *_Nullable *_Nullable)error;

/// 指定格式的必填字段名（暴露给单测/诊断）。
+ (NSArray<NSString *> *)requiredFieldsForFormat:(A2PairingFileFormat)format;

@end

NS_ASSUME_NONNULL_END
