#!/usr/bin/env python3
"""
验证 A2ModpackParser 及其四个子解析器的整合包判别与解析逻辑。

用 Python 复刻 ObjC 实现，再用 zipfile 生成「最小真实整合包 zip」验证 ——
判别顺序（CurseForge → Modrinth → MultiMC → MCBBS，命中即止）与各家字段
语义都是易错点：同名清单文件内容不同、MCBBS 旧包退回 manifest.json 会和
CurseForge 撞签名，一旦判错得到的是「能装但装错」的结果。

iSH 里没有 ObjC 编译器，所以：
  1. 用 Python 的 zipfile 生成四种格式的整合包 zip
  2. 用 Python 按 ObjC 的判定顺序与字段语义解析一遍
  3. 断言识别出的格式与字段是否与预期一致
"""
import io
import json
import zipfile


# ---------------- 复刻 A2ModpackFormat.h 的枚举与签名 ----------------

A2ModpackFormatUnknown = 0
A2ModpackFormatModrinth = 1
A2ModpackFormatCurseForge = 2
A2ModpackFormatMultiMC = 3
A2ModpackFormatMCBBS = 4

FORMAT_DISPLAY = {
    A2ModpackFormatUnknown: "未知",
    A2ModpackFormatModrinth: "Modrinth",
    A2ModpackFormatCurseForge: "CurseForge",
    A2ModpackFormatMultiMC: "MultiMC",
    A2ModpackFormatMCBBS: "MCBBS",
}

FORMAT_SIGNATURE = {
    A2ModpackFormatUnknown: "",
    A2ModpackFormatModrinth: "modrinth.index.json",
    A2ModpackFormatCurseForge: "manifest.json",
    A2ModpackFormatMultiMC: "mmc-pack.json",
    A2ModpackFormatMCBBS: "mcbbs.packmeta",
}


# ---------------- 复刻 A2ModLoaderAPI.h 的枚举 ----------------

L_FABRIC = 0
L_QUILT = 1
L_LEGACYFABRIC = 2
L_FORGE = 3
L_NEOFORGE = 4
L_OPTIFINE = 5


def loader_type_for_identifier(identifier):
    """复刻 A2ModpackLoaderTypeForIdentifier：从最具体到最泛匹配"""
    if not identifier:
        return None
    s = identifier.lower()
    # NeoForge 名字里含 forge，必须先判，否则会被 Forge 抢走
    if "neoforge" in s:
        return L_NEOFORGE
    if "legacyfabric" in s or "legacy-fabric" in s:
        return L_LEGACYFABRIC
    if "optifine" in s:
        return L_OPTIFINE
    if "quilt" in s:
        return L_QUILT
    if "fabric" in s:
        return L_FABRIC
    if "forge" in s:
        return L_FORGE
    return None


def version_from_cf_loader_id(identifier):
    """复刻 A2ModpackVersionFromCurseForgeLoaderID：从第一个数字字符起截取"""
    if not identifier:
        return None
    for i, ch in enumerate(identifier):
        if "0" <= ch <= "9":
            return identifier[i:]
    return None


# ---------------- 复刻 A2ModpackModels.h 的基础工具 ----------------

def a2_string(value):
    """复刻 A2ModpackString：只接受字符串，其它类型一律当不存在"""
    return value if isinstance(value, str) else None


def a2_int(value):
    """近似 NSNumber 的 integerValue / longLongValue：非数字视为 0"""
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return int(value)
    return 0


def a2_bool(value):
    """近似 NSNumber 的 boolValue"""
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    return False


def normalize_path(path):
    """复刻 A2ModpackNormalizedPath：反斜杠统一成正斜杠"""
    return path.replace("\\", "/")


def leading_int(text):
    """复刻 [NSString integerValue]：跳过空白与可选符号后取前导数字"""
    s = text.lstrip()
    i, sign = 0, 1
    if i < len(s) and s[i] in "+-":
        if s[i] == "-":
            sign = -1
        i += 1
    j = i
    while j < len(s) and "0" <= s[j] <= "9":
        j += 1
    if j == i:
        return 0
    return sign * int(s[i:j])


def last_path_component(path):
    """复刻 NSString.lastPathComponent（够用即可）"""
    if not path:
        return ""
    s = path.rstrip("/")
    if "/" in s:
        return s.rsplit("/", 1)[1]
    return s


# ---------------- 生成 zip 并复刻「解压后的整合包根目录」 ----------------

def make_zip(entries):
    """entries: [(name, content)]，content 可为 str 或 bytes"""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, content in entries:
            if isinstance(content, str):
                content = content.encode("utf-8")
            z.writestr(name, content)
    return buf.getvalue()


def unzip(data):
    """解压成 (文件表, 目录集合)；目录集合含显式目录项与文件的隐式父目录"""
    files, dirs = {}, set()
    if not data:
        return files, dirs
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for info in z.infolist():
                name = info.filename
                if name.endswith("/"):
                    dirs.add(name.rstrip("/"))
                    continue
                files[name] = z.read(name)
                parts = name.split("/")
                for i in range(1, len(parts)):
                    dirs.add("/".join(parts[:i]))
    except zipfile.BadZipFile:
        return {}, set()
    return files, dirs


def read_json(files, path):
    """复刻 A2ModpackReadJSONObject：不存在 / 为空 / 非法 JSON 均返回 None"""
    data = files.get(path)
    if not data:
        return None
    try:
        return json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None


def existing_directories(dirs, candidates):
    """复刻 A2ModpackExistingDirectories：按候选顺序挑出真实存在的目录"""
    return [name for name in candidates if name in dirs]


# ---------------- 复刻四个子解析器 ----------------

def parse_curseforge(files, dirs):
    """复刻 A2CurseForgePackParser"""
    d = read_json(files, "manifest.json")
    if not isinstance(d, dict):
        return None

    # CurseForge 的 manifest 必带 minecraft 段；没有就说明是别的格式借用了
    # manifest.json 这个文件名，安静返回 None 让调度器继续往后试。
    mc = d.get("minecraft")
    if not isinstance(mc, dict):
        return None

    info = {"format": A2ModpackFormatCurseForge}
    info["name"] = a2_string(d.get("name")) or "未命名整合包"
    info["recommendedRAM"] = a2_int(d.get("recommendedRam"))
    info["gameVersion"] = a2_string(mc.get("version"))

    # modLoaders 里 primary 那条才是要装的加载器
    loaders = mc.get("modLoaders")
    loaders = loaders if isinstance(loaders, list) else []
    chosen = None
    for raw in loaders:
        if not isinstance(raw, dict):
            continue
        if chosen is None:
            chosen = raw
        if a2_bool(raw.get("primary")):
            chosen = raw
            break
    loader_id = a2_string(chosen.get("id")) if isinstance(chosen, dict) else None
    info["loaderType"] = loader_type_for_identifier(loader_id)
    info["loaderVersion"] = version_from_cf_loader_id(loader_id)

    out_files = []
    raw_files = d.get("files")
    raw_files = raw_files if isinstance(raw_files, list) else []
    for raw in raw_files:
        if not isinstance(raw, dict):
            continue
        pid = raw.get("projectID")
        fid = raw.get("fileID")
        pid = pid if isinstance(pid, (int, float)) else None
        fid = fid if isinstance(fid, (int, float)) else None
        if pid is None or fid is None:
            continue
        # 清单里既没直链也没目标目录，都得联网查 API，交给安装器补齐
        out_files.append({
            "relativePath": "",
            "downloadURLs": [],
            "sha1": None,
            "size": 0,
            "requiresCurseForgeLookup": True,
            "curseForgeProjectID": int(pid),
            "curseForgeFileID": int(fid),
        })
    info["files"] = out_files

    override_name = a2_string(d.get("overrides")) or "overrides"
    info["overrideDirectories"] = existing_directories(dirs, [override_name])
    return info


def parse_modrinth(files, dirs):
    """复刻 A2ModrinthPackParser"""
    d = read_json(files, "modrinth.index.json")
    if not isinstance(d, dict):
        return None

    info = {"format": A2ModpackFormatModrinth}
    info["name"] = a2_string(d.get("name")) or "未命名整合包"
    info["summary"] = a2_string(d.get("summary"))

    deps = d.get("dependencies")
    deps = deps if isinstance(deps, dict) else {}
    info["gameVersion"] = a2_string(deps.get("minecraft"))
    info["loaderType"] = None
    info["loaderVersion"] = None
    # 越具体的键越先判，避免 forge 抢走 neoforge
    for key in ["neoforge", "forge", "quilt-loader",
                "fabric-loader", "legacy-fabric-loader"]:
        version = a2_string(deps.get(key))
        if not version:
            continue
        info["loaderType"] = loader_type_for_identifier(key)
        info["loaderVersion"] = version
        break

    out_files = []
    raw_files = d.get("files")
    raw_files = raw_files if isinstance(raw_files, list) else []
    for raw in raw_files:
        if not isinstance(raw, dict):
            continue
        path = a2_string(raw.get("path"))
        if not path:
            continue
        # server unsupported 的文件客户端用不到
        env = raw.get("env")
        env = env if isinstance(env, dict) else None
        # env 为 nil 时 msg(nil) 返回 nil，故需先判 env 是否为字典
        if env and a2_string(env.get("client")) == "unsupported":
            continue
        urls = []
        raw_urls = raw.get("downloads")
        raw_urls = raw_urls if isinstance(raw_urls, list) else []
        for u in raw_urls:
            s = a2_string(u)
            if s:
                urls.append(s)
        hashes = raw.get("hashes")
        hashes = hashes if isinstance(hashes, dict) else None
        out_files.append({
            "relativePath": normalize_path(path),
            "downloadURLs": urls,
            "sha1": a2_string(hashes.get("sha1")) if hashes else None,
            "size": a2_int(raw.get("fileSize")),
        })
    info["files"] = out_files
    info["overrideDirectories"] = existing_directories(
        dirs, ["overrides", "client-overrides"])
    return info


def mmc_instance_value(files, key):
    """复刻 A2MMCInstanceValue：读 instance.cfg 里的 key=value"""
    data = files.get("instance.cfg")
    if not data:
        return None
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if not text:
        return None
    for line in text.splitlines():
        idx = line.find("=")
        if idx < 0:
            continue
        if line[:idx] == key:
            return line[idx + 1:]
    return None


def parse_multimc(files, dirs, root_name):
    """复刻 A2MultiMCPackParser"""
    d = read_json(files, "mmc-pack.json")
    if not isinstance(d, dict):
        return None

    info = {"format": A2ModpackFormatMultiMC}
    info["name"] = mmc_instance_value(files, "name") or last_path_component(root_name)
    info["recommendedRAM"] = 0
    memory = mmc_instance_value(files, "MaxMemAlloc")
    if memory:
        info["recommendedRAM"] = leading_int(memory)

    info["gameVersion"] = None
    info["loaderType"] = None
    info["loaderVersion"] = None
    components = d.get("components")
    components = components if isinstance(components, list) else []
    for raw in components:
        if not isinstance(raw, dict):
            continue
        uid = a2_string(raw.get("uid"))
        version = a2_string(raw.get("version"))
        if uid == "net.minecraft":
            info["gameVersion"] = version
            continue
        t = loader_type_for_identifier(uid)
        if t is not None and info["loaderType"] is None:
            info["loaderType"] = t
            info["loaderVersion"] = version

    # MultiMC 把模组与配置直接放在实例目录里，没有需要逐个下载的清单
    info["files"] = []
    info["overrideDirectories"] = existing_directories(
        dirs, [".minecraft", "minecraft", "overrides"])
    return info


def mcbbs_path_for_entry(entry):
    """复刻 A2MCBBSPathForEntry：files 条目不带 path 时按 type 猜目录、用 URL 末段当文件名"""
    type_ = (a2_string(entry.get("type")) or "").lower()
    dir_ = "mods"
    if "shader" in type_:
        dir_ = "shaderpacks"
    elif "resourcepack" in type_ or "texture" in type_:
        dir_ = "resourcepacks"
    elif "save" in type_ or "world" in type_:
        dir_ = "saves"
    elif "minecraft" in type_:
        dir_ = ""
    name = last_path_component(a2_string(entry.get("url")))
    if not name:
        return None
    return (dir_ + "/" + name) if dir_ else name


def parse_mcbbs(files, dirs):
    """复刻 A2MCBBSPackParser"""
    d = read_json(files, "mcbbs.packmeta")
    if not isinstance(d, dict):
        # 旧包没有 packmeta，退回 manifest.json
        d = read_json(files, "manifest.json")
    if not isinstance(d, dict):
        return None

    info = {"format": A2ModpackFormatMCBBS}
    info["name"] = a2_string(d.get("name")) or "未命名整合包"
    info["summary"] = a2_string(d.get("description")) or a2_string(d.get("summary"))

    addons = d.get("addons")
    addons = addons if isinstance(addons, dict) else None
    game = addons.get("game") if addons else None
    game = game if isinstance(game, dict) else None
    info["gameVersion"] = (a2_string(game.get("version")) if game else None) \
        or a2_string(d.get("mcversion"))

    # addons 里除 game 外的第一个可识别项就是加载器
    info["loaderType"] = None
    info["loaderVersion"] = None
    if addons:
        for key in addons:
            if key == "game":
                continue
            t = loader_type_for_identifier(key)
            if not t:
                continue
            entry = addons[key] if isinstance(addons[key], dict) else None
            info["loaderType"] = t
            info["loaderVersion"] = (a2_string(entry.get("version")) if entry else None) \
                or (a2_string(entry.get("name")) if entry else None)
            break

    out_files = []
    raw_files = d.get("files")
    raw_files = raw_files if isinstance(raw_files, list) else []
    for raw in raw_files:
        if not isinstance(raw, dict):
            continue
        path = a2_string(raw.get("path"))
        if not path:
            path = mcbbs_path_for_entry(raw)
        if not path:
            continue
        urls = []
        raw_urls = raw.get("urls")
        raw_urls = raw_urls if isinstance(raw_urls, list) else []
        for u in raw_urls:
            s = a2_string(u)
            if s:
                urls.append(s)
        single = a2_string(raw.get("url"))
        if single:
            urls.append(single)
        out_files.append({
            "relativePath": normalize_path(path),
            "downloadURLs": urls,
            "sha1": a2_string(raw.get("hash")) or a2_string(raw.get("sha1")),
            "size": a2_int(raw.get("size")),
        })
    info["files"] = out_files
    info["overrideDirectories"] = existing_directories(dirs, ["overrides"])
    return info


# ---------------- 复刻 A2ModpackParser 的调度 ----------------

PARSE_BY_FORMAT = {
    A2ModpackFormatCurseForge: lambda files, dirs, root: parse_curseforge(files, dirs),
    A2ModpackFormatModrinth: lambda files, dirs, root: parse_modrinth(files, dirs),
    A2ModpackFormatMultiMC: lambda files, dirs, root: parse_multimc(files, dirs, root),
    A2ModpackFormatMCBBS: lambda files, dirs, root: parse_mcbbs(files, dirs),
}


def parse_extracted_pack(root_name, files, dirs):
    """复刻 parseExtractedPackAtRoot：按 CF→Modrinth→MultiMC→MCBBS 命中即止"""
    order = [A2ModpackFormatCurseForge, A2ModpackFormatModrinth,
             A2ModpackFormatMultiMC, A2ModpackFormatMCBBS]
    for fmt in order:
        signature = FORMAT_SIGNATURE[fmt]
        if signature not in files:
            continue
        info = PARSE_BY_FORMAT[fmt](files, dirs, root_name)
        if info:
            return info
    return None


def parse_zip(data, root_name):
    files, dirs = unzip(data)
    return parse_extracted_pack(root_name, files, dirs)


# ---------------- 测试 ----------------

def check(name, got, want):
    ok = got == want
    print(f"  {'✓' if ok else '✗'} {name}")
    if not ok:
        g = got if got is None or len(str(g)) < 120 else str(g)[:120] + '...'
        w = want if want is None or len(str(want)) < 120 else str(want)[:120] + '...'
        print(f"      got  = {g}")
        print(f"      want = {w}")
    return ok


def jget(info, key):
    return info.get(key) if isinstance(info, dict) else None


def fget(info, idx, key):
    files = info.get("files") if isinstance(info, dict) else None
    if not files or idx >= len(files):
        return None
    return files[idx].get(key)


all_ok = True

print("=" * 68)
print("整合包解析器逻辑验证")
print("=" * 68)

# ---- 1. 格式签名与显示名 ----
print("\n[1] 格式签名与显示名")
all_ok &= check("Modrinth 签名", FORMAT_SIGNATURE[A2ModpackFormatModrinth], "modrinth.index.json")
all_ok &= check("CurseForge 签名", FORMAT_SIGNATURE[A2ModpackFormatCurseForge], "manifest.json")
all_ok &= check("MultiMC 签名", FORMAT_SIGNATURE[A2ModpackFormatMultiMC], "mmc-pack.json")
all_ok &= check("MCBBS 签名", FORMAT_SIGNATURE[A2ModpackFormatMCBBS], "mcbbs.packmeta")
all_ok &= check("Unknown 签名", FORMAT_SIGNATURE[A2ModpackFormatUnknown], "")
all_ok &= check("CurseForge 显示名", FORMAT_DISPLAY[A2ModpackFormatCurseForge], "CurseForge")
all_ok &= check("Unknown 显示名", FORMAT_DISPLAY[A2ModpackFormatUnknown], "未知")

# ---- 2. 加载器标识映射 ----
print("\n[2] A2ModpackLoaderTypeForIdentifier 映射")
all_ok &= check("forge", loader_type_for_identifier("forge"), L_FORGE)
all_ok &= check("neoforge 不被 forge 抢走", loader_type_for_identifier("neoforge"), L_NEOFORGE)
all_ok &= check("net.minecraftforge", loader_type_for_identifier("net.minecraftforge"), L_FORGE)
all_ok &= check("fabric-loader", loader_type_for_identifier("fabric-loader"), L_FABRIC)
all_ok &= check("quilt-loader", loader_type_for_identifier("quilt-loader"), L_QUILT)
all_ok &= check("legacy-fabric-loader",
                loader_type_for_identifier("legacy-fabric-loader"), L_LEGACYFABRIC)
all_ok &= check("legacyfabric（无短横线）",
                loader_type_for_identifier("legacyfabric"), L_LEGACYFABRIC)
all_ok &= check("optifine", loader_type_for_identifier("optifine"), L_OPTIFINE)
all_ok &= check("大小写不敏感", loader_type_for_identifier("NEOFORGE"), L_NEOFORGE)
all_ok &= check("原版 net.minecraft", loader_type_for_identifier("net.minecraft"), None)
all_ok &= check("空串", loader_type_for_identifier(""), None)
all_ok &= check("None", loader_type_for_identifier(None), None)

# ---- 3. CurseForge 加载器版本号提取 ----
print("\n[3] A2ModpackVersionFromCurseForgeLoaderID")
all_ok &= check("forge-47.2.0", version_from_cf_loader_id("forge-47.2.0"), "47.2.0")
all_ok &= check("neoforge-21.1.72", version_from_cf_loader_id("neoforge-21.1.72"), "21.1.72")
all_ok &= check("legacy-fabric-0.15.0（前缀含短横线）",
                version_from_cf_loader_id("legacy-fabric-0.15.0"), "0.15.0")
all_ok &= check("纯字母无版本", version_from_cf_loader_id("forge"), None)
all_ok &= check("空串", version_from_cf_loader_id(""), None)

# ---- 4. Modrinth ----
print("\n[4] Modrinth：modrinth.index.json")
modrinth_index = {
    "name": "测试整合包",
    "summary": "一个测试用整合包",
    "dependencies": {"minecraft": "1.20.1", "forge": "47.2.0"},
    "files": [
        {
            "path": "mods\\a.jar",              # 反斜杠应被归一化
            "hashes": {"sha1": "abc123"},
            "downloads": ["https://cdn/a.jar", "https://cdn/a-mirror.jar"],
            "fileSize": 1234,
            "env": {"client": "required"},
        },
        {
            "path": "mods/serveronly.jar",
            "env": {"client": "unsupported"},   # 客户端不需要，应被跳过
            "downloads": ["https://cdn/s.jar"],
            "fileSize": 10,
            "hashes": {"sha1": "deadbeef"},
        },
        {
            "path": "shaderpacks/b.zip",
            "downloads": ["https://cdn/b.zip"],
            "fileSize": 4096,
        },
    ],
}
mr_info = parse_zip(make_zip([
    ("modrinth.index.json", json.dumps(modrinth_index, ensure_ascii=False)),
    ("overrides/config/a.toml", "x"),
    ("client-overrides/options.txt", "y"),
]), "ModrinthPack") or {}

all_ok &= check("识别为 Modrinth", jget(mr_info, "format"), A2ModpackFormatModrinth)
all_ok &= check("name", jget(mr_info, "name"), "测试整合包")
all_ok &= check("summary", jget(mr_info, "summary"), "一个测试用整合包")
all_ok &= check("gameVersion", jget(mr_info, "gameVersion"), "1.20.1")
all_ok &= check("loaderType = Forge", jget(mr_info, "loaderType"), L_FORGE)
all_ok &= check("loaderVersion", jget(mr_info, "loaderVersion"), "47.2.0")
all_ok &= check("跳过 client=unsupported，files 数 = 2", len(jget(mr_info, "files") or []), 2)
all_ok &= check("files[0].relativePath 反斜杠归一化",
                fget(mr_info, 0, "relativePath"), "mods/a.jar")
all_ok &= check("files[0].downloadURLs 取 downloads",
                fget(mr_info, 0, "downloadURLs"),
                ["https://cdn/a.jar", "https://cdn/a-mirror.jar"])
all_ok &= check("files[0].sha1 取 hashes.sha1", fget(mr_info, 0, "sha1"), "abc123")
all_ok &= check("files[0].size 取 fileSize", fget(mr_info, 0, "size"), 1234)
all_ok &= check("files[1].relativePath", fget(mr_info, 1, "relativePath"), "shaderpacks/b.zip")
all_ok &= check("files[1].sha1 无 hashes = None", fget(mr_info, 1, "sha1"), None)
all_ok &= check("files[1].size", fget(mr_info, 1, "size"), 4096)
all_ok &= check("overrideDirectories 只保留真实存在的目录",
                jget(mr_info, "overrideDirectories"), ["overrides", "client-overrides"])

# ---- 5. CurseForge ----
print("\n[5] CurseForge：manifest.json")
cf_manifest = {
    "name": "CF测试包",
    "recommendedRam": 4096,
    "minecraft": {
        "version": "1.19.2",
        "modLoaders": [
            {"id": "fabric-0.15.2", "primary": False},
            {"id": "forge-43.2.0", "primary": True},   # primary 才是要装的
        ],
    },
    "files": [
        {"projectID": 123, "fileID": 456},
        {"projectID": 789},                            # 缺 fileID，应被跳过
    ],
    "overrides": "custom-overrides",
}
cf_info = parse_zip(make_zip([
    ("manifest.json", json.dumps(cf_manifest, ensure_ascii=False)),
    ("custom-overrides/config.txt", "z"),
]), "CFPack") or {}

all_ok &= check("识别为 CurseForge", jget(cf_info, "format"), A2ModpackFormatCurseForge)
all_ok &= check("name", jget(cf_info, "name"), "CF测试包")
all_ok &= check("recommendedRAM", jget(cf_info, "recommendedRAM"), 4096)
all_ok &= check("gameVersion", jget(cf_info, "gameVersion"), "1.19.2")
all_ok &= check("loaderType = Forge（取 primary）", jget(cf_info, "loaderType"), L_FORGE)
all_ok &= check("loaderVersion 从 forge-43.2.0 提取", jget(cf_info, "loaderVersion"), "43.2.0")
all_ok &= check("缺 fileID 的条目被跳过，files 数 = 1", len(jget(cf_info, "files") or []), 1)
all_ok &= check("requiresCurseForgeLookup", fget(cf_info, 0, "requiresCurseForgeLookup"), True)
all_ok &= check("curseForgeProjectID", fget(cf_info, 0, "curseForgeProjectID"), 123)
all_ok &= check("curseForgeFileID", fget(cf_info, 0, "curseForgeFileID"), 456)
all_ok &= check("downloadURL 为空", fget(cf_info, 0, "downloadURLs"), [])
all_ok &= check("relativePath 为空（等 API 补齐）", fget(cf_info, 0, "relativePath"), "")
all_ok &= check("overrideDirectories 用自定义 overrides",
                jget(cf_info, "overrideDirectories"), ["custom-overrides"])

# ---- 6. MultiMC ----
print("\n[6] MultiMC：mmc-pack.json + instance.cfg")
mmc_pack = {
    "formatVersion": 1,
    "components": [
        {"uid": "net.minecraft", "version": "1.20.4"},
        {"uid": "net.minecraftforge", "version": "49.0.30"},
    ],
}
mmc_instance = "InstanceType=OneSix\nname=MMC测试实例\nMaxMemAlloc=6144\n"
mmc_info = parse_zip(make_zip([
    ("mmc-pack.json", json.dumps(mmc_pack, ensure_ascii=False)),
    ("instance.cfg", mmc_instance),
    (".minecraft/mods/x.jar", "m"),
    ("overrides/config/a.toml", "x"),
]), "MMCPack") or {}

all_ok &= check("识别为 MultiMC", jget(mmc_info, "format"), A2ModpackFormatMultiMC)
all_ok &= check("name 来自 instance.cfg", jget(mmc_info, "name"), "MMC测试实例")
all_ok &= check("recommendedRAM 来自 MaxMemAlloc", jget(mmc_info, "recommendedRAM"), 6144)
all_ok &= check("gameVersion 来自 net.minecraft 组件",
                jget(mmc_info, "gameVersion"), "1.20.4")
all_ok &= check("loaderType = Forge（net.minecraftforge）",
                jget(mmc_info, "loaderType"), L_FORGE)
all_ok &= check("loaderVersion", jget(mmc_info, "loaderVersion"), "49.0.30")
all_ok &= check("files 为空数组", jget(mmc_info, "files"), [])
all_ok &= check("overrideDirectories（.minecraft + overrides）",
                jget(mmc_info, "overrideDirectories"), [".minecraft", "overrides"])

# 没有 instance.cfg 的 name 时退回根目录名
mmc_noname = parse_zip(make_zip([
    ("mmc-pack.json", json.dumps({"components": [{"uid": "net.minecraft", "version": "1.20"}]})),
]), "FallbackRoot") or {}
all_ok &= check("无 instance.cfg 时 name 退回根目录名",
                jget(mmc_noname, "name"), "FallbackRoot")

# ---- 7. MCBBS ----
print("\n[7] MCBBS：mcbbs.packmeta（含旧包退回 manifest.json）")
mcbbs_meta = {
    "name": "MCBBS测试包",
    "description": "论坛整合包",
    "addons": {
        "game": {"version": "1.18.2"},
        "forge": {"version": "40.2.0", "name": "Forge"},
    },
    "files": [
        {"path": "mods/x.jar", "urls": ["https://a/x.jar"], "hash": "aa11", "size": 100},
        {"type": "shader", "url": "https://mc.com/shaders/beauty.zip"},  # 无 path，按 type 猜
        {"path": "config/y.toml"},                                       # 无 URL
    ],
}
mc_info = parse_zip(make_zip([
    ("mcbbs.packmeta", json.dumps(mcbbs_meta, ensure_ascii=False)),
    ("overrides/config/a.toml", "x"),
]), "MCBBSPack") or {}

all_ok &= check("识别为 MCBBS", jget(mc_info, "format"), A2ModpackFormatMCBBS)
all_ok &= check("name", jget(mc_info, "name"), "MCBBS测试包")
all_ok &= check("summary 取 description", jget(mc_info, "summary"), "论坛整合包")
all_ok &= check("gameVersion 取 addons.game.version", jget(mc_info, "gameVersion"), "1.18.2")
all_ok &= check("loaderType = Forge", jget(mc_info, "loaderType"), L_FORGE)
all_ok &= check("loaderVersion", jget(mc_info, "loaderVersion"), "40.2.0")
all_ok &= check("files 数 = 3", len(jget(mc_info, "files") or []), 3)
all_ok &= check("files[0].relativePath", fget(mc_info, 0, "relativePath"), "mods/x.jar")
all_ok &= check("files[0].downloadURLs 取 urls", fget(mc_info, 0, "downloadURLs"), ["https://a/x.jar"])
all_ok &= check("files[0].sha1 取 hash", fget(mc_info, 0, "sha1"), "aa11")
all_ok &= check("files[0].size 取 size", fget(mc_info, 0, "size"), 100)
all_ok &= check("files[1] 按 type=shader 猜目录 + URL 末段当文件名",
                fget(mc_info, 1, "relativePath"), "shaderpacks/beauty.zip")
all_ok &= check("files[1].downloadURLs 含单个 url",
                fget(mc_info, 1, "downloadURLs"), ["https://mc.com/shaders/beauty.zip"])
all_ok &= check("files[1] 无 hash/sha1 = None", fget(mc_info, 1, "sha1"), None)
all_ok &= check("files[2].relativePath", fget(mc_info, 2, "relativePath"), "config/y.toml")
all_ok &= check("files[2].downloadURLs 空", fget(mc_info, 2, "downloadURLs"), [])
all_ok &= check("overrideDirectories", jget(mc_info, "overrideDirectories"), ["overrides"])

# 旧包退回 manifest.json —— 解析器直调（调度器只在 mcbbs.packmeta 存在时才会走到 MCBBS）
old_files, old_dirs = unzip(make_zip([
    ("manifest.json", json.dumps({
        "name": "MCBBS旧包", "mcversion": "1.12.2",
        "files": [{"path": "mods/old.jar", "url": "https://o/old.jar", "size": 321}],
    }, ensure_ascii=False)),
]))
old_info = parse_mcbbs(old_files, old_dirs) or {}
all_ok &= check("旧包退回 manifest.json：格式仍为 MCBBS",
                jget(old_info, "format"), A2ModpackFormatMCBBS)
all_ok &= check("旧包 name", jget(old_info, "name"), "MCBBS旧包")
all_ok &= check("旧包 gameVersion 取 mcversion", jget(old_info, "gameVersion"), "1.12.2")
all_ok &= check("旧包 files[0].size", fget(old_info, 0, "size"), 321)

# packmeta 存在但内容不可读时，调度器也会经 MCBBS 走到该退回分支
fallback = parse_zip(make_zip([
    ("mcbbs.packmeta", "this is not json"),
    ("manifest.json", json.dumps({
        "name": "MCBBS退回包", "mcversion": "1.7.10", "files": [],
    }, ensure_ascii=False)),
]), "FallbackPack") or {}
all_ok &= check("packmeta 不可读时调度器经 MCBBS 退回 manifest.json",
                jget(fallback, "format"), A2ModpackFormatMCBBS)
all_ok &= check("退回包 name", jget(fallback, "name"), "MCBBS退回包")

# ---- 8. 判别顺序：前面命中即止 ----
print("\n[8] 判别顺序（命中即止）")
both = parse_zip(make_zip([
    ("manifest.json", json.dumps({
        "name": "CF优先", "minecraft": {"version": "1.20.1",
                                       "modLoaders": [{"id": "forge-1.0", "primary": True}]},
        "files": [],
    }, ensure_ascii=False)),
    ("modrinth.index.json", json.dumps({
        "name": "Modrinth包", "dependencies": {"minecraft": "1.20.1"}, "files": [],
    }, ensure_ascii=False)),
]), "BothPack") or {}
all_ok &= check("manifest+index 同时存在 → CurseForge 优先",
                jget(both, "format"), A2ModpackFormatCurseForge)
all_ok &= check("取到的是 CurseForge 的 name", jget(both, "name"), "CF优先")

# ---- 9. 边界：不应崩溃、应解析失败 ----
print("\n[9] 边界情况")
all_ok &= check("空 zip 解析失败", parse_zip(make_zip([]), "Empty"), None)
all_ok &= check("只有无关文件 → 失败",
                parse_zip(make_zip([("readme.txt", "hi"),
                                    ("assets/logo.png", b"\x89PNG")]), "Junk"), None)
all_ok &= check("manifest.json 非法 JSON → 失败",
                parse_zip(make_zip([("manifest.json", "{ not json")]), "Bad"), None)
all_ok &= check("manifest.json 顶层非对象 → 失败",
                parse_zip(make_zip([("manifest.json", "[1,2,3]")]), "Bad2"), None)
all_ok &= check("manifest.json 无 minecraft 段 → 失败",
                parse_zip(make_zip([("manifest.json", '{"name":"x","files":[]}')]), "Bad3"), None)
all_ok &= check("modrinth.index.json 非法 JSON → 失败",
                parse_zip(make_zip([("modrinth.index.json", "<xml/>")]), "Bad4"), None)
all_ok &= check("mmc-pack.json 非法 JSON → 失败",
                parse_zip(make_zip([("mmc-pack.json", "nope")]), "Bad5"), None)
all_ok &= check("非 zip 数据 → 失败（不崩溃）", parse_zip(b"not a zip at all", "Bad6"), None)
all_ok &= check("空数据 → 失败（不崩溃）", parse_zip(b"", "Bad7"), None)

print("\n" + "=" * 68)
if all_ok:
    print("全部通过")
else:
    print("有失败项")
print("=" * 68)
