//
//  A2GameLaunchCoordinator.h
//  Air2
//
//  启动编排器 —— 对照 ZL2 的「点启动 → 校验 → 补全 → 启动」流程。
//
//  ## 为什么需要单独一层
//
//  点「开始游戏」之后要做一串事，顺序不能错：
//
//      1. 完整性检查（缺什么）
//      2. 补下载（把缺的拉回来）
//      3. 再检查一次（确认补齐）
//      4. 准备 JRE（按 MC 版本选）
//      5. 应用分辨率
//      6. 拉起 JVM
//      7. 遮罩淡出，游戏接管
//
//  这些步骤散在 UI 里会很难维护 —— 任何一步失败都要能回退到
//  「让用户看到发生了什么」的状态。所以集中到编排器，
//  UI 只负责展示进度。
//
//  ## 与 ZL2 的差异
//
//  ZL2 用协程 + Task 系统串起来。iOS 上用完成回调链，
//  但**每个阶段都发通知**，UI 可以独立订阅。
//

#import <Foundation/Foundation.h>
#import "A2VersionManager.h"
#import "A2IntegrityChecker.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2LaunchPhase) {
    A2LaunchPhaseIdle = 0,
    A2LaunchPhaseChecking,      ///< 完整性检查
    A2LaunchPhaseRepairing,     ///< 补下载
    A2LaunchPhasePreparingJRE,  ///< 准备 JRE
    A2LaunchPhaseStarting,      ///< 拉起 JVM
    A2LaunchPhaseSuccess,
    A2LaunchPhaseFailed,
};

/// 启动进度
@interface A2LaunchProgress : NSObject
@property (nonatomic, assign) A2LaunchPhase phase;
@property (nonatomic, assign) double fraction;      ///< 0~1
@property (nonatomic, copy) NSString *message;
@end

/// 阶段变化通知（userInfo[@"progress"] = A2LaunchProgress）
extern NSNotificationName const A2LaunchProgressDidChangeNotification;

@interface A2GameLaunchCoordinator : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) A2LaunchPhase phase;
@property (nonatomic, readonly, getter=isLaunching) BOOL launching;

/// 启动某个版本。
///
/// 流程：完整性检查 → 补全 → 准备 JRE → 拉起 JVM
///
/// @param versionName 目标版本
/// @param skipCheck 跳过完整性检查（用户明确要求时）
/// @param completion 结果。失败时 error 里带具体原因
- (void)launchVersion:(NSString *)versionName
            skipCheck:(BOOL)skipCheck
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// 取消
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
