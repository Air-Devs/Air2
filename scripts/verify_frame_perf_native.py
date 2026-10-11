#!/usr/bin/env python3
"""
Air2 帧性能判据层 —— 静态自证（[FRAME-PERF]）
============================================================
无需 Mac / 无需编译器，全机可跑。查本单两条硬约束：

  ① 【与渲染器解耦】本层 4 个源文件里不得出现任何图形后端专有名。
     （要求：判据层只认中立数值；出现后端名 = 与渲染器耦合 ⇒ 机器判据 = 命中 0。）
     带★阴性对照★：同一台扫描器必须在已知含后端名的文件上报警，否则「命中 0」可能是假通过。
  ② 【禁石山】本层对外声明的每个 a2_frame_perf_* 函数（以及桥新增的帧生产入口），
     必须在工程内**至少有一处调用点**（声明它的头文件本身不算）。
     （要求：每个新增符号必须能指出谁调它。找不到调用点 = 石山。）

用法：python3 scripts/verify_frame_perf_native.py        （退出码 0 = 全通过）
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 本层（[FRAME-PERF]）新增/拥有的源文件 —— 解耦判据只扫这些。
LAYER_FILES = [
    "Natives/Renderer/a2_frame_perf.h",
    "Natives/Renderer/a2_frame_perf.m",
    "Air2/Core/Renderer/A2RenderScaleCatalog.h",
    "Air2/Core/Renderer/A2RenderScaleCatalog.m",
]

# 对外声明「可被调用」的头文件（禁石山判据的声明来源）。
# a2_gl_bridge.h 是既有文件（其内部词汇表本来就含图形 API 名，故只用于本项、不入解耦扫描）。
DECLARED_HEADERS = [
    "Natives/Renderer/a2_frame_perf.h",
    "Natives/Renderer/a2_gl_bridge.h",
]

# 要查调用点的符号前缀（本单新增的对外函数）。
SYMBOL_PREFIXES = ("a2_frame_perf_", "a2_gl_bridge_present_frame")

# 图形后端专有名（出现即视为「具体后端引用」，与本层「中立数值」的定位冲突）
BACKEND_TOKENS = [
    "Metal", "MoltenVK", "molt", "ANGLE", "GL4ES", "MobileGlues",
    "EGL", "OpenGL", "GLES", "Vulkan", "CAMetalLayer", "MTLDevice",
    "EAGL", "osmesa", "OSMesa",
]

# 阴性对照：已知含后端专有名的文件（解耦扫描必须在这里报警）
NEGATIVE_CONTROL = "Natives/Renderer/a2_gl_bridge.m"

SEARCH_ROOTS = ["Natives", "Air2", "JavaApp/src"]


def read(rel, root=ROOT):
    with open(os.path.join(root, rel), encoding="utf-8") as f:
        return f.read()


def check_decoupled():
    print("[1] 渲染器解耦：扫 %d 个本层文件 × %d 个后端专有名"
          % (len(LAYER_FILES), len(BACKEND_TOKENS)))
    hits = []
    for rel in LAYER_FILES:
        if not os.path.exists(os.path.join(ROOT, rel)):
            print("    ★缺文件★ %s" % rel)
            return False
        src = read(rel)
        for tok in BACKEND_TOKENS:
            if src.count(tok):
                hits.append((rel, tok, src.count(tok)))
    if hits:
        for rel, tok, n in hits:
            print("    ★命中★ %s : %s × %d" % (rel, tok, n))
        print("    ⇒ 失败：本层出现了具体后端专有名（应只留中立数值）")
        return False
    print("    命中 = 0 ✓（只认中立数值：像素/毫秒/字节/0-1 标志）")

    # ★阴性对照★：扫描器本身有效 —— 在已知含后端名的文件上必须有命中。
    control_src = read(NEGATIVE_CONTROL)
    control_hits = sum(control_src.count(tok) for tok in BACKEND_TOKENS)
    print("[1b] 阴性对照：%s 命中 = %d（应 > 0）" % (NEGATIVE_CONTROL, control_hits))
    if control_hits == 0:
        print("    ⇒ 失败：扫描器在已知文件上也查不到后端名 ⇒ 上面的 0 是假通过")
        return False
    print("    扫描器有效 ✓")
    return True


def walk_sources():
    out = []
    for top in SEARCH_ROOTS:
        base = os.path.join(ROOT, top)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirs, files in os.walk(base):
            for f in files:
                if f.endswith((".m", ".mm", ".h", ".c")):
                    out.append(os.path.join(dirpath, f))
    return out


def check_no_stone():
    declared = {}
    for rel in DECLARED_HEADERS:
        src = read(rel)
        for name in re.findall(r"\b(a2_\w+)\s*\(", src):
            if name.startswith(SYMBOL_PREFIXES):
                declared.setdefault(name, rel)

    all_files = walk_sources()
    declaring_abs = {os.path.join(ROOT, r) for r in DECLARED_HEADERS}

    print("[2] 禁石山：%d 个对外函数，逐个找调用点" % len(declared))
    if not declared:
        print("    ⇒ 失败：一个对外函数都没解析到（声明来源写错了？）")
        return False

    stone = []
    for name, home in sorted(declared.items()):
        pat = re.compile(r"\b%s\b" % re.escape(name))
        calls = 0
        where = []
        for path in all_files:
            if path in declaring_abs:
                continue          # 声明它的头不算调用点
            try:
                text = open(path, encoding="utf-8").read()
            except (OSError, UnicodeDecodeError):
                continue
            n = len(pat.findall(text))
            if n:
                calls += n
                where.append(os.path.relpath(path, ROOT))
        if calls == 0:
            stone.append((name, home))
        else:
            print("    %-34s <- %s" % (name, ", ".join(sorted(where)[:3])))
    if stone:
        for name, home in stone:
            print("    ★石山★ %s（声明于 %s）找不到任何调用点" % (name, home))
        print("    ⇒ 失败：存在「没人调」的对外接口")
        return False
    print("    全部有调用点 ✓")
    return True


def main():
    ok1 = check_decoupled()
    ok2 = check_no_stone()
    print("=" * 66)
    print("结果：" + ("全部通过 ✓" if (ok1 and ok2) else "失败"))
    return 0 if (ok1 and ok2) else 1


if __name__ == "__main__":
    sys.exit(main())
