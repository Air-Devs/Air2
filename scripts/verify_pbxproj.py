#!/usr/bin/env python3
"""
校验 pbxproj 的内部一致性。

没有 Xcode 的情况下，靠这个脚本抓出最常见的几类错误：
  1. 引用了未定义的 UUID
  2. 定义了但从未被引用的对象（说明文件没被加进工程）
  3. 源文件都在盘上但没进 Sources 阶段
  4. 括号/引号不平衡

pbxproj 是纯文本，这些都能静态查出来。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "Air2.xcodeproj", "project.pbxproj")


def main():
    if not os.path.exists(PBX):
        print(f"找不到 {PBX}")
        return 1

    src = open(PBX).read()
    errors = []
    warnings = []

    # ---------- 1. 括号平衡（先去掉字符串字面量） ----------
    stripped = re.sub(r'"(?:[^"\\]|\\.)*"', '""', src)
    stripped = re.sub(r'/\*.*?\*/', '', stripped, flags=re.S)
    depth = 0
    for ch in stripped:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth < 0:
                errors.append("花括号提前闭合")
                break
    if depth != 0:
        errors.append(f"花括号不平衡，差值 {depth}")
    else:
        print("✓ 花括号平衡")

    # 小括号（仅在 objects 段内检查意义不大，做粗略检查）
    if stripped.count("(") != stripped.count(")"):
        errors.append(f"圆括号不平衡: ( {stripped.count('(')} vs ) {stripped.count(')')}")
    else:
        print("✓ 圆括号平衡")

    # ---------- 2. UUID 定义与引用 ----------
    # 定义形如：\t\tUUID /* comment */ = {
    defined = set(re.findall(r'^\t\t([0-9A-F]{24})\s*(?:/\*.*?\*/)?\s*=', src, re.M))
    # 引用形如：UUID /* comment */,
    referenced = set(re.findall(r'\b([0-9A-F]{24})\b(?=\s*(?:/\*[^*]*\*/)?\s*[,;)])', src))

    print(f"✓ 定义了 {len(defined)} 个对象")

    dangling = referenced - defined
    if dangling:
        for u in sorted(dangling):
            errors.append(f"引用了未定义的 UUID: {u}")
    else:
        print("✓ 所有引用都有对应定义")

    orphans = defined - referenced
    # project 对象是 rootObject 引用的，单独看
    root_m = re.search(r'rootObject = ([0-9A-F]{24})', src)
    if root_m:
        orphans.discard(root_m.group(1))
    if orphans:
        for u in sorted(orphans):
            warnings.append(f"对象定义了但没人引用: {u}")
    else:
        print("✓ 无孤立对象")

    # ---------- 3. 源文件覆盖检查 ----------
    # 盘上所有 .m
    on_disk = []
    base = os.path.join(ROOT, "Air2")
    for dirpath, _, files in os.walk(base):
        for f in files:
            if f.endswith((".m", ".mm")):
                on_disk.append(os.path.relpath(os.path.join(dirpath, f), ROOT))
    on_disk = sorted(on_disk)

    # Sources 阶段里列出的
    src_phase = re.search(r'/\* Begin PBXSourcesBuildPhase section \*/(.*?)/\* End PBXSourcesBuildPhase section \*/', src, re.S)
    if not src_phase:
        errors.append("找不到 PBXSourcesBuildPhase")
        compiled = set()
    else:
        # buildFile UUID 列表
        bf_ids = re.findall(r'([0-9A-F]{24})\s*/\*[^*]*in Sources \*/', src_phase.group(1))
        # 反查每个 buildFile 指向的 fileRef
        compiled = set()
        for bf in bf_ids:
            m = re.search(rf'{bf}[^=]*=\s*\{{isa = PBXBuildFile; fileRef = ([0-9A-F]{{24}})', src)
            if not m:
                errors.append(f"BuildFile {bf} 缺少 fileRef")
                continue
            ref = m.group(1)
            # 由 fileRef 找文件名
            m2 = re.search(rf'{ref}\s*/\*\s*([^*]+?)\s*\*/\s*=\s*\{{isa = PBXFileReference', src)
            if m2:
                compiled.add(m2.group(1))

    missing = []
    for f in on_disk:
        if os.path.basename(f) not in compiled:
            missing.append(f)
    if missing:
        for f in missing:
            errors.append(f"源文件未加入编译: {f}")
    else:
        print(f"✓ 盘上 {len(on_disk)} 个源文件全部在编译列表内")

    # ---------- 4. 关键 build settings ----------
    for key in ["INFOPLIST_FILE", "PRODUCT_BUNDLE_IDENTIFIER", "IPHONEOS_DEPLOYMENT_TARGET", "SDKROOT"]:
        if key not in src:
            errors.append(f"缺少必要的 build setting: {key}")
    if not any(e.startswith("缺少必要") for e in errors):
        print("✓ 关键 build settings 齐全")

    # ---------- 输出 ----------
    print()
    for w in warnings:
        print(f"  警告: {w}")
    if errors:
        for e in errors:
            print(f"  错误: {e}")
        print(f"\n校验失败，{len(errors)} 个错误")
        return 1

    print("校验通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
