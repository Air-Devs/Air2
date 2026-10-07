#!/usr/bin/env python3
"""
用 Python 复刻 A2GamePath 的隔离逻辑，验证与 ZL2 行为一致。
逻辑对了再回填到 ObjC —— iSH 里没有 ObjC 编译器，只能这样验证。
"""
import os

GAME_HOME = "/var/mobile/.minecraft"

FOLDERS = {
    "mods": "mods",
    "resourcepacks": "resourcepacks",
    "saves": "saves",
    "shaderpacks": "shaderpacks",
    "screenshots": "screenshots",
}


def game_directory_for_version(version_name, isolation_type, custom_path):
    """复刻 A2GamePath.gameDirectoryForVersion:isolation:"""
    if isolation_type == "ENABLE":
        return f"{GAME_HOME}/versions/{version_name}"
    if custom_path:
        return custom_path
    return GAME_HOME


def directory_for_folder(folder, version_name, isolation_type, custom_path):
    return os.path.join(
        game_directory_for_version(version_name, isolation_type, custom_path),
        FOLDERS[folder],
    )


# ---------------------------------------------------------------
# ZL2 真实行为对照（从 Version.kt:196-202 抄出来的逻辑）
#   return if (versionConfig.isIsolation()) getVersionPath()
#   else if (versionConfig.customPath.isNotEmpty()) File(versionConfig.customPath)
#   else File(gameHome)
# ---------------------------------------------------------------
def zl2_reference(version_name, isolation_type, custom_path):
    if isolation_type == "ENABLE":
        return f"{GAME_HOME}/versions/{version_name}"
    if custom_path:
        return custom_path
    return GAME_HOME


def check(name, got, want):
    ok = got == want
    mark = "✓" if ok else "✗"
    print(f"  {mark} {name}")
    if not ok:
        print(f"      got  = {got}")
        print(f"      want = {want}")
    return ok


print("=" * 62)
print("版本隔离逻辑验证")
print("=" * 62)
print(f"游戏根目录: {GAME_HOME}\n")

all_ok = True

# ---- 场景 1: 全局关闭隔离，无自定义路径 ----
print("[1] DISABLE + 无自定义路径 → 共用 .minecraft")
got = directory_for_folder("mods", "1.21.5-fabric", "DISABLE", None)
want = "/var/mobile/.minecraft/mods"
all_ok &= check("mods 目录", got, want)
all_ok &= check("与 ZL2 一致", got, os.path.join(zl2_reference("1.21.5-fabric", "DISABLE", None), "mods"))

# ---- 场景 2: 全局关闭隔离，有自定义路径 ----
print("\n[2] DISABLE + 自定义路径 → 用自定义路径")
got = directory_for_folder("saves", "1.21.5-fabric", "DISABLE", "/var/mobile/MyGames")
want = "/var/mobile/MyGames/saves"
all_ok &= check("saves 目录", got, want)
all_ok &= check("与 ZL2 一致", got, os.path.join(zl2_reference("1.21.5-fabric", "DISABLE", "/var/mobile/MyGames"), "saves"))

# ---- 场景 3: 开启隔离 ----
print("\n[3] ENABLE → 版本文件夹独立成家")
got = directory_for_folder("mods", "1.21.5-fabric", "ENABLE", None)
want = "/var/mobile/.minecraft/versions/1.21.5-fabric/mods"
all_ok &= check("mods 目录", got, want)
all_ok &= check("与 ZL2 一致", got, os.path.join(zl2_reference("1.21.5-fabric", "ENABLE", None), "mods"))

# ---- 场景 4: 隔离开启时自定义路径被忽略（关键边界） ----
print("\n[4] ENABLE + 自定义路径 → 自定义路径应被忽略，仍用版本文件夹")
got = directory_for_folder("mods", "1.21.5-forge", "ENABLE", "/var/mobile/MyGames")
want = "/var/mobile/.minecraft/versions/1.21.5-forge/mods"
all_ok &= check("隔离优先于自定义路径", got, want)
all_ok &= check("与 ZL2 一致", got, os.path.join(zl2_reference("1.21.5-forge", "ENABLE", "/var/mobile/MyGames"), "mods"))

# ---- 场景 5: 两个版本隔离后互不干扰 ----
print("\n[5] 两个版本同时隔离 → 目录不重叠")
a = directory_for_folder("saves", "1.20.1-vanilla", "ENABLE", None)
b = directory_for_folder("saves", "1.21.5-fabric", "ENABLE", None)
all_ok &= check("存档目录不同", str(a != b), "True")
all_ok &= check("A 路径", a, "/var/mobile/.minecraft/versions/1.20.1-vanilla/saves")
all_ok &= check("B 路径", b, "/var/mobile/.minecraft/versions/1.21.5-fabric/saves")

# ---- 场景 6: FOLLOW_GLOBAL 未解析时（应由上层解析后传入） ----
print("\n[6] FOLLOW_GLOBAL 直传 → 落到默认根目录（上层应先解析全局值）")
got = directory_for_folder("mods", "1.21.5", "FOLLOW_GLOBAL", None)
want = "/var/mobile/.minecraft/mods"
all_ok &= check("回落行为符合预期", got, want)

# ---- 场景 7: 五个可隔离模块全覆盖 ----
print("\n[7] 五个可隔离模块（隔离模式下的完整布局）")
for f in FOLDERS:
    got = directory_for_folder(f, "1.21.5-fabric", "ENABLE", None)
    want = f"/var/mobile/.minecraft/versions/1.21.5-fabric/{f}"
    all_ok &= check(f"{f:16s}", got, want)

print("\n" + "=" * 62)
if all_ok:
    print("全部通过 —— ObjC 实现可以照此回填")
else:
    print("有失败项，需要修正")
print("=" * 62)
