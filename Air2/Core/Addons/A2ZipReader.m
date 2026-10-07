//
//  A2ZipReader.m
//  Air2
//

#import "A2ZipReader.h"
#import <zlib.h>

/// zip 中央目录条目签名
static const uint32_t kCentralDirSig = 0x02014b50;
/// 本地文件头签名
static const uint32_t kLocalHeaderSig = 0x04034b50;
/// EOCD 签名
static const uint32_t kEOCDSig = 0x06054b50;

static uint16_t readU16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t readU32(const uint8_t *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24));
}

#pragma mark - 条目

@interface A2ZipEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint16_t method;
@property (nonatomic, assign) uint32_t compressedSize;
@property (nonatomic, assign) uint32_t uncompressedSize;
@property (nonatomic, assign) uint32_t localHeaderOffset;
@end

@implementation A2ZipEntry
@end

#pragma mark - 读取器

@interface A2ZipReader ()
@property (nonatomic, strong) NSData *data;
@property (nonatomic, strong) NSMutableDictionary<NSString *, A2ZipEntry *> *entries;
@end

@implementation A2ZipReader

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (!self) return nil;

    // installer jar 可能几十 MB，用映射而不是全读进内存
    NSData *d = [NSData dataWithContentsOfFile:path
                                       options:NSDataReadingMappedIfSafe
                                         error:nil];
    if (!d || d.length < 22) return nil;

    _data = d;
    _entries = [NSMutableDictionary dictionary];

    if (![self parseCentralDirectory]) return nil;
    return self;
}

- (NSArray<NSString *> *)entryNames {
    return self.entries.allKeys;
}

- (BOOL)containsEntry:(NSString *)name {
    return self.entries[name] != nil;
}

- (BOOL)parseCentralDirectory {
    const uint8_t *bytes = _data.bytes;
    NSUInteger len = _data.length;

    // 从尾部往前找 EOCD（可能带注释，最多 64KB）
    NSUInteger scanStart = (len > 65557) ? (len - 65557) : 0;
    NSInteger eocdOffset = -1;
    for (NSInteger i = (NSInteger)len - 22; i >= (NSInteger)scanStart; i--) {
        if (readU32(bytes + i) == kEOCDSig) {
            eocdOffset = i;
            break;
        }
    }
    if (eocdOffset < 0) return NO;

    const uint8_t *eocd = bytes + eocdOffset;
    uint16_t entryCount = readU16(eocd + 10);
    uint32_t cdOffset = readU32(eocd + 16);
    if (cdOffset >= len) return NO;

    NSUInteger p = cdOffset;
    for (uint16_t i = 0; i < entryCount && p + 46 <= len; i++) {
        if (readU32(bytes + p) != kCentralDirSig) break;

        A2ZipEntry *e = [A2ZipEntry new];
        e.method = readU16(bytes + p + 10);
        e.compressedSize = readU32(bytes + p + 20);
        e.uncompressedSize = readU32(bytes + p + 24);
        uint16_t nameLen = readU16(bytes + p + 28);
        uint16_t extraLen = readU16(bytes + p + 30);
        uint16_t commentLen = readU16(bytes + p + 32);
        e.localHeaderOffset = readU32(bytes + p + 42);

        if (p + 46 + nameLen > len) break;

        NSString *name = [[NSString alloc] initWithBytes:bytes + p + 46
                                                  length:nameLen
                                                encoding:NSUTF8StringEncoding];
        if (!name) {
            name = [[NSString alloc] initWithBytes:bytes + p + 46
                                            length:nameLen
                                          encoding:NSISOLatin1StringEncoding];
        }
        e.name = name ?: @"";

        if (e.name.length > 0 && ![e.name hasSuffix:@"/"]) {
            _entries[e.name] = e;
        }

        p += 46 + nameLen + extraLen + commentLen;
    }

    return _entries.count > 0;
}

#pragma mark - 解压

- (NSData *)dataForEntry:(NSString *)name {
    A2ZipEntry *e = _entries[name];
    if (!e) return nil;

    const uint8_t *bytes = _data.bytes;
    NSUInteger len = _data.length;
    NSUInteger p = e.localHeaderOffset;

    if (p + 30 > len) return nil;
    if (readU32(bytes + p) != kLocalHeaderSig) return nil;

    // 关键：本地头的 name/extra 长度可能与中央目录不同，必须读本地头
    uint16_t nameLen = readU16(bytes + p + 26);
    uint16_t extraLen = readU16(bytes + p + 28);
    NSUInteger dataStart = p + 30 + nameLen + extraLen;

    if (dataStart + e.compressedSize > len) return nil;

    NSData *compressed = [NSData dataWithBytesNoCopy:(void *)(bytes + dataStart)
                                              length:e.compressedSize
                                        freeWhenDone:NO];
    if (!compressed) return nil;

    if (e.method == 0) return [compressed copy];
    if (e.method == 8) return [self inflate:compressed expectedSize:e.uncompressedSize];
    return nil;
}

- (nullable NSData *)inflate:(NSData *)input expectedSize:(uint32_t)expected {
    if (input.length == 0) return [NSData data];
    NSUInteger outSize = expected > 0 ? expected : (input.length * 4 + 1024);
    return [self inflate:input intoSize:outSize];
}

- (nullable NSData *)inflate:(NSData *)input intoSize:(NSUInteger)outSize {
    NSMutableData *out = [NSMutableData dataWithLength:outSize];

    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    // 负数窗口位表示 raw deflate —— zip 的数据没有 zlib 头
    if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) return nil;

    strm.next_in = (Bytef *)input.bytes;
    strm.avail_in = (uInt)input.length;
    strm.next_out = (Bytef *)out.mutableBytes;
    strm.avail_out = (uInt)outSize;

    int ret = inflate(&strm, Z_FINISH);
    NSUInteger produced = outSize - strm.avail_out;
    inflateEnd(&strm);

    // 缓冲不够就扩容重试
    if (ret == Z_BUF_ERROR || (ret == Z_OK && produced >= outSize)) {
        if (outSize > 512 * 1024 * 1024) return nil;
        return [self inflate:input intoSize:outSize * 4];
    }

    if (ret != Z_STREAM_END && ret != Z_OK) return nil;

    [out setLength:produced];
    return out;
}

#pragma mark - 解压到磁盘

- (BOOL)extractEntry:(NSString *)name toPath:(NSString *)destPath {
    NSData *d = [self dataForEntry:name];
    if (!d) return NO;

    [[NSFileManager defaultManager] createDirectoryAtPath:destPath.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [d writeToFile:destPath atomically:YES];
}

- (NSString *)extractEntry:(NSString *)name toDirectory:(NSString *)dir {
    if (![self containsEntry:name]) return nil;

    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *dest = [dir stringByAppendingPathComponent:name];
    if ([self extractEntry:name toPath:dest]) return dest;
    return nil;
}

@end
