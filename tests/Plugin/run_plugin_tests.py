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
  ④ plugin_contribution_tests（P2）
       A2PluginContribution.m       （贡献点深校验 / slot·component·token 词表 / 注册表）
       A2PluginManifest.m           （只用它的语义化版本比较、id 判定、错误构造）

为什么是【真编译 + 真运行】而不是源码扫描：
  「拒装」的每一条理由都必须是可执行的绿或红。zip 炸弹、穿越条目、符号链接、
  同版本换包、降级 —— 这些都是**行为**，源码扫描只能证明「文字在文件里」，
  只有把真实实现跑一遍才能证明门在那儿。

用法：
    python3 tests/Plugin/run_plugin_tests.py              # 编译 + 运行（需 macOS + Xcode CLT）
    python3 tests/Plugin/run_plugin_tests.py --syntax-only  # 只做类型检查

★关于 --syntax-only★：它只证明「编译单元类型正确」，**不证明行为**，也不能替代上面那条。
  它存在的理由：仓库平时只有一台 Ubuntu 构建机可远程使用，而 macOS 那台有时被重启进
  Linux（同一台机器的双系统）。在那种情况下至少能跑类型检查，不必把改动攒到 Mac 回来。
  Ubuntu 侧需要：clang-17 + libgnustep-base-dev + libblocksruntime-dev，且
  GNUstep 的 legacy runtime **跑不了**这批用例（ARC / 类扩展属性都不支持），
  所以 --syntax-only 只做 -fsyntax-only。

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
# ★P2★ 贡献点深校验 + 注册表。只依赖 A2PluginManifest 的 C 导出（版本比较 / id 判定 / 错误构造）。
CONTRIBUTION_SRC = os.path.join(PLUGIN_DIR, "A2PluginContribution.m")

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
        # ★P2★ 安装器现在会调 A2PluginContributionSet / Registry（解包时深校验、装完接入注册表），
        # 不把 CONTRIBUTION_SRC 编进来链接就会失败（undefined _OBJC_CLASS_$_A2PluginContributionSet）。
        "sources": [MANIFEST_SRC, REGISTRY_SRC, EXTRACTOR_SRC, INSTALLER_SRC,
                    CONTRIBUTION_SRC,
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
    {
        # P2：贡献点（manifest v2 纯 JSON 声明 + 纯内存注册表）。
        # manifest 必须一起编：本层的版本区间、id 判定、错误构造都直接用 P1 的导出，
        # 否则会出现「两套 semver 比较」这种最不该有的漂移。
        "name": "plugin_contribution_tests",
        "test": os.path.join(HERE, "plugin_contribution_tests.m"),
        "sources": [CONTRIBUTION_SRC, MANIFEST_SRC],
        "libraries": [],
    },
]

INCLUDE_DIRS = [PLUGIN_DIR, ADDONS_DIR, UTILS_DIR]


def find_clang():
    for name in ("clang", "clang-17", "clang-16", "clang-15"):
        clang = shutil.which(name)
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


def syntax_only_command(clang, sources):
    """只做类型检查的参数（macOS 用 ARC；非 macOS 退到 GNUstep 头 + legacy runtime 语法）。

    非 macOS 上必须在 PATH 之外再补两处头文件：GNUstep 的 Foundation 与 gcc 的 objc。
    可选环境变量 A2_GNUSTEP_SHIM 指向一个含 objc/blocks_runtime.h 的垫片目录
    （GNUstep 的 GSVersionMacros.h 在 -fblocks 下会 include 它，而 Ubuntu 的
    libblocksruntime-dev 不含这个头）。
    """
    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    args = [clang, "-fsyntax-only", "-Wall", "-Wno-unused-parameter"] + includes
    if sys.platform == "darwin":
        return args + ["-fobjc-arc"] + sources
    shim = os.environ.get("A2_GNUSTEP_SHIM")
    gnustep = "/usr/include/GNUstep"
    if not os.path.isdir(gnustep):
        return None
    if shim:
        args += ["-I", shim]
    args += ["-I", gnustep]
    gcc = shutil.which("gcc") or shutil.which("cc")
    if gcc:
        out = subprocess.run([gcc, "-print-file-name=include"], capture_output=True, text=True)
        objc_inc = os.path.join(out.stdout.strip(), "objc")
        if os.path.isdir(objc_inc):
            args += ["-I", out.stdout.strip()]
    # -fno-objc-arc：GNUstep 的 legacy runtime 不支持 ARC；-fobjc-runtime=gnustep-1.7 只为
    # 让 clang 打开「字典/数组下标 + 字面量」语法，好让源码能过类型检查（不链接、不运行）。
    return args + ["-fno-objc-arc", "-fconstant-string-class=NSConstantString", "-fblocks",
                   "-fobjc-runtime=gnustep-1.7"] + sources


def uses_corefoundation(path):
    """源文件是否直接用 CoreFoundation（GNUstep 上没有它，macOS 才有）。"""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return "CFGetTypeID" in handle.read()
    except OSError:
        return False


# 非 macOS 上必然编不过的「Apple 专有 API」信号。命中它们只说明「这台机器验不了」，
# 不说明代码有问题 —— 如实标成 skip，绝不冒充 PASS，也不把噪声算成回归。
APPLE_ONLY_MARKERS = (
    "TargetConditionals.h",
    "CommonCrypto/",
    "NSFileAttributeKey",
    "NSDataReadingMappedIfSafe",
    "CFTypeRef",
    "MobileGestalt.h",
    "SecTrust",
    "sys/sysctl.h",
    "UIKit/",
)


def apple_only_dependency(output):
    """编译输出里是否出现「Apple 专有 API 缺失」这类信号。"""
    return any(marker in output for marker in APPLE_ONLY_MARKERS)


def run_syntax_only():
    """类型检查模式：只证明每个编译单元类型正确，不证明行为。

    逐文件检查（不是逐目标）：一个文件失败不代表同目标其它文件有问题，
    而「哪个文件没过」正是这个模式要回答的。
    """
    clang = find_clang()
    if not clang:
        print("找不到 clang ⇒ 连类型检查都做不了"
              "（macOS 需 Xcode CLT；Ubuntu 需 clang + libgnustep-base-dev）。")
        return 1
    print("clang = %s（--syntax-only：只做类型检查，不代表用例通过）" % clang)

    checked = 0
    skipped = 0
    failures = []
    for target in TARGETS:
        name = target["name"]
        sources = list(target["sources"])
        if os.path.exists(target["test"]):
            sources.append(target["test"])
        print("\n=== %s ===" % name)
        for src in sources:
            rel = os.path.relpath(src, ROOT)
            if sys.platform != "darwin" and uses_corefoundation(src):
                # 这条路径在 GNUstep 下必报错：CoreFoundation 是 Apple 的框架。
                # 那是「P1 与 macOS 耦合」，不是本次改动的回归 —— 如实标注跳过，不冒充通过。
                print("[skip] %s（用到 CoreFoundation，非 macOS 无法类型检查）" % rel)
                skipped += 1
                continue
            cmd = syntax_only_command(clang, [src])
            if cmd is None:
                print("[skip] %s（找不到 GNUstep 头文件：apt install libgnustep-base-dev）" % rel)
                skipped += 1
                continue
            result = subprocess.run(cmd, capture_output=True, text=True)
            out = (result.stdout + result.stderr).strip()
            if result.returncode != 0 and sys.platform != "darwin" and apple_only_dependency(out):
                print("[skip] %s（依赖 Apple 专有 API，非 macOS 无法类型检查）" % rel)
                skipped += 1
                continue
            checked += 1
            if result.returncode != 0:
                if rel not in failures:
                    failures.append(rel)
                print("[FAIL] %s" % rel)
                if out:
                    print(out)
            else:
                print("[ok]   %s" % rel)
                if out:
                    print(out)

    print("\n[syntax] 检查 %d 个文件，跳过 %d 个（非 macOS 验不了），失败 %d 个"
          % (checked, skipped, len(failures)))
    if failures:
        print("[syntax] 失败：%s" % ", ".join(failures))
        return 1
    print("[syntax] 结论：受检文件类型检查全部通过 —— 这不代表用例通过，行为验证要跑 macOS 那一档")
    return 0


def main():
    if "--syntax-only" in sys.argv:
        return run_syntax_only()
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
