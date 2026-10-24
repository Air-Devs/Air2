//
//  A2MemorySettings.m
//  Air2
//

#import "A2MemorySettings.h"
#import "A2Logger.h"
#import <os/proc.h>

NSNotificationName const A2MemorySettingsDidChangeNotification = @"A2MemorySettingsDidChangeNotification";

static NSString *const kModeKey   = @"A2MemoryMode";
static NSString *const kRatioKey  = @"A2MemoryRatio";
static NSString *const kManualKey = @"A2MemoryManualMB";

@implementation A2MemorySettings

+ (instancetype)shared {
    static A2MemorySettings *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2MemorySettings alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _mode = A2MemoryModeAuto;
    _ratio = 0.5;
    _manualMB = 1024;
    [self load];
    return self;
}

#pragma mark - 设备内存

- (NSInteger)deviceMemoryMB {
    // NSProcessInfo.physicalMemory 是设备总内存（字节）
    return (NSInteger)(NSProcessInfo.processInfo.physicalMemory / (1024 * 1024));
}

/// 进程可用上限 —— iOS 的 jetsam 阈值。
///
/// 官方没公开这个值，用经验表（与 Air1 的 launcher 一致）：
/// 取设备内存的约 70%，再按档位钳制。
/// 宁可保守 —— 撞上 jetsam 是「无日志闪退」，比 OOM 更难查。
- (NSInteger)processLimitMB {
    NSInteger total = self.deviceMemoryMB;

    if (total <= 2048)  return (NSInteger)(total * 0.68);   // 2GB → ~1390
    if (total <= 3072)  return (NSInteger)(total * 0.60);   // 3GB → ~1840
    if (total <= 4096)  return (NSInteger)(total * 0.58);   // 4GB → ~2370
    return (NSInteger)MIN(3072, total * 0.50);              // 6GB+ → 3072 上限
}

#pragma mark - 计算

- (NSInteger)effectiveHeapMB {
    NSInteger limit = self.processLimitMB;

    if (self.mode == A2MemoryModeManual) {
        // 手动模式也要钳到进程上限以内 —— 否则用户填 8GB 会直接闪退
        return MAX(256, MIN(self.manualMB, (NSInteger)(limit * 0.9)));
    }

    // 自动：设备内存 × 百分比，且不超过进程上限的 80%
    // （留 20% 给原生层：GL 缓冲、音频、资源索引）
    NSInteger byRatio = (NSInteger)(self.deviceMemoryMB * MAX(0.2, MIN(0.8, self.ratio)));
    return MAX(512, MIN(byRatio, (NSInteger)(limit * 0.8)));
}

- (NSString *)jvmHeapArgument {
    return [NSString stringWithFormat:@"-Xmx%ldm", (long)self.effectiveHeapMB];
}

#pragma mark - 持久化

- (void)load {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:kModeKey]) {
        _mode = (A2MemoryMode)[d integerForKey:kModeKey];
    }
    if ([d objectForKey:kRatioKey]) {
        _ratio = [d floatForKey:kRatioKey];
    }
    if ([d objectForKey:kManualKey]) {
        _manualMB = [d integerForKey:kManualKey];
    }
}

- (void)commit {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:self.mode forKey:kModeKey];
    [d setFloat:self.ratio forKey:kRatioKey];
    [d setInteger:self.manualMB forKey:kManualKey];

    [A2Logger info:@"MemorySettings"
           message:[NSString stringWithFormat:
                    @"内存设置：模式=%@ 生效=%ldMB（设备 %ldMB，进程上限 %ldMB）",
                    self.mode == A2MemoryModeAuto ? @"自动" : @"手动",
                    (long)self.effectiveHeapMB,
                    (long)self.deviceMemoryMB,
                    (long)self.processLimitMB]];

    [NSNotificationCenter.defaultCenter postNotificationName:A2MemorySettingsDidChangeNotification
                                                      object:nil];
}

@end
