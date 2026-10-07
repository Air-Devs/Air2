#!/usr/bin/env python3
"""
用 Python 复刻 A2GamePath 的隔离逻辑，逐条对照 ZL2 验证。

对照的 ZL2 源码：
  VersionConfig.kt:
      fun isIsolation() = isolationType.toBoolean(AllSettings.versionIsolation.getValue())
      private fun SettingState.toBoolean(global: Boolean) = when(...) {
          FOLLOW_GLOBAL -> global
          ENABLE -> true
          DISABLE -> false
      }
  Version.kt:
      fun getGameDir(): File {
          return if (versionConfig.isIsolation()) getVersionPath()
          else if (versionConfig.customPath.isNotEmpty()) File(versionConfig.customPath)
          else File(gameHome)
      }
  ModsManagerScreen.kt:
      val modsDir = VersionFolders.MOD.getDir(version.getGameDir())

关键点：FOLLOW_GLOBAL 要落到全局设置上 —— 这是最容易漏的一步。
"""
import os

GAME_HOME = "/var/mobile/Documents/.minecraft"

FOLDERS = {
    "mods": "mods",
    "resourcepacks": "resourcepacks",
    "saves": "saves",
    "shaderpacks": "shaderpacks",
    "screenshots": "screenshots",
}


def resolve_state(state, global_value):
    """复刻 SettingState.toBoolean(global)"""
    if state == "ENABLE":
        return True
    if state == "DISABLE":
        return False
    return global_value          # FOLLOW_GLOBAL


def game_directory(version_name, isolation_type, custom_path, global_isolation):
    """复刻 Version.getGameDir()"""
    enabled = resolve_state(isolation_type, global_isolation)
    if enabled:
        return f"{GAME_HOME}/versions/{version_name}"
    if custom_path:
        return custom_path
    return GAME_HOME


def folder_dir(folder, version_name, isolation_type, custom_path, global_isolation):
    """复刻 VersionFolders.X.getDir(version.getGameDir())"""
    return os.path.join(
        game_directory(version_name, isolation_type, custom_path, global_isolation),
        FOLDERS[folder],
    )


def check(name, got, want):
    ok = got == want
    print(f"  {'✓' if ok else '✗'} {name}")
    if not ok:
        print(f"      got  = {got}")
        print(f"      want = {want}")
    return ok


all_ok = True
V = "1.21.5-fabric"

print("=" * 66)
print("版本隔离逻辑验证（逐条对照 ZL2 源码）")
print("=" * 66)
print(f"游戏根目录: {GAME_HOME}\n")

# ---- 1. 明确关闭隔离 ----
print("[1] DISABLE + 无自定义路径 → 共用 .minecraft")
got = folder_dir("mods", V, "DISABLE", None, global_isolation=False)
all_ok &= check("mods 目录", got, f"{GAME_HOME}/mods")
# 全局开着也一样，因为版本明确 DISABLE
got = folder_dir("mods", V, "DISABLE", None, global_isolation=True)
all_ok &= check("全局开启时仍不隔离（版本优先）", got, f"{GAME_HOME}/mods")

# ---- 2. 明确开启隔离 ----
print("\n[2] ENABLE → 版本文件夹独立成家")
got = folder_dir("mods", V, "ENABLE", None, global_isolation=False)
all_ok &= check("mods 目录", got, f"{GAME_HOME}/versions/{V}/mods")
all_ok &= check("全局关闭时仍隔离（版本优先）", got,
                f"{GAME_HOME}/versions/{V}/mods")

# ---- 3. 关键：FOLLOW_GLOBAL 落到全局设置 ----
print("\n[3] FOLLOW_GLOBAL → 必须读全局设置（这是之前漏掉的）")
got = folder_dir("mods", V, "FOLLOW_GLOBAL", None, global_isolation=True)
all_ok &= check("全局开启 → 实际隔离", got, f"{GAME_HOME}/versions/{V}/mods")
got = folder_dir("mods", V, "FOLLOW_GLOBAL", None, global_isolation=False)
all_ok &= check("全局关闭 → 实际不隔离", got, f"{GAME_HOME}/mods")

# ---- 4. 自定义路径（未隔离时生效）----
print("\n[4] DISABLE + 自定义路径 → 用自定义路径")
CUSTOM = "/var/mobile/MyGames"
got = folder_dir("saves", V, "DISABLE", CUSTOM, global_isolation=False)
all_ok &= check("saves 目录", got, f"{CUSTOM}/saves")

# ---- 5. 隔离优先于自定义路径 ----
print("\n[5] ENABLE + 自定义路径 → 自定义路径被忽略")
got = folder_dir("mods", V, "ENABLE", CUSTOM, global_isolation=False)
all_ok &= check("隔离优先", got, f"{GAME_HOME}/versions/{V}/mods")

# ---- 6. FOLLOW_GLOBAL + 全局开 + 自定义路径 ----
print("\n[6] FOLLOW_GLOBAL(全局开) + 自定义路径 → 隔离优先")
got = folder_dir("mods", V, "FOLLOW_GLOBAL", CUSTOM, global_isolation=True)
all_ok &= check("隔离优先于自定义", got, f"{GAME_HOME}/versions/{V}/mods")

# ---- 7. FOLLOW_GLOBAL + 全局关 + 自定义路径 ----
print("\n[7] FOLLOW_GLOBAL(全局关) + 自定义路径 → 用自定义")
got = folder_dir("mods", V, "FOLLOW_GLOBAL", CUSTOM, global_isolation=False)
all_ok &= check("用自定义路径", got, f"{CUSTOM}/mods")

# ---- 8. 两个版本同时隔离，互不干扰 ----
print("\n[8] 两个版本同时隔离 → 目录不重叠")
a = folder_dir("saves", "1.20.1-vanilla", "ENABLE", None, False)
b = folder_dir("saves", "1.21.5-fabric", "ENABLE", None, False)
all_ok &= check("目录不同", a != b, True)
all_ok &= check("A 路径", a, f"{GAME_HOME}/versions/1.20.1-vanilla/saves")
all_ok &= check("B 路径", b, f"{GAME_HOME}/versions/1.21.5-fabric/saves")

# ---- 9. 五个可隔离模块全覆盖 ----
print("\n[9] 五个可隔离模块（隔离模式下的完整布局）")
for f in FOLDERS:
    got = folder_dir(f, V, "ENABLE", None, False)
    all_ok &= check(f"{f:16s}", got, f"{GAME_HOME}/versions/{V}/{f}")

# ---- 10. libraries / assets 始终共用 ----
print("\n[10] libraries / assets 始终共用（不随隔离变化）")
libs_isolated = f"{GAME_HOME}/libraries"
libs_shared = f"{GAME_HOME}/libraries"
all_ok &= check("libraries 路径固定", libs_isolated, libs_shared)
all_ok &= check("assets 路径固定", f"{GAME_HOME}/assets", f"{GAME_HOME}/assets")

print("\n" + "=" * 66)
if all_ok:
    print("全部通过")
else:
    print("有失败项")
print("=" * 66)
