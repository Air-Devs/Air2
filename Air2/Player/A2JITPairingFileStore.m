//
//  A2JITPairingFileStore.m
//  Air2
//
//  [JIT-IMPL-2] 落盘与记录实现。★只碰文件系统★：无 UI、无网络、无 mach 调用。
//  校验复用旧件 A2PairingFile（本单不改它的解析/校验语义）。
//

#import "A2JITPairingFileStore.h"
#import "A2PairingFile.h"

#import <CommonCrypto/CommonDigest.h>

NSString *const A2JITPairingFileStoreErrorDomain = @"A2JITPairingFileStoreError";

NSString *const A2JITPairingFileStoreSourceNameKey       = @"sourceName";
NSString *const A2JITPairingFileStoreImportedAtKey       = @"importedAt";
NSString *const A2JITPairingFileStoreChecksumKey         = @"sha256";
NSString *const A2JITPairingFileStoreByteSizeKey         = @"byteSize";
NSString *const A2JITPairingFileStoreFormatKey           = @"format";
NSString *const A2JITPairingFileStoreDeviceIdentifierKey = @"deviceIdentifier";

@interface A2JITPairingFileStore ()
// 头文件里是 readonly，内部按 check_imports/lint_objc 的约定重声明为可写。
@property (nonatomic, readwrite, copy) NSString *directory;
@end

@implementation A2JITPairingFileStore

#pragma mark - 约定路径

+ (NSString *)defaultDirectory {
    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (lib.length == 0) {
        lib = NSTemporaryDirectory();
    }
    return [lib stringByAppendingPathComponent:@"Application Support/Pairing"];
}

+ (NSString *)canonicalFileName {
    return @"pairingFile.plist";
}

+ (NSString *)metadataFileName {
    return @"pairingFile.meta.plist";
}

+ (NSArray<NSString *> *)candidateFileNames {
    // 探测面宽（外部工具/文件 App 可能落另一种后缀）、写入面窄（恒定 canonicalFileName）。
    return @[ @"pairingFile.plist", @"pairingFile.mobiledevicepairing" ];
}

- (instancetype)initWithDirectory:(NSString *)directory {
    NSParameterAssert(directory.length > 0);
    self = [super init];
    if (self) {
        _directory = [directory copy];
    }
    return self;
}

+ (instancetype)defaultStore {
    return [[self alloc] initWithDirectory:[self defaultDirectory]];
}

- (NSString *)metadataFilePath {
    return [self.directory stringByAppendingPathComponent:[A2JITPairingFileStore metadataFileName]];
}

#pragma mark - 查询

- (nullable NSString *)importedFilePath {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in [A2JITPairingFileStore candidateFileNames]) {
        NSString *p = [self.directory stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:p]) {
            return p;
        }
    }
    return nil;
}

- (BOOL)hasUsablePairingFile {
    NSString *p = [self importedFilePath];
    if (p == nil) {
        return NO;
    }
    // ★真的解析一遍★：只看文件存在会把「拷进来一个空文件/垃圾文件」当成已配对。
    return [A2PairingFile pairingFileWithContentsOfFile:p error:NULL] != nil;
}

- (nullable NSDictionary<NSString *, id> *)importedMetadata {
    NSString *p = self.metadataFilePath;
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (d.length == 0) {
        return nil;
    }
    id obj = [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:NULL];
    return [obj isKindOfClass:NSDictionary.class] ? (NSDictionary *)obj : nil;
}

#pragma mark - 导入

- (nullable NSString *)importData:(NSData *)data
                       sourceName:(nullable NSString *)sourceName
                            error:(NSError *_Nullable *_Nullable)error {
    if (data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:A2JITPairingFileStoreErrorDomain
                                         code:A2JITPairingFileStoreErrorInvalidPairingFile
                                     userInfo:@{NSLocalizedDescriptionKey: @"所选文件为空"}];
        }
        NSLog(@"[A2JIT] pairing-store: 拒绝空文件（source=%@）", sourceName ?: @"(未命名)");
        return nil;
    }

    // ① 本地校验（不联网）。失败原因沿用 A2PairingFile 的可读文案。
    NSError *parseErr = nil;
    A2PairingFile *pairing = [A2PairingFile pairingFileWithData:data error:&parseErr];
    if (pairing == nil) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[NSLocalizedDescriptionKey] = parseErr.localizedDescription ?: @"不是可识别的配对文件";
        if (parseErr) {
            info[NSUnderlyingErrorKey] = parseErr;
        }
        if (error) {
            *error = [NSError errorWithDomain:A2JITPairingFileStoreErrorDomain
                                         code:A2JITPairingFileStoreErrorInvalidPairingFile
                                     userInfo:info];
        }
        NSLog(@"[A2JIT] pairing-store: 校验失败 source=%@ reason=%@",
              sourceName ?: @"(未命名)", parseErr.localizedDescription ?: @"(无详情)");
        return nil;
    }

    // ② 目录 + 原子写盘。
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *dirErr = nil;
    if (![fm createDirectoryAtPath:self.directory
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&dirErr]) {
        if (error) {
            *error = [NSError errorWithDomain:A2JITPairingFileStoreErrorDomain
                                         code:A2JITPairingFileStoreErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                                        [NSString stringWithFormat:@"无法创建目录：%@",
                                         dirErr.localizedDescription ?: self.directory]}];
        }
        NSLog(@"[A2JIT] pairing-store: 建目录失败 %@ (%@)", self.directory, dirErr.localizedDescription ?: @"?");
        return nil;
    }

    NSString *path = [self.directory stringByAppendingPathComponent:[A2JITPairingFileStore canonicalFileName]];
    NSError *wErr = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&wErr]) {
        if (error) {
            *error = [NSError errorWithDomain:A2JITPairingFileStoreErrorDomain
                                         code:A2JITPairingFileStoreErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                                        [NSString stringWithFormat:@"写入失败：%@",
                                         wErr.localizedDescription ?: path]}];
        }
        NSLog(@"[A2JIT] pairing-store: 写盘失败 %@ (%@)", path, wErr.localizedDescription ?: @"?");
        return nil;
    }

    // ③ 记录来源 / 时间 / 校验和（校验和是「这份文件是不是被人换过」的唯一凭据）。
    NSMutableDictionary<NSString *, id> *meta = [NSMutableDictionary dictionary];
    meta[A2JITPairingFileStoreSourceNameKey] = sourceName.length ? sourceName : @"(未命名)";
    meta[A2JITPairingFileStoreImportedAtKey] = [NSDate date];
    meta[A2JITPairingFileStoreByteSizeKey] = @(data.length);
    meta[A2JITPairingFileStoreChecksumKey] = [A2JITPairingFileStore sha256HexOfData:data] ?: @"";
    meta[A2JITPairingFileStoreFormatKey] =
        (pairing.format == A2PairingFileFormatRemotePairing) ? @"RemotePairing"
      : (pairing.format == A2PairingFileFormatLockdownPairRecord) ? @"LockdownPairRecord"
      : @"Unknown";
    meta[A2JITPairingFileStoreDeviceIdentifierKey] = pairing.deviceIdentifier ?: @"";
    (void)[meta writeToFile:self.metadataFilePath atomically:YES];

    NSLog(@"[A2JIT] pairing-store: 已导入 path=%@ bytes=%lu format=%@ device=%@ sha256=%@",
          path, (unsigned long)data.length, meta[A2JITPairingFileStoreFormatKey],
          meta[A2JITPairingFileStoreDeviceIdentifierKey], meta[A2JITPairingFileStoreChecksumKey]);
    return path;
}

- (BOOL)removeImportedPairingFileWithError:(NSError *_Nullable *_Nullable)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL removedAny = NO;
    for (NSString *name in [A2JITPairingFileStore candidateFileNames]) {
        NSString *p = [self.directory stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:p]) {
            NSError *e = nil;
            if ([fm removeItemAtPath:p error:&e]) {
                removedAny = YES;
            } else if (error) {
                *error = [NSError errorWithDomain:A2JITPairingFileStoreErrorDomain
                                             code:A2JITPairingFileStoreErrorWriteFailed
                                         userInfo:@{NSLocalizedDescriptionKey:
                                            e.localizedDescription ?: @"删除配对文件失败"}];
                return NO;
            }
        }
    }
    NSString *metaPath = self.metadataFilePath;
    if ([fm fileExistsAtPath:metaPath]) {
        [fm removeItemAtPath:metaPath error:NULL];
    }
    NSLog(@"[A2JIT] pairing-store: 移除已导入配对文件（removedAny=%d）", (int)removedAny);
    if (!removedAny && error) {
        *error = [NSError errorWithDomain:A2JITPairingFileStoreErrorDomain
                                     code:A2JITPairingFileStoreErrorNoStoredFile
                                 userInfo:@{NSLocalizedDescriptionKey: @"没有已导入的配对文件"}];
    }
    return YES;
}

#pragma mark - 校验和

+ (nullable NSString *)sha256HexOfData:(NSData *)data {
    if (data.length == 0) {
        return nil;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

@end
