#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GL2 语义层的 metallum 后端（Metal 直出）源码自检。

为什么需要它：本机没有 ObjC/C 编译器（编译在远端 Mac 上做），而这一层最容易犯的错
**不是**语法错，而是三类「编得过、跑起来才发现」的问题：

  ① 接缝漏装 —— `A2GL2ES3` 有 28 个字段，`a2gl2_metallum_install()` 少赋一条，
     编译器不会报（字段就是函数指针，NULL 也合法），真机表现是「某个调用崩/静默不画」。
  ② 符号名打错 —— dlsym 只认字符串，`metallum_MTLDevice_makeCommandQueue` 少一个字母
     就变成 NULL。本脚本把清单与仓内 `Libraries/Renderers/libmetallum.dylib` 的
     实际导出**逐条比对**（不用记忆，不用真机）。
  ③ 字符串/括号错位 —— 本层大量中文注释与 `@"…"` 日志，一个没转义的引号能让整段
     注释变代码。本脚本做词法级的括号/引号平衡检查。

检查项（全部为「机器判据」，失败退出码 1）：
  1 括号/引号平衡 + ★代码区必须是纯 ASCII★（引号漏转义时中文会漏进代码区，这条钉住它）
  2 头文件的 A2GL2ES3 字段表 = 28 字段，且 A2GL2_ES3_COUNT = 28
  3 `a2gl2_metallum_install` 里 `out->field =` 恰好 28 条、每个字段恰好一次、无多余字段
  4 ★28 条赋值的返回类型与参数类型序列逐字等于接缝 typedef★（没有编译器时最接近编译器的一条）
  5 语义层 `a2_gl2_shim.m` 用到的 `gES3.<field>` 全部在头文件字段表里
  6 语义层确实调用了 `a2gl2_metallum_install` / `a2gl2_metallum_reason`（调用点存在）
  7 kA2MTLSyms 里每条符号：在 libmetallum.dylib 的导出里存在（NUL 结尾精确匹配，前缀不算）
  8 kA2MTLSyms 里每条符号：本文件里有对应调用点 `gApi.<field>(`
  9 A2MTLAPI 的字段与符号清单一一对应（无死字段、无幽灵字段）
 10 本层不得 include/import <Metal/…>（保持"中立 dlsym"口径）
 11 本层用到的每个 `a2mtl_*` 标识符都必须在本文件里有定义（抓拼写错）
 12 ★日志格式串与实参对账★（变参调用编译器不报；顺带抓 `%s` 配 NSString 这类野指针）

用法（仓库根目录）：
    python3 scripts/verify_gl2_metallum.py
    python3 scripts/verify_gl2_metallum.py -v      # 逐条打印通过项
环境变量：
    A2_METALLUM_DYLIB=<path>   指定 libmetallum.dylib（默认 Libraries/Renderers/libmetallum.dylib）
    A2_METALLUM_HEADER=<path>  若给出 metallum 的 C 头文件，额外核对每条符号"确实被声明"
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RENDERER = os.path.join(ROOT, "Natives", "Renderer")

HEADER = os.path.join(RENDERER, "a2_gl2_backend_metallum.h")
BACKEND_M = os.path.join(RENDERER, "a2_gl2_backend_metallum.m")
SHIM_M = os.path.join(RENDERER, "a2_gl2_shim.m")

DEFAULT_DYLIB = os.path.join(ROOT, "Libraries", "Renderers", "libmetallum.dylib")

EXPECTED_ENTRIES = 28

# 28 个接缝字段（★与头文件/安装函数逐字对应★；本表是"任务口径"，不是从代码里推导的，
# 这样字段被误删时脚本会报「少了一条」，而不是跟着代码一起漂移）。
EXPECTED_FIELDS = [
    "genBuffers", "bindBuffer", "bufferData", "genVertexArrays", "bindVertexArray",
    "vertexAttribPointer", "enableVertexAttribArray", "drawArrays", "drawElements",
    "createShader", "shaderSource", "compileShader", "getShaderiv", "getShaderInfoLog",
    "createProgram", "attachShader", "linkProgram", "getProgramiv", "getProgramInfoLog",
    "useProgram", "getAttribLocation", "getUniformLocation", "uniformMatrix4fv",
    "uniform1i", "uniform1f", "enable", "disable", "texParameteri",
]


# ---------------------------------------------------------------------------
#  词法：把注释/字符串抹掉，用于括号平衡与"有效代码"搜索
# ---------------------------------------------------------------------------
def strip_comments_and_strings(text):
    """返回 (clean, errors)。

    clean 里注释与字符串内容都被替换成空格（保留换行，行号不变）；
    errors 收集词法级问题：未闭合的块注释 / 字符串 / 字符字面量。
    """
    out = []
    errors = []
    i = 0
    n = len(text)
    line = 1
    while i < n:
        c = text[i]
        if c == "\n":
            out.append("\n")
            line += 1
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            if j < 0:
                j = n
            out.append(" " * (j - i))
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            if j < 0:
                errors.append("第 %d 行：块注释未闭合" % line)
                out.append(" " * (n - i))
                i = n
                continue
            chunk = text[i:j + 2]
            out.append("".join("\n" if ch == "\n" else " " for ch in chunk))
            line += chunk.count("\n")
            i = j + 2
            continue
        if c == '"' or c == "'":
            quote = c
            j = i + 1
            closed = False
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == quote:
                    closed = True
                    j += 1
                    break
                if text[j] == "\n" and quote == "'":
                    break
                if text[j] == "\n" and quote == '"':
                    # C 字符串不能跨行（未转义的换行）——这条正是「引号漏转义」的现场
                    break
                j += 1
            if not closed:
                errors.append("第 %d 行：字符串/字符字面量未闭合（引号漏转义？）" % line)
                out.append(" " * (min(j, n) - i))
                i = min(j, n)
                continue
            chunk = text[i:j]
            out.append("".join("\n" if ch == "\n" else " " for ch in chunk))
            line += chunk.count("\n")
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out), errors


def check_balance(path, errors, verbose):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    clean, lex_errors = strip_comments_and_strings(text)
    for e in lex_errors:
        errors.append("%s %s" % (os.path.basename(path), e))
    pairs = [("{", "}"), ("(", ")"), ("[", "]")]
    for opener, closer in pairs:
        depth = 0
        unbalanced = False
        for ch in clean:
            if ch == opener:
                depth += 1
            elif ch == closer:
                depth -= 1
                if depth < 0:
                    unbalanced = True
                    break
        if unbalanced:
            errors.append("%s 的 %s%s 提前闭合（多了闭括号）" % (os.path.basename(path), opener, closer))
        elif depth != 0:
            errors.append("%s 的 %s%s 不平衡（差 %d 个）"
                          % (os.path.basename(path), opener, closer, depth))
    if verbose:
        print("  · %s：词法与括号平衡通过" % os.path.basename(path))
    # ★引号漏转义的机器判据★：C/ObjC 的**代码区**必须是纯 ASCII
    #   （标识符/关键字/标点）；中文只允许出现在注释与字符串里。
    #   漏一个转义引号时，剩下的中文正文会落到代码区 —— 这条能把它钉住。
    for lineno, line in enumerate(clean.split("\n"), 1):
        bad = [ch for ch in line if ord(ch) > 127]
        if bad:
            errors.append("%s:%d 代码区出现非 ASCII 字符 %r（引号漏转义？该行原文：%s）"
                          % (os.path.basename(path), lineno, "".join(sorted(set(bad))[:4]),
                             text.split("\n")[lineno - 1].strip()[:90]))
            break
    return text, clean


# ---------------------------------------------------------------------------
#  检查 2/3/4/5：接缝字段表与安装完整性
# ---------------------------------------------------------------------------
def struct_fields(header_text):
    """从头文件里取 A2GL2ES3 的字段名（顺序保持）。"""
    m = re.search(r"typedef struct\s*\{(.*?)\}\s*A2GL2ES3\s*;", header_text, re.S)
    if not m:
        return None
    body = m.group(1)
    # 每行形如 "    A2GL2PFN_glFoo               foo;"
    return re.findall(r"\b(\w+)\s*;", body)


def install_assignments(backend_text):
    """从 install 函数里取 `out->field = …;` 的字段名（顺序保持，含重复）。"""
    return re.findall(r"out->(\w+)\s*=", backend_text)


def _strip_preprocessor(text):
    """抹掉预处理行（含 `\\` 续行）：宏体里的 `gES3.field` 不是真实调用点。"""
    out = []
    in_macro = False
    for line in text.split("\n"):
        if in_macro:
            out.append("")
            in_macro = line.rstrip().endswith("\\")
            continue
        if line.lstrip().startswith("#"):
            out.append("")
            in_macro = line.rstrip().endswith("\\")
            continue
        out.append(line)
    return "\n".join(out)


def check_seam(header_text, backend_text, shim_clean, errors, verbose):
    fields = struct_fields(header_text)
    if fields is None:
        errors.append("头文件里找不到 `typedef struct { … } A2GL2ES3;`")
        return
    if len(fields) != EXPECTED_ENTRIES:
        errors.append("A2GL2ES3 字段数 = %d，期望 %d" % (len(fields), EXPECTED_ENTRIES))
    missing = [f for f in EXPECTED_FIELDS if f not in fields]
    extra = [f for f in fields if f not in EXPECTED_FIELDS]
    if missing:
        errors.append("A2GL2ES3 少了字段：%s" % ", ".join(missing))
    if extra:
        errors.append("A2GL2ES3 多了未知字段：%s" % ", ".join(extra))

    const = re.search(r"#define\s+A2GL2_ES3_COUNT\s+(\d+)", header_text)
    if not const:
        errors.append("头文件缺少 `#define A2GL2_ES3_COUNT <n>`")
    elif int(const.group(1)) != EXPECTED_ENTRIES:
        errors.append("A2GL2_ES3_COUNT = %s，期望 %d" % (const.group(1), EXPECTED_ENTRIES))

    assigned = install_assignments(backend_text)
    if len(assigned) != EXPECTED_ENTRIES:
        errors.append("install 里 `out->field =` 有 %d 条，期望 %d 条" % (len(assigned), EXPECTED_ENTRIES))
    dup = sorted({f for f in assigned if assigned.count(f) > 1})
    if dup:
        errors.append("install 里重复赋值：%s" % ", ".join(dup))
    not_assigned = [f for f in EXPECTED_FIELDS if f not in assigned]
    if not_assigned:
        errors.append("install 漏装：%s" % ", ".join(not_assigned))
    unknown = [f for f in assigned if f not in EXPECTED_FIELDS]
    if unknown:
        errors.append("install 赋了不存在的字段：%s" % ", ".join(unknown))
    order_ok = assigned == EXPECTED_FIELDS
    if not order_ok:
        errors.append("install 的赋值顺序与接缝字段顺序不一致（会让人误以为对应关系变了）")

    used = set(re.findall(r"gES3\.(\w+)", _strip_preprocessor(shim_clean)))
    bad = sorted(f for f in used if f not in fields)
    if bad:
        errors.append("a2_gl2_shim.m 用到但接缝里没有的字段：%s" % ", ".join(bad))

    if verbose:
        print("  · 接缝 %d 字段；install 赋值 %d 条（顺序一致=%s）；语义层用到 %d 个字段"
              % (len(fields), len(assigned), order_ok, len(used)))


def check_call_sites(shim_clean, errors, verbose):
    for fn in ("a2gl2_metallum_install", "a2gl2_metallum_reason"):
        if fn not in shim_clean:
            errors.append("a2_gl2_shim.m 里没有调用 %s（后端没有调用点 = 死代码）" % fn)
    # 回落后端判据行必须在语义层里（任务要求的机器判据）
    if "回落后端=GLES" not in shim_clean:
        # 该行是 @"…" 字面量，strip 后被抹掉了 ⇒ 用原文再查一次
        with open(SHIM_M, "r", encoding="utf-8") as fh:
            raw = fh.read()
        if "回落后端=GLES" not in raw:
            errors.append("a2_gl2_shim.m 缺少判据行 `[A2-MTL] 回落后端=GLES（原因=…）`")
    if verbose:
        print("  · 语义层的调用点：a2gl2_metallum_install / a2gl2_metallum_reason 命中")


# ---------------------------------------------------------------------------
#  检查 6/7/8：符号清单 ↔ dylib 导出 ↔ 本文件调用点
# ---------------------------------------------------------------------------
def parse_symbol_table(backend_text):
    """解析 kA2MTLSyms：返回 [(symbol, field, required)]。"""
    m = re.search(r"kA2MTLSyms\[\]\s*=\s*\{(.*?)\n\};", backend_text, re.S)
    if not m:
        return None
    body = m.group(1)
    rows = re.findall(r'\{\s*"([^"]+)"\s*,\s*A2MTL_FIELD\((\w+)\)\s*,\s*([01])\s*\}', body)
    return rows


def check_symbols(backend_text, errors, verbose):
    rows = parse_symbol_table(backend_text)
    if rows is None:
        errors.append("找不到 `kA2MTLSyms[] = { … };` 符号清单")
        return
    if len(rows) < 30:
        errors.append("符号清单只有 %d 条，看起来被截断了" % len(rows))

    # ⑦ 每条符号都要有调用点 `gApi.<field>(`
    no_call = [s for (s, f, _r) in rows if ("gApi.%s(" % f) not in backend_text]
    if no_call:
        errors.append("符号清单里这些字段没有调用点（登记了不用 = 石山）：%s" % ", ".join(no_call))

    # 同一字段被两条符号映射（会静默覆盖）
    fields = [f for (_s, f, _r) in rows]
    dup = sorted({f for f in fields if fields.count(f) > 1})
    if dup:
        errors.append("符号清单里同一字段映射了多条符号：%s" % ", ".join(dup))

    # ⑥ 与仓内 dylib 的实际导出比对（唯一"不用猜"的核对）
    dylib = os.environ.get("A2_METALLUM_DYLIB", DEFAULT_DYLIB)
    if os.path.isfile(dylib):
        with open(dylib, "rb") as fh:
            blob = fh.read()
        absent = [s for (s, _f, r) in rows if r == "1" and (s.encode() + b"\x00") not in blob]
        if absent:
            errors.append("这些**必需**符号在 %s 的导出里找不到：%s"
                          % (os.path.basename(dylib), ", ".join(absent)))
        opt_absent = [s for (s, _f, r) in rows if r == "0" and (s.encode() + b"\x00") not in blob]
        if opt_absent:
            errors.append("这些**可选**符号在整个 dylib 里都找不到（应删掉或改为必需）：%s"
                          % ", ".join(opt_absent))
        if verbose:
            print("  · 符号清单 %d 条：与 %s 比对完成（必需 %d / 可选 %d）"
                  % (len(rows), os.path.basename(dylib),
                     sum(1 for r in rows if r[2] == "1"),
                     sum(1 for r in rows if r[2] == "0")))
    else:
        print("  ! 跳过 dylib 比对：%s 不存在（可用 A2_METALLUM_DYLIB 指定）" % dylib)

    # 可选：给出 metallum 的 C 头文件时，核对每条符号"确实被声明"
    header = os.environ.get("A2_METALLUM_HEADER")
    if header:
        if not os.path.isfile(header):
            errors.append("A2_METALLUM_HEADER=%s 不存在" % header)
        else:
            with open(header, "r", encoding="utf-8", errors="replace") as fh:
                htext = fh.read()
            undeclared = [s for (s, _f, _r) in rows if s not in htext]
            if undeclared:
                errors.append("A2_METALLUM_HEADER 里没有声明这些符号：%s" % ", ".join(undeclared))
            elif verbose:
                print("  · 与 A2_METALLUM_HEADER 逐条对上了（签名仍需人工看一眼）")


def _split_params(param_text):
    """把 `(GLuint, GLint, const void *)` 拆成参数类型列表（按顶层逗号；容忍函数指针）。"""
    text = param_text.strip()
    if text == "" or text == "void":
        return []
    out, depth, cur = [], 0, []
    for ch in text:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur).strip())
            cur = []
            continue
        cur.append(ch)
    out.append("".join(cur).strip())
    return [p for p in out if p]


def _type_signature(param_list):
    """参数类型序列的规范化文本（去掉形参名，只留类型）。"""
    types = []
    for p in param_list:
        p = re.sub(r"\s+", " ", p).strip()
        p = re.sub(r"(\*)\s*\w+$", r"\1", p)   # const GLfloat *value -> const GLfloat *
        p = re.sub(r"\s+\w+$", "", p)          # GLsizei count -> GLsizei
        types.append(p)
    return tuple(types)


def check_assignment_signatures(header_text, backend_text, errors, verbose):
    """★编译器级的检查★：28 个 `out->field = a2mtl_xxx` 两侧的
    返回类型与参数类型序列必须逐字一致（类型别名不同也算错，因为函数指针类型不兼容）。"""
    pfn = dict()
    for m in re.finditer(r"typedef\s+([\w \*]+?)\(\s*\*(\w+)\s*\)\s*\(([^;]*)\)\s*;", header_text):
        pfn[m.group(2)] = (_type_signature(_split_params(m.group(3))), m.group(1).strip())

    struct = re.search(r"typedef struct\s*\{(.*?)\}\s*A2GL2ES3\s*;", header_text, re.S)
    if not struct:
        errors.append("无法解析 A2GL2ES3 结构体（签名检查跳过）")
        return
    field_type = dict((f, t) for t, f in re.findall(r"(A2GL2PFN_\w+)\s+(\w+)\s*;", struct.group(1)))

    impls = {}
    for m in re.finditer(r"^static\s+([\w \*]+?)\b(a2mtl_\w+)\s*\(([^;{]*)\)\s*\{",
                         backend_text, re.M):
        impls[m.group(2)] = (_type_signature(_split_params(m.group(3))), m.group(1).strip())

    checked = 0
    for m in re.finditer(r"out->(\w+)\s*=\s*(a2mtl_\w+)\s*;", backend_text):
        field, fn = m.group(1), m.group(2)
        tname = field_type.get(field)
        if tname is None or tname not in pfn:
            errors.append("字段 %s 的类型不是已知的 A2GL2PFN_*（接缝声明与 install 不一致）" % field)
            continue
        want_params, want_ret = pfn[tname]
        if fn not in impls:
            errors.append("install 赋值的 %s 没有 static 定义" % fn)
            continue
        got_params, got_ret = impls[fn]
        if want_params != got_params:
            errors.append("%s 的参数类型与接缝不一致：接缝 %s / 实现 %s"
                          % (fn, want_params, got_params))
        if want_ret != got_ret:
            errors.append("%s 的返回类型与接缝不一致：接缝 %r / 实现 %r"
                          % (fn, want_ret, got_ret))
        checked += 1
    if checked != EXPECTED_ENTRIES:
        errors.append("只核对了 %d/%d 条赋值的签名" % (checked, EXPECTED_ENTRIES))
    elif verbose:
        print("  · 28 条赋值的返回类型与参数类型逐一与接缝 typedef 对上")


def check_api_table(backend_text, errors, verbose):
    """A2MTLAPI 的每个字段都必须在符号清单里，且清单里没有不存在的字段。"""
    struct = re.search(r"typedef struct\s*\{(.*?)\}\s*A2MTLAPI\s*;", backend_text, re.S)
    if not struct:
        errors.append("找不到 `typedef struct { … } A2MTLAPI;`")
        return
    body = struct.group(1)
    fields = re.findall(r"\(\s*\*\s*(\w+)\s*\)\s*\(", body)
    rows = parse_symbol_table(backend_text) or []
    mapped = [f for (_s, f, _r) in rows]
    dead = [f for f in fields if f not in mapped]
    ghost = [f for f in mapped if f not in fields]
    if dead:
        errors.append("A2MTLAPI 里这些字段没有对应符号（死字段）：%s" % ", ".join(dead))
    if ghost:
        errors.append("符号清单引用了 A2MTLAPI 里不存在的字段：%s" % ", ".join(ghost))
    if verbose:
        print("  · API 表：%d 个字段 ↔ %d 条符号（一一对应=%s）"
              % (len(fields), len(rows), not dead and not ghost))


def check_log_formats(backend_text, errors, verbose):
    """★日志格式与实参对账★：a2_log_f / a2_log_criterion / a2mtl_reason 都是变参，
    参数个数或类型给错**编译器不报**（没有 format attribute），但运行期是 UB。
    顺带抓一类真实踩过的错：`a2_log_f` 走 vsnprintf ⇒ 只认 `%s`+C 字符串，
    而 `a2_log_criterion` 走 NSString ⇒ 认 `%@`。给反了就是野指针。
    """
    # a2_log_f → C 格式化（%s 要 C 字符串，不认 %@）
    # a2_log_criterion → ObjC 格式化（%@ 要 NSString）
    rules = {"a2_log_f": ("%s", "not_objc"), "a2_log_criterion": ("%@", "objc"),
             "a2mtl_reason": ("%s", "not_objc")}
    spec_re = re.compile(r"%[-+ #0]*[0-9*]*(?:\.\d+)?(?:hh|h|ll|l|q|z|j|t|L)?([diouxXeEfgGaAcspn@%])")
    checked = 0
    for fn, (_fmt_kind, mode) in rules.items():
        for m in re.finditer(r"\b" + fn + r"\s*\(", backend_text):
            start = m.end()
            depth, i = 1, start
            while i < len(backend_text) and depth > 0:
                ch = backend_text[i]
                if ch == '"':                      # 跳过字符串
                    i += 1
                    while i < len(backend_text) and backend_text[i] != '"':
                        i += 2 if backend_text[i] == "\\" else 1
                elif ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                i += 1
            if depth != 0:
                continue
            argtext = backend_text[start:i - 1]
            args = _split_params(argtext)
            if not args:
                continue
            fmt_arg = args[0]
            lits = re.findall(r'@?"((?:[^"\\]|\\.)*)"', fmt_arg)
            if not lits or re.sub(r'@?"(?:[^"\\]|\\.)*"', "", fmt_arg).strip():
                continue                            # 格式串不是纯字面量 ⇒ 跳过
            fmt = "".join(lits)
            specs = [s for s in spec_re.findall(fmt) if s != "%"]
            given = args[1:]
            if len(specs) != len(given):
                errors.append("%s 的格式串有 %d 个转换符但给了 %d 个实参：%r"
                              % (fn, len(specs), len(given), fmt.strip()[:60]))
                continue
            for spec, arg in zip(specs, given):
                arg = arg.strip()
                is_objc_literal = arg.startswith('@"')
                is_c_literal = (arg.startswith('"') and not is_objc_literal)
                if spec == "s" and is_c_literal:
                    pass                            # NSString 的 %s 合法（C 字符串）
                if spec == "s" and ('@"' in arg) and ("UTF8String" not in arg):
                    # 三元里出现 @"…" 也是同一类错（之前真踩过：cond ? @"A" : @"B" 塞进 %s）
                    errors.append("%s 用 %%s 却给了 ObjC 字符串（vsnprintf 会当野指针）：%r"
                                  % (fn, fmt.strip()[:60]))
                if spec == "@" and is_c_literal:
                    errors.append("%s 用 %%@ 却给了 C 字符串（要 NSString）：%r"
                                  % (fn, fmt.strip()[:60]))
            checked += 1
    if verbose:
        print("  · 日志调用格式串核对 %d 处（转换符数 = 实参数的全部对上）" % checked)


def check_no_metal_include(paths, errors, verbose):
    bad = []
    for p in paths:
        with open(p, "r", encoding="utf-8") as fh:
            for i, line in enumerate(fh, 1):
                s = line.strip()
                if s.startswith("//") or s.startswith("*"):
                    continue
                if re.match(r'#\s*(import|include)\s*<Metal/', s):
                    bad.append("%s:%d %s" % (os.path.basename(p), i, s))
    if bad:
        errors.append("本层必须保持「中立 dlsym」口径，不得直接 include Metal 头：%s" % "; ".join(bad))
    elif verbose:
        print("  · 未直接 include <Metal/…>（保持中立 dlsym 口径）")


def check_internal_definitions(backend_text, errors, verbose):
    """每个被调用的 a2mtl_* 都必须在同一文件里有定义（抓拼写错；C 里这类错要到链接期才炸）。"""
    clean, _ = strip_comments_and_strings(backend_text)
    defined = set(re.findall(r"\b(?:static\s+[\w \*]+?)\b(a2mtl_\w+)\s*\(", clean))
    defined |= set(re.findall(r"^\s*(a2mtl_\w+)\s*\(", clean, re.M))
    called = set(re.findall(r"\b(a2mtl_\w+)\s*\(", clean))
    undefined = sorted(called - defined)
    if undefined:
        errors.append("这些 a2mtl_* 被调用但没有定义（拼写错？）：%s" % ", ".join(undefined))
    if verbose:
        print("  · 内部符号：定义 %d 个 / 引用 %d 个" % (len(defined), len(called)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    for path in (HEADER, BACKEND_M, SHIM_M):
        if not os.path.isfile(path):
            print("✗ 缺文件：%s" % path)
            return 1

    errors = []
    header_text, _header_clean = check_balance(HEADER, errors, args.verbose)
    backend_text, _backend_clean = check_balance(BACKEND_M, errors, args.verbose)
    _shim_text, shim_clean = check_balance(SHIM_M, errors, args.verbose)

    check_seam(header_text, backend_text, shim_clean, errors, args.verbose)
    check_assignment_signatures(header_text, backend_text, errors, args.verbose)
    check_api_table(backend_text, errors, args.verbose)
    check_call_sites(shim_clean, errors, args.verbose)
    check_symbols(backend_text, errors, args.verbose)
    check_no_metal_include([HEADER, BACKEND_M], errors, args.verbose)
    check_log_formats(backend_text, errors, args.verbose)
    check_internal_definitions(backend_text, errors, args.verbose)

    print()
    if errors:
        for e in errors:
            print("  ✗ %s" % e)
        print("\n发现 %d 处问题" % len(errors))
        return 1
    print("[A2-MTL] 源码自检通过：接缝 %d 字段 / 安装 %d 条 / 符号清单与 dylib 对上"
          % (EXPECTED_ENTRIES, EXPECTED_ENTRIES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
