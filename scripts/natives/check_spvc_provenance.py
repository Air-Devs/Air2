#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""★ [26.4-SPVC] spvc native 出处校验（防"搬家漏带"）。

为什么需要它
============
真机 26.4（iPhone 17 Pro / iOS 27.2 / 26.4-snapshot-2）首次 UI 管线
minecraft:pipeline/gui 崩在：

    Caused by: com.mojang.renderpearl.util.ShaderCompileException:
      SPIRV-Cross error at spvc_context_parse_spirv: -1

-1 = SPVC_ERROR_INVALID_SPIRV（spirv_cross_c.h）。而**真正跑这个解析的库不是树里
Frameworks 下的那份**：

  mlrepo/src/main/java/com/metallum/client/metal/render/bridge/MetalNativeBridge.java
  configureBundledSpvcLibrary():
      · 从 jar 抽 /natives/ios/libspvc.dylib 写到 $POJAV_HOME/libspvc_metallum.dylib
      · System.load(它)（经 Amethyst hooked dlopen）
      · Configuration.SPVC_LIBRARY_NAME.set(该绝对路径)   ← LWJGL 的 Spvc 类照它加载

⇒ 设备上 spvc 解析用的是 **mod jar 里那份 natives/ios/libspvc.dylib**，不是
  Natives/resources/Frameworks/libspirv-cross-c-shared.0.dylib（= 我们的 spvc 串行化
  垫片）—— 真机 26.4 日志里 [spvc-shim] 一行都没有，正是这个原因。

⇒ 于是"搬家/换底时 jar 里的 natives 没带对"就会静默改变整个 SPIR-V→MSL 后端，
  表现就是 parse_spirv 直接 -1。mlrepo 的 buildIOSSpvc 还有一条**静默跳过**路径：

      if (src/main/resources/natives/ios/libspvc.dylib).exists():
          log "already exists, skipping build"; return

  以及 vendor/SPIRV-Cross 是 submodule（未初始化时 git status 显示 '-'）。
  两者叠加 = 搬家后拿到旧/异版本 libspvc 而构建全绿。

本脚本把"jar 内 natives/ios|* 的 libspvc.dylib"与树内 canonical 那份逐个对齐，
不一致就大声报错（默认 exit 1；SPVC_PROVENANCE=warn 仅告警）。

用法：  python3 Natives/check_spvc_provenance.py [--json]
"""
import hashlib
import os
import sys
import zipfile

FATAL_ENV = "SPVC_PROVENANCE"          # warn => 不致命
CANONICAL = os.path.join("Natives", "resources", "Frameworks")
# jar 中与本主题相关的 native 条目
NATIVE_PREFIX = ("natives/",)
# 只有 26.x 世代（ios = 26.1/26.2 通道，ir1 = iris 通道）强制对齐：
# 其它世代（natives/ios12111/…）各自钉自己那套 SPIRV-Cross，树里并不带对应
# canonical，只作信息展示，不算问题。
ENFORCED_PREFIXES = ("natives/ios/", "natives/ir1/")
SPVC_NAMES = ("libspvc.dylib", "libspirv-cross-c-shared.0.dylib",
              "libspirv-cross-c-shared.dylib", "libspirv-cross.dylib")
METALLUM_NAMES = ("libmetallum.dylib",)
# 扫描范围（有界，避免全库遍历）
# ★ [FABRIC-AGENT] mods_preload/ 现在【可选】：官方 MetalUniversal mod 下线后，
#   agent jar(JavaApp/libs/others/metallum_agent.jar) 是唯一且强制的 natives 通道 ——
#   它带 natives/ios|ir1/libspvc.dylib，found_any 由它满足；mods_preload 缺席不报错
#   (iter_jars 对不存在的目录直接 return)。无需把这块"改指 agent"，两处都扫即是。
JAR_ROOTS = (
    os.path.join("Natives", "resources", "mods_preload"),
    os.path.join("JavaApp", "libs", "others"),
)
JAR_MAGIC = b"PK\x03\x04"


def md5_of(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def md5_of_bytes(b):
    return hashlib.md5(b).hexdigest()


def iter_jars(root):
    if not os.path.isdir(root):
        return
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if name.endswith(".jar") or name.endswith(".zip"):
                yield os.path.join(dirpath, name)


def main():
    root = os.environ.get("AMETHYST_SRC", os.getcwd())
    os.chdir(root)
    json_mode = "--json" in sys.argv
    warn_only = os.environ.get(FATAL_ENV, "").strip().lower() == "warn"

    canonical = {}
    for name in SPVC_NAMES + METALLUM_NAMES:
        p = os.path.join(CANONICAL, name)
        if os.path.isfile(p):
            canonical[name] = (os.path.getsize(p), md5_of(p))

    print("[26.4-SPVC] canonical natives under %s:" % CANONICAL)
    for name, (sz, md5) in sorted(canonical.items()):
        print("    %-40s %9d  %s" % (name, sz, md5))
    if not canonical:
        print("[26.4-SPVC] ERROR: no canonical spvc/metallum native found "
              "(run from the repo root)")
        return 2

    spvc_md5 = None
    for name in ("libspvc.dylib", "libspirv-cross-c-shared.0.dylib",
                 "libspirv-cross.dylib"):
        if name in canonical:
            spvc_md5 = canonical[name][1]
            break

    rows = []
    problems = []
    found_any = False
    for jar_root in JAR_ROOTS:
        for jar in iter_jars(jar_root):
            try:
                z = zipfile.ZipFile(jar)
            except Exception as exc:                      # noqa: BLE001
                problems.append("%s: not a readable zip (%s)" % (jar, exc))
                continue
            for entry in z.namelist():
                base = os.path.basename(entry)
                if not entry.startswith(NATIVE_PREFIX):
                    continue
                if base not in SPVC_NAMES and base not in METALLUM_NAMES:
                    continue
                try:
                    data = z.read(entry)
                except Exception as exc:                  # noqa: BLE001
                    problems.append("%s!%s: unreadable (%s)" % (jar, entry, exc))
                    continue
                md5 = md5_of_bytes(data)
                ref = canonical.get(base)
                enforced = entry.startswith(ENFORCED_PREFIXES)
                if enforced:
                    found_any = True
                if not enforced:
                    # 非 26.x 世代：各钉各的 SPIRV-Cross，仅信息展示
                    rows.append((jar, entry, len(data), md5, "variant"))
                    continue
                status = "?"
                if ref is None:
                    status = "NO-CANONICAL"
                elif base in SPVC_NAMES and md5 != spvc_md5:
                    status = "★DIVERGED"
                    problems.append(
                        "%s!%s md5=%s != canonical libspvc md5=%s -- the spvc that "
                        "LWJGL actually loads on iOS is the JAR one "
                        "(MetalNativeBridge.configureBundledSpvcLibrary); a stale/"
                        "foreign libspvc here silently changes SPIR-V->MSL and shows "
                        "up as 'spvc_context_parse_spirv: -1'"
                        % (jar, entry, md5, spvc_md5))
                elif md5 == ref[1]:
                    status = "ok"
                else:
                    # libmetallum 会按 classes 世代/iris 变体合法不同：仅提示
                    status = "diff(metal)" if base in METALLUM_NAMES else "★DIVERGED"
                    if base not in METALLUM_NAMES:
                        problems.append("%s!%s md5=%s != %s md5=%s"
                                        % (jar, entry, md5, base, ref[1]))
                rows.append((jar, entry, len(data), md5, status))

    if not json_mode:
        print("[26.4-SPVC] jar-bundled natives found: %d" % len(rows))
        for jar, entry, sz, md5, status in rows:
            print("    %-9s %9d  %s  %s!%s" % (status, sz, md5, jar, entry))

    if not found_any:
        problems.append(
            "no jar-bundled natives/*/libspvc.dylib found under %s -- if the mod jar "
            "is supposed to carry one, it was dropped in a tree move (exactly the "
            "failure mode this check exists for)" % (JAR_ROOTS,))

    if problems:
        print("")
        print("[26.4-SPVC] ================= PROVENANCE PROBLEMS =================")
        for p in problems:
            print("  ✗ " + p)
        print("[26.4-SPVC] =======================================================")
        if warn_only:
            print("[26.4-SPVC] %s=warn -> not failing" % FATAL_ENV)
            return 0
        print("[26.4-SPVC] set %s=warn to downgrade this to a warning" % FATAL_ENV)
        return 1

    print("[26.4-SPVC] OK: every jar-bundled libspvc.dylib matches the canonical one")
    return 0


if __name__ == "__main__":
    sys.exit(main())
