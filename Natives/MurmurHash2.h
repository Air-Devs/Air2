//
//  MurmurHash2.h
//  Amethyst
//
//  MurmurHash2 流式增量哈希工具（CurseForge 文件指纹专用变体）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// MurmurHash2 流式增量哈希工具
/// 用于 CurseForge 文件指纹反查，计算时过滤 0x09/0x0a/0x0d/0x20 四个空白字节
@interface MurmurHash2 : NSObject

/// 计算指定文件的 MurmurHash2 指纹（CurseForge 格式）
/// @param filePath 文件路径
/// @param error 错误输出
/// @return 无符号 32 位哈希值，失败时返回 0 并设置 error
+ (uint32_t)hashOfFile:(NSString *)filePath error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
