#!/usr/bin/env python3
#
#  lint_objc.py
#  Air2
#
#  Copyright (C) 2026 Air-Devs and contributors.
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
#
#  SPDX-License-Identifier: GPL-3.0-or-later
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
    # 用状态机逐字符扫描，而不是正则去注释 ——
    # 正则很容易把字符串里的 /* 或 // 当成注释起点，
    # 导致后续内容被整段吃掉、括号统计失准（踩过这个坑）。
    # #pragma / #warning 等编译指令整行不参与括号计数。
    # 典型：#pragma mark - 1) 某某  —— 这里的 ")" 会让计数失衡。
    src = re.sub(r'^[ \t]*#\s*(pragma|warning|error)\b[^\n]*$', '', src, flags=re.M)

    depth = 0
    i = 0
    n = len(src)
    in_line_comment = False
    in_block_comment = False
    in_string = False
    in_char = False
    # 同步构建「去掉注释与字符串字面量」的版本，
    # 供后面的括号计数使用 —— 注释里的 "1)" 这类文本不该参与统计。
    cleaned = []
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''

        if in_line_comment:
            if c == '\n':
                in_line_comment = False
            i += 1
            continue

        if in_block_comment:
            if c == '*' and nxt == '/':
                in_block_comment = False
                i += 2
                continue
            if c == '\\n':
                cleaned.append(c)
            i += 1
            continue

        if in_string:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue

        if in_char:
            if c == '\\':
                i += 2
                continue
            if c == "'":
                in_char = False
            i += 1
            continue

        # 正常代码态
        if c == '/' and nxt == '/':
            in_line_comment = True
            i += 2
            continue
        if c == '/' and nxt == '*':
            in_block_comment = True
            i += 2
            continue
        if c == '"':
            in_string = True
            cleaned.append(' ')
            i += 1
            continue
        if c == "'":
            in_char = True
            cleaned.append(' ')
            i += 1
            continue
        cleaned.append(c)

        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth < 0:
                errors.append("花括号提前闭合")
                depth = 0
                break
        i += 1

    if depth != 0:
        errors.append(f"花括号不平衡，差值 {depth}")

    stripped = "".join(cleaned)

    if stripped.count("(") != stripped.count(")"):
        errors.append(f"圆括号不平衡: {stripped.count('(')} vs {stripped.count(')')}")

    # ---------- @interface / @implementation / @end ----------
    # 用 stripped（已去注释与字符串）计数 —— 注释里写 "@implementation block"
    # 这种说明文字会被误算，导致段数对不上。
    _seg = stripped
    ifaces = len(re.findall(r'@interface\b', _seg))
    impls = len(re.findall(r'@implementation\b', _seg))
    # @protocol 有两种：
    #   @protocol Foo <Bar> ... @end    ← 声明，需要 @end
    #   @protocol Foo;                  ← 前置声明，不需要 @end
    # 之前没区分，导致前置声明多算一个 @end。
    # @protocol 有两种：
    #   @protocol Foo <Bar> ... @end   ← 声明，需要 @end
    #   @protocol Foo;                 ← 前置声明，不需要
    # 判据：后面跟 "<" 或换行（声明体）才算声明。
    # 另外 @interface Foo () 是类扩展，也需配对 @end —— 已计入 ifaces，不重复算。
    protos = len(re.findall(r'@protocol\s+\w+\s*(?:<|(?=\n))', _seg))
    ends = len(re.findall(r'@end\b', _seg))
    # 注意 @protocol 也有配对的 @end，之前漏算了会误报
    if ifaces + impls + protos != ends:
        errors.append(
            f"@interface({ifaces}) + @implementation({impls}) + @protocol({protos}) "
            f"= {ifaces+impls+protos} ≠ @end({ends})")

    # ---------- performSelector 必须指向本文件存在的方法 ----------
    # performSelector: 是编译期不检查的 —— 方法不存在只在运行时崩
    # "unrecognized selector"。我在 SurfaceViewController 里就踩过：
    # 三个 initCategory_* 的实现早被删了，调用点还在，
    # 启动游戏时直接崩。
    _impl = set(re.findall(r"^-\s*\([^)]*\)\s*(\w+)", src, re.M))
    for _m in re.finditer(r"performSelector:\s*@selector\((\w+)\)", src):
        _sel = _m.group(1)
        if _sel in _impl:
            continue
        # 系统/其他类的方法（suspend / surface / ...）不归本文件管，
        # 只报以 init/setup/load/update/handle/on 开头的（我们的命名习惯）
        if not re.match(r"^(init|setup|load|update|handle|on|apply|build|refresh)", _sel):
            continue
        _ln = src[:_m.start()].count("\n") + 1
        errors.append(f"第 {_ln} 行: performSelector 指向不存在的方法 {_sel}")

    # （类扩展重复声明属性的检查已移除）
    # 原本想拦住 A2GameMenuOverlay 那次
    # "illegal redeclaration of property in class extension"，
    # 但实测下来大多数「头 readonly + 扩展 readwrite」是【合法】写法
    # （A2ColorScheme 就有 98 处这么写，编译一直没问题）。
    # 真正非法的那个案例是「头里声明了 block 属性，扩展里又抄一遍」，
    # 用一般规则区分不出来，容易误报，所以不做自动检查。

    # ---------- @class 不能在 @interface / @implementation 内 ----------
    # 这条错误我实际踩过：把 @class A2ControlRenderer; 插到了
    # @interface 的 @property 中间，编译报 "missing '@end'" 与
    # 一串 "unexpected '@' in program"，很难一眼看出根因。
    _depth = 0
    for _i, _line in enumerate(src.split("\n"), 1):
        _st = _line.strip()
        if _st.startswith(("@interface", "@implementation", "@protocol ")):
            _depth += 1
        elif _st.startswith("@end"):
            _depth = max(0, _depth - 1)
        elif _st.startswith("@class") and _depth > 0:
            errors.append(f"第 {_i} 行: @class 在 @interface 内 —— 必须移到外面")

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

    # ---------- block 循环引用检查 ----------
    # 常见模式：xxx.onTap = ^{ ... 引用 xxx ... } ——
    # xxx 持有 block，block 又强引用 xxx，形成循环，对象永不释放。
    # 编译器只在部分写法下报 -Warc-retain-cycles，这里主动扫。
    #
    # 做法：找「变量.block属性 = ^{ ... }」结构，检查 block 体内
    # 是否直接引用了同一个变量名（且未先用 __weak 声明弱引用）。
    block_assign = re.compile(
        r'\b(\w+)\.(onTap|onSelect|onRefresh|onMore|onToggle|onTogglePause|'
        r'onProgress|onStateChange|onPinned|onPin|onSettings|completion|'
        r'progress|action)\s*=\s*\^',
        re.M)
    for m in block_assign.finditer(src):
        var = m.group(1)
        if var == 'self':
            continue   # self 的循环引用交给编译器警告，避免大量误报
        # 从 = ^{ 开始找到配对的 }（简易括号计数）
        try:
            start = src.index('^{', m.start())
        except ValueError:
            continue
        depth = 0
        i = start + 1
        while i < len(src):
            if src[i] == '{':
                depth += 1
            elif src[i] == '}':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = src[start:i+1]
        if i >= len(src):
            continue

        # block 体内是否直接使用该变量（不是 weakXxx）
        if re.search(rf'(?<![\w_]){var}\s*\.', body) or \
           re.search(rf'(?<![\w_]){var}\s*\]', body):
            # 但如果先声明了 __weak 别名并只用别名，就不算
            weak_alias = re.search(rf'__weak[^;]*?\b(\w+)\s*=\s*{var}\b', body)
            if weak_alias:
                alias = weak_alias.group(1)
                # 检查是否还有直接引用 var（排除别名声明那一行）
                body_wo_decl = re.sub(
                    rf'__weak[^;]*?{var}\s*;', '', body)
                if not re.search(rf'(?<![\w_]){var}\s*\.', body_wo_decl):
                    continue
            line = src[:m.start()].count('\n') + 1
            errors.append(
                f"第 {line} 行: {var} 的 block 里直接引用了 {var} 自身，"
                f"会形成循环引用（{var} 持有 block，block 又持有 {var}）。"
                f"应先用 __weak typeof({var}) weak{var[0].upper()}{var[1:]} = {var};")

    # ---------- setter 命名检查 ----------
    # 形如 - (非void) setXxx:(T)v; 的方法会被编译器当成属性 setter，
    # 而 ObjC 要求 setter 必须返回 void，否则报
    # "type of setter must be void"。
    # 这类方法应改用动词命名（如 selectXxx: / applyXxx:）。
    # Air1 移植来的代码保持原样 —— setXxx: 返回非 void 是它的既有风格，
    # 改签名会牵连大量调用点。这是我们自己的规范，不适用于第三方代码。
    _skip_setter = "/Player/" in path
    for m in re.finditer(r'^\s*-\s*\(\s*(?!void)\w[\w\s\*<>]*\)\s*(set[A-Z]\w*)\s*:', src, re.M):
        if _skip_setter:
            continue
        line = src[:m.start()].count('\n') + 1
        errors.append(
            f"第 {line} 行: {m.group(1)}: 是 setter 形式但返回非 void，"
            f"编译器会报 type of setter must be void，"
            f"建议改用动词命名（如 select/apply/update）")

    # ---------- readonly 属性重声明检查 ----------
    # 头文件里 readonly 的属性，类扩展里才能重声明为 readwrite。
    # 只在【同一文件】内同时出现两种情况时报 —— 头文件在别的文件时
    # 无法在本文件判断，强行报会产生大量误报。
    if path.endswith('.m'):
        for m in re.finditer(r'@interface\s+\w+\s*\(\)(.*?)@end', src, re.S):
            ext = m.group(1)
            for pm in re.finditer(
                    r'@property\s*\(([^)]*)\)[^;]*?\b(\w+)\s*;', ext):
                attrs, name = pm.group(1), pm.group(2)
                if 'readonly' in attrs:
                    continue
                # 检查同一文件里是否有该属性的 readonly 声明
                decl = re.search(
                    rf'@property\s*\(([^)]*readonly[^)]*)\)[^;]*?\b{name}\s*;', src)
                if decl:
                    line = src[:m.start() + pm.start()].count('\n') + 1
                    errors.append(
                        f"第 {line} 行: 属性 {name} 在同一文件里已声明为 readonly，"
                        f"类扩展里重声明为可写会报 illegal redeclaration")

    # ---------- 字典取值类型检查 ----------
    # NSDictionary 的下标返回 id，直接点属性会报
    # "property 'xxx' not found on object of type 'id'"。
    # 常见于 dict[@"k"].longLongValue 这种写法。
    for m in re.finditer(r'\[\s*@"[^"]+"\s*\]\s*\.\s*(\w+)', src):
        prop = m.group(1)
        # 只有这些是 NSNumber 上的属性，属于典型误用
        if prop in ('longLongValue', 'integerValue', 'doubleValue', 'boolValue',
                    'floatValue', 'intValue', 'unsignedLongLongValue'):
            line = src[:m.start()].count('\n') + 1
            errors.append(
                f"第 {line} 行: 字典下标返回 id，不能直接点 .{prop}。"
                f"应先取出再拆箱：NSNumber *n = dict[@\"k\"]; n.{prop}")

    # ---------- finalize 方法名检查 ----------
    # finalize 与已废弃的 ObjC GC API 撞名，会触发 deprecated 警告
    if re.search(r'^\s*-\s*\(void\)\s*finalize\b', src, re.M):
        line = src[:re.search(r'^\s*-\s*\(void\)\s*finalize\b', src, re.M).start()].count('\n') + 1
        errors.append(
            f"第 {line} 行: 方法名 finalize 与已废弃的 GC API 撞名，"
            f"会触发 deprecated 警告，建议改用 endXxx / finishXxx")

    # ---------- 色板字段完整性 ----------
    # A2ColorScheme 是两段式：原始 slot（secondary 等）
    # + 解析后的具体色值（cSecondary 等）。
    # 两段必须一一对应，否则解析时取不到值（运行期给 nil）。
    # 而这个错误通常是「写代码时以为有、实际没加」。
    if path.endswith('A2ColorScheme.h') or path.endswith('A2ColorScheme.m'):
        pass   # 这两个文件是定义方，自身不做校验

    # ---------- Cocoa 命名族检查 ----------
    # 属性名以 copy / new / alloc / init / mutableCopy 开头时，clang 按
    # Cocoa 命名约定把它归入对应的「方法族」——族内约定返回 +1（owned）
    # 对象。属性不具备这个语义，于是直接编译失败：
    #   error: property follows Cocoa naming convention for returning
    #          'owned' objects
    # 这条是纯语法规则、不依赖运行环境，却要等真编译才暴露（踩过一次：
    # copyButton），本地先拦掉。
    #
    # 只查对象指针类型：族的判定要求返回类型是对象，标量属性
    # （如 BOOL newFlag）不触发该规则，报了就是误报。
    #
    # 族前缀后面必须跟「非小写字母」或结束才算入族：
    # copyButton 入族，copyright / newton / initialValue 不入族。
    for m in re.finditer(r'@property\s*\([^)]*\)[^;{]*?\*\s*(\w+)\s*;', src):
        name = m.group(1)
        fam = re.match(r'(copy|new|alloc|init|mutableCopy)([^a-z].*)?$', name)
        if fam:
            line = src[:m.start()].count('\n') + 1
            errors.append(
                f"第 {line} 行: 属性 {name} 以 {fam.group(1)} 开头，"
                f"会被 clang 判为 Cocoa 的 {fam.group(1)} 族（约定返回 +1 对象），"
                f"报 property follows Cocoa naming convention 编译失败。"
                f"请改名，把族前缀挪到后面（如 copyButton → codeCopyButton）")

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
