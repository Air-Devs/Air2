//
//  CurseForgeMurmurHash.h
//  Amethyst
//
//  CurseForge MurmurHash2 文件指纹计算（mod "检测更新"指纹反查用）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// CurseForge 标准指纹算法核心：MurmurHash2（32 位，种子 1）
/// 对传入的字节序列做纯 MurmurHash2 计算（不做任何字节过滤）
uint32_t CFMurmurHash2(const uint8_t *data, size_t len);

/// CurseForge 文件指纹计算工具
@interface CurseForgeMurmurHash : NSObject

/// 计算指定文件的 CurseForge 指纹
/// 按 CurseForge 实际规则：先过滤空白字节（0x09/0x0a/0x0d/0x20），
/// 再对过滤后的字节流做 MurmurHash2（种子 1）。
/// @param path 本地文件路径（mod jar）
/// @return 无符号 32 位指纹，文件读取失败时返回 0
+ (uint32_t)fingerprintForFileAtPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
