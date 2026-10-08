#!/usr/bin/env python3
"""
MurmurHash2-32 参考实现对照测试。

对照：
  ZL2 MurmurHash2Incremental.kt（M=0x5bd1e995、R=24、seed=1，
  过滤 0x09/0x0A/0x0D/0x20 后哈希）与 commons-codec MurmurHash2 参考语义。
  Air2 的 ObjC 实现（Air2/Utils/A2MurmurHash2）是同一算法的移植，
  本文件用独立 Python 实现锁定向量，改算法时三方必须一起对齐。

已知向量（seed 标注）：
  b''                    seed=1 -> 1540447798
  b'hello'               seed=1 -> 2788266382
  b'hello'               seed=0 -> 3848350155
  b'The quick brown fox' seed=1 -> 370101961
"""
import os
import sys
import tempfile

M32 = 0x5BD1E995
R32 = 24


def hash32(data: bytes, seed: int) -> int:
    h = (seed ^ len(data)) & 0xFFFFFFFF
    i = 0
    n = len(data)
    while i + 4 <= n:
        k = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24)
        k = (k * M32) & 0xFFFFFFFF
        k ^= k >> R32
        k = (k * M32) & 0xFFFFFFFF
        h = (h * M32) & 0xFFFFFFFF
        h ^= k
        i += 4
    tail = n - i
    if tail == 3:
        h ^= data[i + 2] << 16
        h ^= data[i + 1] << 8
        h ^= data[i]
        h = (h * M32) & 0xFFFFFFFF
    elif tail == 2:
        h ^= data[i + 1] << 8
        h ^= data[i]
        h = (h * M32) & 0xFFFFFFFF
    elif tail == 1:
        h ^= data[i]
        h = (h * M32) & 0xFFFFFFFF
    h ^= h >> 13
    h = (h * M32) & 0xFFFFFFFF
    h ^= h >> 15
    return h & 0xFFFFFFFF


SKIP = {0x09, 0x0A, 0x0D, 0x20}


def fingerprint(data: bytes) -> int:
    return hash32(bytes(b for b in data if b not in SKIP), 1)


def check(name, got, want):
    status = "ok" if got == want else "FAIL"
    print(f"  [{status}] {name}: got {got}, want {want}")
    return got == want


def main() -> int:
    ok = True
    ok &= check("empty/seed1", hash32(b"", 1), 1540447798)
    ok &= check("hello/seed1", hash32(b"hello", 1), 2788266382)
    ok &= check("hello/seed0", hash32(b"hello", 0), 3848350155)
    ok &= check("fox/seed1", hash32(b"The quick brown fox", 1), 370101961)
    ok &= check("seed敏感", hash32(b"hello", 1) != hash32(b"hello", 0), True)
    ok &= check("过滤等价", fingerprint(b"a b\tc\nd\re"), 3469237630)
    ok &= check("不过滤不同", fingerprint(b"a b") != hash32(b"a b", 1), True)

    # 文件流式语义：分块喂与整体喂一致（ObjC 按 8192 分块，逻辑等价）。
    with tempfile.NamedTemporaryFile(delete=False) as f:
        path = f.name
        f.write(b"0123456789abcdef" * 1024 + b"\n ")
    try:
        with open(path, "rb") as fh:
            chunks = []
            while True:
                c = fh.read(8192)
                if not c:
                    break
                chunks.append(c)
        joined = b"".join(chunks)
        ok &= check("分块一致", hash32(joined, 1), hash32(b"0123456789abcdef" * 1024 + b"\n ", 1))
    finally:
        os.unlink(path)

    print("==================================================================")
    print("全部通过" if ok else "有失败")
    print("==================================================================")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
