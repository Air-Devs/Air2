//
//  A2MemorySettings.h
//  Air2
//
//  JVM 内存分配 —— 对照 ZL2 的 MemorySettings。
//
//  ## 为什么需要
//
//  Minecraft 的默认堆（-Xmx）按「系统内存的 1/4」自动算，
//  而 iOS 上进程可用内存远小于设备总内存：
//
//    iPhone 8    2GB 设备 → 进程上限约 1.4GB
//    iPhone X    3GB 设备 → 进程上限约 1.8GB
//    iPhone 12+  4~6GB    → 进程上限 2~3GB
//
//  自动分配很容易撞上 jetsam 被系统杀掉（表现为「进游戏几秒后闪退，
//  没有任何错误日志」）。所以必须让用户能调。
//
//  ## ZL2 的做法
//
//  两档：
//    自动 —— 用户只调一个百分比（默认 50%），
//            实际堆 = min(设备内存 × 百分比, 进程上限 × 0.8)
//    手动 —— 直接指定 MB，上限 = 进程上限
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2MemoryMode) {
    A2MemoryModeAuto = 0,   ///< 按百分比自动算
    A2MemoryModeManual,     ///< 用户指定 MB
};

extern NSNotificationName const A2MemorySettingsDidChangeNotification;

@interface A2MemorySettings : NSObject

+ (instancetype)shared;

/// 模式
@property (nonatomic, assign) A2MemoryMode mode;

/// 自动模式：百分比（0.2 ~ 0.8），默认 0.5
@property (nonatomic, assign) CGFloat ratio;

/// 手动模式：堆大小 MB
@property (nonatomic, assign) NSInteger manualMB;

/// 设备物理内存（MB）
@property (nonatomic, readonly) NSInteger deviceMemoryMB;

/// 进程可用上限（MB）—— jetsam 阈值，保守估计
@property (nonatomic, readonly) NSInteger processLimitMB;

/// 最终生效的堆大小（MB）
@property (nonatomic, readonly) NSInteger effectiveHeapMB;

/// 生成 JVM 参数：@"-Xmx2048m"
@property (nonatomic, readonly) NSString *jvmHeapArgument;

/// 保存并广播变化
- (void)commit;

@end

NS_ASSUME_NONNULL_END
