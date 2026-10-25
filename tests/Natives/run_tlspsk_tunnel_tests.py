#!/usr/bin/env python3
"""
Air2 tests/Natives —— [A2-PAIR-ONDEVICE] TLS-PSK 隧道单测运行器。

做什么：
  用 clang 把 Natives/Support 的【真实实现】（a2_tlspsk_tunnel 门面 +
  a2_tlspsk_mbedtls 后端 + a2_tlspsk_selftest 回环服务端 + a2_log）与
  tests/Natives/tlspsk_tunnel_tests.m 一起编成 macOS 可执行文件，并**真跑**：
  起 127.0.0.1 的 PSK 服务端 → 用生产门面握手 → 回显一帧 → 核对协商套件。

为什么能在 macOS 上跑：
  随仓 `Libraries/ThirdParty/mbedtls/lib-macos/libmbedcrypto.a` 含 ssl 目标
  （build_mbedtls_macos_tests.sh:42 的「ssl/x509 一并进库」）⇒ 无需 iOS 设备即可
  做一次真的 TLS 1.2 PSK 握手。设备侧互操作仍属真机判定项。

用法：
    python3 tests/Natives/run_tlspsk_tunnel_tests.py

退出码：0 = 全部通过；1 = 有 FAIL / 编译失败 / 缺库。
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # 仓根

SOURCES = [
    os.path.join(ROOT, "Natives", "Support", "a2_tlspsk_tunnel.m"),
    os.path.join(ROOT, "Natives", "Support", "a2_tlspsk_mbedtls.m"),
    os.path.join(ROOT, "Natives", "Support", "a2_tlspsk_selftest.m"),
    os.path.join(ROOT, "Natives", "Support", "a2_log.m"),
    os.path.join(HERE, "tlspsk_tunnel_tests.m"),
]

INCLUDE_DIRS = [
    os.path.join(ROOT, "Natives", "Support"),
    os.path.join(ROOT, "Libraries", "ThirdParty", "mbedtls", "include"),
]

MBEDTLS_MACOS_LIB = os.path.join(ROOT, "Libraries", "ThirdParty", "mbedtls",
                                 "lib-macos", "libmbedcrypto.a")


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
    if not os.path.exists(MBEDTLS_MACOS_LIB):
        print("缺少 macOS 版 mbedTLS 静态库: %s" % MBEDTLS_MACOS_LIB)
        print("（先跑 bash scripts/build_mbedtls_macos_tests.sh /path/to/mbedtls-3.6.2）")
        return 1

    clang = find_clang()
    if not clang:
        print("找不到 clang（本测试需在装有 Xcode 命令行工具的 macOS 上运行）")
        return 1
    print("clang = %s" % clang)

    tmpdir = tempfile.mkdtemp(prefix="a2tlspsk_tests_")
    binary = os.path.join(tmpdir, "tlspsk_tunnel_tests")

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-fblocks", "-Wall", "-Wno-unused-parameter"] + includes + [
        "-framework", "Foundation", "-framework", "Security", "-o", binary] + SOURCES + [
        MBEDTLS_MACOS_LIB]
    print("compile: clang -fobjc-arc -I Natives/Support -I mbedtls/include … -o tlspsk_tunnel_tests")
    ci = subprocess.run(cmd, capture_output=True, text=True)
    if ci.stderr.strip():
        print("--- clang 输出 ---")
        print(ci.stderr.strip())
    if ci.returncode != 0:
        print("!! 编译失败（rc=%d）" % ci.returncode)
        return 1

    print("run: %s\n" % binary)
    run = subprocess.run([binary], capture_output=True, text=True, timeout=120)
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
