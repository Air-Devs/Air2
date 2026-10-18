#!/usr/bin/env python3
"""
整合包清单解析对照测试（离线，用内存构造的 zip，不碰网络）。

对照：
  ZL2 CurseForgeManifest（manifest.json，edge.forgecdn.net 拼地址规则）
  与 ModrinthManifest（modrinth.index.json，env.server=required 跳过）。
  Air2 的 ObjC 实现（Air2/Core/Addons/A2ModPack）是同一规则的移植，
  本文件锁定规则，改解析时两边一起对齐。
"""
import io
import json
import posixpath
import sys
import zipfile


def cf_manifest():
    return {
        "manifestType": "minecraftModpack",
        "manifestVersion": 1,
        "name": "Demo CF Pack",
        "version": "1.0",
        "author": "tester",
        "overrides": "overrides",
        "minecraft": {
            "version": "1.20.1",
            "modLoaders": [{"id": "forge-47.2.0", "primary": True}],
        },
        "files": [
            {"projectID": 1, "fileID": 1234567, "required": True},
            {"projectID": 2, "fileID": 42, "fileName": "opt.jar",
             "url": "https://cdn.example.com/opt.jar", "required": False},
        ],
    }


def mr_index():
    return {
        "game": "minecraft",
        "formatVersion": 1,
        "versionId": "1.0",
        "name": "Demo MR Pack",
        "files": [
            {"path": "mods/a.jar",
             "hashes": {"sha1": "abc", "sha512": "def"},
             "downloads": ["https://cdn.modrinth.com/a.jar"],
             "fileSize": 10},
            {"path": "mods/server-only.jar",
             "hashes": {"sha1": "x", "sha512": "y"},
             "env": {"server": "required"},
             "downloads": ["https://cdn.modrinth.com/s.jar"],
             "fileSize": 5},
        ],
        "dependencies": {"minecraft": "1.21.5"},
    }


def make_zip(entries):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as z:
        for name, data in entries.items():
            z.writestr(name, data)
    buf.seek(0)
    return buf.read()


# 加载器标识解析：与 A2ModPack.m 的 familyOfLoaderIdentifier /
# loaderTypeForIdentifier / loaderVersionForIdentifier 三处保持同一规则。
LOADER_FAMILIES = ["legacyfabric", "neoforge", "fabric", "quilt", "forge", "optifine"]


def mr_loader_id(deps):
    """Modrinth 依赖键 → 归一后的 loaderID（无加载器返回 None）。"""
    for key in ["fabric-loader", "quilt-loader", "forge", "neoforge"]:
        v = deps.get(key)
        if isinstance(v, str) and v:
            return f"{key}-{v}"
    return None


def loader_family(identifier):
    if not identifier:
        return None
    low = identifier.lower()
    for fam in LOADER_FAMILIES:
        if low.startswith(fam):
            if len(low) == len(fam) or low[len(fam)] == "-":
                return fam
    return None


def loader_type(identifier):
    return loader_family(identifier)


def loader_version(identifier):
    fam = loader_family(identifier)
    if fam is None:
        return None
    rest = identifier[len(fam):]
    if rest.startswith("-"):
        rest = rest[1:]
    if rest.lower().startswith("loader-"):
        rest = rest[len("loader-"):]
    return rest or None


def safe_join(root, relative):
    """A2ImportSafeJoin 的规则镜像：越界（绝对路径 / .. 分量）返回 None。"""
    if not relative or relative.startswith("/"):
        return None
    if ".." in relative.split("/"):
        return None
    joined = posixpath.normpath(posixpath.join(root, relative))
    std_root = posixpath.normpath(root)
    if joined == std_root or not joined.startswith(std_root + "/"):
        return None
    return joined


def detect(names):
    if "modrinth.index.json" in names:
        return "modrinth"
    if "manifest.json" in names:
        return "curseforge"
    return "unknown"


def check(name, got, want):
    ok = got == want
    print(f"  [{'ok' if ok else 'FAIL'}] {name}: got {got!r}, want {want!r}")
    return ok


def main():
    ok = True

    cf = make_zip({"manifest.json": json.dumps(cf_manifest()),
                   "overrides/config/x.txt": b"hi"})
    cfnames = zipfile.ZipFile(io.BytesIO(cf)).namelist()
    ok &= check("CF检出", detect(cfnames), "curseforge")
    # fileID 拼地址：1234567 -> files/1234/567/<name>
    fid = 1234567
    ok &= check("CF拼地址", f"https://edge.forgecdn.net/files/{fid//1000}/{fid%1000}/1234567.jar",
                "https://edge.forgecdn.net/files/1234/567/1234567.jar")
    ok &= check("CF可选标记", cf_manifest()["files"][1]["required"], False)

    mr = make_zip({"modrinth.index.json": json.dumps(mr_index())})
    mrnames = zipfile.ZipFile(io.BytesIO(mr)).namelist()
    ok &= check("MR检出", detect(mrnames), "modrinth")
    kept = [f for f in mr_index()["files"]
            if not (isinstance(f.get("env"), dict)
                    and f["env"].get("server") == "required"
                    and f["env"].get("client") != "required")]
    ok &= check("MR服务端排除", len(kept), 1)
    ok &= check("MR游戏版本", mr_index()["dependencies"]["minecraft"], "1.21.5")
    # Modrinth 加载器在独立依赖键里，归一成 "<键>-<版本>"
    ok &= check("MR无加载器", mr_loader_id(mr_index()["dependencies"]), None)
    ok &= check("MR加载器归一",
                mr_loader_id({"minecraft": "1.21.5", "fabric-loader": "0.16.10"}),
                "fabric-loader-0.16.10")

    # CurseForge 的 modLoaders.id 直接用 "<族名>-<版本>"
    ok &= check("CF加载器标识取用",
                cf_manifest()["minecraft"]["modLoaders"][0]["id"], "forge-47.2.0")

    # loaderID → 类型 / 版本（两种格式归一后走同一套解析）
    ok &= check("forge类型", loader_type("forge-47.2.0"), "forge")
    ok &= check("forge版本", loader_version("forge-47.2.0"), "47.2.0")
    ok &= check("neoforge类型", loader_type("neoforge-21.0.167"), "neoforge")
    ok &= check("neoforge版本", loader_version("neoforge-21.0.167"), "21.0.167")
    ok &= check("quilt-loader类型", loader_type("quilt-loader-0.20.0"), "quilt")
    ok &= check("quilt-loader版本", loader_version("quilt-loader-0.20.0"), "0.20.0")
    ok &= check("fabric-loader类型", loader_type("fabric-loader-0.16.10"), "fabric")
    ok &= check("fabric-loader版本", loader_version("fabric-loader-0.16.10"), "0.16.10")
    ok &= check("legacyfabric不被fabric抢", loader_family("legacyfabric-1.0"), "legacyfabric")
    ok &= check("不认识的加载器", loader_type("wtf-loader-1.0"), None)
    ok &= check("只有族名无版本", loader_type("forge"), "forge")

    # 解压路径守卫：整合包内的条目不能跳出游戏目录
    ok &= check("路径拼接正常", safe_join("/g", "mods/a.jar"), "/g/mods/a.jar")
    ok &= check("拒绝上跳", safe_join("/g", "../x.jar"), None)
    ok &= check("拒绝中段上跳", safe_join("/g", "mods/../../x.jar"), None)
    ok &= check("拒绝绝对路径", safe_join("/g", "/etc/x"), None)
    ok &= check("拒绝空路径", safe_join("/g", ""), None)

    other = make_zip({"readme.txt": b"hi"})
    ok &= check("未知格式", detect(zipfile.ZipFile(io.BytesIO(other)).namelist()), "unknown")

    both = make_zip({"modrinth.index.json": b"{}",
                     "manifest.json": b"{}"})
    ok &= check("双清单优先MR", detect(zipfile.ZipFile(io.BytesIO(both)).namelist()), "modrinth")

    print("==================================================================")
    print("全部通过" if ok else "有失败")
    print("==================================================================")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
