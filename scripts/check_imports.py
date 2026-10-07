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




def strip_comments(src):
    """去掉注释，避免注释里的方法名干扰判断"""
    import re
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src = re.sub(r'//[^\n]*', '', src)
    return src


def extract_methods(src, only_impl):
    """
    提取方法的基本名（用于声明/实现比对）。

    关键：ObjC 的方法声明经常跨行写，例如
        - (BOOL)renameVersion:(A2Version *)version
                           to:(NSString *)newName
                        error:(NSError **)error;
    所以不能按行匹配，要先把整个签名拼起来。
    比对时只用「方法首段」，例如 renameVersion: —— 参数名差异不影响。
    """
    import re
    names = set()

    # 先剔除 @protocol ... @end 段 ——
    # 协议里的方法是「要求别人实现」的，不该要求本类实现。
    src = re.sub(r'@protocol\b.*?@end', '', src, flags=re.S)

    # 匹配 - 或 + 开头，直到遇到 ; 或 { （即一个完整签名）
    # 用 DOTALL 让换行也在其中
    for m in re.finditer(r'^[ \t]*([-+])[ \t]*\(([^)]*)\)(.*?)(?=[;{])',
                         src, re.M | re.S):
        body = m.group(3)
        # 从签名体里取第一个标识符 + 后续连续的 :(type)name 对
        head = re.match(r'\s*([A-Za-z_]\w*)', body)
        if not head:
            continue
        base = head.group(1)

        # 判断有没有参数（看这段签名里是否有冒号）
        if ':' in body:
            names.add(base + ':')
        else:
            names.add(base)

    return names


def check_declarations_vs_implementation():
    """比对每个 .h/.m 对的方法声明"""
    import os
    ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    issues = []

    for dirpath, _, files in os.walk(os.path.join(ROOT, "Air2")):
        for f in files:
            if not f.endswith(".m"):
                continue
            m_path = os.path.join(dirpath, f)
            h_path = m_path[:-2] + ".h"
            if not os.path.exists(h_path):
                continue

            h_src = strip_comments(open(h_path).read())
            m_src = strip_comments(open(m_path).read())

            # 取本文件的【所有】@implementation 段，
            # 再加上同名的分类文件（Xxx+Category.m）——
            # 分类里也常有本类的方法实现。
            sources = [m_src]

            base = m_path[:-2]           # 去掉 .m
            for extra in os.listdir(dirpath):
                if not extra.endswith(".m"):
                    continue
                if not extra.startswith(os.path.basename(base) + "+"):
                    continue
                try:
                    sources.append(open(os.path.join(dirpath, extra)).read())
                except OSError:
                    pass

            impl_src = ""
            for s_src in sources:
                chunks = re.findall(r'@implementation\b(.*?)@end', s_src, re.S)
                impl_src += "\n".join(chunks) + "\n"
            if not impl_src.strip():
                continue

            declared = extract_methods(h_src, False)
            implemented = extract_methods(impl_src, True)

            # 声明了但没实现
            for name in sorted(declared - implemented):
                # 跳过属性生成的 setter/getter（名称里有大写开头且无冒号）
                if not name.endswith(":") and name[0].isupper():
                    continue
                issues.append(f"{os.path.relpath(h_path, ROOT)} 声明了 {name} 但 {f} 未实现")

    return issues


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

    # ---------- 头文件声明 vs 实现 一致性 ----------
    # 这个错误反复出现：改了 .m 忘了 .h（调用方报 no visible @interface），
    # 或改了 .h 忘了 .m（链接期报 unrecognized selector）。
    # 两者都能提前静态发现。
    decl_issues = check_declarations_vs_implementation()
    if decl_issues:
        print(f"\n发现 {len(decl_issues)} 处声明与实现不一致：")
        for msg in decl_issues:
            print(f"  {msg}")
        return 1

    print("✓ 头文件声明与实现一致")
    return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
