#!/usr/bin/env python3
"""
Air2 —— 「二级界面不许有玻璃」的机器判据。

口径（用户 2026-10-16 最新定义）：
  一级页面（启动器主页）保持 iOS 26 液态玻璃观感；
  ★从一级点进去的二级界面一律 Material Design 3，不用玻璃★
  （不要毛玻璃卡片、不要 UIVisualEffectView 材质、不要跟随壁纸的半透明填充，
   选择器也不要用系统的半透明材质弹层）。

为什么要有这个脚本：
  「不用玻璃」如果只靠人眼看截图，下一次有人加一张 A2GlassCard 默认（玻璃）卡片、
  把 A2BackgroundView 挂回二级页面、或者图省事又写一个系统 ActionSheet，
  没有任何东西会拦下来。所以这里把「玻璃」收敛成两份可枚举的清单，
  并用白名单固定它们的合法位置。

判据（五条，全部为断言，任一失败即退出码 1）：
  A. 玻璃 API：扫描面内命中 > 0 的文件，必须全部在白名单里（白名单之外命中 = 错误）。
     白名单 = 一级/基础设施文件，且每个都写明为什么允许。
  B. ★阴性对照①★：白名单里的一级文件命中必须 > 0。
     否则说明扫描器根本没命中玻璃 API（全零是假通过）。
  C. ★二级界面清单命中必须 = 0★：
     二级清单由脚本自己从 `@interface X : A2BaseViewController` 推导（不手抄），
     逐文件断言命中数为 0。
  D. A2GlassCard 的玻璃总开关默认值必须是 NO（`_glassEnabled = NO;`），
     防止有人把默认值改回玻璃、让全部二级页面静默变回玻璃。
  E. 系统材质弹层：`UIAlertControllerStyleActionSheet` 在 Air2/ 命中必须 = 0
     （它的外观是系统半透明材质、又不跟主题，用户口径里的「玻璃弹层」就是它）；
     ★阴性对照②★：替换件 A2OptionSheet 必须既有定义又有调用点。

注释会被剥离（与 scripts/check_imports.py 同一套 strip_comments），
所以注释里提到玻璃 API 不会误报 —— 判据只看真实代码。

用法：
    python3 scripts/check_no_glass.py           # 检查（0 = 通过）
    python3 scripts/check_no_glass.py -v        # 额外打印每个白名单文件的命中明细
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_ROOT = os.path.join(ROOT, "Air2")

# ------------------------------------------------------------
# 扫描面：Air2/ 下全部 ObjC 源文件（含头文件）
# ------------------------------------------------------------
SCAN_EXTS = (".m", ".mm", ".h")

# ------------------------------------------------------------
# 「玻璃」= 这些 API / 组件。命中即算玻璃使用点。
# 每项：(正则, 人话说明)
# ------------------------------------------------------------
GLASS_PATTERNS = [
    (r"\bUIVisualEffectView\b", "UIVisualEffectView —— 系统模糊视图（毛玻璃载体）"),
    (r"\bUIBlurEffect\b", "UIBlurEffect —— 系统模糊材质"),
    (r"\bUIVibrancyEffect\b", "UIVibrancyEffect —— 系统材质"),
    (r"\beffectWithStyle\s*:", "effectWithStyle: —— 材质构造调用"),
    (r"\bblurAmount\b", "A2GlassCard.blurAmount —— 卡片跟随壁纸模糊"),
    (r"\bA2BackgroundView\b", "A2BackgroundView —— 壁纸 + 模糊层组件"),
    (r"\bglassEnabled\b", "A2GlassCard.glassEnabled —— 玻璃总开关"),
    (r"\bUI?GlassEffect\b", "UIGlassEffect —— iOS 26 液态玻璃 API"),
    (r"\bglassEffect\b", "glassEffect —— iOS 26 液态玻璃 API"),
]

# ------------------------------------------------------------
# 白名单：唯一允许出现玻璃 API 的文件（含理由）
#
# ★只登记一级页面与「玻璃能力的实现处」，二级界面一个都不许进★
# 新增条目 = 放行一处玻璃，必须同时给出理由，并在 docs/DECISIONS.md 记录。
# ------------------------------------------------------------
GLASS_ALLOWED = {
    "Air2/UI/Components/A2GlassCard.h":
        "玻璃能力的声明处（默认关闭，唯一实现入口）",
    "Air2/UI/Components/A2GlassCard.m":
        "玻璃能力的实现处（默认 _glassEnabled = NO）",
    "Air2/UI/Components/A2BackgroundView.h":
        "一级页面壁纸层（含模糊）",
    "Air2/UI/Components/A2BackgroundView.m":
        "一级页面壁纸层（含模糊）实现",
    # A2TaskDrawer 原先登记在此（SystemThickMaterialDark 浮层）。
    # 第二批 UI 修复：用户批注「下载进度界面咋这么黑」，二级界面一律 MD3，
    # 该浮层已改为不透明 MD3 surfaceContainerHigh 填充 ⇒ 不再是玻璃使用点，
    # 本条与 NEGATIVE_CONTROL 里的同名项一并删除（★收紧门禁，不是放宽★）。
    "Air2/UI/Screens/Home/A2LauncherViewController.m":
        "★一级页面★：唯一显式打开玻璃（glassEnabled = YES）的调用点",
}

# 阴性对照：这些文件必须命中 > 0，否则扫描器是「假通过」
NEGATIVE_CONTROL = [
    "Air2/UI/Screens/Home/A2LauncherViewController.m",
    "Air2/UI/Components/A2BackgroundView.m",
]

# D 断言：玻璃总开关默认值必须在这一行
GLASS_DEFAULT_FILE = "Air2/UI/Components/A2GlassCard.m"
GLASS_DEFAULT_LINE = re.compile(r"\b_glassEnabled\s*=\s*NO\s*;")

# ------------------------------------------------------------
# E 断言：系统材质（玻璃）弹层不许用在二级界面的选择器上
# ------------------------------------------------------------
# UIAlertController 的 ActionSheet 外观是系统半透明材质，且不跟随本应用主题 /
# 材料包 —— 用户口径里的「玻璃弹层」就是它。替换件是自研 A2OptionSheet。
# 允许保留：UIAlertControllerStyleAlert（危险操作确认，见 air2-ui 的组件规范）。
SYSTEM_PICKER_PATTERNS = [
    (r"\bUIAlertControllerStyleActionSheet\b",
     "系统 ActionSheet —— 半透明系统材质的选择弹层"),
]
# 替换件的存在性（阴性对照②）：定义处 + 调用处都必须还在，
# 否则「二级界面不用系统弹层」这条判据会变成空转。
OPTION_SHEET_DEF = "Air2/UI/Components/A2OptionSheet.m"
OPTION_SHEET_CALL_ROOT = "Air2/UI/Screens"


def strip_comments(src):
    """去掉注释，避免注释里提到玻璃 API 干扰判断（与 check_imports.py 同款）。"""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return src


def collect_sources():
    out = []
    for dirpath, _, files in os.walk(SRC_ROOT):
        for f in sorted(files):
            if f.endswith(SCAN_EXTS):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def rel(path):
    return os.path.relpath(path, ROOT).replace(os.sep, "/")


def scan_file(path, patterns=None):
    """返回 [(行号, 正则说明, 该行原文)]；patterns 缺省用玻璃 API 清单。"""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
    clean_lines = strip_comments(raw).split("\n")
    raw_lines = raw.split("\n")
    hits = []
    for i, line in enumerate(clean_lines):
        for pat, why in (patterns if patterns is not None else GLASS_PATTERNS):
            if re.search(pat, line):
                original = raw_lines[i].strip() if i < len(raw_lines) else line.strip()
                hits.append((i + 1, why, original))
    return hits


def discover_secondary():
    """★二级界面清单由脚本自己推导★：@interface X : A2BaseViewController 的 .h 文件。

    判据是结构性的（继承二级页面基类），不是手抄的名单 ——
    将来新增二级页面会自动被这条断言覆盖。
    """
    pat = re.compile(r"@interface\s+(\w+)\s*:\s*A2BaseViewController\b")
    found = []
    for path in collect_sources():
        if not path.endswith(".h"):
            continue
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = strip_comments(fh.read())
        m = pat.search(text)
        if m:
            found.append((rel(path), m.group(1)))
    return found


def main():
    verbose = "-v" in sys.argv
    fail = False

    def err(msg):
        nonlocal fail
        print("  \033[31m[错误]\033[0m %s" % msg)
        fail = True

    def ok(msg):
        print("  \033[32m[通过]\033[0m %s" % msg)

    sources = collect_sources()
    results = {rel(p): scan_file(p) for p in sources}
    total_hits = sum(len(v) for v in results.values())

    print("==> 二级界面去玻璃检查（口径见 docs/DECISIONS.md）")
    print("    扫描面：Air2/**/*.{m,mm,h} 共 %d 个文件；玻璃使用点合计 %d 处"
          % (len(sources), total_hits))

    # ---------------- A. 白名单之外不得命中 ----------------
    offenders = []
    for name, hits in sorted(results.items()):
        if hits and name not in GLASS_ALLOWED:
            offenders.append((name, hits))
    if offenders:
        for name, hits in offenders:
            err("%s 出现玻璃 API %d 处（二级界面不许有玻璃）：" % (name, len(hits)))
            for line_no, why, text in hits[:5]:
                print("         %s:%d  %s" % (name, line_no, text))
            print("         命中项：%s" % "、".join(sorted({h[1] for h in hits})))
    else:
        ok("白名单之外无任何玻璃 API 命中")

    # ---------------- B. 阴性对照 ----------------
    control_ok = True
    for name in NEGATIVE_CONTROL:
        n = len(results.get(name, []))
        flag = "命中 %d 处" % n
        if n == 0:
            control_ok = False
            err("阴性对照失败：一级文件 %s 命中 0 —— 扫描器可能已失效（假通过）" % name)
        elif verbose:
            print("     对照 %s：%s" % (name, flag))
    if control_ok:
        ok("阴性对照：一级文件命中 %d 个（均 > 0，扫描器确实能命中玻璃 API）"
           % len(NEGATIVE_CONTROL))

    # ---------------- C. 二级界面清单命中 = 0 ----------------
    secondary = discover_secondary()
    sec_bad = [(name, cls, results.get(name, [])) for name, cls in secondary
               if results.get(name, [])]
    if sec_bad:
        for name, cls, hits in sec_bad:
            err("二级界面 %s（%s）玻璃命中 %d 处" % (name, cls, len(hits)))
    else:
        ok("二级界面清单 %d 个文件，玻璃命中 = 0（清单由继承关系推导，非手抄）"
           % len(secondary))

    # ---------------- D. 玻璃总开关默认值 ----------------
    default_path = os.path.join(ROOT, GLASS_DEFAULT_FILE)
    if not os.path.exists(default_path):
        err("找不到 %s（玻璃总开关的默认值必须可被断言）" % GLASS_DEFAULT_FILE)
    else:
        with open(default_path, "r", encoding="utf-8", errors="replace") as fh:
            body = strip_comments(fh.read())
        if GLASS_DEFAULT_LINE.search(body):
            ok("A2GlassCard 玻璃总开关默认值 = NO（二级界面默认即 MD3 实心表面）")
        else:
            err("%s 里找不到 `_glassEnabled = NO;` —— 默认值被改成玻璃了"
                % GLASS_DEFAULT_FILE)

    # ---------------- E. 系统材质弹层 ----------------
    picker_hits = []
    for path in sources:
        for line_no, why, text in scan_file(path, SYSTEM_PICKER_PATTERNS):
            picker_hits.append((rel(path), line_no, text))
    if picker_hits:
        err("命中系统 ActionSheet %d 处（二级界面的选择器必须用 A2OptionSheet）："
            % len(picker_hits))
        for name, line_no, text in picker_hits[:10]:
            print("         %s:%d  %s" % (name, line_no, text))
    else:
        ok("系统 ActionSheet 命中 = 0（选择器一律走 A2OptionSheet）")

    # 阴性对照②：替换件必须既有定义又有调用点，否则上面那条是空转
    def_path = os.path.join(ROOT, OPTION_SHEET_DEF)
    call_root = os.path.join(ROOT, OPTION_SHEET_CALL_ROOT)
    call_files = []
    for dirpath, _, files in os.walk(call_root):
        for f in sorted(files):
            if not f.endswith(SCAN_EXTS):
                continue
            p = os.path.join(dirpath, f)
            if scan_file(p, [(r"\bA2OptionSheet\b", "A2OptionSheet 调用点")]):
                call_files.append(rel(p))
    if not os.path.exists(def_path):
        err("找不到替换件定义 %s（判据 E 会变成空转）" % OPTION_SHEET_DEF)
    elif not call_files:
        err("A2OptionSheet 在 %s 下没有任何调用点（判据 E 会变成空转）" % OPTION_SHEET_CALL_ROOT)
    else:
        ok("阴性对照②：A2OptionSheet 有定义 + %d 个页面在调用" % len(call_files))

    # ---------------- 明细（供报告引用） ----------------
    print("    白名单文件命中明细：")
    for name in sorted(GLASS_ALLOWED):
        n = len(results.get(name, []))
        mark = "★" if name in NEGATIVE_CONTROL else " "
        print("      %s %-52s %d 处   %s" % (mark, name, n, GLASS_ALLOWED[name]))
    print("    二级界面清单（%d）：%s" % (len(secondary), "、".join(c for _, c in secondary)))

    print("")
    if fail:
        print("\033[31m二级界面去玻璃检查失败\033[0m")
        return 1
    print("\033[32m二级界面去玻璃检查通过\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
