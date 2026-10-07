#!/usr/bin/env python3
"""
验证 A2ZipReader 的解析逻辑。

用 Python 复刻 ObjC 实现并用真实 zip 文件验证 ——
zip 中央目录、本地文件头的偏移都是易错点，
一旦搞错读出来的就是垃圾数据（而不是报错）。

iSH 里没有 ObjC 编译器，所以：
  1. 用 Python 的 zipfile 生成测试 zip
  2. 用 Python 按我们的算法解析一遍
  3. 比对结果是否与 zipfile 一致
"""
import struct
import zipfile
import io
import zlib
import os


# ---------------- 复刻 A2ZipReader 的解析逻辑 ----------------

CENTRAL_SIG = 0x02014b50
LOCAL_SIG = 0x04034b50
EOCD_SIG = 0x06054b50


def find_eocd(data):
    """从尾部往前找 EOCD（可能带注释，最多 64KB）"""
    n = len(data)
    if n < 22:
        return -1
    scan_start = max(0, n - 65557)
    for i in range(n - 22, scan_start - 1, -1):
        if struct.unpack_from('<I', data, i)[0] == EOCD_SIG:
            return i
    return -1


def parse_central_directory(data):
    """解析中央目录，返回 {name: entry}"""
    eocd = find_eocd(data)
    if eocd < 0:
        return {}

    entry_count = struct.unpack_from('<H', data, eocd + 10)[0]
    cd_offset = struct.unpack_from('<I', data, eocd + 16)[0]

    if cd_offset >= len(data):
        return {}

    entries = {}
    p = cd_offset
    for _ in range(entry_count):
        if p + 46 > len(data):
            break
        if struct.unpack_from('<I', data, p)[0] != CENTRAL_SIG:
            break

        method = struct.unpack_from('<H', data, p + 10)[0]
        comp_size = struct.unpack_from('<I', data, p + 20)[0]
        uncomp_size = struct.unpack_from('<I', data, p + 24)[0]
        name_len = struct.unpack_from('<H', data, p + 28)[0]
        extra_len = struct.unpack_from('<H', data, p + 30)[0]
        comment_len = struct.unpack_from('<H', data, p + 32)[0]
        local_offset = struct.unpack_from('<I', data, p + 42)[0]

        if p + 46 + name_len > len(data):
            break
        name = data[p + 46:p + 46 + name_len].decode('utf-8', errors='replace')

        if name and not name.endswith('/'):
            entries[name] = {
                'method': method,
                'compressed_size': comp_size,
                'uncompressed_size': uncomp_size,
                'local_offset': local_offset,
            }

        p += 46 + name_len + extra_len + comment_len

    return entries


def extract_entry(data, entry):
    """取出并解压一个条目"""
    p = entry['local_offset']
    if p + 30 > len(data):
        return None
    if struct.unpack_from('<I', data, p)[0] != LOCAL_SIG:
        return None

    # 关键：本地头的 name/extra 长度可能与中央目录不同，必须读本地头
    name_len = struct.unpack_from('<H', data, p + 26)[0]
    extra_len = struct.unpack_from('<H', data, p + 28)[0]
    data_start = p + 30 + name_len + extra_len

    comp = data[data_start:data_start + entry['compressed_size']]

    if entry['method'] == 0:
        return comp
    if entry['method'] == 8:
        # zip 的 deflate 是 raw（无 zlib 头），wbits 要用 -15
        return zlib.decompress(comp, -15)
    return None


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


all_ok = True

print("=" * 68)
print("zip 读取器逻辑验证")
print("=" * 68)

# ---- 1. 基本：stored + deflate ----
print("\n[1] stored 与 deflate 两种压缩方式")
buf = io.BytesIO()
with zipfile.ZipFile(buf, 'w') as z:
    z.writestr('stored.txt', 'hello stored', compress_type=zipfile.ZIP_STORED)
    z.writestr('deflated.txt', 'hello deflated ' * 100, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr('dir/', '')      # 目录条目应被跳过
    z.writestr('dir/nested.json', '{"key":"value"}', compress_type=zipfile.ZIP_DEFLATED)

data = buf.getvalue()
entries = parse_central_directory(data)

all_ok &= check("跳过目录条目", 'dir/' in entries, False)
all_ok &= check("条目数 = 3", len(entries), 3)
all_ok &= check("stored 内容", extract_entry(data, entries['stored.txt']), b'hello stored')
all_ok &= check("deflate 内容", extract_entry(data, entries['deflated.txt']),
                ('hello deflated ' * 100).encode())

# ---- 2. JSON 内容（Forge installer 的实际场景）----
print("\n[2] 模拟 Forge installer 的 version.json")
sample_json = b'{"id":"1.21.5-forge","mainClass":"cpw.mods.modlauncher.Launcher","libraries":[]}'
buf2 = io.BytesIO()
with zipfile.ZipFile(buf2, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('META-INF/MANIFEST.MF', 'Manifest-Version: 1.0\n')
    z.writestr('version.json', sample_json)
    z.writestr('install_profile.json', b'{"spec":1}')
    # 加些干扰文件，模拟真实 jar
    for i in range(20):
        z.writestr(f'net/minecraftforge/Class{i}.class', os.urandom(200))

data2 = buf2.getvalue()
entries2 = parse_central_directory(data2)

all_ok &= check("能在大量干扰文件中定位 version.json",
                'version.json' in entries2, True)
all_ok &= check("version.json 内容正确",
                extract_entry(data2, entries2['version.json']), sample_json)
all_ok &= check("install_profile.json 内容正确",
                extract_entry(data2, entries2['install_profile.json']), b'{"spec":1}')

# ---- 3. 与标准库比对（确保我们的解析没错）----
print("\n[3] 与 Python zipfile 逐一比对")
with zipfile.ZipFile(io.BytesIO(data2)) as z:
    for name in z.namelist():
        if name.endswith('/'):
            continue
        ours = extract_entry(data2, entries2[name])
        theirs = z.read(name)
        all_ok &= check(f"{name[:40]:42s}", ours == theirs, True)

# ---- 4. 带注释的 zip（EOCD 不在最末尾）----
print("\n[4] EOCD 带注释（真实 zip 常见）")
buf3 = io.BytesIO()
with zipfile.ZipFile(buf3, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('a.json', b'{"x":1}')
    z.comment = b'this is a zip comment' * 10
data3 = buf3.getvalue()

eocd_off = find_eocd(data3)
all_ok &= check("能找到 EOCD", eocd_off > 0, True)
entries3 = parse_central_directory(data3)
all_ok &= check("带注释仍能解析", extract_entry(data3, entries3['a.json']), b'{"x":1}')

# ---- 5. 边界：空文件、大文件 ----
print("\n[5] 边界情况")
buf4 = io.BytesIO()
with zipfile.ZipFile(buf4, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('empty.txt', b'')
    z.writestr('big.bin', b'\x00' * (1024 * 1024))   # 1MB
data4 = buf4.getvalue()
entries4 = parse_central_directory(data4)

all_ok &= check("空文件", extract_entry(data4, entries4['empty.txt']), b'')
all_ok &= check("1MB 文件长度", len(extract_entry(data4, entries4['big.bin'])), 1024 * 1024)

# ---- 6. 非法输入 ----
print("\n[6] 非法输入不应崩溃")
all_ok &= check("非 zip 数据", parse_central_directory(b'not a zip at all'), {})
all_ok &= check("空数据", parse_central_directory(b''), {})
all_ok &= check("截断数据", parse_central_directory(data[:len(data)//2]), {})

print("\n" + "=" * 68)
if all_ok:
    print("全部通过")
else:
    print("有失败项")
print("=" * 68)
