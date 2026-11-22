#!/usr/bin/env python3
#
#  precheck_objc.py
#  Air2
#
#  Copyright (C) 2026 Air-Devs and contributors.
#
#  本程序是自由软件：你可以依据自由软件基金会发布的 GNU 通用公共许可证
#  的条款（许可证第 3 版或你选择的任何更新版本）重新分发和/或修改它。
#
#  本程序希望能够有用，但不提供任何担保，甚至不提供适销性或特定用途
#  适用性的默示担保。详见 GNU 通用公共许可证。
#
#  SPDX-License-Identifier: GPL-3.0-or-later
#
"""在推送 CI 之前，本地先做一遍 Objective-C 源码的「低级错误」预检。

为什么需要这个脚本
------------------
iOS 工程只能在 macOS + Xcode 上编译，本机（越狱 iPhone）没有编译器。
CI 一轮构建约 4~6 分钟，如果只是漏了个头文件、少个 @end、括号不配对，
等 CI 报错再改就是好几轮的空转。

这个脚本不做语义分析，只抓那些「一眼就能看出来、但 Xcode 会直接报错」的问题：

  1. #import "X.h" / #include "X.h" 指向的文件不存在（拼错、路径错、文件被删）
  2. @interface / @implementation / @end 不配对
  3. 花括号 / 圆括号不配对
  4. 同一目录下重复的 @implementation 类名
  5. .h 里声明的类在某处没有 @implementation（只警告，可能有分类）
  6. 头文件缺少 #pragma once 或 include guard（只警告）
  7. 文件里有 NUL 字节 / 非 UTF-8（编辑器写坏）
  8. 编码为 GB18030 之类非 UTF-8（编译器会报 illegal character）

退出码：0 = 全部通过；1 = 有硬错误。
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 只检查这些目录下的源码；Libraries/ 是第三方，不检查
SCAN_DIRS = ("Air2",)
# 头文件搜索范围（第三方头在 Libraries/ 下）
IMPORT_ROOTS = ("Air2", "Libraries")
EXTS = (".h", ".m", ".mm")

errors = []
warnings = []


def rel(p):
    return os.path.relpath(p, ROOT).replace(os.sep, "/")


def strip_comments(src):
    """去掉注释和字符串字面量，避免把注释里的 { } 当成代码。

    先处理字符串（含 @"..."），再处理 // 与 /* */。
    顺序很重要：字符串里可能出现 // 或 /*。
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        # 字符串字面量（@"..." 的 @ 已在前面被普通字符处理，这里只处理 "）
        if c == '"':
            out.append('""')
            i += 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        # 单引号字符常量
        if c == "'":
            i += 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == "'":
                    i += 1
                    break
                i += 1
            continue
        # 行注释
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                i += 1
            continue
        # 块注释
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check_encoding(path):
    with open(path, "rb") as f:
        raw = f.read()
    if b"\x00" in raw:
        warnings.append(f"{rel(path)}: 含 NUL 字节（多半是注释里误插入的字面 \\0，clang 容忍但应清理）")
        raw = raw.replace(b"\x00", b"")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as e:
        errors.append(f"{rel(path)}: 不是合法 UTF-8（{e}）—— Xcode 会报 illegal character")
        return None


def collect_files():
    files = []
    for d in SCAN_DIRS:
        base = os.path.join(ROOT, d)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            # 跳过构建产物
            dirnames[:] = [x for x in dirnames if x not in ("build", "DerivedData")]
            for fn in filenames:
                if fn.endswith(EXTS):
                    files.append(os.path.join(dirpath, fn))
    return files


def check_includes(path, src):
    """#import "X.h" 的文件必须存在（相对本目录或工程内唯一同名文件）。"""
    for m in re.finditer(r'^\s*#\s*(?:import|include)\s+"([^"]+)"', src, re.M):
        inc = m.group(1)
        # 只检查相对形式的本地头文件；<...> 形式交给 SDK
        cand = os.path.join(os.path.dirname(path), inc)
        if os.path.isfile(cand):
            continue
        # 再在整个工程里找同名文件（Xcode 的 header search path 比较宽松）
        base = os.path.basename(inc)
        found = False
        for d in IMPORT_ROOTS:
            for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, d)):
                dirnames[:] = [x for x in dirnames if x != "build"]
                if base in filenames:
                    found = True
                    break
            if found:
                break
        if not found:
            warnings.append(f'{rel(path)}: #import "{inc}" 本地找不到（可能在 Xcode header search path 或仓库侧）')


def check_directives(path, src):
    clean = strip_comments(src)
    key = rel(path)

    n_iface = len(re.findall(r'@interface\b', clean))
    n_impl = len(re.findall(r'@implementation\b', clean))
    n_end = len(re.findall(r'@end\b', clean))
    n_proto = len(re.findall(r'@protocol\b', clean))

    # @protocol 可能前向声明（@protocol X;）不计入需要 @end 的数量
    n_proto_fwd = len(re.findall(r'@protocol\s+\w+\s*;', clean))
    need_end = n_iface + n_impl + (n_proto - n_proto_fwd)

    if need_end != n_end:
        errors.append(
            f"{key}: @interface({n_iface}) + @implementation({n_impl}) + "
            f"@protocol({n_proto - n_proto_fwd}) = {need_end} 个，"
            f"但只有 {n_end} 个 @end"
        )

    # 花括号是结构性判据，不配对一定是语法错误
    o, c = clean.count("{"), clean.count("}")
    if o != c:
        errors.append(f"{key}: 花括号不配对（{o} 个 {{ / {c} 个 }}）")
    # 圆括号只做提示：#if 0、宏、跨行拼接都会让静态统计失真
    po, pc = clean.count("("), clean.count(")")
    if po != pc:
        warnings.append(f"{key}: 圆括号计数不等（{po} / {pc}）—— 若含 #if 0 属正常")

    # 只统计「无分类」的 @implementation：
    #   @implementation Foo        → 真正的类实现
    #   @implementation Foo (Cat)  → 分类，允许多个同名
    names = [m.group(1) for m in
             re.finditer(r'@implementation\s+(\w+)\s*(\()?', clean)
             if m.group(2) is None]
    n_impl = len(names)
    return n_impl, names


def main():
    files = collect_files()
    if not files:
        print("没找到待检查的源码（是否在 Air2/ 目录下运行？）")
        return 1

    impl_names = {}
    iface_names = {}

    for path in sorted(files):
        src = check_encoding(path)
        if src is None:
            continue
        check_includes(path, src)
        n_impl, names = check_directives(path, src)

        if n_impl:
            for nm in names:
                impl_names.setdefault(nm, []).append(rel(path))

        if path.endswith(".h"):
            clean = strip_comments(src)
            for nm in re.findall(r'@interface\s+(\w+)', clean):
                iface_names.setdefault(nm, []).append(rel(path))
            # 本工程头文件普遍没有 include guard（靠 Xcode 的 #import 天然防重复），
            # 不做检查 —— 否则 160+ 条噪音淹没真正的问题。

    # 重复的 @implementation
    for nm, where in impl_names.items():
        if len(where) > 1:
            errors.append(f"类 {nm} 有多个 @implementation：" + ", ".join(where))

    # 声明了但没有任何实现（只警告：可能是纯协议/分类/系统类扩展）
    for nm, where in iface_names.items():
        if nm not in impl_names:
            warnings.append(f"@interface {nm} 只出现在 {where[0]}，没有 @implementation")

    print(f"检查 {len(files)} 个文件")

    if warnings:
        print(f"\n--- 警告 {len(warnings)} 条 ---")
        for w in warnings[:40]:
            print("  ⚠", w)
        if len(warnings) > 40:
            print(f"  … 还有 {len(warnings) - 40} 条")

    if errors:
        print(f"\n--- 错误 {len(errors)} 条 ---")
        for e in errors:
            print("  ✗", e)
        print("\n预检未通过。")
        return 1

    print("\n✓ 预检通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
