#!/usr/bin/env python3
"""
A2 [A2-PAIRWIRE] 设备发起配对「最后一跳」单测 —— 一键运行器。

做什么：
  用 clang 把 Natives/Support 下的【真实】源码（pairable-host 广告契约 + pair-setup 的
  accessory 侧驱动 + 整条链的驱动件）与 tests/JIT/pairwire_tests.m 一起编译成 macOS
  可执行文件并运行，输出每例 PASS/FAIL 与末尾计数。

被证的是什么（★只证自洽★）：
  · accessory 侧「先收后发」的 PS-Msg01..06 用【真密码学】跑通（对端用真的 Host 会话对拍）；
  · 广告 → 连入 → 建传输 → 会话 → 交出配对文件 的整条链（假广告器 + 假传输）；
  · 失败路径：超时 / 错码（含篡改）/ 乱序 / 非 TLV / 无本地网络权限 / 被挂起 / 取消 …
  ★与 iOS 27 真设备的互操作未验证（无真机）★ —— 本 runner 不声称那部分。

用法：
    python3 tests/JIT/run_pairwire_tests.py

退出码：0 = 全部通过；1 = 有 FAIL 或工具链/编译失败。
（Windows 无 clang 时本脚本无法运行，属预期；请在 Mac 上跑。）

★与其它单的测试文件不共用★：本 runner 只编译本单需要的文件 + a2_log.m，
  不碰 tests/JIT/jit_logic_tests.m 与 tests/JIT/remotexpc_tests.m（避免撞车）。
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # 仓根
SUPPORT = os.path.join(ROOT, "Natives", "Support")

SOURCES = [
    # 判据行 / 日志（只依赖 Foundation + stdio）
    os.path.join(SUPPORT, "a2_log.m"),
    # RPPairing 内核与密码学原语（pair-setup 会话要用）
    os.path.join(SUPPORT, "a2_rppairing.m"),
    os.path.join(SUPPORT, "a2_rppairing_crypto.m"),
    os.path.join(SUPPORT, "a2_rppairing_chacha.m"),
    os.path.join(SUPPORT, "a2_rppairing_ed25519.m"),
    os.path.join(SUPPORT, "a2_rppairing_srp.m"),            # mbedtls_mpi 模幂
    os.path.join(SUPPORT, "a2_rppairing_pairsetup.m"),      # PS-Msg01..06 消息机 + 两侧驱动
    os.path.join(SUPPORT, "a2_rppairing_pairsetup_accessory.m"),   # ★本单新增：广告→连入→会话→交出文件
    os.path.join(SUPPORT, "a2_rppairing_rsd.m"),            # 服务类型常量（复用，不另造）
    os.path.join(SUPPORT, "a2_rppairing_verify.m"),
    # pairable-host 通告器（accessory 生产工厂要用它的 authTag / 新 altIRK / 服务名 / 广告器类）
    os.path.join(SUPPORT, "a2_rppairing_pairable_host.m"),
    os.path.join(SUPPORT, "a2_remotexpc_framing.m"),
    os.path.join(SUPPORT, "a2_remotexpc_session.m"),
    os.path.join(SUPPORT, "a2_rppairing_pairsetup_transport.m"),
    # 本单测试
    os.path.join(HERE, "pairwire_tests.m"),
]

MBEDTLS_DIR = os.path.join(ROOT, "Libraries", "ThirdParty", "mbedtls")
MBEDTLS_INCLUDE = os.path.join(MBEDTLS_DIR, "include")
MBEDTLS_MACOS_LIB = os.path.join(MBEDTLS_DIR, "lib-macos")


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

    tmpdir = tempfile.mkdtemp(prefix="a2pairwire_tests_")
    binary = os.path.join(tmpdir, "pairwire_tests")

    if not os.path.isdir(MBEDTLS_INCLUDE):
        print("缺少 mbedTLS 头目录: %s" % MBEDTLS_INCLUDE)
        return 1
    mbedcrypto = os.path.join(MBEDTLS_MACOS_LIB, "libmbedcrypto.a")
    if not os.path.exists(mbedcrypto):
        print("缺少 macOS mbedcrypto: %s" % mbedcrypto)
        print("  → 先在 Mac 上跑：bash scripts/build_mbedtls_macos_tests.sh <mbedtls-3.6.2 源码目录>")
        return 1

    includes = ["-I", SUPPORT, "-I", MBEDTLS_INCLUDE]
    cmd = [clang, "-fobjc-arc", "-fblocks", "-Wall", "-Wno-unused-parameter"] + \
        includes + ["-framework", "Foundation", "-framework", "Security",
                    # pairable-host 通告器 + 传输层用 Network.framework
                    "-framework", "Network",
                    # a2_rppairing_srp.m 的 mbedtls_mpi（静态库，macOS 测试用）
                    "-L", MBEDTLS_MACOS_LIB, "-lmbedcrypto",
                    "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Natives/Support ... -o pairwire_tests")
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
