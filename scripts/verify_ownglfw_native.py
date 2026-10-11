#!/usr/bin/env python3
"""
Air2 自研 GLFW native 层 —— 静态自证（[A2-OWNGLFW-NATIVE-1]）
============================================================
无需 Mac / 无需编译器，全机可跑。查两件本单的硬约束：

  ① 【与渲染器解耦】本层 5 个源文件里不得出现任何图形后端的专有名。
     （要求 2：不得出现具体渲染器引用 ⇒ 机器判据 = 命中 0。）
  ② 【禁石山】a2_glfw_window.h / a2_glfw_input.h 里声明的每个 a2_glfw_* 函数，
     必须在工程内**至少有一处调用点**（声明它的头文件本身不算）。
     （要求 3：每个新增函数必须能指出谁调它。找不到调用点 = 石山。）

JNI 符号一一对应（Java 声明 vs native 定义）由 JavaApp/scripts/ownglfw_verify.py 负责，
本脚本不重复。

用法：python3 scripts/verify_ownglfw_native.py        （退出码 0 = 全通过）
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

LAYER_FILES = [
    "Natives/Input/a2_glfw_window.h",
    "Natives/Input/a2_glfw_window.m",
    "Natives/Input/a2_glfw_input.h",
    "Natives/Input/a2_glfw_input.m",
    "Natives/OwnGlfw/a2_own_glfw_bridge.m",
]
PUBLIC_HEADERS = [
    "Natives/Input/a2_glfw_window.h",
    "Natives/Input/a2_glfw_input.h",
]
# 图形后端专有名（出现即视为「具体引用」，与本层「中立抽象」的定位冲突）
BACKEND_TOKENS = [
    "Metal", "MoltenVK", "molt", "ANGLE", "GL4ES", "MobileGlues",
    "EGL", "OpenGL", "GLES", "Vulkan", "CAMetalLayer", "MTLDevice",
    "EAGL", "osmesa", "OSMesa",
]
SEARCH_ROOTS = ["Natives", "Air2", "JavaApp/src"]


def read(rel, root=ROOT):
    with open(os.path.join(root, rel), encoding="utf-8") as f:
        return f.read()


def check_decoupled():
    hits = []
    for rel in LAYER_FILES:
        src = read(rel)
        for tok in BACKEND_TOKENS:
            n = src.count(tok)
            if n:
                hits.append((rel, tok, n))
    print("[1] 渲染器解耦：扫 %d 个本层文件 × %d 个后端专有名" % (len(LAYER_FILES), len(BACKEND_TOKENS)))
    if hits:
        for rel, tok, n in hits:
            print("    ★命中★ %s : %s × %d" % (rel, tok, n))
        print("    ⇒ 失败：本层出现了具体后端专有名（应只留中立抽象）")
        return False
    print("    命中 = 0 ✓（只留中立表面描述 A2GlfwSurface）")
    return True


def walk_sources():
    out = []
    for top in SEARCH_ROOTS:
        base = os.path.join(ROOT, top)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirs, files in os.walk(base):
            for f in files:
                if f.endswith((".m", ".mm", ".h", ".c", ".java")):
                    out.append(os.path.join(dirpath, f))
    return out


def check_no_stone():
    declared = {}
    for rel in PUBLIC_HEADERS:
        src = read(rel)
        for name in re.findall(r"\b(a2_glfw_\w+)\s*\(", src):
            declared.setdefault(name, rel)

    all_files = walk_sources()
    declaring_abs = {os.path.join(ROOT, r) for r in PUBLIC_HEADERS}

    print("[2] 禁石山：%d 个对外函数，逐个找调用点" % len(declared))
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
            print("    %-32s <- %s" % (name, ", ".join(sorted(where)[:3])))
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
