#!/usr/bin/env python3
"""
下载并处理 iOS 版 JRE。

## 来源

Air1 用的是 angelauramc 编译的 iOS JRE：
   https://assets.angelauramc.dev/openjdk/ios-arm64/jre{N}-ios-aarch64.zip

四个版本：8 / 17 / 21 / 25（对应不同时代 MC 的需求）

## 处理流程（对照 Air1 的 Makefile `jre` 目标）

  1. 下载 zip
  2. 解压，处理「多套一层目录」的情况
  3. **校验 lib/server/libjvm.dylib 存在** —— 这是 JVM 的核心
  4. **删除不需要的部分**（大幅减小体积）：
        ASSEMBLY_EXCEPTION  bin/     include/  jre/     legal/
        LICENSE             man/     THIRD_PARTY_README
        lib/ct.sym          lib/jspawnhelper
        lib/libjsig.dylib   lib/src.zip   lib/tools.jar
  5. 补入自编的 libawt_xawt.dylib（AWT 的 iOS 补丁）

## 为什么要删这些

`bin/` 是命令行工具（java/javac），启动器用不到；
`include/` 是 JNI 头，编译期才需要；
`tools.jar` 是 javac，运行时不需要；
`libjsig.dylib` 是信号处理库，iOS 上不能用。

删完大约能省 30-40% 体积。

## 用法

    python3 scripts/fetch_jre.py                 # 下载全部 4 个
    python3 scripts/fetch_jre.py --only 17 21    # 只下指定版本
    python3 scripts/fetch_jre.py --check         # 只校验
"""

import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile

VERSIONS = [8, 17, 21, 25]
BASE_URL = "https://assets.angelauramc.dev/openjdk/ios-arm64/jre{v}-ios-aarch64.zip"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPENDS = os.path.join(ROOT, "depends")

# 解压后要删掉的东西（相对每个 JRE 根）
REMOVE_PATHS = [
    "ASSEMBLY_EXCEPTION",
    "THIRD_PARTY_README",
    "LICENSE",
    "bin",
    "include",
    "jre",
    "legal",
    "man",
    "lib/ct.sym",
    "lib/jspawnhelper",
    "lib/libjsig.dylib",
    "lib/src.zip",
    "lib/tools.jar",
]


def jre_name(version):
    return f"java-{version}-openjdk"


def jre_dir(version):
    return os.path.join(DEPENDS, jre_name(version))


def libjvm_path(version):
    return os.path.join(jre_dir(version), "lib/server/libjvm.dylib")


def release_path(version):
    return os.path.join(jre_dir(version), "release")


def is_ready(version):
    """已完成处理：有 release 且有 libjvm"""
    return os.path.exists(release_path(version)) and os.path.exists(libjvm_path(version))


def download(version):
    url = BASE_URL.format(v=version)
    zip_path = os.path.join(DEPENDS, f"jre{version}-ios-aarch64.zip")

    print(f"  ↓ 下载 JRE {version} ... ", end="", flush=True)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Air2-fetch-jre"})
        with urllib.request.urlopen(req, timeout=1800) as resp, open(zip_path, "wb") as f:
            shutil.copyfileobj(resp, f)
        size = os.path.getsize(zip_path)
        print(f"{size:,} bytes")
        return zip_path
    except Exception as e:
        print(f"失败：{e}")
        if os.path.exists(zip_path):
            os.remove(zip_path)
        return None


def extract(version, zip_path):
    """解压。

    注意这个包是【两层】：zip 里只有一个 .tar.xz，
    需要再解一次 tar.xz 才是真正的 JRE 目录。
    （Air1 的 Makefile 里也是 `unzip` 之后 `tar xf "$_arc"`）
    """
    target = jre_dir(version)
    tmp = target + "_extract"

    print(f"  ⇢ 解压 JRE {version} ... ", end="", flush=True)
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp, exist_ok=True)

    try:
        with zipfile.ZipFile(zip_path) as z:
            bad = z.testzip()
            if bad:
                print(f"zip 损坏（{bad}）")
                return False
            z.extractall(tmp)
    except Exception as e:
        print(f"zip 解压失败：{e}")
        return False

    # 第二层：如果有 .tar.xz 就解开
    tarballs = [f for f in os.listdir(tmp) if f.endswith((".tar.xz", ".tar.gz", ".tgz"))]
    if tarballs:
        tb = os.path.join(tmp, tarballs[0])
        print(f"\n     内层 {tarballs[0]} ... ", end="", flush=True)
        out_dir = os.path.join(tmp, "_tar")
        os.makedirs(out_dir, exist_ok=True)

        try:
            subprocess.run(
                ["tar", "xf", tb, "-C", out_dir],
                check=True, capture_output=True, timeout=1800
            )
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            print(f"tar 解压失败：{e}")
            return False

        # 用 tar 解出来的目录替换掉 zip 的内容
        #
        # ⚠️ iSH 上 shutil.move 对目录会走 copy2 分支并抛 FileNotFoundError
        # （它的语义是先创建目标目录再拷内容，在某些实现里会失败）。
        # 用 os.rename 直接改目录名，同一个父目录下是原子操作。
        final_dir = tmp + "_final"
        shutil.rmtree(final_dir, ignore_errors=True)
        try:
            os.rename(out_dir, final_dir)
        except OSError as e:
            print(f"目录重命名失败：{e}")
            return False

        shutil.rmtree(tmp, ignore_errors=True)
        os.rename(final_dir, tmp)
        print("OK", end="")

    # 判断解压出来的根：可能直接是 java-17-openjdk/，也可能多一层
    candidates = []
    if os.path.exists(os.path.join(tmp, "release")):
        candidates = [tmp]
    else:
        for entry in os.listdir(tmp):
            sub = os.path.join(tmp, entry)
            if os.path.isdir(sub) and os.path.exists(os.path.join(sub, "release")):
                candidates.append(sub)

    # 再深一层（有些包是 java-17-openjdk/jdk-17.0.x/）
    if not candidates:
        for entry in os.listdir(tmp):
            sub = os.path.join(tmp, entry)
            if not os.path.isdir(sub):
                continue
            for inner in os.listdir(sub):
                deep = os.path.join(sub, inner)
                if os.path.isdir(deep) and os.path.exists(os.path.join(deep, "release")):
                    candidates.append(deep)

    if not candidates:
        print("找不到 release 文件")
        return False

    src = candidates[0]
    shutil.rmtree(target, ignore_errors=True)
    shutil.move(src, target)
    shutil.rmtree(tmp, ignore_errors=True)

    print("OK")
    return True


def verify_and_trim(version):
    """校验核心文件 + 删除不需要的部分"""
    if not os.path.exists(libjvm_path(version)):
        print(f"  ✗ 缺 lib/server/libjvm.dylib —— JRE {version} 不可用")
        return False

    removed = 0
    saved = 0
    for rel in REMOVE_PATHS:
        path = os.path.join(jre_dir(version), rel)
        if not os.path.exists(path):
            continue
        size = 0
        for dirpath, _, files in os.walk(path):
            for f in files:
                try:
                    size += os.path.getsize(os.path.join(dirpath, f))
                except OSError:
                    pass
        if os.path.isfile(path):
            size = os.path.getsize(path)

        try:
            if os.path.isdir(path):
                shutil.rmtree(path)
            else:
                os.remove(path)
            removed += 1
            saved += size
        except OSError:
            pass

    if removed:
        print(f"  ✂ 删除 {removed} 项，省 {saved / 1024 / 1024:.1f} MB")

    return True


def copy_awt_patch(version):
    """补入自编的 libawt_xawt.dylib（Air1 编译的 AWT 补丁）"""
    local = os.path.join(ROOT, "Natives/libawt_xawt.dylib")
    if not os.path.exists(local):
        print(f"  · 跳过 AWT 补丁（Natives/libawt_xawt.dylib 不存在）")
        return

    dest_dir = os.path.join(jre_dir(version), "lib")
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, "libawt_xawt.dylib")
    shutil.copy2(local, dest)
    print(f"  + 已补入 libawt_xawt.dylib")


def process(version):
    if is_ready(version):
        print(f"  · JRE {version} 已就绪")
        return True

    os.makedirs(DEPENDS, exist_ok=True)

    zip_path = download(version)
    if not zip_path:
        return False

    if not extract(version, zip_path):
        return False

    try:
        os.remove(zip_path)
    except OSError:
        pass

    if not verify_and_trim(version):
        return False

    copy_awt_patch(version)
    return True


def main():
    args = sys.argv[1:]
    check_only = "--check" in args

    only = VERSIONS
    if "--only" in args:
        idx = args.index("--only")
        only = []
        for a in args[idx + 1:]:
            if a.startswith("--"):
                break
            try:
                only.append(int(a))
            except ValueError:
                pass

    os.makedirs(DEPENDS, exist_ok=True)

    if check_only:
        print("==> 校验 JRE")
        ok = 0
        for v in only:
            if is_ready(v):
                size = 0
                for dirpath, _, files in os.walk(jre_dir(v)):
                    for f in files:
                        try:
                            size += os.path.getsize(os.path.join(dirpath, f))
                        except OSError:
                            pass
                print(f"  ✓ java-{v}-openjdk  ({size / 1024 / 1024:.0f} MB)")
                ok += 1
            else:
                print(f"  ✗ java-{v}-openjdk  未就绪")
        return 0 if ok == len(only) else 1

    print(f"==> 下载并处理 JRE（{len(only)} 个）")
    failed = []
    for v in only:
        print(f"\n[JRE {v}]")
        if not process(v):
            failed.append(v)

    print("\n=== 结果 ===")
    if failed:
        print(f"  失败：{failed}")
        return 1
    print("  ✓ 全部就绪")

    # 输出总体积
    total = 0
    for v in only:
        for dirpath, _, files in os.walk(jre_dir(v)):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(dirpath, f))
                except OSError:
                    pass
    print(f"  总大小：{total / 1024 / 1024:.0f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
