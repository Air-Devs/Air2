//
//  A2ModpackParser.h
//  Air2
//
//  整合包格式判别与解析的总入口。
//
//  调用方把「已解压的整合包根目录」交进来，得到统一模型；
//  具体某个格式怎么读，由四个子解析器各自负责。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class A2ModpackInfo;

/// 整合包解析的错误域
FOUNDATION_EXPORT NSString *const A2ModpackParserErrorDomain;

typedef NS_ENUM(NSInteger, A2ModpackParserErrorCode) {
    A2ModpackParserErrorIO = 1,          ///< 目录或清单读取失败
    A2ModpackParserErrorInvalidFormat,   ///< 清单存在但内容不合法
    A2ModpackParserErrorNoPackFound,     ///< 没有匹配到任何已知格式
};

/// 统一的错误构造。
static inline NSError *A2ModpackError(A2ModpackParserErrorCode code, NSString *message) {
    return [NSError errorWithDomain:A2ModpackParserErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface A2ModpackParser : NSObject

/// 识别并解析已解压的整合包。
///
/// 按 CurseForge → Modrinth → MultiMC → MCBBS 的顺序尝试，命中即止；
/// 一个都不匹配时返回 nil 并给出 A2ModpackParserErrorNoPackFound。
+ (nullable A2ModpackInfo *)parseExtractedPackAtRoot:(NSString *)root
                                              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
