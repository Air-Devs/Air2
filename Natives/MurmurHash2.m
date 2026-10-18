#import "utils.h"
//
//  MurmurHash2.m
//  Amethyst
//
//  MurmurHash2 流式增量哈希工具（CurseForge 文件指纹专用变体）
//  参考实现：ZalithLauncher2 MurmurHash2Incremental.kt
//

#import "MurmurHash2.h"

// MurmurHash2 算法常量
static const uint32_t kMurmurHash2_M = 0x5bd1e995u;
static const uint32_t kMurmurHash2_R = 24u;
static const uint32_t kMurmurHash2_Seed = 1u;

// 流式读取缓冲区大小
static const NSUInteger kMurmurHash2_BufferSize = 8192;

// CurseForge 需要过滤的空白字节：0x09 (tab)、0x0a (LF)、0x0d (CR)、0x20 (space)
static const uint8_t kMurmurHash2_SkipBytes[] = {0x09, 0x0a, 0x0d, 0x20};

/// 判断字节是否属于需要跳过的空白字节
static inline BOOL MurmurHash2_ShouldSkipByte(uint8_t b) {
    for (size_t i = 0; i < sizeof(kMurmurHash2_SkipBytes); i++) {
        if (b == kMurmurHash2_SkipBytes[i]) {
            return YES;
        }
    }
    return NO;
}

@interface MurmurHash2 ()
/// 第一遍扫描：计算过滤空白字节后的总长度
+ (uint32_t)_filteredLengthOfFile:(NSString *)filePath error:(NSError *_Nullable *_Nullable)error;
/// 第二遍扫描：流式计算 MurmurHash2 哈希值
+ (uint32_t)_computeHashOfFile:(NSString *)filePath
                filteredLength:(uint32_t)totalLen
                        error:(NSError *_Nullable *_Nullable)error;
@end

@implementation MurmurHash2

+ (uint32_t)hashOfFile:(NSString *)filePath error:(NSError *_Nullable *_Nullable)error {
    // 参数校验：路径非空
    if (filePath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileNoSuchFileError
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_791", nil)}];
        }
        return 0;
    }

    // 校验文件存在且不是目录
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:filePath isDirectory:&isDirectory] || isDirectory) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileNoSuchFileError
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_792", nil), filePath]}];
        }
        return 0;
    }

    // 第一遍：计算过滤后的总长度
    // 哈希初始值 h = seed ^ totalLen 需要预先知道过滤后的总长度，因此必须先做一遍扫描
    NSError *lengthError = nil;
    uint32_t totalLen = [self _filteredLengthOfFile:filePath error:&lengthError];
    if (lengthError) {
        if (error) { *error = lengthError; }
        return 0;
    }

    // 第二遍：流式计算哈希
    NSError *hashError = nil;
    uint32_t hash = [self _computeHashOfFile:filePath filteredLength:totalLen error:&hashError];
    if (hashError) {
        if (error) { *error = hashError; }
        return 0;
    }

    return hash;
}

#pragma mark - 内部辅助方法

+ (uint32_t)_filteredLengthOfFile:(NSString *)filePath error:(NSError *_Nullable *_Nullable)error {
    uint32_t totalLen = 0;
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:filePath];
    if (!stream) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileReadUnknownError
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_793", nil)}];
        }
        return 0;
    }

    [stream open];
    if ([stream streamStatus] == NSStreamStatusError) {
        if (error) { *error = [stream streamError]; }
        [stream close];
        return 0;
    }

    uint8_t readBuffer[kMurmurHash2_BufferSize];
    NSInteger bytesRead;
    while ((bytesRead = [stream read:readBuffer maxLength:sizeof(readBuffer)]) > 0) {
        for (NSInteger i = 0; i < bytesRead; i++) {
            if (!MurmurHash2_ShouldSkipByte(readBuffer[i])) {
                totalLen++;
            }
        }
    }

    NSError *streamError = [stream streamError];
    [stream close];

    if (streamError) {
        if (error) { *error = streamError; }
        return 0;
    }

    return totalLen;
}

+ (uint32_t)_computeHashOfFile:(NSString *)filePath
                filteredLength:(uint32_t)totalLen
                        error:(NSError *_Nullable *_Nullable)error {
    // 初始哈希值：h = seed ^ totalLen
    uint32_t h = kMurmurHash2_Seed ^ totalLen;

    // tail：不足 4 字节的尾部缓冲；tailLen：已积累的尾部字节数
    uint8_t tail[4];
    uint32_t tailLen = 0;

    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:filePath];
    if (!stream) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileReadUnknownError
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_793", nil)}];
        }
        return 0;
    }

    [stream open];
    if ([stream streamStatus] == NSStreamStatusError) {
        if (error) { *error = [stream streamError]; }
        [stream close];
        return 0;
    }

    uint8_t readBuffer[kMurmurHash2_BufferSize];
    NSInteger bytesRead;
    while ((bytesRead = [stream read:readBuffer maxLength:sizeof(readBuffer)]) > 0) {
        for (NSInteger i = 0; i < bytesRead; i++) {
            uint8_t b = readBuffer[i];

            // 跳过空白字节
            if (MurmurHash2_ShouldSkipByte(b)) {
                continue;
            }

            // 累积到尾部缓冲
            tail[tailLen++] = b;

            // 凑齐 4 字节后进行 MurmurHash2 混淆
            if (tailLen == 4) {
                // 按小端序组装为 32 位整数
                uint32_t k = ((uint32_t)tail[0])
                           | ((uint32_t)tail[1] << 8)
                           | ((uint32_t)tail[2] << 16)
                           | ((uint32_t)tail[3] << 24);

                // MurmurHash2 核心混淆
                // 使用 & 0xFFFFFFFFu 掩码显式保证 uint32_t 溢出语义（与 Kotlin 的 & 0xFFFFFFFFL 等价）
                k = (k * kMurmurHash2_M) & 0xFFFFFFFFu;
                k ^= (k >> kMurmurHash2_R);
                k = (k * kMurmurHash2_M) & 0xFFFFFFFFu;

                h = (h * kMurmurHash2_M) & 0xFFFFFFFFu;
                h ^= k;

                tailLen = 0;
            }
        }
    }

    NSError *streamError = [stream streamError];
    [stream close];

    if (streamError) {
        if (error) { *error = streamError; }
        return 0;
    }

    // 处理尾部不足 4 字节的剩余字节（switch 故意 fall-through，与 Kotlin 各分支行为一致）
    switch (tailLen) {
        case 3:
            h ^= ((uint32_t)tail[2] << 16);
            // fall through
        case 2:
            h ^= ((uint32_t)tail[1] << 8);
            // fall through
        case 1:
            h ^= (uint32_t)tail[0];
            h = (h * kMurmurHash2_M) & 0xFFFFFFFFu;
            break;
        default:
            break;
    }

    // 最终混合（finalizer）
    h ^= (h >> 13);
    h = (h * kMurmurHash2_M) & 0xFFFFFFFFu;
    h ^= (h >> 15);

    return h;
}

@end
