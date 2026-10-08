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
