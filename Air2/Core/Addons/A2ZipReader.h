//
//  A2ZipReader.h
//  Air2
//
//  最小可用的 zip 读取器。
//
//  iOS 上没有公开的 zip 解压 API，而安装 Forge 需要从
//  installer jar 里读 version.json。自己实现只读版本，
//  代价比引入第三方库小。
//
//  支持：stored（不压缩）与 deflate（用 zlib 解压）
//  不支持：加密、zip64、多卷
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2ZipReader : NSObject

/// 打开 zip 文件。失败返回 nil。
- (nullable instancetype)initWithPath:(NSString *)path;

/// 所有条目名（不含目录条目）
@property (nonatomic, copy, readonly) NSArray<NSString *> *entryNames;

/// 条目是否存在
- (BOOL)containsEntry:(NSString *)name;

/// 取出指定条目的内容（自动解压）
- (nullable NSData *)dataForEntry:(NSString *)name;

/// 取出内容并写入指定路径
- (BOOL)extractEntry:(NSString *)name toPath:(NSString *)destPath;

/// 取出内容到目录（文件名用条目名）
- (nullable NSString *)extractEntry:(NSString *)name toDirectory:(NSString *)dir;

@end

NS_ASSUME_NONNULL_END
