#!/usr/bin/env python3
"""
校验 pbxproj 的内部一致性。

没有 Xcode 的情况下，靠这个脚本抓出最常见的几类错误：
  1. 括号 / 引号不平衡
  2. 引用了未定义的 UUID
  3. 定义了但从未被引用的对象（说明文件没被加进工程）
  4. 源文件在盘上但没进 Sources 阶段（.m/.mm/.swift 都查）
  5. 工程里声明的路径在磁盘上不存在（最难排查的一类，
     表现为编译时报 "Build input file cannot be found"）

pbxproj 是纯文本，这些都能静态查出来。

注意：pbxproj 是瞬时产物（真相源是文件系统 + Package.swift）。
如果工程文件根本不存在、而 Package.swift 存在，说明还没重生成，
这时只告警、不报错——CI 的 ios-build 任务会先重生成再严格校验。
"""
import os
import re
import sys
import hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "Air2.xcodeproj", "project.pbxproj")
PROJECT_NAME = "Air2"


def uid_py(*parts):
    """与 gen_xcodeproj.py 完全一致的 UUID 生成算法。
    两处必须同步，否则会去查一个不存在的组。"""
    h = hashlib.sha1("|".join(parts).encode()).hexdigest()
    return h[:24].upper()


def section(src, name):
    """取出 pbxproj 里的某个 section 正文"""
    m = re.search(rf'/\* Begin {name} section \*/(.*?)/\* End {name} section \*/', src, re.S)
    return m.group(1) if m else None


def parse_groups(src):
    """解析所有 PBXGroup，返回 {uuid: {path, name, children}}"""
    out = {}
    seg = section(src, "PBXGroup")
    if not seg:
        return out
    # 逐个匹配完整的 group 定义块
    for m in re.finditer(r'\t\t([0-9A-F]{24}) /\* [^*]* \*/ = \{(.*?)\n\t\t\};', seg, re.S):
        gid, body = m.group(1), m.group(2)
        if "isa = PBXGroup;" not in body:
            continue
        cm = re.search(r'children = \((.*?)\);', body, re.S)
        children = re.findall(r'([0-9A-F]{24})', cm.group(1)) if cm else []
        pm = re.search(r'\n\t\t\tpath = ([^;]+);', body)
        nm = re.search(r'\n\t\t\tname = ([^;]+);', body)
        out[gid] = {
            "path": pm.group(1).strip().strip('"') if pm else None,
            "name": nm.group(1).strip().strip('"') if nm else None,
            "children": children,
        }
    return out


def parse_file_refs(src):
    """解析所有 PBXFileReference，返回 {uuid: 文件名}"""
    out = {}
    seg = section(src, "PBXFileReference")
    if not seg:
        return out
    for m in re.finditer(
        r'\t\t([0-9A-F]{24}) /\*[^*]*\*/ = \{isa = PBXFileReference;[^}]*?path = ([^;]+);',
        seg):
        out[m.group(1)] = m.group(2).strip().strip('"')
    return out


def main():
    if not os.path.exists(PBX):
        # 瞬时产物还没生成不算错：真相源是文件系统 + Package.swift。
        if os.path.exists(os.path.join(ROOT, "Package.swift")):
            print(f"提示：{PBX} 不存在，但 Package.swift 存在。")
            print("pbxproj 是瞬时产物，构建前由 scripts/gen_xcodeproj.py 重生成，本次只告警。")
            return 0
        print(f"找不到 {PBX}")
        return 1

    src = open(PBX).read()
    errors = []
    warnings = []

    # ---------- 1. 括号平衡 ----------
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

    if stripped.count("(") != stripped.count(")"):
        errors.append(f"圆括号不平衡: ( {stripped.count('(')} vs ) {stripped.count(')')}")
    else:
        print("✓ 圆括号平衡")

    # ---------- 2. UUID 引用完整性 ----------
    defined = set(re.findall(r'^\t\t([0-9A-F]{24})\s*(?:/\*.*?\*/)?\s*=', src, re.M))
    referenced = set(re.findall(r'\b([0-9A-F]{24})\b(?=\s*(?:/\*[^*]*\*/)?\s*[,;)])', src))
    print(f"✓ 定义了 {len(defined)} 个对象")

    dangling = referenced - defined
    if dangling:
        for u in sorted(dangling):
            errors.append(f"引用了未定义的 UUID: {u}")
    else:
        print("✓ 所有引用都有对应定义")

    orphans = defined - referenced
    root_m = re.search(r'rootObject = ([0-9A-F]{24})', src)
    if root_m:
        orphans.discard(root_m.group(1))
    if orphans:
        for u in sorted(orphans):
            warnings.append(f"对象定义了但没人引用: {u}")
    else:
        print("✓ 无孤立对象")

    # ---------- 3. 源文件覆盖 ----------
    # .m/.mm 是 ObjC 残留，.swift 是迁移目标，两边都要进 Sources。
    on_disk = []
    for dirpath, _, files in os.walk(os.path.join(ROOT, "Air2")):
        for f in files:
            if f.endswith((".m", ".mm", ".swift")):
                on_disk.append(os.path.relpath(os.path.join(dirpath, f), ROOT))
    on_disk = sorted(on_disk)

    src_seg = section(src, "PBXSourcesBuildPhase")
    compiled = set()
    if not src_seg:
        errors.append("找不到 PBXSourcesBuildPhase")
    else:
        bf_ids = re.findall(r'([0-9A-F]{24})\s*/\*[^*]*in Sources \*/', src_seg)
        for bf in bf_ids:
            m = re.search(rf'{bf}[^=]*=\s*\{{isa = PBXBuildFile; fileRef = ([0-9A-F]{{24}})', src)
            if not m:
                errors.append(f"BuildFile {bf} 缺少 fileRef")
                continue
            ref = m.group(1)
            m2 = re.search(rf'{ref}\s*/\*[^*]*\*/\s*=\s*\{{isa = PBXFileReference', section(src, "PBXFileReference") or "")
            if m2:
                m3 = re.search(rf'{ref} /\*([^*]*)\*/', src)
                if m3:
                    compiled.add(m3.group(1).strip())

    missing = [f for f in on_disk if os.path.basename(f) not in compiled]
    if missing:
        for f in missing:
            errors.append(f"源文件未加入编译: {f}")
    else:
        print(f"✓ 盘上 {len(on_disk)} 个源文件全部在编译列表内")

    # ---------- 4. 路径解析检查 ----------
    # 这是最关键的一项：PBXGroup 的 path 相对父组解析，
    # 层级拼错时 Xcode 只在编译期报 "Build input file cannot be found"，
    # 生成工程时不会有任何提示。所以这里模拟一遍路径拼接。
    groups = parse_groups(src)
    file_refs = parse_file_refs(src)

    # 建立 fileRef → 所属 group 的映射
    ref_to_group = {}
    for gid, g in groups.items():
        for c in g["children"]:
            if c in file_refs:
                ref_to_group[c] = gid

    resolved = {}

    def walk(gid, prefix, seen):
        if gid in seen:      # 防环
            return
        seen.add(gid)
        g = groups.get(gid)
        if not g:
            return
        # 有 path 才参与路径拼接；只有 name 的组（如 Products）不参与
        cur = prefix
        if g["path"]:
            cur = os.path.join(prefix, g["path"]) if prefix else g["path"]
        for c in g["children"]:
            if c in groups:
                walk(c, cur, seen)
            elif c in file_refs:
                resolved[c] = os.path.join(cur, file_refs[c]) if cur else file_refs[c]

    root_gid = uid_py("group", PROJECT_NAME)
    if root_gid not in groups:
        errors.append(f"找不到根组（期望 UUID {root_gid}）")
        resolved = {}
    else:
        walk(root_gid, "", set())

    if not resolved:
        errors.append("路径解析结果为空，说明分组结构无法被遍历到")
    else:
        bad = []
        for fid, rel in resolved.items():
            full = os.path.join(ROOT, rel)
            if not os.path.exists(full):
                bad.append(rel)
        if bad:
            for f in bad[:10]:
                errors.append(f"工程声明路径在磁盘上不存在: {f}")
            if len(bad) > 10:
                errors.append(f"... 另有 {len(bad) - 10} 个")
        else:
            print(f"✓ {len(resolved)} 个源文件的路径全部能解析到真实文件")

    # ---------- 5. 关键 build settings ----------
    for key in ["INFOPLIST_FILE", "PRODUCT_BUNDLE_IDENTIFIER", "IPHONEOS_DEPLOYMENT_TARGET", "SDKROOT", "SWIFT_VERSION"]:
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
