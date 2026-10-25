#!/usr/bin/env python3
"""
Air2 tests/Natives —— ★GL 桥（a2_gl_bridge）单测运行器★（仓内测试入口）。

做什么：
  用 clang 把 Natives/Renderer 的【真实实现】(a2_gl_bridge + a2_renderer)、
  Natives/Support 的日志实现，与 tests/Natives/gl_bridge_tests.m 一起编译成
  macOS 可执行文件并运行，输出每例 PASS/FAIL 与末尾计数。

为什么是【真编译 + 真运行】而不是源码扫描：
  「哪个后端归 GL 桥管 / 该判不归本桥还是该阻断 / 缺库 / 加载失败」都是**行为**。
  源码扫描只能证明文字在文件里；只有把 a2_gl_bridge 的判据函数与 attach 分支
  真的跑一遍，才能证明「主推 Metal 不阻断、GL4ES 缺库会阻断」这类契约成立。

  为什么能在 macOS 上跑：本桥**不链接** EGL/GLES（只在运行期 dlopen），也不 import
  任何图形后端头 ⇒ 无需 EGL 环境即可编、即可跑（真建面需要 iOS 设备，属真机判定表项）。

用法：
    python3 tests/Natives/run_gl_bridge_tests.py

退出码：0 = 全部通过；1 = 有 FAIL 或工具链/编译失败。
（Windows 无 clang 时本脚本无法运行，属预期；请在 Mac 上跑。）
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # 仓根

# 被测的【真实】源文件（只用 Foundation + dlfcn ⇒ 能在 macOS 上直接编、直接跑）。
SOURCES = [
    os.path.join(ROOT, "Natives", "Renderer", "a2_gl_bridge.m"),   # ★被测主体★
    os.path.join(ROOT, "Natives", "Renderer", "a2_renderer.m"),    # 渲染器名常量（本桥复用它）
    os.path.join(ROOT, "Natives", "Renderer", "a2_frame_perf.m"),  # ★[FRAME-PERF] 帧性能判据（本桥的帧动作每帧记一次）★
    # ★MobileGlues 的 glGetError 二进制改写器★：a2_gl_bridge.m 在 attach 里调它，
    #   漏这行 ⇒ 本 runner 链接期 `_a2_gl_error_shim_install_for_handle` 未定义（实测）。
    os.path.join(ROOT, "Natives", "Renderer", "a2_gl_error_shim.m"),
    os.path.join(ROOT, "Natives", "Support", "a2_log.m"),          # 日志实现（本桥记判据行）
    os.path.join(HERE, "gl_bridge_tests.m"),
]

# 头搜索路径：Natives 代码按「裸文件名」互相 import（仓内既有写法）。
INCLUDE_DIRS = [
    os.path.join(ROOT, "Natives", "Renderer"),
    os.path.join(ROOT, "Natives", "Input"),    # a2_glfw_window.h（中立表面描述）
    os.path.join(ROOT, "Natives", "Support"),  # a2_log.h
]


def find_clang():
    clang = shutil.which("clang")
    if clang:
        return clang
    xcrun = shutil.which("xcrun")
    if xcrun:
        try:
            out = subprocess.run([xcrun, "-f", "clang"], capture_output=True, text=True)
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip()
        except Exception:
            pass
    return None


def main():
    for src in SOURCES:
        if not os.path.exists(src):
            print("缺少源文件: %s" % src)
            return 1

    clang = find_clang()
    if not clang:
        print("找不到 clang（本测试需在装有 Xcode 命令行工具的 macOS 上运行）")
        return 1
    print("clang = %s" % clang)

    tmpdir = tempfile.mkdtemp(prefix="a2glb_tests_")
    binary = os.path.join(tmpdir, "gl_bridge_tests")

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-fblocks", "-Wall", "-Wno-unused-parameter"] + includes + \
          ["-framework", "Foundation", "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Natives/{Renderer,Input,Support} ... -o gl_bridge_tests")
    ci = subprocess.run(cmd, capture_output=True, text=True)
    if ci.stderr.strip():
        print("--- clang 输出 ---")
        print(ci.stderr.strip())
    if ci.returncode != 0:
        print("!! 编译失败（rc=%d）" % ci.returncode)
        return 1

    print("run: %s\n" % binary)
    run = subprocess.run([binary], capture_output=True, text=True)
    out = run.stdout + run.stderr
    sys.stdout.write(out)

    passed = sum(1 for ln in out.splitlines() if ln.startswith("PASS"))
    failed = sum(1 for ln in out.splitlines() if ln.startswith("FAIL"))
    print("\n[runner] 解析结果：PASS=%d FAIL=%d" % (passed, failed))

    if failed or run.returncode != 0:
        return 1
    if passed == 0:
        print("[runner] 未解析到任何用例，视为失败")
        return 1
    print("[runner] 全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
