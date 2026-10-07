#!/usr/bin/env python3
"""
校验所有 #import "XXX.h" 的本地头文件是否真实存在。

这类错误在 Xcode 里表现为编译期 "'XXX.h' file not found"，
一个文件一个错误，来回推 CI 非常浪费时间。
本地一次全查出来。

规则：
  - #import "xxx.h"  是本地头文件，必须能在工程内找到
  - #import <xxx.h>  是系统/框架头文件，不检查
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_ROOT = os.path.join(ROOT, "Air2")

# 工程里所有头文件的 basename
available = set()
for dirpath, _, files in os.walk(SRC_ROOT):
    for f in files:
        if f.endswith(".h"):
            available.add(f)

# 也把系统框架的常见头文件排除掉（这些可能被写成 "xxx.h" 形式）
SYSTEM_LIKE = {
    "UIKit.h", "Foundation.h", "CoreGraphics.h", "QuartzCore.h",
    "CoreImage.h", "Photos.h", "PhotosUI.h", "AVFoundation.h",
    "MobileCoreServices.h", "UniformTypeIdentifiers.h",
}


def main():
    problems = []
    total_imports = 0

    for dirpath, _, files in os.walk(SRC_ROOT):
        for fname in sorted(files):
            if not fname.endswith((".m", ".mm", ".h")):
                continue
            path = os.path.join(dirpath, fname)
            rel = os.path.relpath(path, ROOT)
            try:
                lines = open(path, encoding="utf-8").read().split("\n")
            except UnicodeDecodeError:
                continue

            for lineno, line in enumerate(lines, 1):
                m = re.match(r'\s*#\s*import\s+"([^"]+)"', line)
                if not m:
                    continue
                inc = m.group(1)
                total_imports += 1
                base = os.path.basename(inc)
                if base in SYSTEM_LIKE:
                    continue
                if base not in available:
                    problems.append((rel, lineno, inc))

    print(f"检查了 {total_imports} 处本地 #import")
    print(f"工程内共有 {len(available)} 个头文件")

    if problems:
        print(f"\n发现 {len(problems)} 处引用了不存在的头文件：")
        for rel, lineno, inc in problems:
            print(f"  {rel}:{lineno}  →  \"{inc}\"")
        return 1

    print("✓ 所有本地 #import 都能找到对应头文件")
    return 0


if __name__ == "__main__":
    sys.exit(main())
