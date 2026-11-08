#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GL2 登记表 ↔ jar 侧 native 声明逐条比对（不用记忆，只用 javap 实测）。

为什么需要它：`Natives/Renderer/a2_gl2_jni_bind.m` 的登记表里每条
(类, native 方法名, JNI 描述符) 都必须与 jar 里那条 `native` 方法的**声明逐字一致**，
否则 `RegisterNatives` 只能回一个 -1，真机上就只剩「这条入口没被接管」的黑盒现象。
本脚本把两件事机器对上：

  ① `javap -s -p` 从两套 jar 取真实的 native 声明（类 / 方法名 / 描述符）
  ② 解析仓库里三份表：
       · a2_gl2_jni_bind.m 的 `kA2GL2Methods[]`（登记表）与 `kA2GL2Skips[]`（无可登记声明）
       · a2_gl2_jni_probe.m 的 `kA2GL2ProbeEntries[]`（取证用，必须同序同名）
       · a2_gl2_shim.m 的 `kA2GL2Entries[]`（本层真实实现的名字集合 = 覆盖面的唯一判据）
     然后逐条核对：签名有依据、转发器存在且参数个数对得上、三张表同序、shim 全覆盖。

退出码：0 = 全部对上；1 = 有对不上的（逐条打印）。

用法（仓库根目录）：
    python3 scripts/verify_gl2_registry.py
可选环境变量：JAVA_HOME（找不到 javap 时用它）、A2_KEEP_JAVAP=1（保留 javap 输出便于人工核对）。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RENDERER = os.path.join(ROOT, "Natives", "Renderer")

BIND_M = os.path.join(RENDERER, "a2_gl2_jni_bind.m")
PROBE_M = os.path.join(RENDERER, "a2_gl2_jni_probe.m")
SHIM_M = os.path.join(RENDERER, "a2_gl2_shim.m")

# 两套 jar：两代 MC 各一套。★两套都必须有依据★，缺一套就说明这条入口只在某一代可用。
# 注：1.12.2 那一套在仓库里落成 `lwjgl-2/lwjgl-opengl-3.2.3.jar`（LWJGL2 API 兼容层就建在 3.2.3 上；
# 旧的 `lwjgl-2/lwjgl.jar` 路径早已不存在 ⇒ 本脚本以前一条依据都取不到，等于空转）。
JARS = [
    ("LWJGL2 兼容层（1.12.2 及更早）",
     os.path.join(ROOT, "Libraries", "Jars", "lwjgl-2", "lwjgl-opengl-3.2.3.jar")),
    ("LWJGL 3.3.3（1.13–1.16）",
     os.path.join(ROOT, "Libraries", "Jars", "lwjgl-333", "lwjgl-opengl.jar")),
]
CLASSES = ["org.lwjgl.opengl.GL11", "org.lwjgl.opengl.GL11C"]

# 转发器形状名 → 形参个数（见 a2_gl2_jni_bind.m ① 的 typedef）
SHAPE_ARITY = {
    "V": 0, "I": 1, "II": 2, "III": 3, "F": 1, "FF": 2, "FFF": 3, "FFFF": 4,
    "DD": 2, "DDD": 3, "DDDDDD": 6, "IF": 2, "IIF": 3, "U8x3": 3, "U8x4": 4,
    "P": 1, "IP": 2, "IIP": 3, "IIIP": 4,
}


def find_javap():
    """javap 的位置：JAVA_HOME → PATH → 常见 JDK 安装点。找不到就明确报错（不猜）。"""
    cands = []
    home = os.environ.get("JAVA_HOME")
    if home:
        cands.append(os.path.join(home, "bin", "javap"))
    which = shutil.which("javap")
    if which:
        cands.append(which)
    for base in ("/Library/Java/JavaVirtualMachines", "/usr/lib/jvm",
                 r"C:\Program Files\Java"):
        if os.path.isdir(base):
            for name in sorted(os.listdir(base)):
                cands.append(os.path.join(base, name, "bin", "javap"))
                cands.append(os.path.join(base, name, "Contents", "Home", "bin", "javap"))
    for path in cands:
        exe = path if path.endswith(".exe") or not os.path.exists(path + ".exe") else path + ".exe"
        if os.path.isfile(exe) and os.access(exe, os.X_OK):
            return exe
    return None


def javap_surface(javap, jar, cls, workdir):
    """javap -s -p → {方法名: [(描述符, 是否 static, 是否 native)]}。"""
    out = subprocess.run([javap, "-s", "-p", "-cp", jar, cls],
                         capture_output=True, text=True, encoding="utf-8", errors="replace")
    if out.returncode != 0:
        raise RuntimeError("javap 失败：%s %s\n%s" % (jar, cls, out.stderr.strip()))
    if os.environ.get("A2_KEEP_JAVAP"):
        tag = os.path.basename(jar).replace(".jar", "") + "_" + cls.split(".")[-1] + ".txt"
        with open(os.path.join(workdir, tag), "w", encoding="utf-8") as fh:
            fh.write(out.stdout)

    methods, pending = {}, None
    for raw in out.stdout.splitlines():
        m = re.match(r"^\s+descriptor: (\S+)$", raw)
        if m:
            if pending is not None:
                methods.setdefault(pending[0], []).append((m.group(1), pending[1], pending[2]))
                pending = None
            continue
        line = raw.strip()
        if not (line.startswith("public ") or line.startswith("protected ")):
            continue
        if "(" not in line:
            continue
        head = line.split("(")[0]
        pending = (head.split()[-1], " static " in line or line.split()[1] == "static",
                   " native " in line)
    return methods


def parse_bind_table():
    """解析 kA2GL2Methods[] 的行（顺序即登记顺序）。"""
    src = open(BIND_M, encoding="utf-8").read()
    block = re.search(r"static const A2GL2Method kA2GL2Methods\[\] = \{(.*?)\n\};", src, re.S)
    if not block:
        raise RuntimeError("在 %s 里找不到 kA2GL2Methods[]" % BIND_M)
    rows = []
    for m in re.finditer(
            r'\{\s*(kA2GL2Idx\w+),\s*"(\w+)",\s*"(\w+)",\s*"([^"]+)",\s*A2GL2_CLASS_(\w+),'
            r'\s*\(void \*\)(a2gl2_j_\w+)\s*\}', block.group(1)):
        rows.append({"idx": m.group(1), "gl": m.group(2), "jni": m.group(3),
                     "sig": m.group(4), "cls": m.group(5), "fn": m.group(6)})
    return rows


def parse_skips():
    src = open(BIND_M, encoding="utf-8").read()
    block = re.search(r"static const A2GL2Skip kA2GL2Skips\[\] = \{(.*?)\n\};", src, re.S)
    if not block:
        raise RuntimeError("在 %s 里找不到 kA2GL2Skips[]" % BIND_M)
    return [{"gl": m.group(1), "why": m.group(2)} for m in re.finditer(
        r'\{\s*"(\w+)",\s*"([^"]+)"\s*\}', block.group(1))]


def split_top_level(text):
    """按「顶层」逗号切分宏实参（JPARAMS 里本身就带逗号，不能直接 str.split）。"""
    out, depth, cur = [], 0, ""
    for ch in text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
            continue
        cur += ch
    out.append(cur)
    return out


def parse_forwarders():
    """解析 A2GL2_FWD / A2GL2_FWD0 的调用行 → {转发器名: (形状, 原实现形状, 实参个数)}。"""
    src = open(BIND_M, encoding="utf-8").read()
    out = {}
    for m in re.finditer(r"^A2GL2_FWD0?\((.*)\)\s*$", src, re.M):
        parts = [p.strip() for p in split_top_level(m.group(1))]
        # IDX, NAME, JPARAMS(...), SHAPE, [ORIG_SHAPE], args...
        name = parts[1]
        shapes = [p for p in parts[3:] if p.startswith("A2GL2Fn") or p.startswith("A2GL2Jni")]
        tail = parts[3 + len(shapes):]
        out["a2gl2_j_" + name] = (shapes[0] if shapes else None,
                                  shapes[1] if len(shapes) > 1 else None,
                                  len(tail))
    return out


def parse_probe_table():
    src = open(PROBE_M, encoding="utf-8").read()
    block = re.search(r"static const A2GL2ProbeEntry kA2GL2ProbeEntries\[\] = \{(.*?)\n\};", src, re.S)
    if not block:
        raise RuntimeError("在 %s 里找不到 kA2GL2ProbeEntries[]" % PROBE_M)
    return [{"gl": m.group(1), "jni": m.group(2), "cls": m.group(3), "sym": m.group(4)}
            for m in re.finditer(r'\{\s*"(\w+)",\s*"(\w+)",\s*"([\w/]+)",\s*"(\w+)"\s*\}',
                                 block.group(1))]


def parse_shim_names():
    src = open(SHIM_M, encoding="utf-8").read()
    block = re.search(r"static const A2GL2Entry kA2GL2Entries\[\] = \{(.*?)\n\};", src, re.S)
    if not block:
        raise RuntimeError("在 %s 里找不到 kA2GL2Entries[]" % SHIM_M)
    return [m.group(1) for m in re.finditer(r'\{\s*"(\w+)",\s*\(void \*\)', block.group(1))]


def javap_callsites(javap, jar, cls):
    """javap -c → {(声明类, 方法名): {调用者}}：谁在 Java 侧调用了这条 native。

    为什么需要：登记 `nglXxx` 这种「指针入口的 native」时，真正的调用者是 jar 里那个
    `glXxx` 包装（它把 Buffer/数组/long 都汇到 nglXxx）。如果 jar 里没有任何一处
    `invokestatic nglXxx`，那就是「登记了没人调的入口」= 石山。
    """
    out = subprocess.run([javap, "-c", "-p", "-cp", jar, cls],
                         capture_output=True, text=True, encoding="utf-8", errors="replace")
    if out.returncode != 0:
        return {}
    short = cls.split(".")[-1]
    sites, cur = {}, None
    for line in out.stdout.splitlines():
        m = re.match(r"^\s+(?:public|private|protected|static|final|native|synchronized|abstract)"
                     r"[^()]*\s(\w+)\(", line)
        if m:
            cur = m.group(1)
        # javap 的格式是 `// Method nglVertexPointer:(J)V` / `// Method org/lwjgl/opengl/GL11C.nglDrawElements:(IIIJ)V`
        m2 = re.search(r"invokestatic\s+#\d+\s+//\s+Method\s+(?:([\w/$]+)\.)?([\w$<>]+):", line)
        if m2:
            owner = m2.group(1).split("/")[-1] if m2.group(1) else short
            sites.setdefault((owner, m2.group(2)), set()).add("%s.%s" % (short, cur))
    return sites


def main():
    errors = []
    javap = find_javap()
    if javap is None:
        print("★找不到 javap★：设 JAVA_HOME 或在 PATH 上放一个 JDK（本脚本不接受「凭记忆的签名」）")
        return 1

    table = parse_bind_table()
    skips = parse_skips()
    fwds = parse_forwarders()
    probe = parse_probe_table()
    shim_names = parse_shim_names()

    print("javap: %s" % javap)
    print("登记表 %d 条 / 静态跳过 %d 条 / 探针表 %d 条 / shim 实现 %d 个名字\n"
          % (len(table), len(skips), len(probe), len(shim_names)))

    # ---- ① 两套 jar 的真实 native 声明 ----
    surfaces = {}
    with tempfile.TemporaryDirectory() as tmp:
        for label, jar in JARS:
            if not os.path.isfile(jar):
                errors.append("缺 jar：%s（%s）" % (jar, label))
                continue
            surfaces[label] = {}
            for cls in CLASSES:
                surfaces[label][cls.split(".")[-1]] = javap_surface(javap, jar, cls, tmp)
            print("  %s：GL11 %d 个方法 / GL11C %d 个方法"
                  % (label,
                     len(surfaces[label]["GL11"]), len(surfaces[label]["GL11C"])))

    # ---- ② 逐条核对登记表 ----
    evid = 0
    for i, row in enumerate(table):
        want_idx = "kA2GL2Idx" + row["gl"][2].upper() + row["gl"][3:]
        if row["idx"] != want_idx:
            errors.append("第 %d 条 %s 的 idx 常量=%s，按 gl 名应为 %s"
                          % (i, row["gl"], row["idx"], want_idx))
        cls = row["cls"]
        for label in surfaces:
            found = surfaces[label][cls].get(row["jni"], [])
            hits = [d for d, is_static, is_native in found if d == row["sig"] and is_static and is_native]
            if not hits:
                other = "GL11C" if cls == "GL11" else "GL11"
                alt = [d for d, is_static, is_native in surfaces[label][other].get(row["jni"], [])
                       if is_static and is_native]
                errors.append("%s：%s.%s%s 不是 static native（该 jar 里 GL11C/GL11 上的 native 重载=%s）"
                              % (label, cls, row["jni"], row["sig"], alt or "无"))
        evid += 1
        # 转发器：存在、形状参数个数与描述符一致、指针参数按指针传
        fn = fwds.get(row["fn"])
        if fn is None:
            errors.append("第 %d 条 %s 的转发器 %s 没有对应的 A2GL2_FWD 行" % (i, row["gl"], row["fn"]))
            continue
        shape, orig_shape, nargs = fn
        params = row["sig"][1:row["sig"].index(")")]
        if shape is None or shape[7:] not in SHAPE_ARITY:
            errors.append("%s 的形状名 %s 不认识" % (row["fn"], shape))
        elif SHAPE_ARITY[shape[7:]] != len(params) or nargs != len(params):
            errors.append("%s：描述符 %s 有 %d 个参数，形状 %s 期望 %d 个，实际传了 %d 个"
                          % (row["fn"], row["sig"], len(params), shape,
                             SHAPE_ARITY[shape[7:]], nargs))
        if shape is not None and orig_shape != "A2GL2Jni" + shape[7:]:
            errors.append("%s 的原实现形状 %s 与 %s 不配套" % (row["fn"], orig_shape, shape))

    # ---- ②b 转发器宏的形参个数必须与调用行对得上（多一个/少一个都是编译错）----
    src = open(BIND_M, encoding="utf-8").read()
    for macro in ("A2GL2_FWD0", "A2GL2_FWD"):
        m = re.search(r"#define %s\(([^)]*)\)" % macro, src)
        if not m:
            errors.append("找不到宏 %s 的定义" % macro)
            continue
        params = [x.strip() for x in m.group(1).split(",")]
        variadic = params[-1] == "..."
        fixed = len(params) - 1 if variadic else len(params)
        if "ORIG_SHAPE" not in params:
            errors.append("宏 %s 少了 ORIG_SHAPE 形参（转调原实现必须用带 env/cls 的形状）" % macro)
        for call in re.finditer(r"^%s\((.*)\)\s*$" % macro, src, re.M):
            n = len(split_top_level(call.group(1)))
            if (variadic and n < fixed) or (not variadic and n != fixed):
                errors.append("%s 调用实参 %d 个，宏形参%s %d 个：%s"
                              % (macro, n, "至少" if variadic else "恰好", fixed,
                                 call.group(1)[:60]))

    # ---- ③ 三张表必须同序同名（表被重排 = 把 glEnd 装成 glBegin）----
    if len(probe) != len(table):
        errors.append("探针表 %d 条 ≠ 登记表 %d 条（两者必须同序同长）" % (len(probe), len(table)))
    for i, (row, prb) in enumerate(zip(table, probe)):
        if row["gl"] != prb["gl"] or row["jni"] != prb["jni"]:
            errors.append("第 %d 条两侧不一致：登记表 %s/%s，探针表 %s/%s"
                          % (i, row["gl"], row["jni"], prb["gl"], prb["jni"]))
        if prb["cls"].split("/")[-1] != row["cls"]:
            errors.append("第 %d 条 %s 的首选类不一致：%s vs %s"
                          % (i, row["gl"], row["cls"], prb["cls"]))
        want_sym = "Java_org_lwjgl_opengl_%s_%s" % (row["cls"], row["jni"])
        if prb["sym"] != want_sym:
            errors.append("第 %d 条 %s 的 JNI 符号=%s，按类/方法名应为 %s"
                          % (i, row["gl"], prb["sym"], want_sym))

    # ---- ④ shim 的每个名字都必须交代：进登记表，或进跳过表并写明原因 ----
    covered = {r["gl"] for r in table} | {s["gl"] for s in skips}
    for name in shim_names:
        if name not in covered:
            errors.append("shim 实现了 %s，但登记表和跳过表都没交代它" % name)
    for row in table:
        if row["gl"] not in shim_names:
            errors.append("登记表里的 %s 在 a2_gl2_shim.m 里没有实现（不能登记没人接的入口）" % row["gl"])
    dup = [n for n in {r["gl"] for r in table} if [r["gl"] for r in table].count(n) > 1]
    if dup:
        errors.append("登记表有重复 GL 名：%s" % dup)

    # ---- ⑤ 指针入口（nglXxx）必须有 Java 侧调用点：否则就是「登记了没人调」 ----
    if surfaces:
        label = list(surfaces)[-1]      # 3.3.3 那一套（两套结构一致，见上面的方法数）
        jar = dict(JARS)[label]
        sites = {}
        for cls in CLASSES:
            for key, val in javap_callsites(javap, jar, cls).items():
                sites.setdefault(key, set()).update(val)
        ngl = [r for r in table if r["jni"].startswith("ngl")]
        dead = [r["jni"] for r in ngl if not sites.get((r["cls"], r["jni"]))]
        for name in dead:
            errors.append("%s 在 jar 里没有任何 Java 侧调用点（登记了没人调的入口）" % name)
        if not dead:
            print("ngl 指针入口 %d 条：每条都有 jar 内的 Java 调用点（glXxx 包装 → nglXxx）" % len(ngl))

    # ---- ⑥ 结论 ----
    print()
    if errors:
        for e in errors:
            print("  ✗ %s" % e)
        print("\n发现 %d 处问题" % len(errors))
        return 1
    print("表内 %d 条全部有 jar 侧签名依据（两套 jar 的 static native 声明逐条对上）" % evid)
    print("跳过 %d 条（jar 里没有可登记的 native 声明）：" % len(skips))
    for s in skips:
        print("  · %s —— %s" % (s["gl"], s["why"]))
    print("shim 的 %d 个名字 = %d 登记 + %d 跳过（覆盖面无遗漏）"
          % (len(shim_names), len(table), len(skips)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
