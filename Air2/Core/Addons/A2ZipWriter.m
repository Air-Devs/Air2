//
//  A2ZipWriter.m
//  Air2
//

#import "A2ZipWriter.h"
#import "A2Logger.h"

#pragma mark - 小端写入

static void writeU16(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF) };
    [d appendBytes:b length:2];
}

static void writeU32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = {
        (uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF),
        (uint8_t)((v >> 16) & 0xFF), (uint8_t)((v >> 24) & 0xFF)
    };
    [d appendBytes:b length:4];
}

#pragma mark - 已写入的条目（用于生成中央目录）

@interface A2ZipEntryRecord : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint32_t crc32;
@property (nonatomic, assign) uint32_t size;
@property (nonatomic, assign) uint32_t offset;
@end

@implementation A2ZipEntryRecord
@end

#pragma mark - Writer

@interface A2ZipWriter ()
@property (nonatomic, strong) NSFileHandle *handle;
@property (nonatomic, strong) NSMutableArray<A2ZipEntryRecord *> *records;
@property (nonatomic, assign) uint32_t writtenBytes;
@property (nonatomic, assign) BOOL finished;
@end

@implementation A2ZipWriter

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (!self) return nil;

    [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    _handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!_handle) return nil;

    _records = [NSMutableArray array];
    _writtenBytes = 0;
    return self;
}

/// CRC32 查表法 —— zip 要求每个条目带 CRC32
static uint32_t crc32_table[256];
static BOOL crc32_ready = NO;

static void build_crc32_table(void) {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) {
            c = (c & 1) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
        }
        crc32_table[i] = c;
    }
    crc32_ready = YES;
}

static uint32_t crc32_of(const uint8_t *data, size_t len) {
    if (!crc32_ready) build_crc32_table();
    uint32_t c = 0xFFFFFFFF;
    for (size_t i = 0; i < len; i++) {
        c = crc32_table[(c ^ data[i]) & 0xFF] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
}

- (BOOL)writeLocalHeader:(NSString *)name
                     crc:(uint32_t)crc
                    size:(uint32_t)size
                  offset:(uint32_t *)outOffset {
    NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (nameData.length > 0xFFFF) return NO;

    uint32_t offset = _writtenBytes;
    NSMutableData *h = [NSMutableData data];

    // 本地文件头签名
    writeU32(h, 0x04034b50);
    writeU16(h, 20);                    // 解压所需版本
    writeU16(h, 0x0800);                // 标志位：文件名是 UTF-8
    writeU16(h, 0);                     // 压缩方法：0 = stored
    writeU16(h, 0);                     // 修改时间
    writeU16(h, 0);                     // 修改日期
    writeU32(h, crc);
    writeU32(h, size);                  // 压缩后大小（stored 时相等）
    writeU32(h, size);                  // 原始大小
    writeU16(h, (uint16_t)nameData.length);
    writeU16(h, 0);                     // 扩展字段长度
    [h appendData:nameData];

    @try {
        [_handle writeData:h];
    } @catch (NSException *e) {
        return NO;
    }
    _writtenBytes += (uint32_t)h.length;
    *outOffset = offset;
    return YES;
}

- (BOOL)addData:(NSData *)data entryName:(NSString *)entryName {
    if (_finished || !data || entryName.length == 0) return NO;

    uint32_t crc = crc32_of(data.bytes, data.length);
    uint32_t size = (uint32_t)data.length;
    uint32_t offset = 0;

    if (![self writeLocalHeader:entryName crc:crc size:size offset:&offset]) return NO;

    @try {
        [_handle writeData:data];
    } @catch (NSException *e) {
        return NO;
    }
    _writtenBytes += size;

    A2ZipEntryRecord *rec = [A2ZipEntryRecord new];
    rec.name = entryName;
    rec.crc32 = crc;
    rec.size = size;
    rec.offset = offset;
    [_records addObject:rec];
    return YES;
}

- (BOOL)addFileAtPath:(NSString *)filePath entryName:(NSString *)entryName {
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) {
        [A2Logger warning:@"A2ZipWriter"
               message:[NSString stringWithFormat:@"读取失败，跳过: %@", filePath]];
        return NO;
    }
    return [self addData:data entryName:entryName];
}

- (BOOL)addDirectoryAtPath:(NSString *)dirPath prefix:(NSString *)prefix {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    if (!entries) return NO;

    BOOL any = NO;
    for (NSString *name in entries) {
        // 跳过 macOS 元数据与空目录标记
        if ([name hasPrefix:@".DS_Store"] || [name isEqualToString:@".localized"]) continue;

        NSString *full = [dirPath stringByAppendingPathComponent:name];
        NSString *entryName = prefix.length
            ? [NSString stringWithFormat:@"%@/%@", prefix, name]
            : name;

        BOOL isDir = NO;
        [fm fileExistsAtPath:full isDirectory:&isDir];
        if (isDir) {
            if ([self addDirectoryAtPath:full prefix:entryName]) any = YES;
        } else {
            if ([self addFileAtPath:full entryName:entryName]) any = YES;
        }
    }
    return any;
}

/// 写中央目录 —— 没有它 zip 是不完整的
- (BOOL)finish {
    if (_finished) return NO;
    _finished = YES;

    uint32_t cdStart = _writtenBytes;
    NSMutableData *cd = [NSMutableData data];

    for (A2ZipEntryRecord *rec in _records) {
        NSData *nameData = [rec.name dataUsingEncoding:NSUTF8StringEncoding];

        writeU32(cd, 0x02014b50);       // 中央目录条目签名
        writeU16(cd, 20);               // 创建版本
        writeU16(cd, 20);               // 解压所需版本
        writeU16(cd, 0x0800);           // 标志位
        writeU16(cd, 0);                // 压缩方法
        writeU16(cd, 0);                // 时间
        writeU16(cd, 0);                // 日期
        writeU32(cd, rec.crc32);
        writeU32(cd, rec.size);
        writeU32(cd, rec.size);
        writeU16(cd, (uint16_t)nameData.length);
        writeU16(cd, 0);                // 扩展字段
        writeU16(cd, 0);                // 注释
        writeU16(cd, 0);                // 磁盘号
        writeU16(cd, 0);                // 内部属性
        writeU32(cd, 0);                // 外部属性
        writeU32(cd, rec.offset);
        [cd appendData:nameData];
    }

    @try {
        [_handle writeData:cd];
    } @catch (NSException *e) {
        return NO;
    }

    uint32_t cdSize = (uint32_t)cd.length;
    uint16_t count = (uint16_t)MIN(_records.count, 0xFFFF);

    NSMutableData *eocd = [NSMutableData data];
    writeU32(eocd, 0x06054b50);         // EOCD 签名
    writeU16(eocd, 0);                  // 本磁盘号
    writeU16(eocd, 0);                  // 中央目录起始磁盘
    writeU16(eocd, count);              // 本磁盘条目数
    writeU16(eocd, count);              // 总条目数
    writeU32(eocd, cdSize);
    writeU32(eocd, cdStart);
    writeU16(eocd, 0);                  // 注释长度

    @try {
        [_handle writeData:eocd];
        [_handle closeFile];
    } @catch (NSException *e) {
        return NO;
    }

    [A2Logger info:@"A2ZipWriter"
           message:[NSString stringWithFormat:@"打包完成，%lu 个条目",
                    (unsigned long)_records.count]];
    return YES;
}

@end
