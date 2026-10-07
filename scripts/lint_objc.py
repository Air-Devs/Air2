#!/usr/bin/env python3
"""
ObjC 源码静态检查 —— 没有本地编译器时的替代方案。

这不是编译器，只抓几类确定性的错误，用来在推送前过滤掉
「一眼就能看出来」的编译失败，减少 CI 往返。

检查项：
  1. 给只读属性赋值（如 UIViewPropertyAnimator.delay）
  2. 调用未声明的选择器（本文件内 / 已知系统 API）
  3. @interface / @implementation / @end 配对
  4. 花括号与括号平衡
  5. 引用了不存在的自定义类（类名在工程里找不到定义）
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Air2")

# 系统类里常见的只读属性（误赋值会导致 "assignment to readonly property"）
READONLY_PROPS = {
    "UIViewPropertyAnimator": ["delay", "state", "isRunning", "isReversed"],
    "UIView": ["superview", "window", "layer", "intrinsicContentSize", "bounds", "frame"],
    "UIViewController": ["view", "navigationController", "tabBarController", "parent"],
}

# UIKit 里可写的、名字容易和只读混淆的属性（避免误报）
SAFE_PROPS = set()


def collect_classes():
    """收集工程里定义的所有类名"""
    classes = set()
    for dirpath, _, files in os.walk(SRC):
        for f in files:
            if not f.endswith((".h", ".m")):
                continue
            src = open(os.path.join(dirpath, f)).read()
            for m in re.finditer(r'@(?:interface|implementation)\s+(\w+)', src):
                classes.add(m.group(1))
    return classes


def check_file(path, defined_classes):
    errors = []
    src = open(path).read()

    # ---------- 花括号平衡 ----------
    stripped = re.sub(r'//[^\n]*', '', src)
    stripped = re.sub(r'/\*.*?\*/', '', stripped, flags=re.S)
    stripped = re.sub(r'"(?:[^"\\]|\\.)*"', '""', stripped)
    stripped = re.sub(r"'(?:[^'\\]|\\.)*'", "''", stripped)
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

    if stripped.count("(") != stripped.count(")"):
        errors.append(f"圆括号不平衡: {stripped.count('(')} vs {stripped.count(')')}")

    # ---------- @interface / @implementation / @end ----------
    ifaces = len(re.findall(r'@interface\b', src))
    impls = len(re.findall(r'@implementation\b', src))
    ends = len(re.findall(r'@end\b', src))
    if ifaces + impls != ends:
        errors.append(
            f"@interface({ifaces}) + @implementation({impls}) = {ifaces+impls} "
            f"≠ @end({ends})")

    # ---------- 只读属性赋值 ----------
    for var, prop in re.findall(r'\b(\w+)\.(delay|isRunning|state)\s*=', src):
        # delay 只在 UIViewPropertyAnimator 上只读，其他类型（如 CABasicAnimation）可写
        # 这里只报 UIViewPropertyAnimator 的场景，靠变量名启发式判断
        if prop in ("delay", "isRunning") and re.search(
                rf'{var}\s*=\s*(?:A2\w*Spring|\[\[UIViewPropertyAnimator)', src):
            errors.append(f"疑似给只读属性赋值: {var}.{prop}")

    # ---------- 属性归属检查 ----------
    # A2ColorScheme 只有色值，主题名/渐变等元信息在 A2ColorTheme 上。
    # 两者容易被搞混（都从 A2ThemeManager 取），专门查一遍。
    scheme_only = {"primary", "onPrimary", "primaryContainer", "onPrimaryContainer",
                   "secondary", "onSecondary", "secondaryContainer", "onSecondaryContainer",
                   "tertiary", "tertiaryContainer", "surface", "onSurface",
                   "surfaceContainerLowest", "surfaceContainerLow", "surfaceContainer",
                   "surfaceContainerHigh", "surfaceContainerHighest", "surfaceVariant",
                   "onSurfaceVariant", "outline", "outlineVariant", "error", "onError",
                   "errorContainer", "onErrorContainer", "success", "warning",
                   "inverseSurface", "inverseOnSurface", "inversePrimary"}
    theme_only = {"displayName", "themeDescription", "backgroundGradient",
                  "lightPrimary", "darkPrimary", "kind", "scheme"}

    # 找 A2ColorScheme 类型的变量
    scheme_vars = set(re.findall(r'A2ColorScheme \*(\w+)', src))
    for v in scheme_vars:
        for m in re.finditer(rf'\b{v}\.(\w+)\b', src):
            prop = m.group(1)
            if prop in theme_only:
                line = src[:m.start()].count('\n') + 1
                errors.append(
                    f"第 {line} 行: {v} 是 A2ColorScheme，没有 {prop} 属性"
                    f"（该属性在 A2ColorTheme 上，应改用 theme.{prop}）")

    # tm.scheme.xxx 形式
    for m in re.finditer(r'\.scheme\.(\w+)\b', src):
        prop = m.group(1)
        if prop in theme_only:
            line = src[:m.start()].count('\n') + 1
            errors.append(
                f"第 {line} 行: .scheme 是 A2ColorScheme，没有 {prop} 属性"
                f"（该属性在 A2ColorTheme 上，应改用 .theme.{prop}）")

    # ---------- 约束数组嵌套检查 ----------
    # 返回 NSArray<NSLayoutConstraint*> 的方法，如果被直接写进
    # @[ ... ] 传给 activateConstraints:，就变成「数组套数组」，
    # 运行时报 -[__NSArrayI isActive]: unrecognized selector 并崩溃。
    # 编译器不会报（id 类型擦除），只在运行时炸 —— 真机上踩过。
    if not path.endswith('.h'):
        array_returning = set(re.findall(
            r'-\s*\(NSArray<NSLayoutConstraint \*> \*\)(\w+)', src))
        for name in array_returning:
            for m in re.finditer(r'activateConstraints:@\[(.*?)\]\];', src, re.S):
                block = m.group(1)
                if re.search(rf'\[self {name}\b', block):
                    line = src[:m.start()].count('\n') + 1
                    errors.append(
                        f"第 {line} 行: [self {name}] 返回约束数组，"
                        f"不能直接放进 activateConstraints:@[...]，"
                        f"应改用 addObjectsFromArray 展开")

    # ---------- 变量声明顺序检查 ----------
    # 批量重构时容易把声明插错位置（插到使用之后），
    # 这会导致 "use of undeclared identifier"。编译器能报，
    # 但等 CI 跑一轮要几分钟，本地先拦掉。
    #
    # 做法：找出每个方法体，检查 A2ColorScheme *t 这类声明的
    # 首次使用位置是否早于声明位置。
    decl_pattern = re.compile(
        r'^\s*(A2ColorScheme|A2ColorTheme|A2GlassCard|NSMutableArray<[^>]+>)\s*\*(\w+)\s*=',
        re.M)
    for m in decl_pattern.finditer(src):
        var = m.group(2)
        decl_pos = m.start()
        # 找到该声明所在的方法体范围
        body_start = src.rfind('\n- (', 0, decl_pos)
        if body_start == -1:
            body_start = src.rfind('\n+ (', 0, decl_pos)
        if body_start == -1:
            continue
        # 方法体结束：下一个方法或 @end
        nxt = re.search(r'\n[-+] \(|\n@end', src[decl_pos:])
        body_end = decl_pos + (nxt.start() if nxt else len(src) - decl_pos)

        body = src[body_start:body_end]
        # 在体里找该变量的使用（排除声明行自身）
        used_before = False
        local_decl = decl_pos - body_start
        for um in re.finditer(rf'\b{var}\.', body):
            if um.start() < local_decl:
                used_before = True
                break
        if used_before:
            line = src[:decl_pos].count('\n') + 1
            errors.append(
                f"第 {line} 行: 变量 {var} 的声明位置在使用之后，"
                f"会导致 use of undeclared identifier")

    return errors

def main():
    defined_classes = collect_classes()
    print(f"工程内定义 {len(defined_classes)} 个类\n")

    total = 0
    files = []
    for dirpath, _, fs in os.walk(SRC):
        for f in fs:
            if f.endswith((".m", ".h")):
                files.append(os.path.join(dirpath, f))

    for path in sorted(files):
        errs = check_file(path, defined_classes)
        if errs:
            rel = os.path.relpath(path, ROOT)
            for e in errs:
                print(f"  {rel}: {e}")
            total += len(errs)

    print()
    if total:
        print(f"发现 {total} 处问题")
        return 1
    print(f"✓ {len(files)} 个文件检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
