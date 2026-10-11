// ============================================================================
// Natives/Support/utils.h
// ★ Air2 最小兼容桩（COMPAT STUB）—— 仅供 Natives 启动链编译期解析 ★
// ----------------------------------------------------------------------------
// 来源：Amethyst 线 `Natives/utils.h`（57 KiB：UIKit + 私有 API + 大量 JIT 取证实现）。
// Air2 在 P1 阶段搬入 `a2_failbanner.[hm]`，其头文件 `#import "utils.h"` 只为拿到
// 「JIT 取证分类」这一个枚举（见 Amethyst utils.h L294–L308）。JIT 取证真实现
// （brk #0x69 区域探测 / [JIT-P0.x] 判据主体）尚未搬入 Air2 ⇒ 此处只给【最小声明】。
//
// ⇒ 待 JIT 取证层落地 Air2（Natives/Support）后，用真 utils.h 替换本桩；
//    或让 a2_failbanner 改引 A2JITEnvironment.h 的等价枚举（同源搬运，值一致）。
// ============================================================================
#ifndef A2_COMPAT_UTILS_H
#define A2_COMPAT_UTILS_H

#import <Foundation/Foundation.h>

/// brk #0x69 区域判定的分类（取值与 Amethyst utils.h L294 逐项一致）。
typedef NS_ENUM(NSInteger, AMEJITRegionVerdict) {
    AMEJITRegionVerdictUnknown        = 0,  // 尚未探测
    AMEJITRegionVerdictUsable         = 1,  // 可用（非哨兵 + mapped=1 + size>0 + max 含 X）
    AMEJITRegionVerdictNotServiced    = 2,  // brk #0x69 无人服务（返回 NULL）
    AMEJITRegionVerdictLegacySentinel = 3,  // 回 legacy 哨兵 0xE0000069 ⇒ 需指派 Universal JIT 脚本
    AMEJITRegionVerdictNoMapping      = 4,  // 有返回值但该地址在进程内无映射
    AMEJITRegionVerdictZeroSize       = 5,  // 区域 size=0
    AMEJITRegionVerdictNotExecutable  = 6,  // max_protection 不含 EXECUTE
};

#endif /* A2_COMPAT_UTILS_H */
