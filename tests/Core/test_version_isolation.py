#!/usr/bin/env python3
"""
用 Python 复刻 A2GamePath 的版本隔离逻辑，逐条对照 Punch-air 的 PLProfiles.m。

对照的 Punch-air 源码（Natives/PLProfiles.m）：
    PLIsolationMode { None, Mod, Full }

    effectiveGameDirForProfile:
        Full -> {gameHome}/versions/{name}
        其余 -> {gameHome}

    effectiveModsDirForProfile:
        Mod / Full -> {gameHome}/versions/{name}/mods
        其余       -> {gameDir}/mods

    PLIsolationStandardSubdirectories:
        Full 档在版本目录下建 9 个标准子目录：
        mods saves config resourcepacks shaderpacks
        logs crash-reports datapacks screenshots

Air2 的实现对应 A2VersionIsolation.m 里的
    - gameDirectoryForVersion:mode:
    - modsDirectoryForVersion:mode:
    - directoryForFolder:versionName:mode:
以及 A2Settings.m 里的 isolationModeFromDefaults（旧布尔 key 的迁移规则）。

三档语义（全局档位；「仅 Mod」只作用于能装模组的版本）：
    none  关闭    gameDir = 游戏根目录          mods = {根}/mods
    mod   仅 Mod  gameDir = 游戏根目录          mods = versions/{版本名}/mods（仅能装模组的版本）
    full  全部    gameDir = versions/{版本名}   mods = versions/{版本名}/mods

A2GamePath 只按传入的档位解析路径；「仅 Mod 对某个版本是否生效」由 Version 层
（A2Version.effectiveIsolationMode）判定：全局档位为 mod 但该版本不能装模组
（原版 / 仅装 OptiFine）时降级为 none。下面的 effective_mode 复刻这条规则。

libraries / assets 始终共用，不随档位变化。
"""
import os

GAME_HOME = "/var/mobile/Documents/minecraft"

# A2VersionFolderName 的取值（除 mods 外都直接落在游戏目录下）
FOLDERS = {
    "mods": "mods",
    "resourcepacks": "resourcepacks",
    "saves": "saves",
    "shaderpacks": "shaderpacks",
    "screenshots": "screenshots",
}

# A2IsolationStandardSubdirectories（Full 档建的标准结构）
STANDARD_SUBDIRS = [
    "mods", "saves", "config", "resourcepacks", "shaderpacks",
    "logs", "crash-reports", "datapacks", "screenshots",
]

NONE, MOD, FULL = "none", "mod", "full"


# ----------------------------------------------------------------------------
# 复刻 A2GamePath
# ----------------------------------------------------------------------------

def game_directory(version_name, mode):
    """复刻 gameDirectoryForVersion:mode:"""
    if mode == FULL:
        return f"{GAME_HOME}/versions/{version_name}"
    return GAME_HOME


def mods_directory(version_name, mode):
    """复刻 modsDirectoryForVersion:mode:"""
    if mode in (MOD, FULL):
        return f"{GAME_HOME}/versions/{version_name}/mods"
    return os.path.join(game_directory(version_name, mode), "mods")


def folder_dir(folder, version_name, mode):
    """复刻 directoryForFolder:versionName:mode:"""
    if folder == "mods":
        return mods_directory(version_name, mode)
    return os.path.join(game_directory(version_name, mode), FOLDERS[folder])


# ----------------------------------------------------------------------------
# 复刻 A2Settings.isolationModeFromDefaults
# ----------------------------------------------------------------------------

def resolve_isolation_mode(new_key_value, old_bool_value):
    """new_key_value: 新 key 的值（None 表示没写过）；
       old_bool_value: 旧布尔 key 的值（None 表示没写过）。"""
    if new_key_value is not None:
        return new_key_value if new_key_value in (NONE, FULL) else MOD
    if old_bool_value is not None and old_bool_value:
        return FULL
    return MOD


# ----------------------------------------------------------------------------
# 复刻 A2Version.effectiveIsolationMode
# ----------------------------------------------------------------------------

def effective_mode(mode, can_install_mods):
    """全局档位 + 该版本能否装模组 → 该版本的实际生效档位。

    复刻 A2Version.effectiveIsolationMode：「仅 Mod」只隔离能装模组的版本，
    不能装模组（原版 / 仅 OptiFine）就按关闭处理。
    """
    if mode == MOD and not can_install_mods:
        return NONE
    return mode


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
print("版本隔离逻辑验证（逐条对照 Punch-air PLProfiles.m）")
print("=" * 66)
print(f"游戏根目录: {GAME_HOME}\n")

# ---- 1. 关闭档：全部共用 ----
print("[1] none 关闭 → 所有数据在游戏根目录共用")
all_ok &= check("gameDir", game_directory(V, NONE), GAME_HOME)
all_ok &= check("mods", mods_directory(V, NONE), f"{GAME_HOME}/mods")
all_ok &= check("saves", folder_dir("saves", V, NONE), f"{GAME_HOME}/saves")

# ---- 2. 仅 Mod 档：只隔离 mods ----
print("\n[2] mod 仅 Mod → 游戏数据共用，只把 mods 隔离到版本目录")
all_ok &= check("gameDir 仍在根目录", game_directory(V, MOD), GAME_HOME)
all_ok &= check("mods 进版本目录", mods_directory(V, MOD),
                f"{GAME_HOME}/versions/{V}/mods")
all_ok &= check("saves 仍在根目录共用", folder_dir("saves", V, MOD),
                f"{GAME_HOME}/saves")
all_ok &= check("resourcepacks 仍在根目录共用", folder_dir("resourcepacks", V, MOD),
                f"{GAME_HOME}/resourcepacks")

# ---- 3. 全部档：整个游戏目录进版本 ----
print("\n[3] full 全部 → 整个游戏目录搬进版本文件夹")
all_ok &= check("gameDir", game_directory(V, FULL), f"{GAME_HOME}/versions/{V}")
all_ok &= check("mods", mods_directory(V, FULL), f"{GAME_HOME}/versions/{V}/mods")
all_ok &= check("saves", folder_dir("saves", V, FULL),
                f"{GAME_HOME}/versions/{V}/saves")

# ---- 4. 关键：mod 与 none 的 mods 目录必须不同 ----
print("\n[4] mod 与 none 的 mods 目录不重叠（隔离真正生效）")
all_ok &= check("两者不同", mods_directory(V, MOD) != mods_directory(V, NONE), True)

# ---- 5. 五个可隔离模块全覆盖 ----
print("\n[5] 五个可隔离模块（各档布局）")
for f in FOLDERS:
    all_ok &= check(f"{f:14s} none", folder_dir(f, V, NONE), f"{GAME_HOME}/{f}")
for f in FOLDERS:
    want_gd = f"{GAME_HOME}/versions/{V}/mods" if f == "mods" else f"{GAME_HOME}/{f}"
    all_ok &= check(f"{f:14s} mod ", folder_dir(f, V, MOD), want_gd)
for f in FOLDERS:
    all_ok &= check(f"{f:14s} full", folder_dir(f, V, FULL),
                    f"{GAME_HOME}/versions/{V}/{f}")

# ---- 6. 全部档的标准目录结构 ----
print("\n[6] full 档在版本目录下建 9 个标准子目录")
for sub in STANDARD_SUBDIRS:
    all_ok &= check(f"{sub:16s}", f"{GAME_HOME}/versions/{V}/{sub}"
                    == os.path.join(f"{GAME_HOME}/versions/{V}", sub), True)
all_ok &= check("子目录数量 = 9", len(STANDARD_SUBDIRS), 9)
all_ok &= check("mods 在标准目录里", "mods" in STANDARD_SUBDIRS, True)

# ---- 7. 两个版本同时隔离，互不干扰 ----
print("\n[7] 两个版本同时隔离 → 目录不重叠")
a = folder_dir("saves", "1.20.1-vanilla", FULL)
b = folder_dir("saves", "1.21.5-fabric", FULL)
all_ok &= check("目录不同", a != b, True)
all_ok &= check("A 路径", a, f"{GAME_HOME}/versions/1.20.1-vanilla/saves")
all_ok &= check("B 路径", b, f"{GAME_HOME}/versions/1.21.5-fabric/saves")
# 仅 Mod 档下，mods 也随版本不同
all_ok &= check("mod 档 mods 也随版本不同",
                mods_directory("1.20.1-vanilla", MOD)
                != mods_directory("1.21.5-fabric", MOD), True)

# ---- 8. libraries / assets 始终共用 ----
print("\n[8] libraries / assets 始终共用（不随档位变化）")
for mode in (NONE, MOD, FULL):
    all_ok &= check(f"{mode:4s} libraries 固定",
                    f"{GAME_HOME}/libraries", f"{GAME_HOME}/libraries")
    all_ok &= check(f"{mode:4s} assets 固定",
                    f"{GAME_HOME}/assets", f"{GAME_HOME}/assets")

# ---- 9. 默认档 = 仅 Mod ----
print("\n[9] 档位解析与旧 key 迁移（默认 = 仅 Mod）")
all_ok &= check("全新安装（两个 key 都没写）→ mod",
                resolve_isolation_mode(None, None), MOD)
all_ok &= check("新 key = none", resolve_isolation_mode(NONE, None), NONE)
all_ok &= check("新 key = mod", resolve_isolation_mode(MOD, None), MOD)
all_ok &= check("新 key = full", resolve_isolation_mode(FULL, None), FULL)
all_ok &= check("新 key 脏数据（越界）→ 回落 mod",
                resolve_isolation_mode(99, None), MOD)
all_ok &= check("旧布尔 key = true → full（老用户迁移）",
                resolve_isolation_mode(None, True), FULL)
all_ok &= check("旧布尔 key = false → mod",
                resolve_isolation_mode(None, False), MOD)
all_ok &= check("新 key 优先于旧 key",
                resolve_isolation_mode(NONE, True), NONE)

# ---- 10. 「仅 Mod」只作用于能装模组的版本 ----
print("\n[10] effective_mode：仅 Mod 只隔离能装模组的版本")
all_ok &= check("可装模组 + mod → mod", effective_mode(MOD, True), MOD)
all_ok &= check("不能装模组 + mod → none（降级）",
                effective_mode(MOD, False), NONE)
# 其余档位不受版本能否装模组影响
all_ok &= check("不能装模组 + full → full", effective_mode(FULL, False), FULL)
all_ok &= check("可装模组 + full → full", effective_mode(FULL, True), FULL)
all_ok &= check("不能装模组 + none → none", effective_mode(NONE, False), NONE)

# 生效档位决定实际路径：原版在全局 mod 档下 mods 仍留在根目录共用
V_VANILLA = "1.21.5"          # 原版（无加载器）
V_FABRIC = "1.21.5-fabric"    # 装了 Fabric
all_ok &= check("原版 + 全局 mod：mods 仍在根目录",
                mods_directory(V_VANILLA, effective_mode(MOD, False)),
                f"{GAME_HOME}/mods")
all_ok &= check("Fabric + 全局 mod：mods 进版本目录",
                mods_directory(V_FABRIC, effective_mode(MOD, True)),
                f"{GAME_HOME}/versions/{V_FABRIC}/mods")
all_ok &= check("原版 + 全局 full：整目录仍隔离",
                folder_dir("saves", V_VANILLA, effective_mode(FULL, False)),
                f"{GAME_HOME}/versions/{V_VANILLA}/saves")
all_ok &= check("原版 + 全局 none：全部共用",
                folder_dir("saves", V_VANILLA, effective_mode(NONE, False)),
                f"{GAME_HOME}/saves")

print("\n" + "=" * 66)
if all_ok:
    print("全部通过")
else:
    print("有失败项")
print("=" * 66)

raise SystemExit(0 if all_ok else 1)
