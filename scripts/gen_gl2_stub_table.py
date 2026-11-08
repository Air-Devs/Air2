#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 GL11 / GL11C 的**空实现（no-op）**注册表 —— 消除 LWJGL 函数指针为 NULL 的踩空崩溃。

为什么需要它（真机证据，不接受推测）：
  MC 1.12.2 在桌面 GL 路径上会调用一大批**固定管线 / 桌面专用**入口
  （glLogicOp / glPointSize / glHint / glPolygonMode / glLineWidth / glAccum …）。
  本层（a2_gl2_shim.m）只实现了 68 条，其余入口仍是 `liblwjgl_opengl.dylib` 里的原生实现；
  而 LWJGL 的入口函数指针表在我们接管 GL 过程之后是 NULL
  ⇒ `liblwjgl_opengl.dylib+0xbbbc` 里一次间接调用就踩空，JVM os::abort（SIGSEGV）。
  修法不是「猜哪些入口会被调」，而是**把 GL11/GL11C 上全部 native 都注册掉**：
  有真实现的走真实现（68 条），没有的走 no-op stub（返回默认值）。

本脚本做四件事（每一步都可机器复核，不靠记忆）：
  ① `javap -s -p` 从 jar 取出 `org.lwjgl.opengl.GL11` / `GL11C` 的**全部 static native**（名字 + 描述符）；
  ② 按描述符归类（`(I)V`、`()V`、`(FFF)V`、`(IF)V`、`(Z)V` …），每类生成一个 C no-op 实现；
  ③ 写出 `Natives/Renderer/a2_gl2_stub_table.h`：stub 函数 + `kA2GL2Stubs[]`（名字 → 描述符 → 函数指针）；
  ④ 自检：重新解析写出的表，条数与 `(类, 方法名, 描述符)` 集合必须与 jar 的 native 集合**逐条相等**；
     并核对 `a2_gl2_jni_bind.m` 的 `kA2GL2Methods[]`（真实现）里每条都能在 jar 里找到依据
     ⇒ 结论是「每个 jar native 都有 stub 或真实现」，一个都不落在 NULL 上。
  ⑤ 交叉核对：1.13–1.16 的 3.3.3 jar 与本表的 native 面必须逐条一致（一张表覆盖两代）。
  ⑥ 空跑安装：按 .m 的落地规则 + taken 集跑一遍，预测真机判据行的
     「已实现 N 条 / 空实现 M 条 / 总计 T」—— 本机没有 C 编译器，这三个数只能在这里先对上。

用法（仓库根目录）：
    python3 scripts/gen_gl2_stub_table.py            # 生成 + 自检（默认写文件）
    python3 scripts/gen_gl2_stub_table.py --check     # 只自检，不写文件（CI 用）
    python3 scripts/gen_gl2_stub_table.py --stdout    # 打到 stdout，便于 diff 审阅

可选环境变量：JAVA_HOME（找不到 javap 时用它）。

退出码：0 = 生成且自检通过；1 = 有对不上的（逐条打印）。
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RENDERER = os.path.join(ROOT, "Natives", "Renderer")
OUT_H = os.path.join(RENDERER, "a2_gl2_stub_table.h")
BIND_M = os.path.join(RENDERER, "a2_gl2_jni_bind.m")

# ★唯一的签名来源★：GL2 层接管的就是这一套 jar（1.12.2 及更早，LWJGL2 API 兼容层）。
# 换 jar 必须重新跑本脚本并把生成的头文件一起提交 —— 表里的 (类, 名字, 描述符) 全部由它实测得出。
JAR = os.path.join(ROOT, "Libraries", "Jars", "lwjgl-2", "lwjgl-opengl-3.2.3.jar")
# ★交叉核对用的第二套 jar★：1.13–1.16 的 LWJGL 3.3.3。它必须与主 jar 的 native 面**完全一致**，
# 否则这张表只覆盖一代 MC，另一代仍会有没被接管的入口（= 新的踩空点）。
JAR_CROSS = os.path.join(ROOT, "Libraries", "Jars", "lwjgl-333", "lwjgl-opengl.jar")
CLASSES = [("GL11", "org.lwjgl.opengl.GL11"), ("GL11C", "org.lwjgl.opengl.GL11C")]

# ---- Java 描述符里的类型 → (JNI C 类型, 名字里用的类型码, 默认返回值) ----
FIELD = {
    "Z": ("jboolean", "Z", "JNI_FALSE"),
    "B": ("jbyte", "B", "0"),
    "C": ("jchar", "C", "0"),
    "S": ("jshort", "S", "0"),
    "I": ("jint", "I", "0"),
    "J": ("jlong", "J", "0"),
    "F": ("jfloat", "F", "0.0f"),
    "D": ("jdouble", "D", "0.0"),
    # 引用类型：GL11/GL11C 的 native 里目前没有，但生成器不假设「以后也没有」
    "L": ("jobject", "O", "NULL"),
    "[": ("jobject", "A", "NULL"),
}
RET_VOID = ("void", "v", "")


# ----------------------------------------------------------------------------
#  javap
# ----------------------------------------------------------------------------
def find_javap():
    """javap 的位置：JAVA_HOME → PATH → 常见 JDK 安装点。找不到就明确报错（不猜）。"""
    cands = []
    home = os.environ.get("JAVA_HOME")
    if home:
        cands.append(os.path.join(home, "bin", "javap"))
    which = shutil.which("javap")
    if which:
        cands.append(which)
    for base in ("/Library/Java/JavaVirtualMachines", "/usr/lib/jvm", r"C:\Program Files\Java"):
        if os.path.isdir(base):
            for name in sorted(os.listdir(base)):
                cands.append(os.path.join(base, name, "bin", "javap"))
                cands.append(os.path.join(base, name, "Contents", "Home", "bin", "javap"))
    for path in cands:
        exe = path if path.endswith(".exe") or not os.path.exists(path + ".exe") else path + ".exe"
        if os.path.isfile(exe) and os.access(exe, os.X_OK):
            return exe
    return None


def javap_natives(javap, jar, cls):
    """javap -s -p → [(方法名, 描述符)]，只留 `static native`。

    为什么必须走 javap 而不是「按名字猜」：GL11 上大量 glXxx 是**Java 包装**
    （glEnable/glDrawArrays … 在 GL11 里就是普通 static 方法，真正 native 在 GL11C）。
    把包装当 native 去 RegisterNatives 只会回 JNI_ERR；反过来漏掉一个 native，
    就是 LWJGL 函数指针为 NULL 的踩空点。
    """
    out = subprocess.run([javap, "-s", "-p", "-cp", jar, cls],
                         capture_output=True, text=True,
                         encoding="utf-8", errors="replace")
    if out.returncode != 0:
        raise RuntimeError("javap 失败：%s %s\n%s" % (jar, cls, out.stderr.strip()))
    found, pending = [], None
    for raw in out.stdout.splitlines():
        m = re.match(r"^\s+descriptor: (\S+)$", raw)
        if m:
            if pending is not None and pending[2]:
                found.append((pending[0], m.group(1)))
            pending = None
            continue
        line = raw.strip()
        if not (line.startswith("public ") or line.startswith("protected ")):
            continue
        if "(" not in line:
            continue                                  # 常量字段
        toks = line.split("(")[0].split()
        pending = (toks[-1], "static" in toks, "native" in toks)
    return found


# ----------------------------------------------------------------------------
#  描述符归类
# ----------------------------------------------------------------------------
def split_desc(desc):
    """`(IIIJ)V` → (['I','I','I','J'], 'V')。只支持生成器需要的那套描述符语法。"""
    if not desc.startswith("("):
        raise ValueError("描述符不是方法描述符：%r" % desc)
    close = desc.index(")")
    params, i, body = [], 0, desc[1:close]
    while i < len(body):
        ch = body[i]
        if ch == "[":
            j = i
            while body[j] == "[":
                j += 1
            if body[j] == "L":
                j = body.index(";", j) + 1
            else:
                j += 1
            params.append(body[i:j])
            i = j
        elif ch == "L":
            j = body.index(";", i) + 1
            params.append(body[i:j])
            i = j
        else:
            params.append(ch)
            i += 1
    return params, desc[close + 1:]


def type_info(t):
    """单个类型 → (JNI C 类型, 名字用类型码, 默认返回值)。"""
    return FIELD[t[0]]


def stub_symbol(desc):
    """描述符 → stub 函数名。`(I)V`→a2gl2_stub_vI、`()V`→a2gl2_stub_v、`(FFF)V`→a2gl2_stub_vFFF。

    命名规则：`a2gl2_stub_` + 返回类型码 + 形参类型码串。返回类型码全小写 v 表示 void、
    大写表示有返回值 ⇒ `(I)V` 与 `(I)F` 不会撞名（撞名会让两条入口指向同一个实现）。
    """
    params, ret = split_desc(desc)
    rcode = "v" if ret == "V" else type_info(ret)[1]
    return "a2gl2_stub_" + rcode + "".join(type_info(p)[1] for p in params)


def stub_signature(desc):
    """生成 C 函数声明（返回类型 + 函数名 + 形参表）。

    ★返回类型必须与描述符一致★：JNI 调用方按描述符解释返回值，
    把 `()I`（glGetError）声明成 void 会让 Java 侧读到寄存器里的垃圾值 ——
    编译器也会在 `return 0;` 处直接报错。
    """
    params, ret = split_desc(desc)
    rtype = "void" if ret == "V" else type_info(ret)[0]
    decls = ["JNIEnv *env", "jclass cls"]
    for i, p in enumerate(params):
        decls.append("%s a%d" % (type_info(p)[0], i))
    return "%s %s(%s)" % (rtype, stub_symbol(desc), ", ".join(decls))


def stub_body(desc):
    """no-op 函数体：参数全部显式丢弃，非 void 返回类型返回默认值。"""
    params, ret = split_desc(desc)
    lines = ["{", "    (void)env;", "    (void)cls;"]
    for i in range(len(params)):
        lines.append("    (void)a%d;" % i)
    if ret != "V":
        lines.append("    return %s;" % type_info(ret)[2])
    lines.append("}")
    return "\n".join(lines)


# ----------------------------------------------------------------------------
#  生成
# ----------------------------------------------------------------------------
BANNER = """\
// ============================================================================
//  Natives/Renderer/a2_gl2_stub_table.h
//  ★自动生成，不要手改★  生成器：scripts/gen_gl2_stub_table.py
//  签名来源：javap -s -p %(jar)s
//            org.lwjgl.opengl.GL11 / org.lwjgl.opengl.GL11C
// ----------------------------------------------------------------------------
//  这张表是「GL11/GL11C 上全部 static native」的**安全空实现（no-op）**清单：
//  本层没有真实实现的入口，一律注册成这里的空函数，而不是留给
//  `liblwjgl_opengl.dylib` 去走它那张**已被我们置空**的函数指针表。
//  为什么必须这么做（真机证据）：MC 1.12.2 会调 glLogicOp / glPointSize / glHint /
//  glPolygonMode / glLineWidth / glAccum 这类桌面专用入口；没接管的入口 ⇒ LWJGL
//  函数表里是 NULL ⇒ `liblwjgl_opengl.dylib+0xbbbc` 一次间接调用踩空 ⇒ SIGSEGV + os::abort。
//
//  命名：a2gl2_stub_<返回类型码><形参类型码串>（v=void，其余同 Java 描述符；
//        数组→A、引用→O）
//        (I)V   → a2gl2_stub_vI        ()V       → a2gl2_stub_v
//        (FFF)V → a2gl2_stub_vFFF      (IF)V     → a2gl2_stub_vIF
//        (Z)V   → a2gl2_stub_vZ        (J)Z      → a2gl2_stub_ZZ
//  空实现的语义：**不改 GL 状态、不抛异常、返回默认值（0 / JNI_FALSE / NULL）**。
//  它只保证「调用不踩空」，不保证「这条入口的效果被模拟」—— 需要效果的入口
//  必须在 a2_gl2_shim.m 里有真实现（真实现优先，见 a2_gl2_jni_bind.m ⑦b 的去重）。
//
//  条数：%(total)d 条 native（GL11 %(n11)d / GL11C %(n11c)d），归为 %(ndesc)d 类描述符。
//  覆盖代：%(gens)s
// ============================================================================
#ifndef A2_GL2_STUB_TABLE_H
#define A2_GL2_STUB_TABLE_H

#include <jni.h>

/// 一条空实现登记项。declClass 取值同 a2_gl2_jni_bind.m 的 A2GL2_CLASS_*（0=GL11 1=GL11C）。
typedef struct {
    int         declClass;
    const char *name;
    const char *sig;
    void       *fn;
} A2GL2StubMethod;

// ----------------------------------------------------------------------------
//  stub 实现（每个「描述符类」一个；同一描述符的所有入口共用同一个函数）
// ----------------------------------------------------------------------------
"""


def render(entries, jar_label, generations):
    """entries = [(declClass:int, cls:str, name:str, desc:str)]，渲染整个头文件。"""
    descs = sorted({e[3] for e in entries})
    # 描述符按「形参个数、再字典序」排 —— 稳定输出，diff 只反映真的变化
    descs.sort(key=lambda d: (len(split_desc(d)[0]), d))
    syms = {d: stub_symbol(d) for d in descs}
    assert len(set(syms.values())) == len(syms), "描述符→函数名撞名：%s" % syms

    n11 = sum(1 for e in entries if e[0] == 0)
    out = [BANNER % {"jar": jar_label, "total": len(entries), "n11": n11,
                     "n11c": len(entries) - n11, "ndesc": len(descs),
                     "gens": generations}]

    for d in descs:
        users = [e[2] for e in entries if e[3] == d]
        out.append("/// %s —— %d 条入口：%s%s\n" % (
            d, len(users), ", ".join(users[:6]),
            " …" if len(users) > 6 else ""))
        out.append("static %s %s\n\n" % (stub_signature(d), stub_body(d)))

    out.append("// ----------------------------------------------------------------------------\n"
               "//  登记表（按 类 + 方法名 排序；★顺序不影响语义★，但必须是确定的，便于 diff 审阅）\n"
               "// ----------------------------------------------------------------------------\n")
    out.append("static const A2GL2StubMethod kA2GL2Stubs[] = {\n")
    last_cls = None
    for decl_class, cls, name, desc in sorted(entries, key=lambda e: (e[0], e[2])):
        if cls != last_cls:
            out.append("    // ---- %s\n" % cls)
            last_cls = cls
        out.append('    { %d, "%s", "%s", (void *)%s },\n' % (decl_class, name, desc, syms[desc]))
    out.append("};\n\n")
    out.append("#define A2GL2_STUB_COUNT ((int)(sizeof(kA2GL2Stubs) / sizeof(kA2GL2Stubs[0])))\n\n")
    out.append("#endif  // A2_GL2_STUB_TABLE_H\n")
    return "".join(out)


# ----------------------------------------------------------------------------
#  自检
# ----------------------------------------------------------------------------
def parse_generated(text):
    """把写出的头文件重新解析回 [(declClass, name, desc, fn)] —— 自检只信「落盘的那份」。"""
    block = re.search(r"static const A2GL2StubMethod kA2GL2Stubs\[\] = \{(.*?)\n\};", text, re.S)
    if not block:
        raise RuntimeError("生成结果里找不到 kA2GL2Stubs[]")
    rows = []
    for m in re.finditer(r'\{\s*(\d+),\s*"(\w+)",\s*"([^"]+)",\s*\(void \*\)(\w+)\s*\}',
                         block.group(1)):
        rows.append((int(m.group(1)), m.group(2), m.group(3), m.group(4)))
    return rows


def parse_real_table():
    """解析 a2_gl2_jni_bind.m 的 kA2GL2Methods[]（真实现）。

    返两套：required = 主名字（jniName）—— ★必须★是 jar 里的 static native，否则这条永远装不上；
            optional = 另一套命名（glName）—— 运行时兜底用，jar 里不一定有，缺了不算错。
    为什么区分：指针入口在 jar 里叫 `nglXxx`，表里同时记了 `glXxx` 作兜底；
    `glXxx` 那条在 jar 里通常是 Java 包装（非 native），把它当成「必须有依据」就是误报。
    """
    src = open(BIND_M, encoding="utf-8").read()
    block = re.search(r"static const A2GL2Method kA2GL2Methods\[\] = \{(.*?)\n\};", src, re.S)
    if not block:
        raise RuntimeError("在 %s 里找不到 kA2GL2Methods[]" % BIND_M)
    required, optional = set(), set()
    ordered = []
    for m in re.finditer(
            r'\{\s*(kA2GL2Idx\w+),\s*"(\w+)",\s*"(\w+)",\s*"([^"]+)",\s*A2GL2_CLASS_(\w+),',
            block.group(1)):
        gl_name, jni_name, sig, cls = m.group(2), m.group(3), m.group(4), m.group(5)
        required.add((cls, jni_name, sig))
        optional.add((cls, gl_name, sig))
        ordered.append((gl_name, jni_name, sig, cls))
    return required, optional, ordered


def simulate(jar_keys, ordered):
    """空跑一遍安装顺序（真实现先、空实现后），预测真机那行判据的数字。

    为什么值得做：本机没有 C 编译器，「已实现 N 条 / 空实现 M 条 / 总计 T」这三个数
    在装机之前就该对上 —— 对不上是逻辑错，不是环境问题。这里逐字复刻
    `a2_gl2_jni_install` 的落地规则（先主名字再 gl 名、先首选类再另一类）与 taken 集的四处记录。
    """
    taken, hit, miss = set(), 0, []
    for gl_name, jni_name, sig, decl in ordered:
        names = [jni_name] if jni_name == gl_name else [jni_name, gl_name]
        kinds = [decl, "GL11C" if decl == "GL11" else "GL11"]
        landed = landed_name = None
        for nm in names:
            for kind in kinds:
                if (kind, nm, sig) in jar_keys:      # = GetStaticMethodID 成功且是 native
                    landed, landed_name = kind, nm
                    break
            if landed:
                break
        if landed is None:
            miss.append((gl_name, jni_name, sig))
            continue
        hit += 1
        for kind in (landed, "GL11C" if landed == "GL11" else "GL11"):
            for nm in (landed_name, gl_name):
                taken.add((kind, nm, sig))
    covered = sum(1 for k in jar_keys if k in taken)
    return hit, len(jar_keys) - covered, covered, miss



def parse_stub_overrides():
    """解析 a2_gl2_jni_bind.m 的 `kA2GL2StubOverrides[]`（值敏感入口的安全常量实现）。

    为什么要单独核对：覆盖表里的条目是手写的，一旦 jar 换了、或者那条入口后来在
    `kA2GL2Methods[]` 里有了真实现，它就是一条**永远到不了**的死条目
    （真实现优先级更高 ⇒ 覆盖表静默失效）。
    """
    src = open(BIND_M, encoding="utf-8").read()
    block = re.search(r"static const A2GL2StubOverride kA2GL2StubOverrides\[\] = \{(.*?)\n\};",
                      src, re.S)
    if not block:
        raise RuntimeError("在 %s 里找不到 kA2GL2StubOverrides[]" % BIND_M)
    rows = []
    for m in re.finditer(r'\{\s*A2GL2_CLASS_(\w+),\s*"(\w+)",\s*"([^"]+)",', block.group(1)):
        rows.append((m.group(1), m.group(2), m.group(3)))
    return rows


def cross_surface(javap, entries):
    """第二套 jar（3.3.3）的 native 面 vs 主 jar（3.2.3）的 native 面。

    为什么要这一步：本层要覆盖的不止 1.12.2。若两代 jar 的 native 集合不同，
    这张表就只对一代有效 —— 另一代里那些「表里没有」的入口仍会落回 LWJGL 的
    NULL 函数表。面完全一致才是「一张表覆盖两代」，不一致必须看见（而不是默认一致）。
    """
    if not os.path.isfile(JAR_CROSS):
        return None
    other = set()
    for _, cls in CLASSES:
        for name, desc in javap_natives(javap, JAR_CROSS, cls):
            other.add((cls.split(".")[-1], name, desc))
    mine = {(cls, n, d) for _, cls, n, d in entries}
    return mine, other


def self_check(jar_entries, text, required, optional):
    """① 表条数 == jar native 总数；② 逐条 (类,名字,描述符) 与 jar 相等；③ 每条都有 stub 或真实现。"""
    errors = []
    rows = parse_generated(text)
    stub_keys = {(("GL11", "GL11C")[c], n, d) for c, n, d, _ in rows}
    jar_keys = {(cls, n, d) for _, cls, n, d in jar_entries}

    if len(rows) != len(jar_entries):
        errors.append("表条数 %d ≠ jar native 总数 %d" % (len(rows), len(jar_entries)))
    if len(rows) != len(stub_keys):
        errors.append("表里有重复行（同一 (类,名字,描述符) 出现多次）：%d 行 / %d 唯一"
                      % (len(rows), len(stub_keys)))
    for key in sorted(jar_keys - stub_keys):
        errors.append("jar 里的 native %s.%s%s 在表里没有 stub" % key)
    for key in sorted(stub_keys - jar_keys):
        errors.append("表里的 %s.%s%s 在 jar 里不是 static native（凭空多出来的入口）" % key)

    # 函数指针必须真的指向一个 stub 函数，且同一个描述符共用同一个实现
    by_desc = {}
    for _, name, desc, fn in rows:
        if fn != stub_symbol(desc):
            errors.append("%s%s 指向 %s，按描述符应为 %s" % (name, desc, fn, stub_symbol(desc)))
        by_desc.setdefault(desc, set()).add(fn)
    for desc, fns in by_desc.items():
        if len(fns) != 1:
            errors.append("描述符 %s 对应了多个 stub 实现：%s" % (desc, sorted(fns)))

    # ③ 覆盖：jar 的每条 native 要么有 stub（表里必然有），要么有真实现 ——
    #    真实现优先的优先级由 a2_gl2_jni_bind.m 的 taken 集保证，这里只核对
    #    「真实现的主名字有没有 jar 依据」（没有依据的条目永远装不上 = 死条目）。
    for cls, name, sig in sorted(required):
        if (cls, name, sig) not in jar_keys:
            errors.append("真实现表里的主名字 %s.%s%s 在 jar 里不是 static native（装不上）"
                          % (cls, name, sig))
    covered = stub_keys | required | optional
    missed = jar_keys - covered
    if missed:
        errors.append("共 %d 个 jar native 既没有 stub 也没有真实现" % len(missed))

    # ④ 值敏感覆盖表：每一条都必须真的存在，且没有被真实现抢先（抢先 = 死条目）
    overrides = parse_stub_overrides()
    for cls, name, sig in overrides:
        if (cls, name, sig) not in jar_keys:
            errors.append("覆盖表里的 %s.%s%s 不是 jar 里的 static native（装了也没用）"
                          % (cls, name, sig))
        if (cls, name, sig) in required:
            errors.append("覆盖表里的 %s.%s%s 已被 kA2GL2Methods[] 的真实现接管 ⇒ 覆盖不生效，应删掉"
                          % (cls, name, sig))
    return errors, len(rows), len(required), len(overrides)


# ----------------------------------------------------------------------------
#  main
# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="生成 GL11/GL11C 的 no-op stub 登记表")
    ap.add_argument("--check", action="store_true", help="只自检，不写文件")
    ap.add_argument("--stdout", action="store_true", help="打到 stdout（不写文件）")
    args = ap.parse_args()

    javap = find_javap()
    if javap is None:
        print("★找不到 javap★：设 JAVA_HOME 或在 PATH 上放一个 JDK（本脚本不接受凭记忆的签名）")
        return 1
    if not os.path.isfile(JAR):
        print("★缺 jar★：%s" % JAR)
        return 1

    print("javap: %s" % javap)
    print("jar  : %s" % os.path.relpath(JAR, ROOT))

    entries = []
    for decl_class, (short, cls) in enumerate(CLASSES):
        natives = javap_natives(javap, JAR, cls)
        seen = set()
        for name, desc in natives:
            if (name, desc) in seen:
                continue                # 同名同描述符不可能有两条，防御性去重
            seen.add((name, desc))
            entries.append((decl_class, short, name, desc))
        print("  %-5s %3d 个 static native" % (short, len(seen)))

    # 两代 jar 的 native 面先比一遍：结果要写进生成的头文件（别让头文件里的话变成断言）
    cross = cross_surface(javap, entries)
    cross_ok = (cross is not None and cross[0] == cross[1])
    gens = ("1.12.2 及更早（Libraries/Jars/lwjgl-2/lwjgl-opengl-3.2.3.jar）"
            + ("＋1.13–1.16（3.3.3）逐条一致" if cross_ok else "；★未与其它代核对/不一致★"))

    text = render(entries, os.path.relpath(JAR, ROOT).replace(os.sep, "/"), gens)

    if args.stdout:
        sys.stdout.write(text)
    elif not args.check:
        with open(OUT_H, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        print("写出 %s" % os.path.relpath(OUT_H, ROOT))
    else:
        # --check：与落盘文件比对，不一致就报（CI 用；防止「改了 jar 忘了重生成」）
        if not os.path.isfile(OUT_H):
            print("★缺 %s★：先跑一次不带 --check 的生成" % os.path.relpath(OUT_H, ROOT))
            return 1
        with open(OUT_H, encoding="utf-8") as fh:
            on_disk = fh.read()
        if on_disk != text:
            print("★%s 与当前 jar 不一致★：请重新生成并提交（会改变注册面）"
                  % os.path.relpath(OUT_H, ROOT))
            return 1
        text = on_disk

    required, optional, ordered = parse_real_table()
    errors, n_rows, n_real, n_over = self_check(entries, text, required, optional)

    # ⑥ 空跑一遍安装（真实现先、空实现后）⇒ 预测真机那行判据的三个数字
    jar_keys = {(cls, n, d) for _, cls, n, d in entries}
    sim_real, sim_stub, sim_covered, sim_miss = simulate(jar_keys, ordered)
    print("空跑安装：已实现 %d 条 / 空实现 %d 条 / 总计 %d（免装 %d 条）"
          % (sim_real, sim_stub, len(jar_keys), sim_covered))
    if sim_real + sim_stub != len(jar_keys):
        errors.append("空跑对不上：已实现 %d + 空实现 %d ≠ 总计 %d（装机后判据行会显示接管面有洞）"
                      % (sim_real, sim_stub, len(jar_keys)))
    if sim_miss:
        for gl_name, jni_name, sig in sim_miss:
            errors.append("空跑里真实现落不下地：%s（%s%s）——jar 里没有这条 native" %
                          (gl_name, jni_name, sig))

    # ⑤ 两代 jar 的 native 面必须一致（否则这张表只覆盖一代，另一代仍有踩空点）
    if cross is None:
        print("（跳过交叉核对：缺 %s）" % os.path.relpath(JAR_CROSS, ROOT))
    else:
        mine, other = cross
        only_other = sorted(other - mine)
        only_mine = sorted(mine - other)
        if only_other or only_mine:
            for k in only_other:
                errors.append("3.3.3 有、本表没有：%s.%s%s（1.13–1.16 上仍会落回 LWJGL）" % k)
            for k in only_mine:
                errors.append("本表有、3.3.3 没有：%s.%s%s（1.13+ 上会被跳过并各打一行日志）" % k)
        else:
            print("交叉核对：3.3.3 的 GL11/GL11C native 面与本表逐条一致（%d 条）" % len(other))

    print()
    print("表 %d 条 / jar native %d 条 / 真实现主名字 %d 条（含兜底命名共 %d 条）/ 值敏感覆盖 %d 条"
          % (n_rows, len(entries), n_real, len(required | optional), n_over))
    if errors:
        for e in errors:
            print("  ✗ %s" % e)
        print("\n发现 %d 处问题" % len(errors))
        return 1
    print("✓ 表条数 == jar native 总数；每个 jar native 都有 stub；真实现表无死条目")
    return 0


if __name__ == "__main__":
    sys.exit(main())
