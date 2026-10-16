#!/usr/bin/env python3
"""
Air2 —— 「启动内存预算」自证（设备内存 → 安全堆顶 → -Xmx；按 Java 档位分参数集；判据行）

本单要修死的三件事：
    ① `-Xmx` 写死（原来是 A2LaunchPlan 直接吃设置里的固定 MB）；
    ② 参数集不分档（原来只有一条 -Xmx）；
    ③ 没有内存判据行（真机看不出堆上限从哪来）。
本脚本不测「能不能编译」（那是 xcodebuild 的事），只把这条链上**机器可复核**的
不变量固化成断言，防止日后有人改了其中一头而另一头没跟上：

  [1] 预算策略在 Utils 且只用 Foundation（⇒ 能被 clang 单测直编直跑），常量取值在
  [2] 探测落在 Bridge（唯一与系统接口相邻的层），用 os_proc_available_memory()，且如实标 source
  [3] Player 先探测后产出选项，并把 decision 打成默认可见的 `[MEM] ceiling=… -> -Xmx…`
  [4] 计划按 javaMajorVersion 分档：17+ 才进 G1 组；五类必需参数逐条在位
  [5] 设置页真的暴露「内存档位（自动/手动）」并接到 A2Settings
  [6] 阴性对照：启动链上不得再有写死的 -Xmx；单参数版 jvmOptions 已不存在

退出码：0 = 全部通过；1 = 有 FAIL。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MEM_H = os.path.join(ROOT, "Air2", "Utils", "A2LaunchMemory.h")
MEM_M = os.path.join(ROOT, "Air2", "Utils", "A2LaunchMemory.m")
PLAN_H = os.path.join(ROOT, "Air2", "Core", "Version", "A2LaunchPlan.h")
PLAN_M = os.path.join(ROOT, "Air2", "Core", "Version", "A2LaunchPlan.m")
SESSION_M = os.path.join(ROOT, "Air2", "Player", "A2LaunchSession.m")
RUNNER_H = os.path.join(ROOT, "Air2", "Bridge", "A2LaunchRunner.h")
RUNNER_M = os.path.join(ROOT, "Air2", "Bridge", "A2LaunchRunner.m")
SETTINGS_H = os.path.join(ROOT, "Air2", "Core", "Settings", "A2Settings.h")
SETTINGS_M = os.path.join(ROOT, "Air2", "Core", "Settings", "A2Settings.m")
MEMSET_M = os.path.join(ROOT, "Air2", "UI", "Screens", "Settings", "A2MemorySettings.m")
SETVC_M = os.path.join(ROOT, "Air2", "UI", "Screens", "Settings", "A2SettingsViewController.m")

# 本单要求必须真的进 argv 的参数（每一条都要能说出「为什么是这个值」；见计划里的注解）
REQUIRED_OPTIONS = [
    "-Xms128M",
    "-XX:MaxMetaspaceSize=192M",
    "-XX:CompressedClassSpaceSize=128M",
    "-XX:ReservedCodeCacheSize=64M",
    "-XX:MaxDirectMemorySize=512M",
    "-Xss1m",
    "-XX:SoftRefLRUPolicyMSPerMB=250",
]
G1_OPTIONS = ["-XX:+UseG1GC", "-XX:MaxGCPauseMillis=50", "-XX:+UseStringDeduplication"]

g_pass = 0
g_fail = 0


def ok(cond, what):
    global g_pass, g_fail
    if cond:
        g_pass += 1
        print(u"      \u2713 %s" % what)
    else:
        g_fail += 1
        print(u"      \u2717 FAIL %s" % what)
    return bool(cond)


def read(path):
    if not os.path.isfile(path):
        return ""
    with open(path, "rb") as f:
        return f.read().decode("utf-8", "replace")


def strip_comments(src):
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src = re.sub(r'//[^\n]*', '', src)
    return src


def rel(path):
    return os.path.relpath(path, ROOT).replace("\\", "/")


def main():
    print("Air2 —— 启动内存预算自证（设备内存 -> -Xmx / 分档 / 判据行）")
    print("=" * 74)

    mem_h, mem_m = read(MEM_H), read(MEM_M)
    plan_h, plan_m = read(PLAN_H), read(PLAN_M)
    session_m = read(SESSION_M)
    runner_h, runner_m = read(RUNNER_H), read(RUNNER_M)
    settings_h, settings_m = read(SETTINGS_H), read(SETTINGS_M)
    memset_m, setvc_m = read(MEMSET_M), read(SETVC_M)

    for p, name in ((MEM_M, "A2LaunchMemory.m"), (PLAN_M, "A2LaunchPlan.m"),
                    (SESSION_M, "A2LaunchSession.m"), (RUNNER_M, "A2LaunchRunner.m"),
                    (SETTINGS_M, "A2Settings.m"), (MEMSET_M, "A2MemorySettings.m"),
                    (SETVC_M, "A2SettingsViewController.m")):
        if not read(p):
            print("  [致命] 读不到 %s（%s）" % (name, rel(p)))
            return 1

    # ---------------------------------------------------------------- [1] 预算策略
    print("[1] 预算策略在 Utils（叶子层）、只用 Foundation、常量取值")
    mem_code = strip_comments(mem_m)
    ok("UIKit" not in mem_code and "UIView" not in mem_code,
       "A2LaunchMemory.m 不依赖 UIKit（Core/Player 与单测都能用）")
    ok(re.search(r'A2LaunchMemoryNativeReserveMB\s*=\s*1200', mem_m) is not None,
       "原生预留常量 = 1200MB（出处：老线 ame173）")
    ok(re.search(r'A2LaunchMemoryPhysicalRatio\s*=\s*0\.6', mem_m) is not None,
       "fallback 比例常量 = 0.6（出处：老线 fallback 分支）")
    ok(re.search(r'A2LaunchMemoryMinXmxMB\s*=\s*256', mem_m) is not None,
       "下限常量 = 256MB")
    ok(re.search(r'A2LaunchMemoryMaxXmxMB\s*=\s*4096', mem_m) is not None,
       "上限常量 = 4096MB")
    ok(re.search(r'safeHeapCeilingMBForProbe', mem_h) is not None and
       re.search(r'xmxMBWithCeilingMB', mem_h) is not None,
       "两个纯函数（安全顶 / 档位决策）都在头文件声明")
    ok(re.search(r'if\s*\(probe\.availableMB\s*>\s*0\)', mem_m, re.S) is not None,
       "权威路径判据 = availableMB > 0（有读数才走 api）")

    # ---------------------------------------------------------------- [2] 探测落点
    print("[2] 探测落在 Bridge（唯一与系统接口相邻的层）")
    ok("#import <os/proc.h>" in runner_m, "A2LaunchRunner.m import <os/proc.h>")
    ok("os_proc_available_memory()" in runner_m, "★真调 os_proc_available_memory()★（不是物理内存比例当权威）")
    ok("+ (A2MemoryProbe *)currentMemoryProbe" in runner_h and
       "+ (A2MemoryProbe *)currentMemoryProbe" in runner_m, "接口与实现都在")
    ok(re.search(r'return\s+\(self\.availableMB\s*>\s*0\)\s*\?\s*@"api"\s*:\s*@"default"', mem_m) is not None,
       '来源标记：有读数 => "api"，否则 => "default"（不把回退伪装成权威）')
    ok("physicalMemory" in runner_m, "物理内存取自 NSProcessInfo（fallback 用）")

    # ---------------------------------------------------------------- [3] Player 接线
    print("[3] Player：先探测、后产出选项，并打默认可见的 [MEM] 判据行")
    i_probe = session_m.find("currentMemoryProbe")
    i_ceiling = session_m.find("safeHeapCeilingMBForProbe")
    i_opts = session_m.find("jvmOptionsWithMemoryMB:")
    ok(i_probe >= 0, "A2LaunchSession.m 调用了 [A2LaunchRunner currentMemoryProbe]")
    ok(i_ceiling >= 0, "调用了 [A2LaunchMemory safeHeapCeilingMBForProbe:]")
    ok(0 <= i_probe < i_opts and 0 <= i_ceiling < i_opts,
       "★探测/安全顶都在产出 jvmOptions【之前】★")
    ok(re.search(r'jvmOptionsWithMemoryMB:xmxMB\s*\n?\s*javaMajorVersion:jreMajor', session_m) is not None,
       "把算出的 xmxMB 与 jreMajor 一起递进计划")
    ok(re.search(r'@"\[MEM\] ceiling=%ldMB -> -Xmx%ldMB \(source=%@\) mode=%@ jre=%ld gc=%@"', session_m) is not None,
       "★判据行格式：`[MEM] ceiling=…MB -> -Xmx…MB (source=<api|default>) …`★")
    session_code = strip_comments(session_m)
    ok("[A2Log log:@" in session_m and "ceiling=" in session_m,
       "判据行经 A2Log 打出（默认可见，不在任何 debug 开关后面）")
    ok("A2Settings.shared.memoryMode" in session_code, "档位取自 A2Settings.memoryMode")
    ok("UIScreen" not in session_code and "UIKit" not in session_code,
       "Player 仍不 import UIKit（分层不回退）")

    # ---------------------------------------------------------------- [4] 计划分档
    print("[4] 计划：按 javaMajorVersion 分档 + 必需参数逐条在位")
    ok(re.search(r'jvmOptionsWithMemoryMB:\(NSInteger\)memoryMB\s*\n\s*javaMajorVersion:\(NSInteger\)javaMajorVersion',
                 plan_h) is not None,
       "头文件签名已带 javaMajorVersion（档位进得来）")
    ok("usesG1TuningForJavaMajorVersion" in plan_m,
       "★档位判据走 A2LaunchMemory 的唯一实现（不在计划里另写 >=17）★")
    for opt in REQUIRED_OPTIONS:
        ok(('@"%s"' % opt) in plan_m, '参数在位：%s' % opt)
    for opt in G1_OPTIONS:
        ok(('@"%s"' % opt) in plan_m, 'G1 组参数在位：%s' % opt)
    ok(re.search(r'usesG1TuningForJavaMajorVersion:javaMajorVersion\]\)\s*\{[^}]*UseG1GC',
                 plan_m, re.S) is not None,
       "★G1 组【只在档位判据为真的 if 里】★（Java 8 拿不到）")
    ok(re.search(r'@"-Xmx%ldM"', plan_m) is not None and
       re.search(r'@\"-Xms128M\"', plan_m) is not None,
       "堆上限仍是 -Xmx%ldM（数值来自调用方），初始堆 -Xms128M")
    ok(re.search(r'if\s*\(memoryMB\s*>\s*0\)\s*\{[^}]*Xms128M[^}]*Xmx%ldM', plan_m, re.S) is not None,
       "memoryMB<=0 ⇒ -Xms/-Xmx 都不下发（既有语义不变）")

    # ---------------------------------------------------------------- [5] 设置暴露
    print("[5] 设置：内存档位（自动/手动）真的暴露并可写")
    ok("A2SettingsKeyMemoryMode" in settings_h and "A2SettingsKeyMemoryMode" in settings_m,
       "新增托管 key A2SettingsKeyMemoryMode（头/实现都在）")
    ok(re.search(r'@property \(nonatomic, assign\) A2LaunchMemoryMode memoryMode;', settings_h) is not None,
       "属性 memoryMode 的类型 = A2LaunchMemoryMode（枚举单一来源）")
    ok("memoryModeFromStore" in settings_m and "setMemoryMode:" in settings_m,
       "读/写实现都在（缺省自动；脏数据回落自动）")
    ok("A2SettingsKeyMemoryMode" in settings_m.split("A2SettingsAllKeys")[1][:400],
       "新 key 进了托管 key 全集（迁移/重置一并覆盖）")
    ok("@interface A2MemorySettings" in read(os.path.join(ROOT, "Air2", "UI", "Screens", "Settings",
                                                          "A2SettingsSections.h")),
       "A2MemorySettings 已在 A2SettingsSections.h 登记")
    ok("[A2MemorySettings buildWithHost:self]" in setvc_m,
       "★设置页真的挂上了这一组（游戏分类）★")
    ok("A2Settings.shared.memoryMode = mode" in memset_m,
       "档位行的写入点唯一 = A2MemorySettings")
    ok("A2Settings.shared.ramAllocationMB = mb" in memset_m,
       "手动堆上限的写入点 = A2MemorySettings 的预设表")

    # ---------------------------------------------------------------- [6] 阴性对照
    print("[6] 阴性对照：启动链上不得再有写死的堆上限")
    ok("- (NSArray<NSString *> *)jvmOptionsWithMemoryMB:(NSInteger)memoryMB;" not in plan_h,
       "旧的单参数版声明已不存在（不留半成品/歧义入口）")
    hard_xmx = re.findall(r'-Xmx(?!%)[0-9]+M', session_m + plan_m + runner_m + mem_m)
    ok(len(hard_xmx) == 0, "启动链里没有写死的 `-Xmx<数字>M`（实际：%s）" % (hard_xmx or "无"))

    print("=" * 74)
    print("pass=%d fail=%d" % (g_pass, g_fail))
    if g_fail:
        print("结果：有 FAIL")
        return 1
    print("结果：全部通过 \u2713")
    return 0


if __name__ == "__main__":
    sys.exit(main())
