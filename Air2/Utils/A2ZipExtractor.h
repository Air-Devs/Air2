//
//  A2ZipExtractor.h
//  Air2
//
//  在 A2ZipReader 之上提供「解压到目录」。
//
//  reader 只负责把单个条目读成 NSData；整合包安装需要的是
// 「把 overrides/ 整个落到游戏目录」「把 mods/ 落到 mods 目录」，
// 于是把「遍历条目 + 建目录 + 落盘」这套收在这里。
//
//  与其它解压实现一样，路径穿越是必须防的：整合包是外部输入，
//  条目名里出现 ../../ 或绝对路径时，绝不能写到目标目录之外。
//
//  线程模型：与 reader 相同 —— 不可跨线程并发使用。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class A2ZipReader;

/// 解压失败的错误域
extern NSString *const A2ZipExtractorErrorDomain;

typedef NS_ENUM(NSInteger, A2ZipExtractorErrorCode) {
    A2ZipExtractorErrorNoReader = 1,      /// reader 为空
    A2ZipExtractorErrorCreateDirectory,   /// 目标目录创建失败
    A2ZipExtractorErrorReadEntry,         /// 条目数据损坏，读不出来
    A2ZipExtractorErrorWriteEntry,        /// 落盘失败
};

@interface A2ZipExtractor : NSObject

+ (instancetype)extractorWithReader:(A2ZipReader *)reader;

/// 名字以 prefix 开头的条目，按中央目录顺序返回。
/// prefix 传 nil 或空串表示「全部条目」。
- (NSArray<NSString *> *)entryNamesWithPrefix:(nullable NSString *)prefix;

/// 把条目解压到 directory。
///
/// prefix 非空时只解压该前缀下的条目，并在落盘时剥掉前缀 ——
/// 整合包的 overrides/ 就是这种用法：包内是 overrides/mods/xxx.jar，
/// 落到游戏目录时要变成 mods/xxx.jar。
///
/// overwrite 为 NO 时，已存在的目标文件跳过不覆盖。
///
/// 含 .. 分量 / 绝对路径的条目会被跳过，不会写到 directory 之外。
- (BOOL)extractToDirectory:(NSString *)directory
              entryPrefix:(nullable NSString *)prefix
                overwrite:(BOOL)overwrite
                 progress:(nullable void (^)(NSUInteger completed, NSUInteger total))progress
                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
