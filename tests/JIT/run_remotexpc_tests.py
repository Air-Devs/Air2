#!/usr/bin/env python3
"""
A2 [A2-RXPC] 传输层单测 —— 一键运行器。

做什么：
  用 clang 把 Natives/Support 下的【真实】传输层源文件与 tests/JIT/remotexpc_tests.m
  一起编译成 macOS 可执行文件并运行，输出每例 PASS/FAIL 与末尾计数。

为什么是真编译而不是 Python 镜像：
  被测的是 ObjC 的帧/HPACK/XPC 编解码与会话状态机 —— 直接编译【真实实现】严格强于镜像。

用法：
    python3 tests/JIT/run_remotexpc_tests.py

退出码：0 = 全部通过；1 = 有 FAIL 或工具链/编译失败。
（Windows 无 clang 时本脚本无法运行，属预期；请在 Mac 上跑。）

★与另一单的测试文件不共用★：本 runner 只编译本单新增的文件 + a2_log.m，
  不碰 tests/JIT/jit_logic_tests.m 与 run_jit_tests.py（避免撞车）。
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # 仓根
SUPPORT = os.path.join(ROOT, "Natives", "Support")

# 被测的【真实】源文件（本单新增；纯逻辑 + Network 适配层）。
SOURCES = [
    os.path.join(SUPPORT, "a2_remotexpc_framing.m"),
    os.path.join(SUPPORT, "a2_remotexpc_session.m"),
    os.path.join(SUPPORT, "a2_rppairing_pairsetup_transport.m"),
    os.path.join(SUPPORT, "a2_rppairing_pairable_host.m"),
    # pairable-host 复用既有 RSD 层的服务类型常量（★不另造常量★）⇒ 需要链接该层。
    # 该层已在 tests/JIT/run_jit_tests.py 里被证明可在本编译配置下编过。
    os.path.join(SUPPORT, "a2_rppairing_rsd.m"),
    os.path.join(SUPPORT, "a2_rppairing_verify.m"),
    os.path.join(SUPPORT, "a2_rppairing.m"),
    os.path.join(SUPPORT, "a2_rppairing_crypto.m"),
    os.path.join(SUPPORT, "a2_rppairing_chacha.m"),
    os.path.join(SUPPORT, "a2_rppairing_ed25519.m"),
    # 判据行走到 a2_log_f ⇒ 一并链接项目统一的纯日志实现（只有 Foundation + stdio）。
    os.path.join(SUPPORT, "a2_log.m"),
    os.path.join(HERE, "remotexpc_tests.m"),
]

# 头搜索路径：本层文件以裸文件名互相 import（与 gen_xcodeproj.py 的 NATIVES_INCLUDE_DIRS 同款）。
EXTRA_INCLUDES = [SUPPORT]


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

    tmpdir = tempfile.mkdtemp(prefix="a2rxpc_tests_")
    binary = os.path.join(tmpdir, "remotexpc_tests")

    includes = []
    for inc in EXTRA_INCLUDES:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-fblocks", "-Wall", "-Wno-unused-parameter"] + \
          includes + ["-framework", "Foundation", "-framework", "Security",
                      # 传输层与 pairable-host 通告器用 Network.framework
                      "-framework", "Network",
                      "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Natives/Support ... -o remotexpc_tests")
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
