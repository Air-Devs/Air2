//
//  A2JITDDIStore.m
//  Air2
//
//  [JIT-DDI-1] 本地 DDI 镜像的发现 / 校验 / 导入 实现。
//  ★只碰文件系统★：无 UI、无网络、无设备服务、无 mach 调用。
//

#import "A2JITDDIStore.h"

#import <CommonCrypto/CommonDigest.h>

NSString *const A2JITDDIStoreErrorDomain = @"A2JITDDIStoreError";

NSString *const A2JITDDIStoreSourceNameKey        = @"sourceName";
NSString *const A2JITDDIStoreImportedAtKey        = @"importedAt";
NSString *const A2JITDDIStoreChecksumKey          = @"sha256";
NSString *const A2JITDDIStoreByteSizeKey          = @"byteSize";
NSString *const A2JITDDIStoreKindKey              = @"kind";
NSString *const A2JITDDIStoreDeclaredBuildKey     = @"declaredBuild";
NSString *const A2JITDDIStoreDeclaredOSVersionKey = @"declaredOSVersion";
NSString *const A2JITDDIStoreTrustcacheNameKey    = @"trustcacheName";

/// UDIF 尾标块（磁盘映像最后 512 字节）的魔数。
static const char kA2UDIFTrailerMagic[4] = { 'k', 'o', 'l', 'y' };

static NSError *A2StoreError(A2JITDDIStoreError code, NSString *desc) {
    return [NSError errorWithDomain:A2JITDDIStoreErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: desc ?: @"未知错误" }];
}

/// 尾部 512 字节是否为 UDIF 尾标（'koly'）。数据本身已通过大小检查。
static BOOL A2TailLooksLikeUDIF(NSData *tail, NSString *_Nullable *_Nullable whyOut) {
    if (tail.length < 512) {
        if (whyOut) {
            *whyOut = @"文件小于 512 字节 ⇒ 不是磁盘镜像";
        }
        return NO;
    }
    const uint8_t *p = tail.bytes;
    BOOL ok = (p[0] == (uint8_t)kA2UDIFTrailerMagic[0] &&
               p[1] == (uint8_t)kA2UDIFTrailerMagic[1] &&
               p[2] == (uint8_t)kA2UDIFTrailerMagic[2] &&
               p[3] == (uint8_t)kA2UDIFTrailerMagic[3]);
    if (!ok) {
        if (whyOut) {
            *whyOut = @"尾部 512 字节不是 'koly'（UDIF 尾标魔数）⇒ 不是磁盘镜像";
        }
        return NO;
    }
    if (whyOut) {
        *whyOut = @"UDIF 尾标 OK（'koly'）";
    }
    return YES;
}

@interface A2JITDDIStore ()
// 头文件里是 readonly，内部按仓内约定重声明为可写。
@property (nonatomic, readwrite, copy) NSString *directory;

/// 探测面：可能放着镜像的绝对路径（约定目录 → Documents/DDI → Documents）。
- (NSArray<NSString *> *)candidateImagePaths;
/// 给定路径 + 元数据，装配一份 A2JITDDIImage。
- (A2JITDDIImage *)imageAtPath:(NSString *)path;
/// 就地校验一个文件路径是不是磁盘镜像（只读尾部 512 字节）。
- (BOOL)fileLooksLikeDiskImageAtPath:(NSString *)path why:(NSString *_Nullable *_Nullable)whyOut;
/// 已落盘的元数据（无则 nil）。
- (nullable NSDictionary<NSString *, id> *)storedMetadata;
/// 文件名里第一个「版本串[-构建号]」匹配（group 1 = 版本，group 2 = 构建号）。
+ (nullable NSString *)firstMatchInFileName:(NSString *)fileName group:(NSInteger)group;
/// 摘要 → 十六进制小写。
+ (NSString *)hexFromDigest:(const unsigned char *)digest;
@end

@implementation A2JITDDIStore

#pragma mark - 约定路径

+ (NSString *)defaultDirectory {
    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (lib.length == 0) {
        lib = NSTemporaryDirectory();
    }
    return [lib stringByAppendingPathComponent:@"Application Support/DDI"];
}

+ (NSString *)canonicalImageName {
    return @"DeveloperDiskImage.dmg";
}

+ (NSString *)canonicalTrustcacheName {
    return @"DeveloperDiskImage.trustcache";
}

+ (NSString *)metadataFileName {
    return @"ddi.meta.plist";
}

+ (NSArray<NSString *> *)candidateImageNames {
    // 探测面宽（用户按习惯命名也认）、写入面窄（恒定 canonicalImageName）。
    return @[ @"DeveloperDiskImage.dmg", @"ddi.dmg" ];
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
    return [self.directory stringByAppendingPathComponent:[A2JITDDIStore metadataFileName]];
}

- (NSArray<NSString *> *)candidateImagePaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *name in [A2JITDDIStore candidateImageNames]) {
        [paths addObject:[self.directory stringByAppendingPathComponent:name]];
    }
    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    for (NSString *doc in docs) {
        for (NSString *name in [A2JITDDIStore candidateImageNames]) {
            [paths addObject:[[doc stringByAppendingPathComponent:@"DDI"] stringByAppendingPathComponent:name]];
            [paths addObject:[doc stringByAppendingPathComponent:name]];
        }
    }
    return paths;
}

#pragma mark - 可读性

- (BOOL)isStoreReadable {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:self.directory isDirectory:&isDir]) {
        // 目录还没建 ⇒ 我们【确定】这里没有镜像（是「缺失」，不是「读不到」）。
        return YES;
    }
    if (!isDir) {
        return NO;
    }
    return [fm isReadableFileAtPath:self.directory];
}

#pragma mark - 发现

- (nullable NSDictionary<NSString *, id> *)storedMetadata {
    NSData *d = [NSData dataWithContentsOfFile:self.metadataFilePath];
    if (d.length == 0) {
        return nil;
    }
    id obj = [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:NULL];
    return [obj isKindOfClass:NSDictionary.class] ? (NSDictionary *)obj : nil;
}

- (A2JITDDIImage *)imageAtPath:(NSString *)path {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) {
        return nil;
    }

    NSDictionary<NSString *, id> *meta = [self storedMetadata];
    unsigned long long size = 0;
    NSDictionary<NSString *, id> *attrs = [fm attributesOfItemAtPath:path error:NULL];
    NSNumber *sz = attrs[NSFileSize];
    if ([sz isKindOfClass:NSNumber.class]) {
        size = sz.unsignedLongLongValue;
    }

    // 来源：约定目录 ⇒ Container；Documents 下 ⇒ 用户导入/外部工具放的。
    A2JITDDISource source = [path hasPrefix:self.directory] ? A2JITDDISourceContainer
                                                             : A2JITDDISourceUserImport;

    // 同目录的 trustcache（个性化镜像）。
    NSString *trustcachePath = nil;
    for (NSString *tcName in @[ [A2JITDDIStore canonicalTrustcacheName], @"trustcache" ]) {
        NSString *p = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:tcName];
        if ([fm fileExistsAtPath:p]) {
            trustcachePath = p;
            break;
        }
    }

    A2JITDDIKind kind = A2JITDDIKindUnknown;
    NSString *kindName = meta[A2JITDDIStoreKindKey];
    if ([kindName isKindOfClass:NSString.class]) {
        if ([kindName isEqualToString:@"Personalized"]) {
            kind = A2JITDDIKindPersonalized;
        } else if ([kindName isEqualToString:@"Legacy"]) {
            kind = A2JITDDIKindLegacy;
        }
    } else if (trustcachePath.length > 0) {
        kind = A2JITDDIKindPersonalized;
    }

    // ★声明的版本/构建号只来自两处：元数据、文件名里的显式声明★（不做任何推断性猜测）。
    NSString *declaredBuild = meta[A2JITDDIStoreDeclaredBuildKey];
    NSString *declaredVersion = meta[A2JITDDIStoreDeclaredOSVersionKey];
    if (![declaredBuild isKindOfClass:NSString.class] || !((NSString *)declaredBuild).length) {
        declaredBuild = [A2JITDDIStore buildFromFileName:path.lastPathComponent];
    }
    if (![declaredVersion isKindOfClass:NSString.class] || !((NSString *)declaredVersion).length) {
        declaredVersion = [A2JITDDIStore osVersionFromFileName:path.lastPathComponent];
    }

    NSDate *importedAt = meta[A2JITDDIStoreImportedAtKey];
    NSString *sha = meta[A2JITDDIStoreChecksumKey];

    return [A2JITDDIImage imageWithFilePath:path
                             trustcachePath:trustcachePath
                                       kind:kind
                                     source:source
                                   byteSize:size
                                     sha256:[sha isKindOfClass:NSString.class] ? sha : nil
                                 importedAt:[importedAt isKindOfClass:NSDate.class] ? importedAt : nil
                              declaredBuild:[declaredBuild isKindOfClass:NSString.class] ? declaredBuild : nil
                          declaredOSVersion:[declaredVersion isKindOfClass:NSString.class] ? declaredVersion : nil];
}

- (nullable A2JITDDIImage *)currentImage {
    // ★真探测★：找到文件 + 就地校验过尾部才是「一份可用镜像」；
    // 只看文件存在会把「拷进来一个空文件/垃圾」当成已就位。
    for (NSString *path in [self candidateImagePaths]) {
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            continue;
        }
        if (![self fileLooksLikeDiskImageAtPath:path why:NULL]) {
            NSLog(@"[A2JIT] ddi-store: 候选文件不是有效磁盘镜像，跳过 %@", path);
            continue;
        }
        return [self imageAtPath:path];
    }
    return nil;
}

#pragma mark - 校验

+ (BOOL)looksLikeUDIFDiskImageData:(NSData *)data why:(NSString *_Nullable *_Nullable)whyOut {
    if (data.length < 512) {
        if (whyOut) {
            *whyOut = @"文件小于 512 字节 ⇒ 不是磁盘镜像";
        }
        return NO;
    }
    if ((data.length % 512) != 0) {
        if (whyOut) {
            *whyOut = @"大小不是 512 的整数倍（UDIF 尾标块要求）";
        }
        return NO;
    }
    NSData *tail = [data subdataWithRange:NSMakeRange(data.length - 512, 512)];
    return A2TailLooksLikeUDIF(tail, whyOut);
}

- (BOOL)fileLooksLikeDiskImageAtPath:(NSString *)path why:(NSString *_Nullable *_Nullable)whyOut {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSNumber *sz = [fm attributesOfItemAtPath:path error:NULL][NSFileSize];
    unsigned long long size = [sz isKindOfClass:NSNumber.class] ? sz.unsignedLongLongValue : 0;
    if (size < 512) {
        if (whyOut) {
            *whyOut = @"文件小于 512 字节 ⇒ 不是磁盘镜像";
        }
        return NO;
    }
    if ((size % 512) != 0) {
        if (whyOut) {
            *whyOut = @"大小不是 512 的整数倍（UDIF 尾标块要求）";
        }
        return NO;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (fh == nil) {
        if (whyOut) {
            *whyOut = @"文件打不开（权限或不存在）";
        }
        return NO;
    }
    BOOL ok = NO;
    @try {
        [fh seekToFileOffset:(unsigned long long)(size - 512)];
        NSData *tail = [fh readDataOfLength:512];
        ok = A2TailLooksLikeUDIF(tail, whyOut);
    } @catch (NSException *e) {
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:@"读尾部失败：%@", e.reason ?: e.name];
        }
        ok = NO;
    }
    [fh closeFile];
    return ok;
}

#pragma mark - 文件名里的显式声明

+ (nullable NSString *)osVersionFromFileName:(NSString *)fileName {
    NSString *m = [self firstMatchInFileName:fileName group:1];
    return m;
}

+ (nullable NSString *)buildFromFileName:(NSString *)fileName {
    return [self firstMatchInFileName:fileName group:2];
}

/// 匹配 `27.2` 或 `27.2-24B5084k`；group1 = 版本串，group2 = 构建号（可无）。
+ (nullable NSString *)firstMatchInFileName:(NSString *)fileName group:(NSInteger)group {
    if (fileName.length == 0) {
        return nil;
    }
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:@"([0-9]{2}\\.[0-9]{1,2})(?:-([A-Za-z0-9]{4,}))?"
                                                  options:0
                                                    error:NULL];
    NSTextCheckingResult *r = [re firstMatchInString:fileName options:0
                                               range:NSMakeRange(0, fileName.length)];
    if (r == nil || group >= (NSInteger)r.numberOfRanges) {
        return nil;
    }
    NSRange range = [r rangeAtIndex:(NSUInteger)group];
    if (range.location == NSNotFound || range.length == 0) {
        return nil;
    }
    return [fileName substringWithRange:range];
}

#pragma mark - 导入

- (nullable NSString *)importImageData:(NSData *)data
                              fileName:(nullable NSString *)fileName
                            sourceName:(nullable NSString *)sourceName
                                 error:(NSError *_Nullable *_Nullable)error {
    if (data.length == 0) {
        if (error) {
            *error = A2StoreError(A2JITDDIStoreErrorInvalidImage, @"所选镜像为空");
        }
        NSLog(@"[A2JIT] ddi-store: 拒绝空文件（source=%@）", sourceName ?: @"(未命名)");
        return nil;
    }

    NSString *why = nil;
    if (![A2JITDDIStore looksLikeUDIFDiskImageData:data why:&why]) {
        if (error) {
            *error = A2StoreError(A2JITDDIStoreErrorInvalidImage,
                                  [NSString stringWithFormat:@"不是可识别的磁盘镜像：%@", why ?: @"未知原因"]);
        }
        NSLog(@"[A2JIT] ddi-store: 校验失败 source=%@ reason=%@", sourceName ?: @"(未命名)", why ?: @"?");
        return nil;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *dirErr = nil;
    if (![fm createDirectoryAtPath:self.directory
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&dirErr]) {
        if (error) {
            *error = A2StoreError(A2JITDDIStoreErrorWriteFailed,
                                  [NSString stringWithFormat:@"无法创建目录：%@",
                                   dirErr.localizedDescription ?: self.directory]);
        }
        return nil;
    }

    NSString *path = [self.directory stringByAppendingPathComponent:[A2JITDDIStore canonicalImageName]];
    NSError *wErr = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&wErr]) {
        if (error) {
            *error = A2StoreError(A2JITDDIStoreErrorWriteFailed,
                                  [NSString stringWithFormat:@"写入失败：%@",
                                   wErr.localizedDescription ?: path]);
        }
        return nil;
    }

    NSString *declaredVersion = [A2JITDDIStore osVersionFromFileName:fileName ?: @""];
    NSString *declaredBuild = [A2JITDDIStore buildFromFileName:fileName ?: @""];

    NSMutableDictionary<NSString *, id> *meta = [NSMutableDictionary dictionary];
    meta[A2JITDDIStoreSourceNameKey] = sourceName.length ? sourceName : @"(未命名)";
    meta[A2JITDDIStoreImportedAtKey] = [NSDate date];
    meta[A2JITDDIStoreByteSizeKey] = @(data.length);
    meta[A2JITDDIStoreChecksumKey] = [A2JITDDIStore sha256HexOfData:data] ?: @"";
    meta[A2JITDDIStoreKindKey] = @"Legacy";
    if (declaredVersion.length) {
        meta[A2JITDDIStoreDeclaredOSVersionKey] = declaredVersion;
    }
    if (declaredBuild.length) {
        meta[A2JITDDIStoreDeclaredBuildKey] = declaredBuild;
    }
    (void)[meta writeToFile:self.metadataFilePath atomically:YES];

    NSLog(@"[A2JIT] ddi-store: 已导入 path=%@ bytes=%lu declared=%@/%@ sha256=%@",
          path, (unsigned long)data.length,
          declaredVersion ?: @"(未声明)", declaredBuild ?: @"(未声明)",
          meta[A2JITDDIStoreChecksumKey]);
    return path;
}

- (nullable NSString *)importImageFromURL:(NSURL *)url
                               sourceName:(nullable NSString *)sourceName
                                    error:(NSError *_Nullable *_Nullable)error {
    if (url == nil) {
        if (error) {
            *error = A2StoreError(A2JITDDIStoreErrorInvalidImage, @"没有拿到文件 URL");
        }
        return nil;
    }

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *srcPath = url.path;
    NSString *why = nil;
    if (![self fileLooksLikeDiskImageAtPath:srcPath why:&why]) {
        if (error) {
            *error = A2StoreError(A2JITDDIStoreErrorInvalidImage,
                                  [NSString stringWithFormat:@"不是可识别的磁盘镜像：%@", why ?: @"未知原因"]);
        }
        NSLog(@"[A2JIT] ddi-store: URL 校验失败 %@ reason=%@", url.lastPathComponent, why ?: @"?");
        if (scoped) {
            [url stopAccessingSecurityScopedResource];
        }
        return nil;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *dirErr = nil;
    if (![fm createDirectoryAtPath:self.directory
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&dirErr]) {
        if (error) {
            *error = A2StoreError(A2JITDDIStoreErrorWriteFailed,
                                  [NSString stringWithFormat:@"无法创建目录：%@",
                                   dirErr.localizedDescription ?: self.directory]);
        }
        if (scoped) {
            [url stopAccessingSecurityScopedResource];
        }
        return nil;
    }

    NSString *dst = [self.directory stringByAppendingPathComponent:[A2JITDDIStore canonicalImageName]];
    [fm removeItemAtPath:dst error:NULL];

    NSError *copyErr = nil;
    if (![fm copyItemAtPath:srcPath toPath:dst error:&copyErr]) {
        if (error) {
            *error = A2StoreError(A2JITDDIStoreErrorWriteFailed,
                                  [NSString stringWithFormat:@"拷贝失败：%@",
                                   copyErr.localizedDescription ?: dst]);
        }
        if (scoped) {
            [url stopAccessingSecurityScopedResource];
        }
        return nil;
    }
    if (scoped) {
        [url stopAccessingSecurityScopedResource];
    }

    NSNumber *sz = [fm attributesOfItemAtPath:dst error:NULL][NSFileSize];
    unsigned long long size = [sz isKindOfClass:NSNumber.class] ? sz.unsignedLongLongValue : 0;
    NSString *fileName = sourceName.length ? sourceName : url.lastPathComponent;
    NSString *declaredVersion = [A2JITDDIStore osVersionFromFileName:fileName];
    NSString *declaredBuild = [A2JITDDIStore buildFromFileName:fileName];

    NSMutableDictionary<NSString *, id> *meta = [NSMutableDictionary dictionary];
    meta[A2JITDDIStoreSourceNameKey] = fileName ?: @"(未命名)";
    meta[A2JITDDIStoreImportedAtKey] = [NSDate date];
    meta[A2JITDDIStoreByteSizeKey] = @(size);
    meta[A2JITDDIStoreChecksumKey] = [A2JITDDIStore sha256HexOfFile:dst] ?: @"";
    meta[A2JITDDIStoreKindKey] = @"Legacy";
    if (declaredVersion.length) {
        meta[A2JITDDIStoreDeclaredOSVersionKey] = declaredVersion;
    }
    if (declaredBuild.length) {
        meta[A2JITDDIStoreDeclaredBuildKey] = declaredBuild;
    }
    (void)[meta writeToFile:self.metadataFilePath atomically:YES];

    NSLog(@"[A2JIT] ddi-store: 已导入（文件）path=%@ bytes=%llu declared=%@/%@ sha256=%@",
          dst, size, declaredVersion ?: @"(未声明)", declaredBuild ?: @"(未声明)",
          meta[A2JITDDIStoreChecksumKey]);
    return dst;
}

- (BOOL)removeImportedImageWithError:(NSError *_Nullable *_Nullable)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL removedAny = NO;
    for (NSString *name in [A2JITDDIStore candidateImageNames]) {
        NSString *p = [self.directory stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:p]) {
            NSError *e = nil;
            if ([fm removeItemAtPath:p error:&e]) {
                removedAny = YES;
            } else if (error) {
                *error = A2StoreError(A2JITDDIStoreErrorWriteFailed,
                                      e.localizedDescription ?: @"删除镜像失败");
                return NO;
            }
        }
    }
    if ([fm fileExistsAtPath:self.metadataFilePath]) {
        [fm removeItemAtPath:self.metadataFilePath error:NULL];
    }
    NSLog(@"[A2JIT] ddi-store: 移除已导入镜像（removedAny=%d）", (int)removedAny);
    if (!removedAny && error) {
        *error = A2StoreError(A2JITDDIStoreErrorNoStoredImage, @"没有已导入的 DDI 镜像");
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
    return [self hexFromDigest:digest];
}

+ (nullable NSString *)sha256HexOfFile:(NSString *)path {
    NSInputStream *in = [NSInputStream inputStreamWithFileAtPath:path];
    if (in == nil) {
        return nil;
    }
    [in open];
    if (in.streamStatus == NSStreamStatusError) {
        [in close];
        return nil;
    }
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    const NSUInteger chunk = 256 * 1024;
    uint8_t *buf = malloc(chunk);
    if (buf == NULL) {
        [in close];
        return nil;
    }
    NSInteger n = 0;
    while ((n = [in read:buf maxLength:chunk]) > 0) {
        CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
    }
    free(buf);
    [in close];
    if (n < 0) {
        return nil;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    return [self hexFromDigest:digest];
}

+ (NSString *)hexFromDigest:(const unsigned char *)digest {
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

@end
