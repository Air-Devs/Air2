#!/usr/bin/env python3
"""
模组身份解析对照测试。

对照 Air2/Core/Addons/A2ModScanner.m 的解析规则，用独立 Python 实现
锁定同一组向量：三路元数据、TOML 子集、开关后缀、兜底。改解析时
两边必须一起对齐，差异即失败。
"""
import sys

DISABLED = ".disabled"


def non_empty(v):
    return v if isinstance(v, str) and v else None


def is_disabled(name):
    return name.lower().endswith(DISABLED)


def strip_disabled(name):
    if not is_disabled(name):
        return name
    return name[: -len(DISABLED)]


def display_of(filename):
    base = strip_disabled(filename)
    no_ext = base.rsplit(".", 1)[0] if "." in base else base
    return no_ext if no_ext else filename


def split_authors(s):
    return [p.strip() for p in s.split(",") if p.strip()]


def fabric_authors(value):
    if not isinstance(value, list):
        return []
    out = []
    for item in value:
        name = None
        if isinstance(item, str):
            name = non_empty(item)
        elif isinstance(item, dict):
            name = non_empty(item.get("name"))
        if name:
            out.append(name)
    return out


def quilt_contributors(value):
    if not isinstance(value, dict):
        return []
    out = []
    for key, role in value.items():
        if not key:
            continue
        text = None
        if isinstance(role, str):
            text = non_empty(role)
        elif isinstance(role, dict):
            text = non_empty(role.get("name"))
        out.append(f"{key} ({text})" if text else key)
    return out


def toml_strip_comment(line):
    out = []
    in_double = in_single = False
    i = 0
    while i < len(line):
        c = line[i]
        if c == "\\" and (in_double or in_single) and i + 1 < len(line):
            out.append(c + line[i + 1])
            i += 2
            continue
        if c == '"' and not in_single:
            in_double = not in_double
        elif c == "'" and not in_double:
            in_single = not in_single
        if c == "#" and not in_double and not in_single:
            break
        out.append(c)
        i += 1
    return "".join(out).strip()


def toml_unescape(s):
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c != "\\" or i + 1 >= len(s):
            out.append(c)
            i += 1
            continue
        n = s[i + 1]
        out.append({'"': '"', "\\": "\\", "n": "\n", "t": "\t", "r": "\r"}.get(n, c + n))
        i += 2
    return "".join(out)


def toml_key_value(line, key):
    if "=" not in line:
        return None
    lhs, _, rhs = line.partition("=")
    if lhs.strip() != key:
        return None
    rhs = rhs.strip()
    if len(rhs) < 2 or not rhs.startswith('"') or not rhs.endswith('"'):
        return None
    return toml_unescape(rhs[1:-1])


def toml_code_lines(text):
    out = []
    pending_key = pending_buf = None
    for raw in text.split("\n"):
        line = raw[:-1] if raw.endswith("\r") else raw
        if pending_key is not None:
            end = line.find("'''")
            if end < 0:
                pending_buf += line + "\n"
                continue
            pending_buf += line[:end]
            out.append(f'{pending_key} = "{pending_buf}"')
            pending_key = pending_buf = None
            continue
        t = line.find("'''")
        if t >= 0:
            before = line[:t].strip()
            after = line[t + 3:]
            close = after.find("'''")
            if "=" not in before:
                return None
            lhs = before.split("=", 1)[0].strip()
            if not lhs:
                return None
            if close >= 0:
                out.append(f'{lhs} = "{after[:close]}"')
            else:
                pending_key, pending_buf = lhs, after + "\n"
            continue
        out.append(toml_strip_comment(line))
    if pending_key is not None:
        return None
    return out


def toml_first_table(code_lines):
    table = None
    for line in code_lines:
        if line.startswith("["):
            if table is not None:
                break
            if line == "[[mods]]":
                table = {}
            continue
        if table is None:
            continue
        if "=" not in line:
            continue
        lhs, _, rhs = line.partition("=")
        lhs, rhs = lhs.strip(), rhs.strip()
        if not lhs or len(rhs) < 2 or not rhs.startswith('"') or not rhs.endswith('"'):
            continue
        table[lhs] = toml_unescape(rhs[1:-1])
    if not table:
        return None
    return table


def toml_top_value(code_lines, key):
    for line in code_lines:
        if line.startswith("["):
            break
        v = toml_key_value(line, key)
        if v is not None:
            return v
    return None


def kind_for_entries(entries):
    """分发顺序镜像：OptiFine 特征优先，其次 fabric/quilt/forge/neoforge。"""
    if "optifine/Installer.class" in entries and "optifine/OptiFineTweaker.class" in entries:
        return "OptiFine"
    if "fabric.mod.json" in entries:
        return "Fabric"
    if "quilt.mod.json" in entries:
        return "Quilt"
    if "META-INF/mods.toml" in entries:
        return "Forge"
    if "META-INF/neoforge.mods.toml" in entries:
        return "NeoForge"
    return None


def optifine_version(data: bytes):
    """Config 类字节里找 OptiFine_ 标记，截取后按 _ 去前两段拼回。"""
    marker = b"OptiFine_"
    start = data.find(marker)
    if start < 0:
        return None
    end = start
    while end < len(data) and 32 <= data[end] <= 122:
        end += 1
    try:
        full = data[start:end].decode("ascii")
    except UnicodeDecodeError:
        return None
    parts = full.split("_")
    if len(parts) <= 2:
        return ""
    return " ".join(parts[2:])


def assemble_fabric(j):
    mod_id = non_empty(j.get("id"))
    version = non_empty(j.get("version"))
    if not mod_id or not version:
        return None
    name = non_empty(j.get("name")) or mod_id
    return {"id": mod_id, "name": name, "version": version,
            "authors": fabric_authors(j.get("authors")),
            "summary": non_empty(j.get("description")), "kind": "Fabric"}


def assemble_quilt(j):
    if j.get("schema_version") != 1:
        return None
    loader = j.get("quilt_loader")
    if not isinstance(loader, dict):
        return None
    mod_id = non_empty(loader.get("id"))
    version = non_empty(loader.get("version"))
    if not mod_id or not version:
        return None
    meta = loader.get("metadata") if isinstance(loader.get("metadata"), dict) else {}
    name = non_empty(meta.get("name")) or mod_id
    return {"id": mod_id, "name": name, "version": version,
            "authors": quilt_contributors(meta.get("contributors")),
            "summary": non_empty(meta.get("description")), "kind": "Quilt"}


def assemble_toml(table, top_authors, jar_version):
    table = table or {}
    mod_id = non_empty(table.get("modId"))
    raw_version = non_empty(table.get("version"))
    name = non_empty(table.get("displayName")) or mod_id
    if not mod_id or raw_version is None or not name:
        return None
    version = raw_version
    if "${file.jarVersion}" in version:
        version = version.replace("${file.jarVersion}", jar_version or "")
    t = non_empty(table.get("authors"))
    authors = split_authors(t) if t else (split_authors(top_authors) if top_authors else [])
    return {"id": mod_id, "name": name, "version": version, "authors": authors,
            "summary": non_empty(table.get("description"))}


def check(name, got, want):
    ok = got == want
    print(f"  [{'ok' if ok else 'FAIL'}] {name}: got {got!r}, want {want!r}")
    return ok


def main() -> int:
    ok = True

    ok &= check("dis-ci", is_disabled("mod.jar.DISABLED"), True)
    ok &= check("dis-no", is_disabled("mod.jar"), False)
    ok &= check("strip", strip_disabled("mod.jar.disabled"), "mod.jar")
    ok &= check("strip-once", strip_disabled("a.disabled.disabled"), "a.disabled")
    ok &= check("display", display_of("sodium.jar.disabled"), "sodium")
    ok &= check("display-plain", display_of("readme.txt"), "readme")
    ok &= check("authors", split_authors(" Alice, ,Bob ,, "), ["Alice", "Bob"])
    ok &= check("fabric-authors", fabric_authors(["a", {"name": "b"}, {"x": 1}, ""]),
                ["a", "b"])
    ok &= check("quilt-contrib",
                quilt_contributors({"amy": "dev", "bob": "", "cid": {"name": "Cid"}}),
                ["amy (dev)", "bob", "cid (Cid)"])

    ok &= check("comment-str", toml_strip_comment('a = "x#y" # c'), 'a = "x#y"')
    ok &= check("comment-plain", toml_strip_comment("a = 1 # c"), "a = 1")
    ok &= check("unescape", toml_unescape('a\\"b\\\\c'), 'a"b\\c')

    sample = ('modLoader="javafml"\n'
              'authors="Alice, Bob"\n'
              '# comment line\n'
              '[[mods]]\n'
              'modId="examplemod"\n'
              'version="1.0.0"\n'
              'displayName="Example"\n'
              'description=\'\'\'line # kept\n'
              'second\'\'\'\n'
              '[[dependencies.examplemod]]\n'
              'modId="forge"\n')
    lines = toml_code_lines(sample)
    ok &= check("code-lines-ok", lines is not None, True)
    table = toml_first_table(lines)
    ok &= check("table-mod", table.get("modId"), "examplemod")
    ok &= check("table-desc", table.get("description"), "line # kept\nsecond")
    ok &= check("table-no-dep", "modId" in table and table.get("version"), "1.0.0")
    ok &= check("top-authors", toml_top_value(lines, "authors"), "Alice, Bob")
    ok &= check("unclosed", toml_code_lines('a = \'\'\'oops\nmore'), None)
    # 反斜杠只洗一次：源 '''a\\nb''' → 值 a\nb（斜杠+n 四字符变两字符只一次）
    bs = toml_first_table(toml_code_lines('[[mods]]\nd = \'\'\'a\\\\nb\'\'\''))
    ok &= check("unescape-once", bs.get("d"), "a\\nb")

    jar = ('[[mods]]\nmodId="m"\nversion="${file.jarVersion}"\n'
           'displayName="M"\n')
    t = toml_first_table(toml_code_lines(jar))
    v = t["version"].replace("${file.jarVersion}", "21.4.0")
    ok &= check("jarversion", v, "21.4.0")

    bare = '[[mods]]\nmodId="m"\nversion=1.0\n'
    t2 = toml_first_table(toml_code_lines(bare))
    ok &= check("bare-skipped", "version" in (t2 or {}), False)

    ok &= check("dispatch-optifine-first",
                kind_for_entries({"fabric.mod.json", "optifine/Installer.class",
                                  "optifine/OptiFineTweaker.class"}), "OptiFine")
    ok &= check("dispatch-fabric", kind_for_entries({"fabric.mod.json"}), "Fabric")
    ok &= check("dispatch-quilt", kind_for_entries({"quilt.mod.json"}), "Quilt")
    ok &= check("dispatch-forge", kind_for_entries({"META-INF/mods.toml"}), "Forge")
    ok &= check("dispatch-neo", kind_for_entries({"META-INF/neoforge.mods.toml"}),
                "NeoForge")
    ok &= check("dispatch-none", kind_for_entries({"META-INF/MANIFEST.MF"}), None)

    blob = b"\xca\xfe\xba\xbeOptiFine_1.20.4_HD_U_I7\x00tail"
    ok &= check("optifine-ver", optifine_version(blob), "HD U I7")
    ok &= check("optifine-miss", optifine_version(b"\x00\x01\x02"), None)
    ok &= check("optifine-short", optifine_version(b"OptiFine_X"), "")

    fab = {"id": "m", "name": "M", "version": "1.0", "authors": ["a"],
           "description": "d"}
    ok &= check("asm-fabric", assemble_fabric(fab)["kind"], "Fabric")
    ok &= check("asm-fabric-noid", assemble_fabric({"name": "M", "version": "1.0"}), None)
    ok &= check("asm-fabric-nover", assemble_fabric({"id": "m", "name": "M"}), None)
    ok &= check("asm-fabric-noname",
                assemble_fabric({"id": "m", "version": "1.0"})["name"], "m")
    qmeta = {"name": "Q", "description": "d", "contributors": {"amy": "dev"}}
    quilt = {"schema_version": 1,
             "quilt_loader": {"id": "q", "version": "2.0", "metadata": qmeta}}
    ok &= check("asm-quilt", assemble_quilt(quilt)["authors"], ["amy (dev)"])
    ok &= check("asm-quilt-schema", assemble_quilt({"schema_version": 2,
                "quilt_loader": {"id": "q", "version": "2.0", "metadata": qmeta}}), None)
    ok &= check("asm-quilt-noname",
                assemble_quilt({"schema_version": 1, "quilt_loader": {
                    "id": "q", "version": "2.0", "metadata": {}}})["name"], "q")
    ok &= check("asm-quilt-nodesc",
                assemble_quilt({"schema_version": 1, "quilt_loader": {
                    "id": "q", "version": "2.0", "metadata": {"name": "Q"}}})["summary"],
                None)
    ok &= check("asm-toml-name",
                assemble_toml({"modId": "m", "version": "1.0"}, None, None)["name"], "m")
    ok &= check("asm-toml-table-authors",
                assemble_toml({"modId": "m", "version": "1.0", "displayName": "M",
                               "authors": "a, b"}, "top", None)["authors"], ["a", "b"])
    ok &= check("asm-toml-top-authors",
                assemble_toml({"modId": "m", "version": "1.0",
                               "displayName": "M"}, "x, y", None)["authors"], ["x", "y"])
    ok &= check("asm-toml-nomod",
                assemble_toml({"version": "1.0", "displayName": "M"}, None, None), None)
    ok &= check("asm-toml-nojarver",
                assemble_toml({"modId": "m", "version": "${file.jarVersion}",
                               "displayName": "M"}, None, None)["version"], "")

    print("==================================================================")
    print("全部通过" if ok else "有失败")
    print("==================================================================")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
