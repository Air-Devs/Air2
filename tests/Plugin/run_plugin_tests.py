#!/usr/bin/env python3
"""
Air2 tests/Plugin —— ★插件数据层 + 安装器单测运行器★

做什么：
  用 clang 把 Air2/Core 下的【真实实现】与 tests/Plugin 下的用例编成两个 macOS
  可执行文件并运行，逐例输出 PASS/FAIL 与末尾计数：

  ① plugin_data_tests
       A2PluginManifest.m  （manifest.json 解析 / 校验 / 权限集规范串）
       A2PluginRegistry.m  （registry.json 原子读写 / approvedHashes 淘汰 / 损坏不覆写）
  ② plugin_installer_tests
       A2PluginInstaller.m          （安装 / 卸载 / 回退 / 版本规则）
       A2PluginPackageExtractor.m   （中央目录预检 / 解压 / 完整性 / 摘要）
       A2ZipReader.m                （条目元数据 / 流式解压 / 本地头核对）
       A2PluginManifest.m、A2PluginRegistry.m、A2Log.m
  ③ plugin_boot_guard_tests
       A2PluginBootGuard.m          （boot marker / 连续 3 次未跨首帧自动停用）
       A2PluginRegistry.m、A2PluginManifest.m

为什么是【真编译 + 真运行】而不是源码扫描：
  「拒装」的每一条理由都必须是可执行的绿或红。zip 炸弹、穿越条目、符号链接、
  同版本换包、降级 —— 这些都是**行为**，源码扫描只能证明「文字在文件里」，
  只有把真实实现跑一遍才能证明门在那儿。

用法：
    python3 tests/Plugin/run_plugin_tests.py

退出码：0 = 全部通过；1 = 有 FAIL 或工具链/编译失败。
（本机没有 clang 时脚本会明确报告「未编译」，不假装跑过 —— 属预期；请在 Mac 上跑。）
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # 仓根

PLUGIN_DIR = os.path.join(ROOT, "Air2", "Core", "Plugin")
ADDONS_DIR = os.path.join(ROOT, "Air2", "Core", "Addons")
UTILS_DIR = os.path.join(ROOT, "Air2", "Utils")

MANIFEST_SRC = os.path.join(PLUGIN_DIR, "A2PluginManifest.m")
REGISTRY_SRC = os.path.join(PLUGIN_DIR, "A2PluginRegistry.m")
EXTRACTOR_SRC = os.path.join(PLUGIN_DIR, "A2PluginPackageExtractor.m")
INSTALLER_SRC = os.path.join(PLUGIN_DIR, "A2PluginInstaller.m")
ZIP_READER_SRC = os.path.join(ADDONS_DIR, "A2ZipReader.m")
# ★2026-10-31★ 安装器现在会查「是否改启动链」⇒ 依赖 A2PluginLaunchChainRisk.m 的三个导出符号，
# 不把它编进来链接就会失败（真跑踩到：Undefined symbols _A2PluginLaunchChainPermissionIds/Names）。
LAUNCH_RISK_SRC = os.path.join(PLUGIN_DIR, "A2PluginLaunchChainRisk.m")
# 权限目录（A2PluginPermissionInfoForId）—— A2PluginLaunchChainRisk 用它取 shortName。
PERMISSION_STORE_SRC = os.path.join(PLUGIN_DIR, "A2PluginPermissionStore.m")
LOG_SRC = os.path.join(UTILS_DIR, "A2Log.m")
# ★2026-10-31★ 第⑤块：启动看门狗（boot marker / failureCount / 自动停用）。
# 它自己的用例在 plugin_boot_guard_tests，因此必须单独编进那个目标。
BOOT_GUARD_SRC = os.path.join(PLUGIN_DIR, "A2PluginBootGuard.m")

# 每个目标 = 一个可执行文件（用例各自用独立临时目录，互不污染）
TARGETS = [
    {
        "name": "plugin_data_tests",
        "test": os.path.join(HERE, "plugin_data_tests.m"),
        "sources": [MANIFEST_SRC, REGISTRY_SRC],
        "libraries": [],
    },
    {
        "name": "plugin_installer_tests",
        "test": os.path.join(HERE, "plugin_installer_tests.m"),
        "sources": [MANIFEST_SRC, REGISTRY_SRC, EXTRACTOR_SRC, INSTALLER_SRC,
                    ZIP_READER_SRC, LAUNCH_RISK_SRC, PERMISSION_STORE_SRC, LOG_SRC],
        "libraries": ["-lz"],       # A2ZipReader 的 deflate 走 zlib
    },
    {
        # 第⑤块：boot marker + 连续 3 次未跨首帧自动停用。
        # 注册表要一起编（failureCount / lastAutoDisabledReason 落在 entry 上），
        # manifest 提供 A2PluginIsValidIdentifier（registry 的写前校验用它）。
        "name": "plugin_boot_guard_tests",
        "test": os.path.join(HERE, "plugin_boot_guard_tests.m"),
        "sources": [BOOT_GUARD_SRC, REGISTRY_SRC, MANIFEST_SRC],
        "libraries": [],
    },
]

INCLUDE_DIRS = [PLUGIN_DIR, ADDONS_DIR, UTILS_DIR]


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


def build_command(clang, binary, sources, libraries):
    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    return ([clang, "-fobjc-arc", "-Wall", "-Wno-unused-parameter"] + includes +
            ["-framework", "Foundation", "-framework", "CoreFoundation"] +
            libraries + ["-o", binary] + sources)


def main():
    for target in TARGETS:
        for src in target["sources"] + [target["test"]]:
            if not os.path.exists(src):
                print("缺少源文件: %s" % src)
                return 1

    clang = find_clang()
    if not clang:
        print("找不到 clang（本测试需在装有 Xcode 命令行工具的 macOS 上运行）。")
        print("本机没有工具链 ⇒ 这些用例【未编译、未执行】，不代表通过。")
        return 1
    print("clang = %s" % clang)

    tmpdir = tempfile.mkdtemp(prefix="a2plugin_tests_")
    total_passed = 0
    total_failed = 0

    for target in TARGETS:
        name = target["name"]
        binary = os.path.join(tmpdir, name)
        cmd = build_command(clang, binary, target["sources"] + [target["test"]],
                            target["libraries"])
        print("\n=== %s ===" % name)
        print("compile: clang -fobjc-arc ... %s -o %s" %
              (" ".join(target["libraries"]), name))
        compile_result = subprocess.run(cmd, capture_output=True, text=True)
        if compile_result.stderr.strip():
            print("--- clang 输出 ---")
            print(compile_result.stderr.strip())
        if compile_result.returncode != 0:
            print("!! 编译失败（rc=%d）" % compile_result.returncode)
            return 1

        run = subprocess.run([binary], capture_output=True, text=True)
        out = run.stdout + run.stderr
        sys.stdout.write(out)

        passed = sum(1 for ln in out.splitlines() if ln.startswith("PASS"))
        failed = sum(1 for ln in out.splitlines() if ln.startswith("FAIL"))
        total_passed += passed
        total_failed += failed
        print("[runner] %s：PASS=%d FAIL=%d 合计=%d" %
              (name, passed, failed, passed + failed))

        if failed or run.returncode != 0:
            print("[runner] %s 有失败用例" % name)
            return 1
        if passed == 0:
            print("[runner] %s 未解析到任何用例，视为失败" % name)
            return 1

    print("\n[runner] 合计：PASS=%d FAIL=%d" % (total_passed, total_failed))
    print("[runner] 全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
