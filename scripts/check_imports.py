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




def check_property_readonly():
    """
    检查 .h 与 .m 里同名属性的修饰符是否冲突。

    规则：如果 .h 里的属性【没有】标 readonly，
    而 .m 的类扩展里又声明了同名属性，会报 illegal redeclaration。
    正确做法是 .h 标 readonly、.m 重声明为可写。
    """
    import os, re
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

            # 头文件里的属性 → 是否 readonly
            header_props = {}
            for pm in re.finditer(
                    r'@property\s*\(([^)]*)\)[^;]*?\b(\w+)\s*;', h_src):
                header_props[pm.group(2)] = 'readonly' in pm.group(1)

            # .m 的类扩展里的属性
            for em in re.finditer(r'@interface\s+\w+\s*\(\)(.*?)@end', m_src, re.S):
                ext = em.group(1)
                for pm in re.finditer(
                        r'@property\s*\(([^)]*)\)[^;]*?\b(\w+)\s*;', ext):
                    attrs, name = pm.group(1), pm.group(2)
                    if name not in header_props:
                        continue
                    header_readonly = header_props[name]
                    ext_readonly = 'readonly' in attrs

                    # 头文件可写 + 扩展也存在 = 重复声明
                    if not header_readonly and not ext_readonly:
                        issues.append(
                            f"{os.path.relpath(h_path, ROOT)} 的属性 {name} "
                            f"未标 readonly，但 {f} 的类扩展里又声明了一遍 "
                            f"→ 会报 illegal redeclaration。"
                            f"应把头文件标 readonly、扩展里重声明为可写")

    return issues




def check_color_scheme_alignment():
    """
    检查 A2ColorScheme 的头文件与实现是否字段对齐。
    """
    import os, re
    ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    issues = []

    h_path = os.path.join(ROOT, "Air2/UI/Theme/A2ColorScheme.h")
    m_path = os.path.join(ROOT, "Air2/UI/Theme/A2ColorScheme.m")
    if not (os.path.exists(h_path) and os.path.exists(m_path)):
        return issues

    h = open(h_path).read()
    m = open(m_path).read()

    declared = set(re.findall(r'UIColor \*(c[A-Z]\w+);', h))
    resolved = set(re.findall(r'A2RESOLVE\(\w+,\s*(c[A-Z]\w+)\)', m))

    for name in sorted(declared - resolved):
        issues.append(f"A2ColorScheme.h 声明了 {name} 但 .m 里没有对应的 A2RESOLVE")
    for name in sorted(resolved - declared):
        issues.append(f"A2ColorScheme.m 解析了 {name} 但 .h 里没有声明")

    # 原始 slot 与解析字段数量应一致
    slots = set(re.findall(r'A2ColorSlot \*(\w+);', h))
    if slots and declared and len(slots) != len(declared):
        issues.append(
            f"原始色槽 {len(slots)} 个 vs 解析字段 {len(declared)} 个，数量不匹配")

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

    # ---------- 属性修饰符跨文件一致性 ----------
    # 常见错误：头文件里 .h 声明了非 readonly 的属性，
    # 而 .m 的类扩展里又声明了一遍 —— 报 illegal redeclaration。
    # 或者反过来：头文件标 readonly 但 .m 扩展里没重声明为可写，
    # 导致内部无法赋值。
    prop_issues = check_property_readonly()
    if prop_issues:
        print(f"\n发现 {len(prop_issues)} 处属性修饰符问题：")
        for msg in prop_issues:
            print(f"  {msg}")
        return 1

    print("✓ 属性修饰符一致")

    # ---------- 色板字段对齐 ----------
    # A2ColorScheme 头文件声明的 cXxx 字段，必须在 .m 里都有对应的
    # A2RESOLVE 解析。缺一个就会在运行期取到 nil（界面变透明/黑块），
    # 而且编译器不报错。
    scheme_issues = check_color_scheme_alignment()
    if scheme_issues:
        print(f"\n发现 {len(scheme_issues)} 处色板字段未对齐：")
        for msg in scheme_issues:
            print(f"  {msg}")
        return 1

    print("✓ 色板字段对齐")
    return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
