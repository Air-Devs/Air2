#!/usr/bin/env python3
"""
版本身份解析对照测试。

对照 Air2/Core/Version/A2VersionInfo.m 的解析规则，用独立 Python 实现
锁定同一组向量：MC 版本提取顺序、加载器判定、展示串格式、无效判定。
改解析规则时两边必须一起对齐，差异即失败。

规则摘要：
  MC 版本按 patches[0].version → clientVersion → launchFor[Minecraft].version
  → net.minecraft:client/server 库版本 → inheritsFrom → 版本名正则的顺序取，
  全都取不到才回落到文件夹名。
  加载器只看 libraries 的 group:artifact，不看版本名子串；
  同一加载器去重后按固定优先级排序；展示串为「MC, 加载器 - 版本」。
"""
import re
import sys

VERSION_RE = r"(\d+\.\d+(?:\.\d+)?|\d{2}w\d{2}[a-z])"
ID_PATTERNS = [
    VERSION_RE + r"-OptiFine",
    VERSION_RE + r"-forge",
    r"^(\d+\.\d+(?:\.\d+)?)-(Forge[\d.]*)-mc\d+",
    r"fabric-loader-[\w.\-]+-(" + VERSION_RE + r")",
    r"quilt-loader-[\w.\-]+-(" + VERSION_RE + r")",
]

PRIORITY = ["Forge", "NeoForge", "Cleanroom", "Fabric", "Quilt",
            "LegacyFabric", "Babric", "OptiFine", "LiteLoader"]


def non_empty(v):
    return v if isinstance(v, str) and v else None


def first_capture(text, pattern):
    m = re.search(pattern, text or "")
    return m.group(1) if m else None


def parse_forge(raw):
    parts = raw.split("-")
    if len(parts) == 2:
        return parts[-1]
    if len(parts) >= 3:
        if parts[-1].startswith("mc"):
            return parts[1]
        if parts[0] == parts[-1]:
            return parts[1]
    return raw


def neoforge_version(args_game):
    strs = [x for x in (args_game or []) if isinstance(x, str)]
    for i in range(len(strs) - 1):
        if strs[i] == "--fml.neoForgeVersion":
            return strs[i + 1]
    return None


def extract_mc(j, fallback):
    jid = non_empty(j.get("id")) or fallback
    patches = j.get("patches")
    if isinstance(patches, list) and patches and isinstance(patches[0], dict):
        v = non_empty(patches[0].get("version"))
        if v:
            return v
    v = non_empty(j.get("clientVersion"))
    if v:
        return v
    launch_for = j.get("launchFor")
    if isinstance(launch_for, dict):
        infos = launch_for.get("infos")
        if isinstance(infos, list):
            for item in infos:
                if isinstance(item, dict) and item.get("name") == "Minecraft":
                    v = non_empty(item.get("version"))
                    if v:
                        return v
    libs = j.get("libraries")
    if isinstance(libs, list):
        for lib in libs:
            if not isinstance(lib, dict):
                continue
            name = non_empty(lib.get("name"))
            if not name:
                continue
            parts = name.split(":")
            if len(parts) < 3:
                continue
            if parts[0] == "net.minecraft" and parts[1] in ("client", "server") and parts[2]:
                return parts[2]
    v = non_empty(j.get("inheritsFrom"))
    if v:
        return v
    for pattern in ID_PATTERNS:
        hit = first_capture(jid, pattern)
        if hit:
            return hit
    return jid


def detect_loaders(j):
    out = []
    has_fabric = has_legacy = has_babric = False
    fabric_ver = None
    libs = j.get("libraries") or []
    for lib in libs:
        if not isinstance(lib, dict):
            continue
        name = non_empty(lib.get("name"))
        if not name:
            continue
        parts = name.split(":")
        if len(parts) < 2:
            continue
        group, artifact = parts[0], parts[1]
        ver = parts[2] if len(parts) >= 3 else ""
        if group == "net.fabricmc" and artifact == "fabric-loader":
            has_fabric, fabric_ver = True, ver
        elif group == "net.legacyfabric" and artifact == "intermediary":
            has_legacy = True
        elif group == "babric" and artifact == "intermediary-upstream":
            has_babric = True
        elif group == "net.minecraftforge" and artifact in ("forge", "fmlloader"):
            out.append(("Forge", parse_forge(ver)))
        elif group == "net.neoforged.fancymodloader" and artifact == "loader":
            game = (j.get("arguments") or {}).get("game")
            out.append(("NeoForge", neoforge_version(game) or ver))
        elif group in ("optifine", "net.optifine") and artifact == "OptiFine":
            out.append(("OptiFine", ver))
        elif group == "org.quiltmc" and artifact == "quilt-loader":
            out.append(("Quilt", ver))
        elif group == "com.mumfrey" and artifact == "liteloader":
            out.append(("LiteLoader", ver))
        elif group == "com.cleanroommc" and artifact == "cleanroom":
            out.append(("Cleanroom", ver))
    if has_fabric and fabric_ver:
        kind = "LegacyFabric" if has_legacy else "Babric" if has_babric else "Fabric"
        out.append((kind, fabric_ver))
    seen = {}
    for kind, ver in out:
        if kind not in seen:
            seen[kind] = ver
    return sorted(seen.items(), key=lambda kv: PRIORITY.index(kv[0]) if kv[0] in PRIORITY else 999)


def parse_info(j, version_id):
    """复刻 +infoFromJSONDictionary:versionID:（非字典/无标识返回 None）。"""
    if not isinstance(j, dict):
        return None
    fallback = version_id if version_id else non_empty(j.get("id"))
    if not fallback:
        return None
    mc = extract_mc(j, fallback)
    if not mc:
        return None
    return (mc, detect_loaders(j))


def info_string(mc, loaders):
    parts = [mc] + [f"{k} - {v}" if v else k for k, v in loaders]
    return ", ".join(parts)


def loader_display(loaders):
    if not loaders:
        return None
    return ", ".join(f"{k} {v}" if v else k for k, v in loaders)


def check(name, got, want):
    ok = got == want
    print(f"  [{'ok' if ok else 'FAIL'}] {name}: got {got!r}, want {want!r}")
    return ok


def main() -> int:
    ok = True

    vanilla = {"id": "1.21.5", "libraries": [{"name": "net.minecraft:client:1.21.5"}]}
    ok &= check("vanilla-mc", parse_info(vanilla, "1.21.5")[0], "1.21.5")
    ok &= check("vanilla-loader", parse_info(vanilla, "1.21.5")[1], [])
    ok &= check("vanilla-display", loader_display([]), None)

    forge = {"id": "1.20.1-forge-47.2.0", "libraries": [
        {"name": "net.minecraft:client:1.20.1"},
        {"name": "net.minecraftforge:forge:1.20.1-47.2.0"}]}
    ok &= check("forge-mc", parse_info(forge, "x")[0], "1.20.1")
    ok &= check("forge-loader", parse_info(forge, "x")[1], [("Forge", "47.2.0")])

    old_forge = {"id": "1.7.10-Forge10.13.4.1614-1.7.10", "libraries": [
        {"name": "net.minecraftforge:forge:1.7.10-10.13.4.1614-1.7.10"}]}
    ok &= check("old-forge-ver", parse_info(old_forge, "x")[1], [("Forge", "10.13.4.1614")])

    fabric = {"id": "fabric-loader-0.16.10-1.21.5", "libraries": [
        {"name": "net.minecraft:client:1.21.5"},
        {"name": "net.fabricmc:fabric-loader:0.16.10"}]}
    ok &= check("fabric", parse_info(fabric, "x")[1], [("Fabric", "0.16.10")])

    legacy = {"id": "fabric-loader-0.15.0-1.12.2", "libraries": [
        {"name": "net.minecraft:client:1.12.2"},
        {"name": "net.fabricmc:fabric-loader:0.15.0"},
        {"name": "net.legacyfabric:intermediary:1.12.2"}]}
    ok &= check("legacy-fabric", parse_info(legacy, "x")[1], [("LegacyFabric", "0.15.0")])

    neo = {"id": "1.21.4-neoforge-21.4.0", "libraries": [
        {"name": "net.minecraft:client:1.21.4"},
        {"name": "net.neoforged.fancymodloader:loader:21.4.0"}],
        "arguments": {"game": ["--fml.neoForgeVersion", "21.4.0-beta"]}}
    ok &= check("neoforge-arg", parse_info(neo, "x")[1], [("NeoForge", "21.4.0-beta")])

    opti = {"id": "1.20.4-OptiFine_HD_U_I7", "libraries": [
        {"name": "net.minecraft:client:1.20.4"},
        {"name": "optifine:OptiFine:HD_U_I7"}]}
    mc, loaders = parse_info(opti, "x")
    ok &= check("optifine-mc", mc, "1.20.4")
    ok &= check("optifine-loader", loaders, [("OptiFine", "HD_U_I7")])
    ok &= check("optifine-display", loader_display(loaders), "OptiFine HD_U_I7")

    quilt = {"id": "quilt-loader-0.27.1-1.21.3", "libraries": [
        {"name": "net.minecraft:client:1.21.3"},
        {"name": "org.quiltmc:quilt-loader:0.27.1"}]}
    ok &= check("quilt", parse_info(quilt, "x")[1], [("Quilt", "0.27.1")])

    inherit = {"id": "my-pack", "inheritsFrom": "1.20.1", "libraries": []}
    ok &= check("inherits", parse_info(inherit, "my-pack")[0], "1.20.1")

    patches = {"id": "x", "patches": [{"version": "1.19.2"}], "libraries": []}
    ok &= check("patches-first", parse_info(patches, "x")[0], "1.19.2")

    ok &= check("non-dict", parse_info([1, 2], "x"), None)
    ok &= check("no-identity", parse_info({}, ""), None)
    ok &= check("id-fallback", parse_info({"libraries": []}, "custom")[0], "custom")

    ok &= check("info-string", info_string("1.21.5", [("Fabric", "0.16.10")]),
                "1.21.5, Fabric - 0.16.10")

    print("==================================================================")
    print("全部通过" if ok else "有失败")
    print("==================================================================")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
