#!/usr/bin/env python3
"""
A2 JIT 纯逻辑单元测试 —— 一键运行器（★仓内测试入口★）。

做什么：
  用 clang 把 Air2/Player 下的【真实】纯逻辑源文件与 tests/JIT/jit_logic_tests.m
  一起编译成 macOS 可执行文件并运行，输出每例 PASS/FAIL 与末尾计数。

为什么是真编译而不是 Python 镜像：
  版本隔离那套测试用 Python 镜像，是因为当年 iSH 里没有 ObjC 编译器。
  本机（Mac）有 clang + Foundation，可以直接编译【被测的真实实现】——这严格强于镜像。

用法：
    python3 tests/JIT/run_jit_tests.py

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
PLAYER = os.path.join(ROOT, "Air2", "Player")

# 被测的【真实】源文件（纯逻辑，无 UIKit）。
SOURCES = [
    os.path.join(PLAYER, "A2JITProvider.m"),
    os.path.join(PLAYER, "A2JITFacts.m"),
    os.path.join(PLAYER, "A2JITStrategySelector.m"),
    os.path.join(PLAYER, "A2PairingFile.m"),
    os.path.join(PLAYER, "A2JITStateMachine.m"),
    os.path.join(PLAYER, "A2JITCoordinator.m"),
    os.path.join(PLAYER, "A2LaunchChain.m"),
    # --- [JIT↔VM] 启动链失败分类 / 判据行 / 用户文案（纯逻辑，可单测）---
    os.path.join(PLAYER, "A2LaunchFailure.m"),
    os.path.join(PLAYER, "A2JITAutomaticPairingProvider.m"),
    os.path.join(PLAYER, "A2JITImportedPairingProvider.m"),
    os.path.join(PLAYER, "A2JITExternalToolProvider.m"),
    os.path.join(PLAYER, "A2JITKernelJITProvider.m"),
    os.path.join(PLAYER, "A2JITLocalFactsSource.m"),
    # --- [JIT-IMPL-2] 本单新增的纯逻辑件（判据缝 / 分流表 / 四语文案 / 配对文件存储）---
    os.path.join(PLAYER, "A2JITVerdictGuidance.m"),
    os.path.join(PLAYER, "A2JITStrings.m"),
    os.path.join(PLAYER, "A2JITPairingFileStore.m"),
    # --- [JIT-AUTOPAIR-1] 自动配对（iOS 27+，自研 RPPairing）的类型 / 前置条件 / 分流表 ---
    os.path.join(PLAYER, "A2JITAutoPairing.m"),
    os.path.join(PLAYER, "A2JITAutoPairingGuidance.m"),
    # --- [JIT-AUTOPAIR-3] 配对码来源（可选项表 + 解析）+ 设备发起档的 6 位码会话 ---
    os.path.join(PLAYER, "A2JITPairingPinSource.m"),
    os.path.join(PLAYER, "A2JITPairingCodeSession.m"),
    # 跨层契约常量（A2SelectedPairingPinSourcePrefKey 的唯一定义点）
    os.path.join(ROOT, "Air2", "Utils", "A2LaunchContract.m"),
    # --- [JIT-DDI-1] DDI（Developer Disk Image）：类型 / 纯逻辑 / 本地镜像存储 / 判定合成 / 分流表 ---
    os.path.join(PLAYER, "A2JITDDI.m"),
    os.path.join(PLAYER, "A2JITDDIStore.m"),
    os.path.join(PLAYER, "A2JITDDIProbe.m"),
    os.path.join(PLAYER, "A2JITDDIGuidance.m"),
    # --- [JIT-AUTOPAIR-2] RPPairing 握手内核（Natives/Support：★真实现，含系统 corecrypto 的 X25519★）---
    os.path.join(ROOT, "Natives", "Support", "a2_rppairing_crypto.m"),
    os.path.join(ROOT, "Natives", "Support", "a2_rppairing.m"),
    # --- [JIT-AUTOPAIR-2] 真握手本体：自研密码学原语 + pair-verify 消息机 + RSD 发现/连接 ---
    os.path.join(ROOT, "Natives", "Support", "a2_rppairing_chacha.m"),
    os.path.join(ROOT, "Natives", "Support", "a2_rppairing_ed25519.m"),
    os.path.join(ROOT, "Natives", "Support", "a2_rppairing_verify.m"),
    os.path.join(ROOT, "Natives", "Support", "a2_rppairing_rsd.m"),
    # --- [JIT-AUTOPAIR-3] pair-setup：SRP-3072 内核 + PS-Msg01..06 消息机
    #     （真实现；大数模幂用随仓第三方 mbedTLS 的 mbedtls_mpi —— 见下方 MBEDTLS_MACOS_LIB）---
    os.path.join(ROOT, "Natives", "Support", "a2_rppairing_srp.m"),
    os.path.join(ROOT, "Natives", "Support", "a2_rppairing_pairsetup.m"),
    # --- [A2-INTEGRATION] TLS-PSK 隧道门面（可替换后端 / 默认关 / 不上云；纯逻辑，无第三方）---
    os.path.join(ROOT, "Natives", "Support", "a2_tlspsk_tunnel.m"),
    # 门面用项目统一的 a2_log_f 记日志 ⇒ 测试里一并链接该纯日志实现（只有 Foundation+stdio）。
    os.path.join(ROOT, "Natives", "Support", "a2_log.m"),
    os.path.join(HERE, "jit_logic_tests.m"),
]

# 额外头搜索路径：测试要用 Natives 的判据枚举做「跨层镜像」的运行期断言
# （★只读头文件里的枚举值，不链接 A2JITEnvironment.m★ —— 后者的实现含 arm64 裸 brk）。
EXTRA_INCLUDES = [os.path.join(ROOT, "Natives", "Support"),
                  # [JIT-AUTOPAIR-3] 跨层契约常量（A2SelectedPairingPinSourcePrefKey 等）
                  os.path.join(ROOT, "Air2", "Utils")]

# ---------------------------------------------------------------------------
# [JIT-AUTOPAIR-3] 随仓第三方 mbedTLS（Apache-2.0）—— a2_rppairing_srp.m 用 mbedtls_mpi 做模幂。
#   头：Libraries/ThirdParty/mbedtls/include
#   库：Libraries/ThirdParty/mbedtls/lib-macos/libmbedcrypto.a
#       ★macOS(x86_64+arm64) 专用★，供本测试在 Mac 上真链接；由
#       scripts/build_mbedtls_macos_tests.sh 离线重建（与 iOS 版同源 3.6.2）。
# ---------------------------------------------------------------------------
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

    tmpdir = tempfile.mkdtemp(prefix="a2jit_tests_")
    binary = os.path.join(tmpdir, "jit_logic_tests")

    includes = ["-I", PLAYER]
    for inc in EXTRA_INCLUDES:
        includes += ["-I", inc]
    # [JIT-AUTOPAIR-3] mbedTLS（a2_rppairing_srp.m 的 mbedtls_mpi）—— 头 + macOS 库。
    if not os.path.isdir(MBEDTLS_INCLUDE):
        print("缺少 mbedTLS 头目录: %s" % MBEDTLS_INCLUDE)
        return 1
    mbedcrypto = os.path.join(MBEDTLS_MACOS_LIB, "libmbedcrypto.a")
    if not os.path.exists(mbedcrypto):
        print("缺少 macOS mbedcrypto: %s" % mbedcrypto)
        print("  → 先在 Mac 上跑：bash scripts/build_mbedtls_macos_tests.sh <mbedtls-3.6.2 源码目录>")
        return 1
    includes += ["-I", MBEDTLS_INCLUDE]
    cmd = [clang, "-fobjc-arc", "-fblocks", "-Wall", "-Wno-unused-parameter"] + \
          includes + ["-framework", "Foundation", "-framework", "Security",
                      # RSD 层用 Bonjour 发现/连接（NWBrowser/NWConnection）⇒ 需要 Network
                      "-framework", "Network",
                      # [JIT-AUTOPAIR-3] 链 macOS 版 mbedcrypto（静态；只被 mbedtls_mpi 用到）
                      "-L", MBEDTLS_MACOS_LIB, "-lmbedcrypto",
                      "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Air2/Player ... -o jit_logic_tests")
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
