#!/usr/bin/env python3
"""Air2 tests/Plugin —— ★坏包夹具生成 + 校验顺序推演★

为什么有这个脚本：
  安装器的完整性校验（逐文件 SHA-256 / 文件集合双向相等）是真机验收发现的漏洞，
  对应的**真单测**是 tests/Plugin/plugin_installer_tests.m 里的
  `testIntegrityTwoWayStrictness`（需 macOS + clang 才能跑，见 run_plugin_tests.py）。
  但构建机是 Linux，没有 ObjC 运行时，跑不了那份单测 —— 本脚本在同一台机器上
  用**真实 zip 字节 + 真实 SHA-256** 把 A2PluginPackageExtractor 的判定顺序推演一遍，
  同时把夹具产出到磁盘，供真机导入验收：

      python3 tests/Plugin/probe_bad_packages.py [--out DIR]

推演范围（严格对应 A2PluginPackageExtractor.m 的步骤编号）：
  预检  precheckEntryInfos       → 包根没有 manifest.json ⇒ E_MANIFEST_MISSING
  ⑤    manifest 解析
  ⑥    verifyIntegrityOfManifest → ① 清单→盘（缺文件 E_FILE_SET_MISMATCH /
                                    字节数、SHA-256 不符 E_HASH_MISMATCH）
                                   ② 盘→清单（多文件 E_FILE_SET_MISMATCH，
                                     manifest.json 自身与目录条目不计）

★边界声明★：它是**推演器**，不是第二份事实来源。规则只以 ObjC 实现为准；
  改校验逻辑时必须同时改本脚本与那份单测，三者不一致就是 bug。
"""

import argparse
import hashlib
import json
import os
import sys
import tempfile
import zipfile

MANIFEST_NAME = "manifest.json"


# ---------------------------------------------------------------- 夹具构造

def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def manifest(plugin_id: str, version: str = "1.0.0", files=None, **extra) -> dict:
    doc = {
        "formatVersion": 2,
        "id": plugin_id,
        "name": "验收夹具",
        "version": version,
        "type": "json",
        "air2": {"host": {"apiVersion": 1}},
        "platforms": ["ios"],
        "files": files if files is not None else [],
    }
    doc.update(extra)
    return doc


def declare(declared: dict) -> list:
    """{包内路径: 字节} → manifest.files（真实哈希与字节数）。"""
    return [{"path": path,
             "sha256": sha256_hex(data),
             "size": len(data)}
            for path, data in sorted(declared.items())]


def write_package(path: str, doc: dict, payloads: dict) -> None:
    """把 manifest + 文件写成 .air2plugin（stored，不压缩）。"""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as zf:
        zf.writestr(MANIFEST_NAME, json.dumps(doc, ensure_ascii=False).encode("utf-8"))
        for name, data in payloads.items():
            zf.writestr(name, data)


def build_fixtures(out_dir: str) -> dict:
    """三只坏包 + 两只对照包。返回 {文件名: 期望机器码 or None(应装得上)}。"""
    os.makedirs(out_dir, exist_ok=True)
    good_bytes = b'{"a":1}'
    other_bytes = b'{"a":2}'

    # ① good：一条声明、一条内容，全部对得上
    doc = manifest("top.example.probe.good", files=declare({"ui/a.json": good_bytes}))
    write_package(os.path.join(out_dir, "good.air2plugin"), doc, {"ui/a.json": good_bytes})

    # ② bad-hash：清单写的是另一份内容的哈希
    doc = manifest("top.example.probe.badhash",
                   files=[{"path": "ui/a.json",
                           "sha256": sha256_hex(good_bytes),
                           "size": len(good_bytes)}])
    write_package(os.path.join(out_dir, "bad-hash.air2plugin"), doc, {"ui/a.json": other_bytes})

    # ③ bad-fileset（包里多文件）：多出来的在包根，不在任何已知目录下
    doc = manifest("top.example.probe.badset", files=declare({"ui/a.json": good_bytes}))
    write_package(os.path.join(out_dir, "bad-fileset.air2plugin"), doc,
                  {"ui/a.json": good_bytes, "evil.js": b"// undeclared"})

    # ④ bad-fileset（清单多文件）：声明了幽灵文件
    doc = manifest("top.example.probe.ghost",
                   files=declare({"ui/a.json": good_bytes, "ui/ghost.json": b'{"g":1}'}))
    write_package(os.path.join(out_dir, "bad-fileset-ghost.air2plugin"), doc,
                  {"ui/a.json": good_bytes})

    # ⑤ bad-empty：files 为空数组 —— 合法包（schema minItems = 0）
    doc = manifest("top.example.probe.empty", files=[])
    write_package(os.path.join(out_dir, "empty.air2plugin"), doc, {})

    # ⑥ no-manifest：包里根本没有 manifest.json
    with zipfile.ZipFile(os.path.join(out_dir, "no-manifest.air2plugin"), "w") as zf:
        zf.writestr("ui/a.json", good_bytes)

    return {
        "good.air2plugin": None,
        "bad-hash.air2plugin": "E_HASH_MISMATCH",
        "bad-fileset.air2plugin": "E_FILE_SET_MISMATCH",
        "bad-fileset-ghost.air2plugin": "E_FILE_SET_MISMATCH",
        "empty.air2plugin": None,
        "no-manifest.air2plugin": "E_MANIFEST_MISSING",
    }


# ---------------------------------------------------------------- 推演

def replay(package_path: str):
    """按 A2PluginPackageExtractor 的顺序判一遍。返回 (机器码 or None, 原因)。"""
    with zipfile.ZipFile(package_path) as zf:
        infos = [i for i in zf.infolist() if not i.is_dir()]

    names = [i.filename for i in infos]

    # 预检：包根必须有 manifest.json
    if MANIFEST_NAME not in names:
        return "E_MANIFEST_MISSING", "包根缺少 manifest.json"

    # ⑤ manifest 解析（这里只取 files；格式/字段校验不是本脚本的范围）
    with zipfile.ZipFile(package_path) as zf:
        doc = json.loads(zf.read(MANIFEST_NAME).decode("utf-8"))
    declared = {entry["path"]: entry for entry in doc["files"]}

    # ⑥ 完整性
    actual = {name for name in names if name != MANIFEST_NAME}   # 目录条目已被过滤
    with zipfile.ZipFile(package_path) as zf:
        # ① 清单 → 盘
        for path, entry in declared.items():
            if path not in actual:
                return ("E_FILE_SET_MISMATCH",
                        f"manifest.files 声明了「{path}」，但包内没有这个文件")
            data = zf.read(path)
            if len(data) != entry["size"]:
                return ("E_HASH_MISMATCH",
                        f"「{path}」字节数与清单不符：清单 {entry['size']}，实际 {len(data)}")
            digest = sha256_hex(data)
            if digest != entry["sha256"]:
                return ("E_HASH_MISMATCH",
                        f"「{path}」的 SHA-256 不符：清单 {entry['sha256']}，实际 {digest}")
        # ② 盘 → 清单（manifest.json 不计，目录条目不计）
        for path in sorted(actual):
            if path not in declared:
                return ("E_FILE_SET_MISMATCH",
                        f"包里有「{path}」却没写进 manifest.files")
    return None, "校验通过"


def main() -> int:
    parser = argparse.ArgumentParser(description="Air2 坏包夹具生成与校验顺序推演")
    parser.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "air2_plugin_fixtures"),
                        help="夹具输出目录")
    args = parser.parse_args()

    expected = build_fixtures(args.out)
    print(f"夹具目录：{args.out}\n")
    failures = 0
    for name, want in expected.items():
        got, why = replay(os.path.join(args.out, name))
        verdict = "PASS" if got == want else "FAIL"
        if got != want:
            failures += 1
        print(f"[{verdict}] {name:<28} 期望 {want or '装得上':<22} 实际 {got or '装得上':<22} {why}")

    print(f"\n---- {len(expected) - failures} passed, {failures} failed ----")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
