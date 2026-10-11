#!/usr/bin/env python3
"""
Air2 复用线 GLFW 覆盖层 —— native 对端静态自证（[A2-GLFW-OVERLAY-1]）
====================================================================
无需 Mac / 无需编译器 / 无需 MC 实例，全机可跑。查四件事：

  ① 【JNI 逐名对齐】从复用线 Java 覆盖层（JavaApp/src/lwjgl/**）抽 `static native` 声明，
     与 Natives/Input/a2_glfw_overlay_bridge.m 的 JNIEXPORT 定义逐名比对：
     缺一个 = Java 侧第一次调用就 UnsatisfiedLinkError；多一个 = 没人调的石山。
     ★唯一允许的例外★：`nativeSetModifiers`（全仓无调用方）必须【不在】实现里，
     且必须出现在许可名单中 —— 这条断言把「只列清单不落」变成机器可判。

  ② 【pojav* 契约】GLFW.java 的 `apiGetFunctionAddress(GLFW, "pojav…")` 集合
     （Functions 类初始化时逐个解析，缺一个就让该类初始化抛异常）
     与 .m 里的 C 入口定义逐名对齐。

  ③ 【渲染器解耦】本文件不得出现任何图形后端专有名（与 scripts/verify_ownglfw_native.py 同款判据）。

  ④ 【包内判据锚点】本文件必须含 `[A2-GLFW-PEER]`（真机 grep 锚点 + 包内自证用）。

用法：python3 scripts/verify_glfw_overlay_native.py        （退出码 0 = 全通过）
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

JAVA_GLFW = "JavaApp/src/lwjgl/org/lwjgl/glfw/GLFW.java"
JAVA_CB = "JavaApp/src/lwjgl/org/lwjgl/glfw/CallbackBridge.java"
NATIVE_M = "Natives/Input/a2_glfw_overlay_bridge.m"

# 「只列清单不落」的许可名单（必须“声明存在、实现不存在”）
DECLARED_BUT_NOT_IMPLEMENTED = {
    "nativeSetModifiers": "CallbackBridge.java:64 声明；全仓无调用方（其原设计由 native 输入桥在"
                          "按键时回调以同步 modifier 缓存，那条桥未落）⇒ 按纪律只列清单不落",
}

BACKEND_TOKENS = [
    "Metal", "MoltenVK", "molt", "ANGLE", "GL4ES", "MobileGlues",
    "EGL", "OpenGL", "GLES", "Vulkan", "CAMetalLayer", "MTLDevice",
    "EAGL", "osmesa", "OSMesa",
]

JNI_PREFIX_GLFW = "Java_org_lwjgl_glfw_GLFW_"
JNI_PREFIX_CB = "Java_org_lwjgl_glfw_CallbackBridge_"


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def strip_line_comments(src):
    """去掉 // 行注释（Java 里被注释掉的 native 声明不算声明，如 nglfwSetInputReady）。"""
    return "\n".join(re.sub(r"//.*$", "", line) for line in src.splitlines())


def strip_block_comments(src):
    return re.sub(r"/\*.*?\*/", "", src, flags=re.S)


def java_static_natives():
    """复用线 Java 侧真实的 `static native` 声明名（按声明所在类分组）。"""
    out = {}
    for rel, cls in ((JAVA_GLFW, "GLFW"), (JAVA_CB, "CallbackBridge")):
        src = strip_line_comments(strip_block_comments(read(rel)))
        names = re.findall(r"\bstatic\s+native\s+[\w\.\[\]<>]+\s+(\w+)\s*\(", src)
        out[cls] = sorted(set(names))
    return out


def java_pojav_entries():
    src = strip_line_comments(strip_block_comments(read(JAVA_GLFW)))
    return sorted(set(re.findall(r'apiGetFunctionAddress\(GLFW,\s*"(pojav\w+)"\)', src)))


def native_defs():
    src = read(NATIVE_M)
    jni = sorted(set(re.findall(r"\bJNIEXPORT\s+[\w\s\*]+?\sJNICALL\s+(\w+)", src)))
    # C 入口允许带可见性宏（如 A2_GLFW_ENTRY = __attribute__((visibility("default")))）：
    # 主可执行文件里「普通全局函数」会被标 N_PEXT（未导出），而 Java 侧是运行期 dlsym 按名字找
    # ⇒ 这批入口必须显式 default 可见性（本单实测：不加属性时 nm -gU 计 0）。
    c_entries = sorted(set(re.findall(r"^\s*(?:\w+\s+)?(?:jint|jlong|void)\s+(pojav\w+)\s*\(", src, re.M)))
    return jni, c_entries, src


def main():
    ok = True
    jni, c_entries, native_src = native_defs()
    jni_glfw = [s for s in jni if s.startswith(JNI_PREFIX_GLFW)]
    jni_cb = [s for s in jni if s.startswith(JNI_PREFIX_CB)]
    java = java_static_natives()
    java_glfw = [JNI_PREFIX_GLFW + n for n in java["GLFW"]]
    java_cb = [JNI_PREFIX_CB + n for n in java["CallbackBridge"]]

    print("[1] JNI 逐名对齐（Java 声明 ↔ native 定义）")
    for label, jlist, nlist, cls in (("GLFW", java_glfw, jni_glfw, "GLFW"),
                                     ("CallbackBridge", java_cb, jni_cb, "CallbackBridge")):
        # 许可名单里的声明不计入「必须实现」
        must = [s for s in jlist if s.rsplit("_", 1)[-1] not in DECLARED_BUT_NOT_IMPLEMENTED]
        missing = sorted(set(must) - set(nlist))
        extra = sorted(set(nlist) - set(jlist))
        print("    %-15s Java 声明 %2d（需实现 %2d） / native 定义 %2d" % (label, len(jlist), len(must), len(nlist)))
        if missing:
            print("      ★缺实现★", missing)
            ok = False
        if extra:
            print("      ★多余（没人调的符号）★", extra)
            ok = False
    for name, why in DECLARED_BUT_NOT_IMPLEMENTED.items():
        declared = any(s.endswith(name) for s in jni_cb + jni_glfw)
        actually_declared = any(n == name for n in java["CallbackBridge"] + java["GLFW"])
        if not actually_declared:
            print("      ★许可名单失配★ %s 在 Java 侧已不存在声明（名单该删）" % name)
            ok = False
        elif declared:
            print("      ★许可名单失配★ %s 被实现了，但它应在「只列清单不落」名单里" % name)
            ok = False
        else:
            print("      ✓ 未落项 %s：声明存在、实现不存在 —— %s" % (name, why))
    if not jni_glfw:
        print("      ★native 侧一个 GLFW JNI 符号都没有★")
        ok = False

    print("[2] pojav* 契约（GLFW.java:604-624 的 Functions 类）")
    jp = java_pojav_entries()
    missing = sorted(set(jp) - set(c_entries))
    extra = sorted(set(c_entries) - set(jp))
    print("    Java 侧 apiGetFunctionAddress(pojav…) = %d / native 侧 C 入口 = %d" % (len(jp), len(c_entries)))
    if missing:
        print("      ★缺★", missing)
        ok = False
    if extra:
        print("      ★多★", extra)
        ok = False
    if not missing and not extra and jp:
        print("      逐名一致 ✓", jp)

    print("[3] 渲染器解耦：%s × %d 个后端专有名" % (NATIVE_M, len(BACKEND_TOKENS)))
    hits = [(t, native_src.count(t)) for t in BACKEND_TOKENS if native_src.count(t)]
    if hits:
        for t, n in hits:
            print("      ★命中★ %s × %d" % (t, n))
        ok = False
    else:
        print("      命中 = 0 ✓")

    print("[4] 包内判据锚点")
    for anchor in ("[A2-GLFW-PEER]", "Java_org_lwjgl_glfw_GLFW_nglfwSetKeyCallback"):
        if anchor in native_src:
            print("      ✓ %s" % anchor)
        else:
            print("      ★缺★ %s" % anchor)
            ok = False

    print("=" * 66)
    print("结果：" + ("全部通过 ✓" if ok else "失败"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
