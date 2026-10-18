#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ★ [SHADER-GLSLANG] pack_shader_glslang.py
#   Iris 光影最后一跳的 native 缺口打包器（幂等）。
#
# 背景（真机 latestlog-38.txt，MC 26.2 / Fabric / metallum Metal 后端）：
#   java.lang.ExceptionInInitializerError
#     at MetalCrossShaderCompiler.compileShaderpack(…:247)
#   Caused by: java.util.NoSuchElementException: Symbol not found: glslang_initialize_process
#     at java.lang.foreign.SymbolLookup.findOrThrow
#     at ...bridge.GlslangBridge.downcall(GlslangBridge.java:807)
#     at ...bridge.GlslangBridge.<clinit>(GlslangBridge.java:275)
#
# 根因：mod 的 glslang 桥有两条加载路径：
#   1) MetalNativeBridge.configureBundledGlslangLibrary()
#        → Class.getResourceAsStream("/natives/ios/libglslang.dylib")  [jar 资源]
#        → 解出 <home>/libglslang_metallum.dylib → System.load(绝对路径)
#      jar 里【没有】该资源 ⇒ 静默 return（上游源码 8..20 行 ifnull return）。
#   2) GlslangBridge.createIOSGlslangLookup()
#        → System.loadLibrary("glslang")   [java.library.path = <app>/Frameworks]
#        → SymbolLookup.loaderLookup()
#      Frameworks 里【没有】libglslang.dylib ⇒ loadLibrary 抛 UnsatisfiedLinkError 被吞
#      ⇒ loaderLookup 找不到 glslang_* ⇒ 上面那条 NoSuchElementException。
#
# ★★★★★ [SHADER-SIGBUS] 本轮修正 —— glslang 的唯一合法落点是 Frameworks ————————
#   上一轮把 #1 的 jar 资源补齐后，真机上 dlopen 真的跑起来了，于是撞到下一层：
#       SIGBUS (0xa) at pc=…  Problematic frame:
#       C  [libglslang_metallum.dylib+0xccbc4]  _GLOBAL__sub_I_Scan.cpp+0x0
#       → abort() 被 Amethyst 的 hooked_abort 接管 ⇒ 进程不死不活（表现为"卡"）
#
#   证据链（本轮取证，逐条可复现）：
#     a. `libglslang_metallum.dylib` 这个文件名【只】由 #1 生成
#        （configureBundledGlslangLibrary 把 jar 内 /natives/ios/libglslang.dylib
#        写到 <home>/libglslang_metallum.dylib；javap -c 复核 ldc 常量池：
#        "/natives/ios/libglslang.dylib" → getResourceAsStream →
#        "libglslang_metallum.dylib" → System.load）。jar 内字节 = 2924256 B /
#        md5 4afe653de58d = Natives/resources/Frameworks/libglslang.dylib 逐字节相同。
#        ⇒ 崩溃镜像名 = 解包副本名 ⇒ 真机走的是 #1，不是 Frameworks。
#     b. 该 dylib 本身【是干净的】（Mach-O 直接核对）：
#          cputype=0x100000c(arm64) platform=iOS minos=14.0 sdk=26.2
#          __DefaultRuneLocale 为【已定义】数据符号（不是未定义引用）；
#          init_rl 计数 = 0；LC_CODE_SIGNATURE 存在；
#          __GLOBAL__sub_I_Scan.cpp 值 0xccbc4 == 崩溃偏移；
#          __TEXT vmsize == filesize == 0x248000 == 崩溃日志里 PrepareRegion 的 len
#        ⇒ 不是"编错目标/编坏符号"那一类（那类已在 v375/v376 修掉，见 VERSION_HISTORY.md）。
#     c. 剩下的差别只有【加载路径】：
#          · #1 = 从 jar 解包到 home 的副本 → 文件【没有随 app 一起签名】
#          · #2 = app/Frameworks 内随 app 一起被签名的副本
#        Amethyst 的 dyld bypass（Natives/dyld_bypass_validation.m）对 RX 映射有两级
#        处理：先 mmap + mprotect(RX)；失败才退化为"匿名映射 + PrepareRegion +
#        经镜像 memcpy 内容"，而该文件自己写着
#            "Modifying exec page during execution may cause SIGBUS"
#        ⇒ 只有走兜底（非文件后备、页被重写）的映射会在首次执行时 SIGBUS。
#        真机日志里紧邻崩溃的那一行正是
#            [JIT26] [JIT-NOCRASH] PrepareRegion serviced (addr=…, len=2392064)
#        而 2392064 == 0x248000 == 该 dylib __TEXT 的 filesize/vmsize，
#        pc − addr == 0xCCBC4 == _GLOBAL__sub_I_Scan.cpp 的段内偏移
#        ⇒ 崩溃页正是"被 PrepareRegion + memcpy 重写过的匿名 RX 页"。
#     d. 项目历史档案同款结论（D:\CTF\VERSION_HISTORY.md）：
#          v377 glslangalldll.ipa / v378 **noglslanginjar.ipa** / v379 glslangmerged.ipa
#          → 均为「★★★★★ 巨大突破 —— SIGBUS 彻底消失了」
#        以及本仓库技能里记录的不变量：
#          「**mod jar 内不放 glslang**（会被抽成未签名副本 ⇒ SIGBUS）；glslang 只放 Frameworks」
#        ⇒ 正确做法就是 v378：**从 jar 里拿掉 glslang，只留 Frameworks**。
#
#   ⇒ 因此本脚本从"往 jar 里塞 glslang"翻转成"**从 jar 里清除 glslang**"：
#        只让 #2（loadLibrary → <app>/Frameworks/libglslang.dylib，随包签名）生效，
#        彻底不再产生 <home>/libglslang_metallum.dylib 这个未签名副本。
#      #2 的失败模式是"符号找不到"（可见、可降级）；#1 的失败模式是
#      "dlopen 期 SIGBUS + hooked_abort 吞掉"（不可见、卡住）—— 宁可要前者。
#
#   ★ 兼容性核对（不碰 26.3 / 26.4 / 其它类集）：
#       agent jar 里只有 classes262iris/ 与 jar 根那两份 MetalNativeBridge 引用
#       /natives/ios/libglslang.dylib；classes263 / classes261 / classes12111_1_21_11
#       的 MetalNativeBridge 【完全没有】glslang 字样（逐类二进制扫描实证），
#       故移除该条目对 26.3/26.4 路径零影响。
#
# 同时补齐缺口 B：com/mojang/blaze3d【整组】（不再是三个固定名字）
#   ★★★ [BLAZE3D-ONDEMAND] 本脚本只负责把【镜像源】放进 jar 的三处位置(缺一即
#   "半边可见": classes262iris/ + classes262/ + jar 根)。**是否 define 由 agent 运行时
#   按「目标加载器能解析就不定义、只补真缺」决定**(MetallumAgent.collectBlaze3dMissing)。
#   真机 latestlog-41 (26.2/Fabric/knot) 证明：无差别 define 会撞两类崩 ——
#     · knot 已加载的类 → "attempted duplicate ... class definition" LinkageError；
#     · VertexFormat(Sodium mixin 靶子)被裸定义 → 绕过 mixin → ClassCastException 启动崩。
#   ⇒ 本脚本保留整组镜像(给"没有游戏 jar"的 loader 兜底), agent 侧改为按需补缺。
#   这些镜像必须落到【每一处可能被解析到的位置】，否则就是"半边可见"：
#   某个 loader 能读到 com/metallum/** 副本，却读不到这些副本 implements/引用 的
#   com/mojang/blaze3d/** ⇒ NoClassDefFoundError。
#   演进：latestlog-39 报 `GpuSurfaceBackend`（只补了 3 个固定名字）→ 修好后
#   latestlog-40 退到下一层 `GpuSurface$PresentMode`（内部类）⇒ 必须整组。
#   组 = Natives/shader_glslang/blaze3d/**（清单 blaze3d_group.txt），见
#   Natives/extract_blaze3d_group.py 头部（从 client-26.2.jar 求【链接面闭包】）。
#   agent 的 `collectClassNames(resPrefix + "com/mojang/blaze3d/")` 会在 com/metallum
#   类【之前】先 define 这些类（与 classes261 类集同款机制），但那只覆盖 resPrefix
#   这一个目录 ⇒ 三个镜像位置缺一不可（见 GLSLANG_IFACE_PREFIXES）。
#
#   ★ [SHADER-BLAZE3D] 不改 mod jar（MetalUniversal-1.0.4.jar）里的接口：
#     它是 Fabric mod，由 Knot 载入 ⇒ 看得见 client jar 的 blaze3d；往 mod jar 塞
#     游戏包名（com.mojang.*）反而可能触发 Fabric 类加载隔离。mod jar 只做移除。
#
# 用法:
#   python Natives/pack_shader_glslang.py            # 打包（幂等）
#   python Natives/pack_shader_glslang.py --check    # 只检查（jar 无 glslang / Frameworks 有）
import sys, os, zipfile, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))            # <tree>/Natives
TREE = os.path.dirname(HERE)                                 # <tree>

FW_DIR      = os.path.join(HERE, "resources", "Frameworks")
# ★ [SHADER-BLAZE3D-GROUP] blaze3d 整组的源目录/清单在下面 GLSLANG_GROUP_* 定义
AGENT_JAR   = os.path.join(TREE, "JavaApp", "libs", "others", "metallum_agent.jar")
MOD_JAR     = os.path.join(TREE, "Natives", "resources", "mods_preload", "MetalUniversal-1.0.4.jar")

# ★ [SHADER-SIGBUS] glslang 的唯一合法落点：app/Frameworks（随 app 一起被签名，
#   由 GlslangBridge.createIOSGlslangLookup() 的 System.loadLibrary("glslang") 加载）。
#   三个文件名是同一份字节的三个别名（install name 兼容用），必须都在。
FW_GLSLANG = ["libglslang.dylib", "libglslang.16.dylib", "libglslang.16.4.0.dylib"]

# ★ [SHADER-SIGBUS] 这些 jar 条目必须【不存在】：
#   · natives/ios/…  → classes262iris / jar 根那两份 MetalNativeBridge 的
#                      configureBundledGlslangLibrary() 会解包到 home 再 System.load
#   · natives/ir1/…  → 无任何类引用（死重量），一并清掉
JAR_GLSLANG_NATIVE = ["natives/ios/libglslang.dylib", "natives/ir1/libglslang.dylib"]

# 必须带 C API（GlslangBridge 需要 17 个 glslang_* 符号）的导出核对清单
REQUIRED = [
    "glslang_default_resource", "glslang_initialize_process",
    "glslang_program_SPIRV_generate", "glslang_program_SPIRV_get",
    "glslang_program_SPIRV_get_size", "glslang_program_add_shader",
    "glslang_program_create", "glslang_program_delete", "glslang_program_get_info_log",
    "glslang_program_link", "glslang_shader_create", "glslang_shader_delete",
    "glslang_shader_get_info_debug_log", "glslang_shader_get_info_log",
    "glslang_shader_parse", "glslang_shader_preprocess", "glslang_shader_set_options",
]
# ★ [SHADER-BLAZE3D-GROUP] 【整组镜像】—— 不再是三个硬编码名字。
#   上一轮只镜像 3 个固定名字（GpuSurfaceBackend / CommandEncoderBackend /
#   TransientMemory），真机 latestlog-40.txt 立刻在下一层炸：
#       FLOW=ERR:java.lang.NoClassDefFoundError:
#                com/mojang/blaze3d/systems/GpuSurface$PresentMode      ← 内部类($)
#   ⇒ 要镜像的是【一整组】。组由 Natives/extract_blaze3d_group.py 从
#     D:\CTF\client-26.2.jar 算出（= agent 真正 define 的 com/metallum/client/** +
#     3 个接口的【链接面闭包】：超类/接口/字段方法 descriptor/泛型 Signature 引用到的
#     com/mojang/blaze3d/**，逐个递归到闭），逐字节落到
#       Natives/shader_glslang/blaze3d/**      (源目录)
#       Natives/shader_glslang/blaze3d_group.txt (清单: md5/size/name)
#   组内【不含】mixin 目标本体 (opengl/GlStateManager、systems/RenderSystem)：
#   agent 用原始 ClassLoader.defineClass 把类 define 进 Knot ⇒ 若含 mixin 目标会
#   绕过 Fabric/Iris mixin 变换（真机 GlStateManagerMixin 生效的证据是
#   `[metallum:gl] reporting 6 GL extension(s)`）。见 extract 脚本头部说明。
GLSLANG_GROUP_MANIFEST = os.path.join(HERE, "shader_glslang", "blaze3d_group.txt")
GLSLANG_GROUP_SRC      = os.path.join(HERE, "shader_glslang", "blaze3d")

# ★ [SHADER-BLAZE3D-GROUP] 镜像位置（只在两个类集前缀）：
#   · classes262iris/ … agent routing(iris 桥开)define 的类集
#   · classes262/     … agent routing(iris 桥关)define 的类集
# ★★★ [BLAZE3D-ROOT-SHADOW] 【不再】镜像到 jar 根：
#   "-javaagent" 的 agent jar 会被追加到 app/system classpath ⇒ 放在 jar 根的
#   com/mojang/blaze3d/** 会让 app loader 抢先服务游戏自己的类, 造成
#   "同名包 / 不同 runtime package" 的 loader 分裂。26.4 真机实证:
#     IndexGenerator 在 loader 'app' / RenderSystem 在 PojavClassLoader
#     ⇒ IllegalAccessError ⇒ Could not initialize class RenderSystem ⇒ exit(1)。
#   agent 只按前缀枚举/读取 blaze3d 类集(collectBlaze3dMissing(resPrefix) 与
#   readClassResource(resPrefix, …)), jar 根副本【从未被读】⇒ 移除后功能零变化,
#   只消除影子风险。本脚本同时把历史遗留的 jar 根 blaze3d 镜像【清掉】(幂等)。
GLSLANG_IFACE_PREFIXES = ["classes262iris/", "classes262/"]
ROOT_BLAZE3D_PREFIX = "com/mojang/blaze3d/"


def load_group():
    """★ [SHADER-BLAZE3D-GROUP] 读清单 + 源目录 ⇒ {class_name: bytes}。
       逐条核对 md5/size（清单 vs 源目录）；任何不符即 FATAL。"""
    if not os.path.isfile(GLSLANG_GROUP_MANIFEST):
        print("FATAL: missing group manifest: %s" % GLSLANG_GROUP_MANIFEST)
        return None
    group, bad = {}, []
    for ln in open(GLSLANG_GROUP_MANIFEST, encoding="utf-8"):
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        try:
            h, sz, nm = ln.split(None, 2)
            sz = int(sz)
        except ValueError:
            bad.append("BAD-LINE " + ln[:60]); continue
        p = os.path.join(GLSLANG_GROUP_SRC, nm + ".class")
        if not os.path.isfile(p):
            bad.append("MISSING-SRC " + nm); continue
        b = open(p, "rb").read()
        if len(b) != sz or hashlib.md5(b).hexdigest() != h:
            bad.append("SRC-MISMATCH " + nm); continue
        group[nm] = b
    if bad:
        print("FATAL: blaze3d group source problem: %s" % bad[:20])
        return None
    if not group:
        print("FATAL: empty blaze3d group manifest")
        return None
    return group


def md5b(b):
    return hashlib.md5(b).hexdigest()[:8]


def read_entries(jar):
    z = zipfile.ZipFile(jar)
    order = [i.filename for i in z.infolist()]
    data = {i.filename: z.read(i.filename) for i in z.infolist()}
    z.close()
    return order, data


def present_jars():
    """★ [FABRIC-AGENT] 参与打包的 jar: agent jar 永远在; 官方 mod jar 已下线即缺席(<可选>)。
    原实现无条件 read_entries(MOD_JAR) ⇒ mod 被下线后直接 FileNotFoundError 断构建。"""
    js = [AGENT_JAR]
    if os.path.isfile(MOD_JAR):
        js.append(MOD_JAR)
    else:
        print("[glslang] NOTE: mod jar absent (%s) -- agent-only channel (mod 下线模式)"
              % os.path.basename(MOD_JAR))
    return js


def write_entries(jar, order, data):
    tmp = jar + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zo:
        for n in order:
            zo.writestr(n, data[n])
    zz = zipfile.ZipFile(tmp)
    assert zz.testzip() is None, "zip integrity fail: " + jar
    zz.close()
    os.replace(tmp, jar)


def fw_glslang_check(verbose=True):
    """★ [SHADER-SIGBUS] Frameworks 里那份（唯一合法）glslang 自检。
    返回缺失/异常项列表（空 = 通过）。"""
    bad = []
    base = None
    for n in FW_GLSLANG:
        p = os.path.join(FW_DIR, n)
        if not os.path.isfile(p):
            bad.append("%s: MISSING" % n)
            continue
        b = open(p, "rb").read()
        if len(b) < 1024 * 1024:
            bad.append("%s: too small (%d B)" % (n, len(b)))
            continue
        miss = [s for s in REQUIRED if s.encode() not in b]
        if miss:
            bad.append("%s: missing C-API syms %s" % (n, miss))
            continue
        if base is None:
            base = b
            if verbose:
                print("[glslang] FRAMEWORKS %s  %d B  md5 %s  C-API %d/%d"
                      % (n, len(b), md5b(b), len(REQUIRED), len(REQUIRED)))
        elif b != base:
            bad.append("%s: NOT byte-identical to libglslang.dylib" % n)
        elif verbose:
            print("[glslang] FRAMEWORKS %s  = same bytes as libglslang.dylib (%d B)" % (n, len(b)))
    return bad


def strip_jar_glslang(jar):
    """★ [SHADER-SIGBUS] 从 jar 里移除所有 glslang native 条目（幂等）。"""
    order, data = read_entries(jar)
    removed = [n for n in order if n in JAR_GLSLANG_NATIVE]
    if not removed:
        return 0, len(order)
    order = [n for n in order if n not in JAR_GLSLANG_NATIVE]
    for n in removed:
        data.pop(n, None)
    write_entries(jar, order, data)
    return len(removed), len(order)


def jar_glslang_present(jar):
    _o, data = read_entries(jar)
    return [n for n in JAR_GLSLANG_NATIVE if n in data]


def main():
    check_only = "--check" in sys.argv

    # ---- 1. ★ [SHADER-SIGBUS] Frameworks 自检（唯一合法落点；缺一即真机照样报错）----
    fw_bad = fw_glslang_check(verbose=True)
    if fw_bad:
        print("[glslang] FATAL: Frameworks glslang problem: %s" % fw_bad)
        print("[glslang]        (加载方是 System.loadLibrary(\"glslang\")，java.library.path=<app>/Frameworks)")
        return 2

    # ---- 2. ★ [SHADER-BLAZE3D-GROUP] blaze3d【整组】源字节 ----
    group = load_group()
    if group is None:
        return 2
    n_bytes = sum(len(b) for b in group.values())
    print("[glslang] blaze3d GROUP: %d class(es), %d B (source=client-26.2.jar, manifest=%s)"
          % (len(group), n_bytes, os.path.basename(GLSLANG_GROUP_MANIFEST)))

    if check_only:
        n_ent = len(GLSLANG_IFACE_PREFIXES) * len(group)
        for jar in present_jars():
            _o, data = read_entries(jar)
            pres = [n for n in JAR_GLSLANG_NATIVE if n in data]
            n_cls = {}
            for pfx in GLSLANG_IFACE_PREFIXES:
                n_cls[pfx] = sum(1 for nm in group
                                 if (pfx + nm + ".class") in data)
            print("[check] %s : entries=%d" % (os.path.basename(jar), len(data)))
            # ★ [SHADER-SIGBUS] 期望：jar 内【没有】glslang native
            print("[check]   glslang-native-in-jar: %s   (want: NONE)"
                  % ("NONE ✓" if not pres else ("PRESENT ✗ %s" % pres)))
            for pfx in GLSLANG_IFACE_PREFIXES:
                print("[check]   blaze3d-group @ %-16s %d/%d"
                      % (pfx or "<jar-root>", n_cls[pfx], len(group)))
            # ★ [BLAZE3D-ROOT-SHADOW] jar 根必须【没有】blaze3d 镜像
            root_shadow = [n for n in data if n.startswith(ROOT_BLAZE3D_PREFIX)
                           and n.endswith(".class")]
            print("[check]   blaze3d @ jar-root: %s   (want: NONE)"
                  % ("NONE ✓" if not root_shadow
                     else ("PRESENT ✗ %d" % len(root_shadow))))
            if os.path.basename(jar) == os.path.basename(AGENT_JAR):
                print("[check]   want: %d entry total (%d loc x %d class)"
                      % (n_ent, len(GLSLANG_IFACE_PREFIXES), len(group)))
        return 0

    # ---- 3. agent jar：注入 blaze3d【整组】镜像(两个类集前缀) + ★ 移除 jar 根镜像 + 移除 glslang native ----
    order, data = read_entries(AGENT_JAR)
    # ★ [BLAZE3D-ROOT-SHADOW] 先清掉历史遗留的 jar 根 blaze3d 镜像(幂等, 消除 classpath 影子)
    root_removed = [n for n in order if n.startswith(ROOT_BLAZE3D_PREFIX) and n.endswith(".class")]
    if root_removed:
        order = [n for n in order if n not in root_removed]
        for n in root_removed:
            data.pop(n, None)
    added = replaced = 0
    targets = {}
    for c, b in group.items():
        # ★ [SHADER-BLAZE3D-GROUP] 镜像到两处类集前缀：classes262iris/ + classes262/
        for pfx in GLSLANG_IFACE_PREFIXES:
            targets[pfx + c + ".class"] = b
    for name, blob in targets.items():
        if name in data:
            if data[name] != blob:
                data[name] = blob
                replaced += 1
        else:
            data[name] = blob
            order.append(name)
            added += 1
    # ★ [SHADER-SIGBUS] 移除 glslang native（本轮真修）
    removed = [n for n in order if n in JAR_GLSLANG_NATIVE]
    if removed:
        order = [n for n in order if n not in JAR_GLSLANG_NATIVE]
        for n in removed:
            data.pop(n, None)
    write_entries(AGENT_JAR, order, data)
    print("[glslang] agent jar: +%d group entry, %d replaced, -%d glslang-native %s, "
          "-%d jar-root blaze3d (shadow), entries=%d"
          % (added, replaced, len(removed), removed or "(none)", len(root_removed), len(order)))

    # ---- 4. mod jar（★ [FABRIC-AGENT] 可选）：★ [SHADER-SIGBUS] 只移除 glslang native（不注入任何类）----
    if os.path.isfile(MOD_JAR):
        n_rem, n_left = strip_jar_glslang(MOD_JAR)
        print("[glslang] mod jar  : -%d glslang-native, entries=%d" % (n_rem, n_left))
    else:
        print("[glslang] mod jar  : absent -- skip (agent-only channel)")

    # ---- 5. ★ 静态自检（打包与资源名一致 = 硬约束）----
    ok = True
    for jar in present_jars():
        pres = jar_glslang_present(jar)
        print("[glslang] VERIFY %-40s glslang-native-in-jar = %s"
              % (os.path.basename(jar), pres or "NONE ✓"))
        if pres:
            print("[glslang] FATAL: %s still carries %s "
                  "(会被解包成未签名副本 ⇒ dlopen 期 SIGBUS)" % (os.path.basename(jar), pres))
            ok = False
    order, data = read_entries(AGENT_JAR)
    # ★ [SHADER-BLAZE3D-GROUP] 数量断言：每个镜像位置必须恰好 len(group) 条，且逐字节一致
    n_expect = len(GLSLANG_IFACE_PREFIXES) * len(group)
    bad = []
    for pfx in GLSLANG_IFACE_PREFIXES:
        for c, b in group.items():
            name = pfx + c + ".class"
            if data.get(name) != b:
                bad.append(name)
    # 旧 3 名字的"位置计数"式核对（防误删/漏删）：blaze3d 条目总数必须 == 期望
    n_mirror = sum(1 for n in data if any(n == (pfx + c + ".class")
                                          for pfx in GLSLANG_IFACE_PREFIXES for c in group))
    if bad:
        print("[glslang] FATAL: blaze3d group mirror mismatch (%d): %s" % (len(bad), bad[:10]))
        ok = False
    elif n_mirror != n_expect:
        print("[glslang] FATAL: blaze3d group mirror count %d != expected %d" % (n_mirror, n_expect))
        ok = False
    else:
        print("[glslang] VERIFY blaze3d GROUP: %d location(s) x %d class(es) = %d entry, "
              "all byte-identical + count-asserted" % (len(GLSLANG_IFACE_PREFIXES), len(group), n_expect))
    # ★ [BLAZE3D-ROOT-SHADOW] 硬断言: jar 根不得残留任何 blaze3d 镜像
    root_shadow = [n for n in data if n.startswith(ROOT_BLAZE3D_PREFIX) and n.endswith(".class")]
    if root_shadow:
        print("[glslang] FATAL: jar-root blaze3d shadow still present (%d): %s"
              % (len(root_shadow), root_shadow[:10]))
        ok = False
    else:
        print("[glslang] VERIFY blaze3d @ jar-root: NONE ✓ (no app-loader shadow)")
    if not ok:
        return 2
    print("[glslang] VERIFY glslang route: Frameworks-only "
          "(System.loadLibrary(\"glslang\") → <app>/Frameworks/libglslang.dylib, 随包签名)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
