// ============================================================================
//  Air2/Core/Version/A2IntegrityChecker.h
//  启动前的完整性核对（口径参考 PCL：对着版本清单逐项核，不是只探目录）
// ----------------------------------------------------------------------------
//  检查项：
//    ① 客户端 jar：存在 + 非空 + 是 zip（EOCD）
//    ② 版本 json：存在 + 可解析 + id 与目录名一致
//    ③ libraries：json 里 downloads.artifact.path 声明的每个文件存在（缺哪些列出来）
//    ④ assets：assetIndex 里的 objects 按 hash 落在 assets/objects/xx/ 下（抽样+全量计时）
//  口径：
//    · 只做**只读核对**，不修不删（修复交给下载器，另做）
//    · 「跳过完整性检查」开关命中 ⇒ 整段跳过（PCL 也允许跳过）
//    · 结果按「致命/告警」分级：致命=不可能启动（缺 jar/json），告警=可能缺资源
// ============================================================================
#ifndef A2_INTEGRITY_CHECKER_H
#define A2_INTEGRITY_CHECKER_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, A2IntegrityLevel) {
    A2IntegrityLevelOK = 0,      ///< 全部就绪
    A2IntegrityLevelWarning,     ///< 能启动，但缺库/资源（可能黑屏/无音效）
    A2IntegrityLevelFatal,       ///< 缺 jar / json 损坏 —— 不可能启动
};

@interface A2IntegrityReport : NSObject
@property (nonatomic, assign) A2IntegrityLevel level;
@property (nonatomic, copy) NSArray<NSString *> *missingLibraries;   // 缺的库（最多 20 条）
@property (nonatomic, assign) NSInteger missingLibraryCount;
@property (nonatomic, assign) NSInteger missingAssetCount;
@property (nonatomic, assign) NSInteger assetsChecked;
@property (nonatomic, copy, nullable) NSString *fatalReason;
@property (nonatomic, copy) NSString *summary;   // 一行可读结论（进日志/失败页）
@end

@interface A2IntegrityChecker : NSObject

/// 对一个已安装版本做只读核对。
/// @param versionDir  versions/<id>
/// @param versionID   版本 id
/// @param gameHome    游戏根（里面应有 libraries/、assets/）
+ (A2IntegrityReport *)checkVersionAtPath:(NSString *)versionDir
                                versionID:(NSString *)versionID
                                 gameHome:(NSString *)gameHome;

@end

#endif
