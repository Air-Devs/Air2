//
//  A2IntegrityChecker.h
//  Air2
//
//  游戏文件完整性检查 —— 对照 ZL2 的校验逻辑。
//
//  ## 为什么需要（不是锦上添花）
//
//  启动失败的常见原因之一就是文件损坏：
//    · 下载时镜像给错区间（大小对、内容坏）
//    · 断点续传把两个版本的文件拼在一起
//    · 磁盘写满导致文件截断
//    · 用户手动改过 jar/mod
//
//  没有完整性检查时，这些错误表现为
//  「NoClassDefFoundError」「解压失败」「进不去游戏」——
//  用户完全看不出是文件问题。
//
//  ## 检查什么（与 ZL2 一致）
//
//    · 版本 JSON        ← version json 里的 sha1
//    · 客户端 jar       ← downloads.client.sha1
//    · 依赖库           ← libraries[].downloads.artifact.sha1
//    · 资源索引         ← assetIndex.sha1
//    · 资源对象         ← objects[].hash（本身就是 sha1）
//
//  ## 两档检查
//
//    快速：只查文件是否存在 + 大小（秒级，几百个文件）
//    完整：逐个算 SHA1（分钟级，但能发现内容损坏）
//
//  默认用快速档 —— 多数情况够用；怀疑损坏时让用户选完整档。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2IntegrityCheckMode) {
    A2IntegrityCheckModeQuick = 0,   ///< 存在 + 大小
    A2IntegrityCheckModeFull,        ///< 逐个 SHA1
};

/// 一个损坏/缺失的文件
@interface A2IntegrityIssue : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *kind;       ///< "客户端" / "依赖库" / "资源"
@property (nonatomic, copy) NSString *reason;     ///< "缺失" / "大小不符" / "SHA1 不符"
@property (nonatomic, copy, nullable) NSString *expectedSHA1;
@property (nonatomic, assign) long long expectedSize;
@end

/// 检查结果
@interface A2IntegrityReport : NSObject
@property (nonatomic, assign) NSInteger totalFiles;
@property (nonatomic, assign) NSInteger okFiles;
@property (nonatomic, copy) NSArray<A2IntegrityIssue *> *issues;
@property (nonatomic, assign) NSTimeInterval elapsed;
@property (nonatomic, readonly) BOOL clean;
@end

@interface A2IntegrityChecker : NSObject

/// 检查某个版本。
///
/// @param versionName 版本名
/// @param gameHome 游戏根目录
/// @param mode 检查强度
/// @param progress 进度回调（0~1，当前文件名）
/// @param completion 结果
- (void)checkVersion:(NSString *)versionName
            gameHome:(NSString *)gameHome
                mode:(A2IntegrityCheckMode)mode
            progress:(nullable void (^)(double progress, NSString *currentFile))progress
          completion:(void (^)(A2IntegrityReport *report))completion;

/// 修复：把所有问题文件删掉，让下次启动/下载时重新拉取。
/// 不直接下载 —— 下载逻辑在安装器里，避免两处重复实现。
/// @return 删除成功的文件数
- (NSInteger)repairReport:(A2IntegrityReport *)report;

@end

NS_ASSUME_NONNULL_END
