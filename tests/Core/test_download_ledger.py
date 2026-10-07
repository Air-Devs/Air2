#!/usr/bin/env python3
"""
验证 A2WriteLedger 的区间合并与缺口计算逻辑。

这是断点续传的核心：并发分片是乱序写入的，
必须准确知道「哪些字节已经写好、哪些还是空洞」。
逻辑错了会导致文件静默损坏（大小对、内容错）。

用 Python 复刻 ObjC 实现，逐场景验证。
"""
from dataclasses import dataclass, field


@dataclass
class Ledger:
    total: int
    ranges: list = field(default_factory=list)   # [(start, end)] 左闭右开，有序不重叠

    def record(self, start, length):
        if length <= 0:
            return
        end = start + length
        merged = []
        inserted = False
        for (rs, re_) in self.ranges:
            if re_ < start:
                merged.append((rs, re_))
            elif rs > end:
                if not inserted:
                    merged.append((start, end))
                    inserted = True
                merged.append((rs, re_))
            else:
                start = min(start, rs)
                end = max(end, re_)
        if not inserted:
            merged.append((start, end))
        self.ranges = merged

    @property
    def written(self):
        return sum(e - s for s, e in self.ranges)

    def gaps(self):
        out = []
        cursor = 0
        for (rs, re_) in self.ranges:
            if rs > cursor:
                out.append((cursor, rs))
            cursor = max(cursor, re_)
        if cursor < self.total:
            out.append((cursor, self.total))
        return out

    @property
    def complete(self):
        if self.total <= 0:
            return False
        cursor = 0
        for (rs, re_) in self.ranges:
            if rs > cursor:
                return False
            cursor = max(cursor, re_)
        return cursor >= self.total


def check(name, got, want):
    ok = got == want
    print(f"  {'✓' if ok else '✗'} {name}")
    if not ok:
        print(f"      got  = {got}")
        print(f"      want = {want}")
    return ok


all_ok = True
SIZE = 1000

print("=" * 62)
print("下载区间账本验证（断点续传核心）")
print("=" * 62)

# ---- 1. 顺序写入 ----
print("\n[1] 顺序写入 4 片")
l = Ledger(SIZE)
for i in range(4):
    l.record(i * 250, 250)
all_ok &= check("已写入 = 1000", l.written, 1000)
all_ok &= check("无缺口", l.gaps(), [])
all_ok &= check("完成", l.complete, True)

# ---- 2. 乱序写入（并发分片的真实情况）----
print("\n[2] 乱序写入（模拟并发分片）")
l = Ledger(SIZE)
for start in [750, 0, 500, 250]:
    l.record(start, 250)
all_ok &= check("已写入 = 1000", l.written, 1000)
all_ok &= check("区间被合并为 1 段", len(l.ranges), 1)
all_ok &= check("完成", l.complete, True)

# ---- 3. 有空洞 ----
print("\n[3] 中间缺一片")
l = Ledger(SIZE)
l.record(0, 250)
l.record(500, 250)    # 跳过 250-500
l.record(750, 250)
all_ok &= check("已写入 = 750（不重复计数）", l.written, 750)
all_ok &= check("缺口 = [(250,500)]", l.gaps(), [(250, 500)])
all_ok &= check("未完成", l.complete, False)

# ---- 4. 重复写入不虚涨 ----
print("\n[4] 同一区间写两次（重复下载）")
l = Ledger(SIZE)
l.record(0, 500)
l.record(0, 500)      # 完全重叠
all_ok &= check("已写入仍是 500", l.written, 500)
all_ok &= check("区间未重复", len(l.ranges), 1)

# ---- 5. 部分重叠 ----
print("\n[5] 部分重叠写入")
l = Ledger(SIZE)
l.record(0, 300)
l.record(200, 300)    # 与上一段重叠 100
all_ok &= check("合并为 (0,500)", l.ranges, [(0, 500)])
all_ok &= check("已写入 = 500", l.written, 500)

# ---- 6. 关键：区间完整但顺序错乱，必须判定完成 ----
print("\n[6] 乱序补全后判定完成")
l = Ledger(SIZE)
l.record(500, 500)    # 后半
l.record(0, 500)      # 前半
all_ok &= check("完成", l.complete, True)
all_ok &= check("缺口为空", l.gaps(), [])

# ---- 7. 关键：总量相等但内容错位 —— 必须能识别 ----
print("\n[7] 总量相等但有空洞（这是最容易漏的损坏场景）")
l = Ledger(SIZE)
l.record(0, 250)
l.record(250, 250)
l.record(750, 250)    # 漏了 500-750，但总写入 750
l.record(500, 250)    # 补上后才是完整
all_ok &= check("补全前未完成", l.complete, True)   # 这里已补，故为 True
l2 = Ledger(SIZE)
l2.record(0, 250)
l2.record(250, 250)
l2.record(750, 250)
all_ok &= check("漏一片时未完成", l2.complete, False)
all_ok &= check("漏一片时缺口正确", l2.gaps(), [(500, 750)])

# ---- 8. 碎片化写入（大量小片）----
print("\n[8] 碎片化写入 100 片，乱序")
l = Ledger(SIZE)
import random
random.seed(42)
order = list(range(100))
random.shuffle(order)
for i in order:
    l.record(i * 10, 10)
all_ok &= check("已写入 = 1000", l.written, 1000)
all_ok &= check("合并为 1 段", len(l.ranges), 1)
all_ok &= check("完成", l.complete, True)

# ---- 9. 边界：0 长度写入 ----
print("\n[9] 边界情况")
l = Ledger(100)
l.record(50, 0)
all_ok &= check("0 长度被忽略", l.ranges, [])
l.record(0, 100)
all_ok &= check("完整覆盖", l.complete, True)

print("\n" + "=" * 62)
if all_ok:
    print("全部通过")
else:
    print("有失败项")
print("=" * 62)
