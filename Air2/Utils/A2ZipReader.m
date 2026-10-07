//
//  A2ZipReader.m
//  Air2
//

#import "A2ZipReader.h"
#import <zlib.h>

/// 三个关键签名，都是小端存储。
/// zip 格式规定所有多字节整数为小端，x86/arm 也是小端，
/// 但仍显式按字节拼，避免依赖平台字节序。
static const uint32_t kA2ZipCentralSig = 0x02014b50;
static const uint32_t kA2ZipLocalSig   = 0x04034b50;
static const uint32_t kA2ZipEOCDSig    = 0x06054b50;

/// 只有不超过这个大小的条目才进缓存。
/// 缓存是为了让「同一个配置/清单被反复读」时不必重复 inflate；
/// 大文件（mod、jar、音频）一旦全缓存，解压整个整合包会直接吃光内存。
static const NSUInteger kA2ZipSmallEntryLimit = 4 * 1024 * 1024;

/// 中央目录里的一个条目。
///
/// 只保留「定位并解压数据」所需的最小字段 ——
/// 时间戳、CRC、属性等对读取内容没有用。
@interface A2ZipEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint16_t method;
@property (nonatomic, assign) uint32_t compressedSize;
@property (nonatomic, assign) uint32_t uncompressedSize;
/// 本地文件头相对文件起点的偏移（不是数据起点）
@property (nonatomic, assign) uint32_t localHeaderOffset;
@end

@implementation A2ZipEntry
@end

@interface A2ZipReader ()
@property (nonatomic, strong) NSData *data;
@property (nonatomic, strong) NSMutableDictionary<NSString *, A2ZipEntry *> *entries;
/// 按中央目录出现顺序记录条目名。NSDictionary 无序，
/// 而 entryNames 的契约是「顺序与中央目录一致」，所以要另存。
@property (nonatomic, strong) NSMutableArray<NSString *> *orderedNames;
/// 已解压结果的缓存，键为条目名。只缓存小条目。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *cache;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *entryNames;
@end

@implementation A2ZipReader

#pragma mark - 小端读取

static inline uint16_t A2LE16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static inline uint32_t A2LE32(const uint8_t *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24));
}

/// 从尾部往前找 EOCD。zip 允许在 EOCD 之后跟最多 64KB 的注释，
/// 所以不能假设 EOCD 就在最后 22 字节处。
static NSInteger A2FindEOCD(const uint8_t *bytes, NSUInteger length) {
    if (length < 22) return -1;
    // 22 是 EOCD 固定长度，65535 是注释上限
    NSUInteger scanStart = length > 65557 ? length - 65557 : 0;
    for (NSUInteger i = length - 22; ; i--) {
        if (A2LE32(bytes + i) == kA2ZipEOCDSig) return (NSInteger)i;
        if (i == scanStart) break;
    }
    return -1;
}

/// zip 的 deflate 是 raw 流 —— 没有 zlib 头，也没有 Adler-32 校验尾，
/// 所以 wbits 必须传 -15，否则 inflateInit2 会直接失败。
static NSData *A2InflateRaw(NSData *input, NSUInteger expectedSize) {
    if (input.length == 0) return [NSData data];

    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (inflateInit2(&strm, -15) != Z_OK) return nil;

    strm.next_in = (Bytef *)(uintptr_t)input.bytes;
    strm.avail_in = (uInt)input.length;

    NSMutableData *out = [NSMutableData dataWithCapacity:
                          expectedSize > 0 ? expectedSize : input.length * 4];
    uint8_t buf[65536];

    NSData *result = nil;
    while (YES) {
        strm.next_out = buf;
        strm.avail_out = (uInt)sizeof(buf);

        int status = inflate(&strm, Z_NO_FLUSH);
        if (status != Z_OK && status != Z_STREAM_END) break;

        NSUInteger produced = sizeof(buf) - strm.avail_out;
        if (produced > 0) [out appendBytes:buf length:produced];

        if (status == Z_STREAM_END) {
            result = out;
            break;
        }
        // 没到流尾但输入已耗尽 —— 数据被截断，宁可报错也不返回半截内容
        if (strm.avail_in == 0) break;
    }

    inflateEnd(&strm);
    return result;
}

#pragma mark - 生命周期

- (nullable instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (!self) return nil;

    // mmap 读取：整合包动辄几十上百 MB，整份读进堆里没必要。
    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    if (data.length == 0) return nil;

    _data = data;
    _entries = [NSMutableDictionary dictionary];
    _orderedNames = [NSMutableArray array];
    _cache = [NSMutableDictionary dictionary];

    if (![self parseCentralDirectory]) return nil;
    // 一个条目都没有（非 zip / 空 zip / 中央目录损坏）视为读取失败
    if (_entries.count == 0) return nil;

    _entryNames = [_orderedNames copy];
    return self;
}

#pragma mark - 解析

/// 解析中央目录。
///
/// 中央目录是 zip 的权威索引：它给出条目名、压缩方式、压缩后大小
/// 以及本地头偏移。比「顺序扫本地头」可靠，因为本地头可能夹着
/// 数据描述符 / 流式写入的残留。
- (BOOL)parseCentralDirectory {
    const uint8_t *bytes = self.data.bytes;
    NSUInteger length = self.data.length;

    NSInteger eocd = A2FindEOCD(bytes, length);
    if (eocd < 0) return NO;

    uint16_t entryCount = A2LE16(bytes + (NSUInteger)eocd + 10);
    uint32_t cdOffset = A2LE32(bytes + (NSUInteger)eocd + 16);
    if (cdOffset >= length) return NO;

    NSUInteger p = cdOffset;
    for (uint16_t i = 0; i < entryCount; i++) {
        if (p + 46 > length) break;
        if (A2LE32(bytes + p) != kA2ZipCentralSig) break;

        uint16_t method      = A2LE16(bytes + p + 10);
        uint32_t compSize    = A2LE32(bytes + p + 20);
        uint32_t uncompSize  = A2LE32(bytes + p + 24);
        uint16_t nameLen     = A2LE16(bytes + p + 28);
        uint16_t extraLen    = A2LE16(bytes + p + 30);
        uint16_t commentLen  = A2LE16(bytes + p + 32);
        uint32_t localOffset = A2LE32(bytes + p + 42);

        if (p + 46 + nameLen > length) break;

        NSString *name = [[NSString alloc] initWithBytes:bytes + p + 46
                                                  length:nameLen
                                                encoding:NSUTF8StringEncoding];
        if (!name) {
            // 少量非 UTF-8 的旧 zip 用本地编码；退到 Latin-1 至少不丢条目
            name = [[NSString alloc] initWithBytes:bytes + p + 46
                                            length:nameLen
                                          encoding:NSISOLatin1StringEncoding];
        }

        // 目录条目（以 / 结尾）不参与读取
        if (name.length > 0 && ![name hasSuffix:@"/"]) {
            A2ZipEntry *e = [A2ZipEntry new];
            e.name = name;
            e.method = method;
            e.compressedSize = compSize;
            e.uncompressedSize = uncompSize;
            e.localHeaderOffset = localOffset;
            // 重名时后者覆盖前者；名字顺序按首次出现记
            if (!self.entries[name]) [self.orderedNames addObject:name];
            self.entries[name] = e;
        }

        p += (NSUInteger)46 + nameLen + extraLen + commentLen;
    }

    return YES;
}

#pragma mark - 读取

- (BOOL)hasEntry:(NSString *)name {
    return name.length > 0 && self.entries[name] != nil;
}

- (nullable NSData *)dataForEntry:(NSString *)name {
    if (name.length == 0) return nil;

    NSData *cached = self.cache[name];
    if (cached) return cached;

    A2ZipEntry *entry = self.entries[name];
    if (!entry) return nil;

    NSData *out = [self extractEntry:entry];
    if (out && out.length <= kA2ZipSmallEntryLimit) self.cache[name] = out;
    return out;
}

/// 定位并解压单个条目。
///
/// 关键：数据起点要按**本地头**算 —— 本地头记录的
/// name/extra 长度与中央目录可能不同（例如中央目录带了
/// zip64 扩展信息），直接用中央目录的长度会算偏。
- (nullable NSData *)extractEntry:(A2ZipEntry *)entry {
    const uint8_t *bytes = self.data.bytes;
    NSUInteger length = self.data.length;

    NSUInteger p = entry.localHeaderOffset;
    if (p + 30 > length) return nil;
    if (A2LE32(bytes + p) != kA2ZipLocalSig) return nil;

    uint16_t nameLen  = A2LE16(bytes + p + 26);
    uint16_t extraLen = A2LE16(bytes + p + 28);
    NSUInteger dataStart = p + 30 + nameLen + extraLen;

    NSUInteger compSize = entry.compressedSize;
    if (dataStart > length || dataStart + compSize > length) return nil;

    if (entry.method == 0) {
        // stored：直接拷贝，注意复制而不是包住 _data 的内存 ——
        // 返回值可能比本实例活得更久
        return [NSData dataWithBytes:bytes + dataStart length:compSize];
    }
    if (entry.method == 8) {
        NSData *comp = [NSData dataWithBytes:bytes + dataStart length:compSize];
        return A2InflateRaw(comp, entry.uncompressedSize);
    }
    // 其他压缩方式（bzip2 / lzma / deflate64）暂不支持
    return nil;
}

@end
