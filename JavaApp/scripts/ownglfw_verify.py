#!/usr/bin/env python3
"""
Air2 自研 GLFW —— 阶段 1 自证脚本（[A2-OWNGLFW-1]）
=====================================================
做四件事，全机可跑（不依赖 make / 不依赖 Mac）：
  ① 用 javac 编译 src/ownglfw/ 全部 .java（-source 8 -target 8，classpath = 官方 jar）
     ⇒ 断言 error = 0；
  ② 用 javac -h 生成 JNI 头，抽出全部 Java native 符号；
     再从 Natives/OwnGlfw/a2_own_glfw_bridge.m 抽出 JNIEXPORT 定义；
     ⇒ 断言 两侧符号集合逐名相等（薄 JNI 对齐自证）；
  ③ 打 build/air2-ownglfw.jar，列出包内类；断言 4 个新类在包内；
  ④ 包内自证：扫 net/kdt/pojavlaunch|Boardwalk|Amethyst|Pojav 传承标记 ⇒ 断言 命中 = 0。

退出码 0 = 全通过；非 0 = 有失败。
用法：python JavaApp/scripts/ownglfw_verify.py
"""
import os
import re
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
JAVAAPP = os.path.dirname(HERE)
ROOT = os.path.dirname(JAVAAPP)

SRC = os.path.join(JAVAAPP, "src", "ownglfw")
BUILD = os.path.join(JAVAAPP, "build")
CLASSES = os.path.join(BUILD, "ownglfw-classes")
JNI_HDR = os.path.join(BUILD, "ownglfw-jni")
JAR = os.path.join(BUILD, "air2-ownglfw.jar")
NATIVE_M = os.path.join(ROOT, "Natives", "OwnGlfw", "a2_own_glfw_bridge.m")
JARS = [os.path.join(ROOT, "Libraries", "Jars", "lwjgl-341", n)
        for n in ("lwjgl-glfw.jar", "lwjgl.jar")]

EXPECTED_CLASSES = [
    "org/lwjgl/glfw/GLFW.class",
    "org/lwjgl/glfw/GLFW$Window.class",
    "org/lwjgl/glfw/Callbacks.class",
    "org/lwjgl/glfw/GLFWNativeCocoa.class",
]
FORBIDDEN = re.compile(r"net/kdt/pojavlaunch|Boardwalk|Amethyst|Pojav", re.I)


def java_sources():
    out = []
    for base, _dirs, files in os.walk(SRC):
        for f in files:
            if f.endswith(".java"):
                out.append(os.path.join(base, f))
    return sorted(out)


# ---------------------------------------------------------------------------
# ⑤ 事件通道对齐（native ⇄ Java 全链的机器判据）
# ---------------------------------------------------------------------------
# 两侧的事件类型编号是手写的（native 头里的 A2GlfwEventType vs GLFW.java 的 A2_EV_*），
# 任何一侧加/改事件而另一侧没跟 ⇒ 事件静默丢失。这里逐名+逐值比对，不靠人眼。
NATIVE_HEADER = os.path.join(ROOT, "Natives", "Input", "a2_glfw_window.h")
GLFW_JAVA = os.path.join(SRC, "org", "lwjgl", "glfw", "GLFW.java")

# JNI 描述符首字符 → Java 类型名（只列本链用到的）
DESC_TYPES = {"J": "long", "I": "int", "D": "double", "F": "float",
              "Z": "boolean", "B": "byte", "S": "short", "C": "char"}


def check_event_channel():
    fails = []
    java = open(GLFW_JAVA, encoding="utf-8").read()
    hdr = open(NATIVE_HEADER, encoding="utf-8").read()
    bridge = open(NATIVE_M, encoding="utf-8").read()

    native_ev = {m: int(v) for m, v in
                 re.findall(r"A2_GLFW_EVENT_(\w+)\s*=\s*(\d+)", hdr)}
    java_ev = {m: int(v) for m, v in re.findall(r"A2_EV_(\w+)\s*=\s*(\d+)", java)}
    names = sorted(k for k in native_ev if k != "NONE")

    missing = [k for k in names if k not in java_ev]
    value_bad = [k for k in names if k in java_ev and native_ev[k] != java_ev[k]]
    case_bad = [k for k in names if ("case A2_EV_%s:" % k) not in java]

    print("[5] 事件通道对齐：native %d 种（不含 NONE）/ Java 常量 %d 个 / 缺 %d / 值错 %d / 无 case %d"
          % (len(names), len(java_ev), len(missing), len(value_bad), len(case_bad)))
    if missing:
        print("    缺 Java 常量:", missing)
        fails.append("event-const")
    if value_bad:
        print("    值不一致:", [(k, native_ev[k], java_ev[k]) for k in value_bad])
        fails.append("event-value")
    if case_bad:
        print("    派发缺 case:", case_bad)
        fails.append("event-case")

    # 派发入口的签名必须与 native 侧 upcall 的描述符逐位一致（描述符 = 唯一事实源）
    m = re.search(r'a2OwnGlfwDispatch\s*\(([^)]*)\)', java)
    sig_m = re.search(r'A2_OWN_GLFW_JAVA_SIG\s+"([^"]+)"', bridge)
    if not m or not sig_m:
        print("    找不到派发方法或 native 描述符宏")
        fails.append("dispatch-sig")
        return fails
    params = [p.strip() for p in m.group(1).split(",") if p.strip()]
    jtypes = [p.split()[0] for p in params]
    sig = sig_m.group(1)
    desc_args = sig[1:sig.index(")")]
    ntypes = [DESC_TYPES.get(c, "?") for c in desc_args]
    print("    %s 参数 %s / native 描述符 %s ⇒ %s"
          % ("a2OwnGlfwDispatch", jtypes, sig, ntypes))
    if jtypes != ntypes:
        print("    ★签名与描述符不一致★")
        fails.append("dispatch-sig")
    return fails


def main():
    fails = []

    # ---- ① 编译 ----
    for d in (CLASSES, JNI_HDR):
        if os.path.isdir(d):
            for base, _dirs, files in os.walk(d, topdown=False):
                for f in files:
                    os.remove(os.path.join(base, f))
                os.rmdir(base)
    os.makedirs(CLASSES, exist_ok=True)
    os.makedirs(JNI_HDR, exist_ok=True)

    cp = os.pathsep.join(JARS)
    srcs = java_sources()
    cmd = ["javac", "-J-Duser.language=en", "-J-Duser.country=US",
           "-source", "8", "-target", "8", "-encoding", "UTF-8",
           "-Xlint:-options", "-cp", cp, "-h", JNI_HDR, "-d", CLASSES] + srcs
    r = subprocess.run(cmd, capture_output=True, text=True)
    errors = [l for l in (r.stdout + r.stderr).splitlines() if "error" in l.lower()]
    print("[1] javac rc=%d  sources=%d  error_lines=%d" % (r.returncode, len(srcs), len(errors)))
    for l in errors[:20]:
        print("    ", l)
    if r.returncode != 0 or errors:
        fails.append("compile")

    # ---- ② 薄 JNI 符号对齐 ----
    hdr_path = os.path.join(JNI_HDR, "org_lwjgl_glfw_GLFW.h")
    java_syms = []
    if os.path.isfile(hdr_path):
        h = open(hdr_path, encoding="utf-8").read()
        java_syms = sorted(set(re.findall(r"Java_org_lwjgl_glfw_GLFW_\w+", h)))
    native_syms = []
    if os.path.isfile(NATIVE_M):
        m = open(NATIVE_M, encoding="utf-8").read()
        native_syms = sorted(set(re.findall(r"Java_org_lwjgl_glfw_GLFW_\w+", m)))
    missing = [s for s in java_syms if s not in native_syms]
    extra = [s for s in native_syms if s not in java_syms]
    print("[2] JNI 符号：Java 声明 %d 个 / native 定义 %d 个 / 缺 %d / 多 %d"
          % (len(java_syms), len(native_syms), len(missing), len(extra)))
    if missing:
        print("    缺:", missing)
    if extra:
        print("    多:", extra)
    if java_syms != native_syms or not java_syms:
        fails.append("jni-parity")

    # ---- ③ 打包 + 包内类 ----
    manifest = "Manifest-Version: 1.0\r\nCreated-By: Air2 ownglfw\r\n\r\n"
    entries = []
    with zipfile.ZipFile(JAR, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("META-INF/MANIFEST.MF", manifest)
        for base, _dirs, files in os.walk(CLASSES):
            for f in files:
                p = os.path.join(base, f)
                arc = os.path.relpath(p, CLASSES).replace(os.sep, "/")
                z.write(p, arc)
                entries.append(arc)
        listing = os.path.join(SRC, "META-INF", "ownglfw.list")
        if os.path.isfile(listing):
            z.write(listing, "META-INF/ownglfw.list")
            entries.append("META-INF/ownglfw.list")
    print("[3] jar=%s  包内条目=%d" % (os.path.relpath(JAR, ROOT), len(entries)))
    for c in EXPECTED_CLASSES:
        if c not in entries:
            print("    缺类:", c)
            fails.append("jar-class:" + c)
    print("    关键类:", ", ".join(EXPECTED_CLASSES))

    # ---- ④ 传承标记自证 ----
    hits = [e for e in entries if FORBIDDEN.search(e)]
    print("[4] 包内自证：Pojav/Boardwalk/Amethyst 传承命中 = %d" % len(hits))
    if hits:
        print("    命中:", hits)
        fails.append("provenance")

    # ---- ⑤ 事件通道对齐（native ⇄ Java）----
    fails.extend(check_event_channel())

    print("=" * 66)
    print("结果：" + ("全部通过 ✓" if not fails else ("失败 " + ", ".join(fails))))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
