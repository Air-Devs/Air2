#!/usr/bin/env python3
"""
复刻 A2GameDirMigration.m 的目录改名迁移逻辑，验证决策矩阵。

背景：旧版把游戏数据放在隐藏目录 Documents/.minecraft，现在改成可见的
Documents/minecraft。老用户首次启动时由 A2GameDirMigration 迁移。

    旧目录 = Documents/.minecraft
    新目录 = Documents/minecraft

规则（与 A2GameDirMigration.m 及头文件注释一致）：
    · 只有旧目录 → 旧为空则删掉；否则改名成新目录（保数据）
    · 只有新目录 → 不动
    · 两者都在   → 旧为空则删旧；
                   否则新为空就删新再把旧改名过来；
                   两个都非空则丢弃旧目录，保留新目录

与 test_version_isolation.py 的纯逻辑复刻不同，这里在临时目录里真实建出
目录结构跑一遍，直接检查迁移后的文件系统状态。
"""
import os
import shutil
import tempfile

LEGACY = ".minecraft"
CURRENT = "minecraft"


def is_empty(path):
    """目录是否为空；不存在也算空。复刻 A2DirIsEmpty。"""
    if not os.path.exists(path):
        return True
    return len(os.listdir(path)) == 0


def migrate(docs):
    """复刻 +[A2GameDirMigration migrateIfNeeded]，docs 为 Documents 目录。"""
    legacy = os.path.join(docs, LEGACY)
    current = os.path.join(docs, CURRENT)

    if not os.path.exists(legacy):
        return
    if is_empty(legacy):
        os.rmdir(legacy)
        return
    if os.path.exists(current) and not is_empty(current):
        shutil.rmtree(legacy)
        return
    if os.path.exists(current):
        os.rmdir(current)
    os.rename(legacy, current)


def check(name, got, want):
    ok = got == want
    print(f"  {'✓' if ok else '✗'} {name}")
    if not ok:
        print(f"      got  = {got}")
        print(f"      want = {want}")
    return ok


def build(docs, spec):
    """按 spec 在 docs 下建目录。spec: {目录名: [子项...]}，空列表 = 空目录。"""
    for name, children in spec.items():
        path = os.path.join(docs, name)
        os.makedirs(path, exist_ok=True)
        for child in children:
            with open(os.path.join(path, child), "w") as fh:
                fh.write(child)


def exists(docs, name):
    return os.path.exists(os.path.join(docs, name))


def entries(docs, name):
    return sorted(os.listdir(os.path.join(docs, name)))


all_ok = True

print("=" * 66)
print("游戏目录改名迁移验证（.minecraft → minecraft）")
print("=" * 66)

# ---- 1. 两者都不存在：什么都不做 ----
print("\n[1] 两者都不存在 → 不动")
with tempfile.TemporaryDirectory() as docs:
    migrate(docs)
    all_ok &= check("无旧目录", exists(docs, LEGACY), False)
    all_ok &= check("无新目录", exists(docs, CURRENT), False)

# ---- 2. 只有旧目录且有内容：改名，数据保留 ----
print("\n[2] 只有旧目录（有内容）→ 改名成新目录，数据保留")
with tempfile.TemporaryDirectory() as docs:
    build(docs, {LEGACY: ["saves", "versions"]})
    migrate(docs)
    all_ok &= check("旧目录已消失", exists(docs, LEGACY), False)
    all_ok &= check("新目录已出现", exists(docs, CURRENT), True)
    all_ok &= check("数据保留", entries(docs, CURRENT), ["saves", "versions"])

# ---- 3. 只有旧目录但为空：直接删掉 ----
print("\n[3] 只有旧目录（空）→ 直接删掉")
with tempfile.TemporaryDirectory() as docs:
    build(docs, {LEGACY: []})
    migrate(docs)
    all_ok &= check("旧目录已删除", exists(docs, LEGACY), False)
    all_ok &= check("未建新目录", exists(docs, CURRENT), False)

# ---- 4. 只有新目录：不动 ----
print("\n[4] 只有新目录 → 不动")
with tempfile.TemporaryDirectory() as docs:
    build(docs, {CURRENT: ["saves"]})
    migrate(docs)
    all_ok &= check("新目录仍在", exists(docs, CURRENT), True)
    all_ok &= check("数据未变", entries(docs, CURRENT), ["saves"])

# ---- 5. 旧空 + 新有内容：删旧，保新 ----
print("\n[5] 旧空 + 新有内容 → 删旧，保留新目录")
with tempfile.TemporaryDirectory() as docs:
    build(docs, {LEGACY: [], CURRENT: ["saves"]})
    migrate(docs)
    all_ok &= check("旧目录已删除", exists(docs, LEGACY), False)
    all_ok &= check("新目录数据保留", entries(docs, CURRENT), ["saves"])

# ---- 6. 旧有内容 + 新空：删新，旧改名过来 ----
print("\n[6] 旧有内容 + 新空 → 删空的新目录，旧目录改名过来（保数据）")
with tempfile.TemporaryDirectory() as docs:
    build(docs, {LEGACY: ["saves", "versions"], CURRENT: []})
    migrate(docs)
    all_ok &= check("旧目录已消失", exists(docs, LEGACY), False)
    all_ok &= check("新目录已就位", exists(docs, CURRENT), True)
    all_ok &= check("数据保留", entries(docs, CURRENT), ["saves", "versions"])

# ---- 7. 两者都有内容：删旧，保新（核心约定）----
print("\n[7] 两者都有内容 → 删除旧目录，保留新目录")
with tempfile.TemporaryDirectory() as docs:
    build(docs, {LEGACY: ["old-saves"], CURRENT: ["new-saves"]})
    migrate(docs)
    all_ok &= check("旧目录已删除", exists(docs, LEGACY), False)
    all_ok &= check("新目录仍在", exists(docs, CURRENT), True)
    all_ok &= check("保留的是新目录数据", entries(docs, CURRENT), ["new-saves"])

# ---- 8. 幂等：迁移完成后再跑一次不改变结果 ----
print("\n[8] 幂等：连续迁移两次结果不变")
with tempfile.TemporaryDirectory() as docs:
    build(docs, {LEGACY: ["saves"]})
    migrate(docs)
    before = entries(docs, CURRENT)
    migrate(docs)
    all_ok &= check("第二次不改变", entries(docs, CURRENT), before)
    all_ok &= check("没有残留旧目录", exists(docs, LEGACY), False)

print("\n" + "=" * 66)
if all_ok:
    print("全部通过")
else:
    print("有失败项")
print("=" * 66)

raise SystemExit(0 if all_ok else 1)
