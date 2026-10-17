#!/usr/bin/env python3
"""
安装期批量下载的并发度解析（默认 6 / 上限 8 / 偏好覆盖 / 夹取）。

为什么是「源码断言 + 规则镜像」而不是真编译：
  被解析的那个函数（A2InstallEffectiveConcurrency）是 A2GameInstaller.m 里的
  static C 函数，而该翻译单元会把整条安装器依赖图（ModLoaderInstaller /
  DownloadEngine / VersionIsolation …）全拉进来，单独编译不可行。
  所以这里做两件事，缺一不可：
    1) **源码断言**：默认值 / 上限 / 偏好键名 / 夹取语句必须与下面镜像的规则一致
       —— 常量一漂移就红（这是「并发常量解析」真正要防的回归）；
    2) **规则镜像**：把「默认 ← 偏好覆盖 → 夹到 [1, 上限]」的解析规则逐例跑一遍。
  真实行为（下载真的按这个并发度并发）由 tests/Mirror 的接线断言 +
  真机日志里的 `[DL-CONC] 批量下载开始: N 个文件, 并发度=X` 承担。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INSTALLER = os.path.join(ROOT, "Air2", "Core", "Version", "A2GameInstaller.m")

# ---- 按源码读到的常量（下面的断言会证明它们真的在源码里）----
DEFAULT_CONCURRENCY = 6
MAX_CONCURRENCY = 8
PREF_KEY = "air2.install.concurrency"

failures = []


def check(name, got, want):
    ok = got == want
    print("  %s %s" % ("✓" if ok else "✗", name))
    if not ok:
        print("      got  = %r" % (got,))
        print("      want = %r" % (want,))
        failures.append(name)
    return ok


def effective(pref, default=DEFAULT_CONCURRENCY):
    """镜像 A2InstallEffectiveConcurrency()：默认 ← 偏好覆盖 → 夹到 [1, 上限]。

    与源码逐句对应：
        NSInteger n = kA2InstallDefaultConcurrency;
        if ([pref isKindOfClass:NSNumber.class]) n = pref.integerValue;
        if (n < 1) n = 1;
        if (n > kA2InstallMaxConcurrency) n = kA2InstallMaxConcurrency;
    """
    n = default
    if isinstance(pref, (int, float)) and not isinstance(pref, bool):
        n = int(pref)
    if n < 1:
        n = 1
    if n > MAX_CONCURRENCY:
        n = MAX_CONCURRENCY
    return n


def main():
    with open(INSTALLER, encoding="utf-8") as f:
        src = f.read()

    print("== ① 源码断言：并发常量与解析语句仍在（防漂移）==")
    check("默认并发常量 = 6",
          bool(re.search(r"kA2InstallDefaultConcurrency\s*=\s*6\s*;", src)), True)
    check("并发上限常量 = 8（本单未放开上限）",
          bool(re.search(r"kA2InstallMaxConcurrency\s*=\s*8\s*;", src)), True)
    check("偏好键 = air2.install.concurrency",
          ('@"%s"' % PREF_KEY) in src, True)
    check("默认值来自常量（不是字面量写死两处）",
          "NSInteger n = kA2InstallDefaultConcurrency;" in src, True)
    check("只认 NSNumber 类型的偏好（字符串/字典不吃）",
          "if ([pref isKindOfClass:NSNumber.class]) n = pref.integerValue;" in src, True)
    check("下限夹到 1",
          "if (n < 1) n = 1;" in src, True)
    check("上限夹到 kA2InstallMaxConcurrency",
          "if (n > kA2InstallMaxConcurrency) n = kA2InstallMaxConcurrency;" in src, True)
    check("默认值与上限的关系成立（6 <= 8）",
          DEFAULT_CONCURRENCY <= MAX_CONCURRENCY, True)

    print("\n== ② 规则镜像：默认 ← 偏好覆盖 → 夹到 [1, 8] ==")
    check("无偏好 → 默认 6", effective(None), 6)
    check("偏好 1 → 1（下限）", effective(1), 1)
    check("偏好 5 → 5", effective(5), 5)
    check("偏好 8 → 8（上限）", effective(8), 8)
    check("偏好 9 → 夹到 8", effective(9), 8)
    check("偏好 100 → 夹到 8", effective(100), 8)
    check("偏好 0 → 夹到 1", effective(0), 1)
    check("偏好 -3 → 夹到 1", effective(-3), 1)
    check("偏好是字符串 → 不用它，回落默认 6", effective("12"), 6)
    check("偏好是 None → 默认 6", effective(None), 6)

    print("\n== ③ 接线：这个并发度真的用在批量下载路径上 ==")
    check("批量下载读的是 A2InstallEffectiveConcurrency()",
          "NSInteger maxConcurrent = A2InstallEffectiveConcurrency();" in src, True)
    check("有界并发窗口用 maxConcurrent 补位（不是写死数字）",
          "while (inFlight < (NSUInteger)maxConcurrent && nextIndex < total)" in src, True)
    check("判据行打出本次并发度（真机可 grep）",
          "[DL-CONC] 批量下载开始" in src and "并发度=%ld" in src, True)
    check("★镜像链的候选展开也在同一下载入口（库/资源都吃候选链）★",
          "for (NSString *c in [self candidatesForURL:u])" in src, True)

    print("\n== ④ 阴性对照：断言不能恒真 ==")
    check("源码里没有 kA2InstallDefaultConcurrency = 3（旧值已改掉）",
          bool(re.search(r"kA2InstallDefaultConcurrency\s*=\s*3\s*;", src)), False)
    check("源码里没有 kA2InstallMaxConcurrency = 16（上限没有被偷偷放开）",
          bool(re.search(r"kA2InstallMaxConcurrency\s*=\s*16\s*;", src)), False)
    check("阴性对照：不存在的常量名扫不到",
          "kA2InstallDefaultConcurrencyNope" in src, False)

    print("\n" + "=" * 68)
    print("例数 = 25，失败 = %d" % len(failures))
    if failures:
        print("有失败项：%s" % ", ".join(failures))
        print("=" * 68)
        return 1
    print("全部通过")
    print("=" * 68)
    return 0


if __name__ == "__main__":
    sys.exit(main())
