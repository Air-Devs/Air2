#pragma once

// ★ [VI-FLOW] B：版本隔离向导（每次进启动器都会再弹，直到用户主动选「以后不再提示」）。
//
// 采纳《_LAUNCHER_ISOLATION_SURVEY.md》§③ 建议 B（学 GDLauncher Carbon / Modrinth App 的
// onboarding，不学 HMCL-PE 的「改后请自行搬」）：
//   顶部【新功能提示】(现在可以给每个实例开版本隔离) + 列出现有实例 + 每个的目录形状嗅探结果
//   + 建议的隔离三态 ⇒ 一键批量【写设置】；底部另有「以后不再提示」动作行。
//
// 硬约束：
//   * ★ 只写设置（profile 的 versionIsolation 一个键），绝不移动 / 复制 / 删除任何文件；
//     文案明确「数据仍在原处，可随时改回」。
//   * 可跳过（左上角「跳过」= 关闭，什么都不写）——跳过 ≠ 以后不弹，下次仍会再出现。
//   * 「以后不再提示」才落哨兵 internal.version_isolation_wizard_off（幂等、只在用户选择时写一次），
//     之后不再【自动】弹；实例设置页的「版本隔离向导」手动入口不受哨兵约束，随时可再看。
//   * 不阻碍启动：本页是异步 present 的可关闭模态，启动路径不等待它。

#import <UIKit/UIKit.h>

@interface VersionIsolationWizardViewController : UIViewController
@end
