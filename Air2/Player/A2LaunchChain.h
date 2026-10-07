//
//  A2LaunchChain.h
//  Air2
//
//  Player —— 启动链【顺序编排】入口。
//
//  分层关系（见 docs/ARCHITECTURE.md 依赖方向 App → UI → Player → Core → Bridge → Natives）：
//    · 本类只表达【顺序】：① 先下发 JIT 脚本 → ② 再探测 JIT 可用 → ③ 再创建 JVM。
//    · 每一步「怎么做」由调用方以 block 注入；真机实现经 Bridge 落到
//      Natives/Support（A2JITEnvironment）与 Natives/Context（A2JVMContext），
//      Core/Version、Core/Path 提供已解析好的启动参数。
//    · 本类不感知版本 / 账号 / 下载，也【不 import Natives 头】—— 保持 Player 只编排、
//      不跨界（跨界只经 Bridge）。
//
//  与上层关系：UI（Screens/Home 的「启动游戏」按钮）→ Player（本类 run）→ 各步实现。
//  失败语义（对齐 [JIT-ORDER] / [JIT-P0.1]）：
//    · ① 下发脚本失败【不拦路】（下发本身是尽力而为，探测会再兜底）；
//    · ② 探测不合格【拦路】——绝不进 ③（否则 JVM 首帧 JIT 取指 SIGBUS）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

//  用 block 而非协议（protocol）：Air2 的静态检查 scripts/lint_objc.py 只看
//  「类声明数量 与 实现/结束标记 的配对」，协议声明会被误判为多余的结束标记。
//  故此处以注入 block 表达「三步」，不用协议。
//
/// ① 下发脚本：幂等下发自包含 JIT 脚本，返回是否成功（失败不拦路）。
typedef BOOL (^A2LaunchChainDeliverScriptBlock)(NSError *_Nullable *_Nullable error);

/// ② 探测 JIT：有界探测本次进程 JIT 真的可用否；返回 NO 则停止，reason 回填原因。
typedef BOOL (^A2LaunchChainVerifyBlock)(NSString *_Nullable *_Nullable reason);

/// ③ 创建 JVM。
typedef BOOL (^A2LaunchChainCreateVMBlock)(NSError *_Nullable *_Nullable error);

/// 启动链阶段（失败定位用）。
typedef NS_ENUM(NSInteger, A2LaunchChainStage) {
    A2LaunchChainStageIdle     = 0,
    A2LaunchChainStageScript   = 1,  ///< ① 下发脚本
    A2LaunchChainStageVerify   = 2,  ///< ② 探测 JIT
    A2LaunchChainStageCreateVM = 3,  ///< ③ 建 VM
    A2LaunchChainStageDone     = 4,  ///< 完成
};

/// 启动链顺序编排器。
@interface A2LaunchChain : NSObject

/// 当前/最近阶段（失败时指出停在哪一步）。
@property (nonatomic, readonly) A2LaunchChainStage stage;

/// 失败原因（可读；成功为空串）。
@property (nonatomic, readonly, copy) NSString *failureReason;

/// 构造：注入三步实现。
+ (instancetype)chainWithDeliverScript:(A2LaunchChainDeliverScriptBlock)deliver
                                verify:(A2LaunchChainVerifyBlock)verify
                             createJVM:(A2LaunchChainCreateVMBlock)createJVM;

/// 依次执行 ①→②→③。返回 YES = 全链成功。
- (BOOL)runWithError:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
