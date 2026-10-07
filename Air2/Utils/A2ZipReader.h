//
//  A2ZipReader.h
//  Air2
//
//  只读 zip 读取器。
//
//  iOS 没有公开的 zip 读取 API，而「读取 Forge installer jar 里的
//  version.json」与「解压整合包」都需要它。这里只做只读路径：
//
//    · 从尾部扫 EOCD 定位中央目录（zip 允许尾部注释，最长 64KB）
//    · 中央目录是条目的权威索引，比顺序扫本地头可靠
//    · 解压时按「本地文件头」定位数据起点 —— 本地头的
//      name/extra 长度可能与中央目录不同，必须重新读本地头
//    · method 0 直取；method 8 用 zlib 的 raw inflate
//      （wbits = -15，zip 的 deflate 流没有 zlib 头）
//
//  行为规格见 tests/Core/test_zip_reader.py，两边的判定必须一致。
//
//  线程模型：同一实例不可跨线程并发使用；小条目（配置/清单）首次
//  读取后缓存，大文件每次读取都重新 inflate，避免占满内存。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2ZipReader : NSObject

/// 读取并解析中央目录；文件不存在、不是 zip、或中央目录为空时返回 nil
- (nullable instancetype)initWithPath:(NSString *)path;

/// 全部条目名（不含目录条目），顺序与中央目录一致
@property (nonatomic, copy, readonly) NSArray<NSString *> *entryNames;

- (BOOL)hasEntry:(NSString *)name;

/// 取某个条目解压后的数据；不存在或数据损坏时返回 nil
- (nullable NSData *)dataForEntry:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
