//
//  A2JITImportedPairingProvider.h
//  Air2
//
//  Player —— 取得路径 ②：【导入配对文件】（iOS 17.4+）。
//
//  语义（用户拍板 / ADR-009）：
//    · iOS 26：【内置手动】—— 导入配对文件 → 连 LocalDevVPN → 在本 App 内开启 JIT；
//    · iOS 17.4–25：导入配对文件后仍需【外部工具】完成开启（本 Provider 会返回未接入并让编排层降级）。
//
//  [JIT-IMPL-2] 本单把「占位」换成真实现：
//    · 就绪判定 = ★真的去容器里找 + 解析★配对文件（A2JITPairingFileStore），
//      不再只读 A2JITFacts 的布尔位；
//    · 开启 = ★真调判据内核★（经注入的 A2JITReadinessProbe，真机实现是
//      Bridge/A2JITEnvironmentProbe → Natives/Support/A2JITEnvironment 的
//      `ensureVerifiedWithinBudget:reason:`），按 A2JITRegionVerdict 如实判成败。
//    · ★仍不做★：ExtensionKit 内置 helper（XPC 附加调试器）本身 —— 那是下一阶段
//      （需 vendor StikJIT(MPL-2.0) / idevice(MIT)，见 JIT-PROVISIONING.md §4.1）。
//      所以本单在 iOS 26 上「真判据」会说真话：helper 未接时判 NotServiced，不假装成功。
//

#import <Foundation/Foundation.h>
#import "A2JITProvider.h"
#import "A2JITReadinessProbe.h"

@class A2JITFacts;
@class A2JITPairingFileStore;

NS_ASSUME_NONNULL_BEGIN

/// ② 导入配对文件（iOS 17.4+）。
@interface A2JITImportedPairingProvider : NSObject <A2JITProvider>

/// 注入本机环境事实（默认 store = A2JITPairingFileStore.defaultStore，probe = nil）。
- (instancetype)initWithFacts:(A2JITFacts *)facts;

/// ★装配用★：注入容器存储与判据内核（真机由 UI 装配处传 store + Bridge probe）。
- (instancetype)initWithFacts:(A2JITFacts *)facts
                        store:(A2JITPairingFileStore *)store
                        probe:(nullable id<A2JITReadinessProbe>)probe;

/// ★真调判据★：有界复验「本进程现在能不能用 JIT」，并回填取证文本。
/// @param evidenceOut 可读取证（可为 NULL 指针）。
- (BOOL)refreshReadinessWithBudget:(NSTimeInterval)budget
                          evidence:(NSString *_Nullable *_Nullable)evidenceOut;

/// 最近一次复验的区域判定（无 probe 时为 Unknown）。
@property (nonatomic, readonly) A2JITReadinessVerdict lastVerdict;
/// 最近一次复验的取证摘要（无则 nil）。
@property (nonatomic, readonly, copy, nullable) NSString *lastEvidence;
/// 当前已导入配对文件的路径（无则 nil）。
@property (nonatomic, readonly, copy, nullable) NSString *pairingFilePath;

@end

NS_ASSUME_NONNULL_END
