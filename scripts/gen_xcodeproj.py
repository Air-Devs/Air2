#!/usr/bin/env python3
"""
生成 Air2.xcodeproj/project.pbxproj

为什么不手写：pbxproj 是 Xcode 的内部格式，结构严格、UUID 到处引用，
手写几乎必错且难排查。用脚本生成，源文件列表从磁盘扫描，
新增文件不用手动改工程。

用法：
    python3 scripts/gen_xcodeproj.py
"""
import os
import sys
import hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_NAME = "Air2"
BUNDLE_ID = "dev.airdevs.air2"
DEPLOYMENT_TARGET = "14.0"
MARKETING_VERSION = "0.1.0"
BUILD_VERSION = "1"

# 参与编译的源码根目录。原脚本只扫 Air2/，于是 Natives/ 下的自研启动链
# （a2_launch / a2_argbuilder / A2JVMContext …）永远进不了 target ⇒ 编了也不进包。
# 现在两端都扫：Air2（应用主体）与 Natives（原生层）——同一 target、同一 Sources 阶段。
SOURCE_ROOTS = ("Air2", "Natives")

# 原生层的头搜索路径：Natives 代码按「裸文件名」互相引用
# （`#include "jni.h"`、`#import "a2_log.h"`、`#import "A2JITEnvironment.h"`），
# 而这些文件分处 Natives/Context 与 Natives/Support ⇒ 需要把各目录加入搜索路径。
NATIVES_INCLUDE_DIRS = [
    "$(SRCROOT)/Natives",
    "$(SRCROOT)/Natives/Context",
    "$(SRCROOT)/Natives/Support",
    # Natives/Renderer：a2_renderer.h 被 Bridge 的 A2LaunchRunner.m 以裸文件名引用（[RENDER-WIRE]）。
    "$(SRCROOT)/Natives/Renderer",
    # Natives/Input：自研 GLFW 窗口/事件/输入层（[A2-OWNGLFW-NATIVE-1]）。
    # a2_own_glfw_bridge.m 以裸文件名 #include "a2_glfw_window.h"，须能被解析。
    "$(SRCROOT)/Natives/Input",
]

# ----------------------------------------------------------------------------
# Java 启动核心（JavaApp/）随包阶段
# ----------------------------------------------------------------------------
# 为什么是「脚本阶段」而不是把 jar 列进 Resources 阶段：
#   jar 是构建产物，生成 pbxproj 时它在磁盘上还不存在，而 collect_resources() 是按
#   磁盘现状扫描的 —— 列进去会让 verify_pbxproj.py 判「工程声明路径在磁盘上不存在」。
#   脚本阶段既能把 jar 编出来又能拷进 bundle，且不依赖生成时的文件存在性。
# 拷贝目标：<Air2.app>/Java/{air2-launch.jar, air2-lwjgl-patch.jar}（IPA 内为 Payload/Air2.app/Java/…）。
JAVA_PHASE_NAME = "Build Java Launch Core"
JAVA_JAR_NAME = "air2-launch.jar"
# ★决策（org.lwjgl.* 补丁类归属）★：补丁类在 Java 侧、独立 jar，随包到同一目录；
# Bridge 组 classpath 时把它放在最前（先于 libs/lwjgl-<ver>/*）。见 docs/ARCHITECTURE.md [LWJGL-PATCH]。
JAVA_PATCH_JAR_NAME = "air2-lwjgl-patch.jar"
JAVA_PHASE_SCRIPT = (
    "set -e\n"
    "cd \"$SRCROOT/JavaApp\"\n"
    "BOOT=$(/usr/libexec/java_home -v 1.8 2>/dev/null || true)\n"
    "make -s all BOOTJDK=\"$BOOT\"\n"          # all ⇒ air2-launch.jar + air2-lwjgl-patch.jar
    "make -s verify BOOTJDK=\"$BOOT\"\n"
    "make -s verify-lwjgl BOOTJDK=\"$BOOT\"\n"
    # CONTENTS_FOLDER_PATH 在 -target 构建下可能为空 ⇒ 显式兜底，避免把 jar 写到
    # BUILT_PRODUCTS_DIR 根上（那样 IPA 里没有它，且构建不报错 —— 静默失败最难查）。
    "CFP=\"$CONTENTS_FOLDER_PATH\"\n"
    "[ -n \"$CFP\" ] || CFP=\"Air2.app\"\n"
    "DEST=\"$BUILT_PRODUCTS_DIR/$CFP/Java\"\n"
    "mkdir -p \"$DEST\"\n"
    "cp -f build/" + JAVA_JAR_NAME + " \"$DEST/\"\n"
    "test -f \"$DEST/" + JAVA_JAR_NAME + "\"\n"
    "cp -f build/" + JAVA_PATCH_JAR_NAME + " \"$DEST/\"\n"
    "test -f \"$DEST/" + JAVA_PATCH_JAR_NAME + "\"\n"
    "echo \"note: Java 启动核心 -> $DEST/" + JAVA_JAR_NAME + "\"\n"
    "echo \"note: LWJGL 补丁类 -> $DEST/" + JAVA_PATCH_JAR_NAME + "\"\n"
)


def pbx_escape_script(text):
    """转义 pbxproj 里 shellScript 的字符串字面量（反斜杠、引号、换行、制表）。"""
    return (text.replace("\\", "\\\\")
                .replace('"', '\\"')
                .replace("\n", "\\n")
                .replace("\t", "\\t"))

# ----------------------------------------------------------------------------
# 运行时随包阶段（★防石山：只搬「启动必需 + 必要渲染器」★）
# ----------------------------------------------------------------------------
# 为什么不走 Resources 阶段 / Copy Files 阶段：
#   · 启动链对「目标子目录」有硬要求，Resources 阶段表达不了（它只会把文件平铺到 app 根）：
#       - 渲染器 + LWJGL native → <App>/Frameworks   （-Djava.library.path 指向它，
#                                                     Natives/Context/a2_resourcepaths.m:117）
#       - LWJGL jar            → <App>/libs/lwjgl-<ver>（a2_resourcepaths.m 的 <lwjglDir>/* 尾项）
#       - JVM 运行时           → <App>/java_runtimes/<ver>（a2_vmloader.m:15-27 解析
#                                                     <javaHome>/lib/server/libjvm.dylib）
#   · 且 JRE 体量 ~119 MB，走 Xcode 资源管线得不偿失。
#   ⇒ 用一个独立脚本阶段显式 cp（与已有「Build Java Launch Core」同款做法）。
#   ★本函数与 collect_resources() / scan_sources() 完全解耦★：只新增，不改公共段落。
#
# 源：
#   · Libraries/Renderers/*.dylib 与 Libraries/Frameworks/lib* —— 随仓（BSD-3 / GPL-3，见 docs/DEPENDENCIES.md）
#   · Libraries/Jars/lwjgl-*/      —— 随仓（BSD-3）
#   · Libraries/java_runtimes/     —— ★不入 git★（119 MB「防石山」）；由 scripts/stage_runtime.sh
#                                     从本地 Amethyst 构建产物就位（★不上云★）。
# 缺失处理：JRE 缺失只告警不失败（同树其它任务可能未就位；本单的包内断言负责兜底）。
RUNTIME_PHASE_NAME = "Stage Runtime Bundle"


def runtime_stage_script():
    """生成「运行时随包」脚本阶段的 shell 脚本（目标路径与启动链约定一一对应）。"""
    lines = [
        "set -e",
        'APP="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH"',
        'LIB="$SRCROOT/Libraries"',
        'mkdir -p "$APP/Frameworks" "$APP/libs" "$APP/java_runtimes"',
        # ① 渲染器 + LWJGL native → <App>/Frameworks（= -Djava.library.path）
        'for f in "$LIB"/Renderers/*.dylib "$LIB"/Frameworks/lib*; do',
        '  [ -f "$f" ] || continue',
        '  cp -f "$f" "$APP/Frameworks/"',
        'done',
        # ② LWJGL jar → <App>/libs/lwjgl-<ver>/
        'for d in "$LIB"/Jars/lwjgl-*; do',
        '  [ -d "$d" ] || continue',
        '  mkdir -p "$APP/libs/$(basename "$d")"',
        '  cp -f "$d"/*.jar "$APP/libs/$(basename "$d")/"',
        'done',
        # ③ JVM 运行时 → <App>/java_runtimes/<ver>/
        'if [ -d "$LIB/java_runtimes" ]; then',
        '  for r in "$LIB"/java_runtimes/*; do',
        '    [ -d "$r" ] || continue',
        '    rm -rf "$APP/java_runtimes/$(basename "$r")"',
        '    cp -R "$r" "$APP/java_runtimes/$(basename "$r")"',
        '  done',
        'else',
        '  echo "warning: Libraries/java_runtimes 缺失 —— 先跑 scripts/stage_runtime.sh 再出包" >&2',
        'fi',
        'echo "note: runtime bundle -> $APP/{Frameworks,libs,java_runtimes}"',
    ]
    return "\n".join(lines) + "\n"


# libterracotta 是「可选二进制依赖」（工程内无 libterracotta.xcframework）。
# A2Multiplayer.m 以 __attribute__((weak)) 声明其 C ABI，但现代 ld64 对
# 「任何库都不提供」的符号即使声明为 weak 也不放行 ⇒ 链接期须显式 -Wl,-U,<sym>
# 放行未定义符号；运行期缺库时这些函数指针为 NULL，
# [A2Multiplayer checkAvailable] 返回 NO（UI 如实显示「联机组件未就绪」）。
TERRACOTTA_UNDEFINED_SYMS = [
    "_terracotta_ios_start",
    "_terracotta_ios_get_state",
    "_terracotta_ios_set_waiting",
    "_terracotta_ios_set_scanning",
    "_terracotta_ios_start_host_with_port",
    "_terracotta_ios_set_guesting",
    "_terracotta_ios_verify_room_code",
    "_terracotta_ios_get_metadata",
    "_terracotta_ios_free_string",
]


def terracotta_ldflags():
    items = ",\n\t\t\t\t\t".join('"-Wl,-U,%s"' % s for s in TERRACOTTA_UNDEFINED_SYMS)
    return "(\n\t\t\t\t\t" + items + ",\n\t\t\t\t)"


def uid(*parts):
    """由内容生成稳定的 24 位十六进制 UUID。

    用确定性哈希而不是随机数：重新生成工程时 UUID 不变，
    git diff 才不会因为 UUID 抖动而炸开。
    """
    h = hashlib.sha1("|".join(parts).encode()).hexdigest()
    return h[:24].upper()


def collect_resources():
    """
    收集需要打进 app 包的资源。

    当前只处理 Assets/ 下的 .xcassets（图标、颜色集）。
    本地化文件（.lproj）将来也在这里收集。
    """
    resources = []
    assets_dir = os.path.join(ROOT, "Assets")
    if not os.path.isdir(assets_dir):
        return resources
    for entry in sorted(os.listdir(assets_dir)):
        if entry.startswith("."):
            continue
        full = os.path.join(assets_dir, entry)
        # 资源目录（.xcassets 资产目录 / .lproj 本地化）或散落的资源文件。
        # 后者用于 AmethystJIT69.js（自包含 JIT 脚本，必须随包下发）。
        if entry.endswith(".xcassets") or entry.endswith(".lproj") or os.path.isfile(full):
            # 归一化为 POSIX 分隔符：Windows 下 os.path.join 会产出反斜杠，
            # 后续 group_tree() 按 "/" 切分，反斜杠会让所有路径落进空路径孤儿组
            resources.append(os.path.join("Assets", entry).replace(os.sep, "/"))
    return resources


def scan_sources():
    """扫描 SOURCE_ROOTS（Air2/ 与 Natives/）下的所有编译单元与头文件"""
    impl, headers = [], []
    for top in SOURCE_ROOTS:
        base = os.path.join(ROOT, top)
        if not os.path.isdir(base):
            continue
        for dirpath, _, files in os.walk(base):
            for f in sorted(files):
                if f.endswith(".m") or f.endswith(".mm"):
                    impl.append(os.path.relpath(os.path.join(dirpath, f), ROOT).replace(os.sep, "/"))
                elif f.endswith(".h"):
                    headers.append(os.path.relpath(os.path.join(dirpath, f), ROOT).replace(os.sep, "/"))
    return sorted(impl), sorted(headers)


def group_tree(paths):
    """把平铺的文件路径展开成完整的目录集合。

    注意：不能只收集「有文件的目录」。像 Air2/Core/Path 这种，
    它的父目录 Air2/Core 本身可能没有文件，但必须也建出组来，
    否则 Path 组会成为孤立的、没有被引用的对象，
    Xcode 也找不到它的相对路径。
    """
    groups = {}
    for p in paths:
        parts = p.split("/")
        # 逐级补出所有祖先目录（不含文件名）
        for i in range(1, len(parts)):
            d = "/".join(parts[:i])
            groups.setdefault(d, [])
        # 文件挂到它所在的目录
        group = "/".join(parts[:-1])
        groups.setdefault(group, []).append(p)
    return groups


def build():
    impl_files, header_files = scan_sources()
    all_files = impl_files + header_files

    if not impl_files:
        print("错误：没有找到任何 .m 源文件", file=sys.stderr)
        return 1

    L = []
    add = L.append

    # ---------------- 头部 ----------------
    add("// !$*UTF8*$!")
    add("{")
    add("\tarchiveVersion = 1;")
    add("\tclasses = {")
    add("\t};")
    add("\tobjectVersion = 56;")
    add("\tobjects = {")
    add("")

    # ---------------- PBXBuildFile ----------------
    add("/* Begin PBXBuildFile section */")
    for f in impl_files:
        u = uid("buildfile", f)
        name = os.path.basename(f)
        add(f"\t\t{u} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {uid('fileref', f)} /* {name} */; }};")
    # 资源文件也要有 BuildFile 条目，否则只在 Resources 阶段列出而不会被打包
    for rpath in collect_resources():
        u = uid("buildfile", rpath)
        name = os.path.basename(rpath)
        add(f"\t\t{u} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {uid('fileref', rpath)} /* {name} */; }};")
    add("/* End PBXBuildFile section */")
    add("")

    # ---------------- PBXFileReference ----------------
    add("/* Begin PBXFileReference section */")

    app_ref = uid("fileref", "PRODUCT", PROJECT_NAME)
    add(f"\t\t{app_ref} /* {PROJECT_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {PROJECT_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};")

    plist_ref = uid("fileref", "Info.plist")
    add(f"\t\t{plist_ref} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")

    for f in all_files:
        u = uid("fileref", f)
        name = os.path.basename(f)
        if f.endswith(".h"):
            ftype = "sourcecode.c.h"
        else:
            ftype = "sourcecode.c.objc"
        # path 一律加引号：文件名可能含 + - # 等字符
        #（如 A2LauncherViewController+Actions.m），
        # 不加引号会让 Xcode 的旧式 plist 解析器在遇到特殊字符时中断
        add(f"\t\t{u} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = \"{name}\"; sourceTree = \"<group>\"; }};")

    # 资源文件的引用（.xcassets 用 folder.assetcatalog 类型，Xcode 才会编译成 Assets.car）
    for rpath in collect_resources():
        u = uid("fileref", rpath)
        name = os.path.basename(rpath)
        if name.endswith(".xcassets"):
            ftype = "folder.assetcatalog"
        elif name.endswith(".js"):
            ftype = "sourcecode.javascript"
        else:
            ftype = "file"
        add(f"\t\t{u} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = \"{rpath}\"; sourceTree = \"<group>\"; }};")
    add("/* End PBXFileReference section */")
    add("")

    # ---------------- PBXFrameworksBuildPhase ----------------
    frameworks_phase = uid("phase", "frameworks")
    add("/* Begin PBXFrameworksBuildPhase section */")
    add(f"\t\t{frameworks_phase} /* Frameworks */ = {{")
    add("\t\t\tisa = PBXFrameworksBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXFrameworksBuildPhase section */")
    add("")

    # ---------------- PBXGroup ----------------
    add("/* Begin PBXGroup section */")

    main_group = uid("group", "main")
    products_group = uid("group", "Products")

    # 目录组：按真实目录层级嵌套。Air2/ 与 Natives/ 各自一棵子树，都挂在主组下。
    groups = group_tree(all_files)
    all_dirs = sorted(set(list(groups.keys()) + list(SOURCE_ROOTS)), key=lambda x: (x.count("/"), x))
    dir_group_ids = {g: uid("group", g) for g in all_dirs}

    add(f"\t\t{main_group} = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for top in SOURCE_ROOTS:
        add(f"\t\t\t\t{dir_group_ids[top]} /* {top} */,")
    add(f"\t\t\t\t{products_group} /* Products */,")
    add("\t\t\t);")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")
    add("")

    add(f"\t\t{products_group} /* Products */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{app_ref} /* {PROJECT_NAME}.app */,")
    add("\t\t\t);")
    add("\t\t\tname = Products;")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")
    add("")

    # 目录组：按真实目录层级嵌套。
    #
    # 关键：PBXGroup 的 path 是相对父组的。之前我把所有目录都平铺挂在
    # Air2 组下、path 只写目录名，Xcode 拼出来是 Air2/Version/，
    # 而实际文件在 Air2/UI/Screens/Version/ —— 于是报
    # "Build input file cannot be found"。
    # 必须按真实层级逐层嵌套，每层 path 只写自己那一级。
    # （groups / all_dirs / dir_group_ids 已在主组处算好，Air2 与 Natives 各自一棵子树。）

    def child_groups(g):
        """g 的直接子目录组"""
        out = []
        prefix = g + "/"
        for g2 in sorted(groups.keys()):
            if g2.startswith(prefix) and "/" not in g2[len(prefix):]:
                out.append(g2)
        return out

    for g in all_dirs:
        gid = dir_group_ids[g]
        name = os.path.basename(g)

        add(f"\t\t{gid} /* {name} */ = {{")
        add("\t\t\tisa = PBXGroup;")
        add("\t\t\tchildren = (")

        # 该目录下的文件
        for f in groups.get(g, []):
            add(f"\t\t\t\t{uid('fileref', f)} /* {os.path.basename(f)} */,")

        # Air2 根组额外挂 Info.plist
        if g == "Air2":
            add(f"\t\t\t\t{plist_ref} /* Info.plist */,")

        # 直接子目录组
        for cg in child_groups(g):
            cname = os.path.basename(cg)
            add(f"\t\t\t\t{dir_group_ids[cg]} /* {cname} */,")

        add("\t\t\t);")
        add(f"\t\t\tpath = {name};")
        add("\t\t\tsourceTree = \"<group>\";")
        add("\t\t};")
        add("")

    # Air2 根组额外挂 Products
    # （上面已输出，这里改用它作为主组的孩子）
    # 见下方 main_group 定义处

    add("/* End PBXGroup section */")
    add("")

    # ---------------- PBXNativeTarget ----------------
    target = uid("target", PROJECT_NAME)
    sources_phase = uid("phase", "sources")
    resources_phase = uid("phase", "resources")
    java_phase = uid("phase", "java-launch-core")
    runtime_phase = uid("phase", "runtime-stage")
    project_obj = uid("project", PROJECT_NAME)

    add("/* Begin PBXNativeTarget section */")
    add(f"\t\t{target} /* {PROJECT_NAME} */ = {{")
    add("\t\t\tisa = PBXNativeTarget;")
    add(f"\t\t\tbuildConfigurationList = {uid('cfglist', 'target')} /* Build configuration list for PBXNativeTarget \"{PROJECT_NAME}\" */;")
    add("\t\t\tbuildPhases = (")
    add(f"\t\t\t\t{sources_phase} /* Sources */,")
    add(f"\t\t\t\t{frameworks_phase} /* Frameworks */,")
    add(f"\t\t\t\t{resources_phase} /* Resources */,")
    add(f"\t\t\t\t{java_phase} /* {JAVA_PHASE_NAME} */,")
    add(f"\t\t\t\t{runtime_phase} /* {RUNTIME_PHASE_NAME} */,")
    add("\t\t\t);")
    add("\t\t\tbuildRules = (")
    add("\t\t\t);")
    add("\t\t\tdependencies = (")
    add("\t\t\t);")
    add(f"\t\t\tname = {PROJECT_NAME};")
    add(f"\t\t\tproductName = {PROJECT_NAME};")
    add(f"\t\t\tproductReference = {app_ref} /* {PROJECT_NAME}.app */;")
    add("\t\t\tproductType = \"com.apple.product-type.application\";")
    add("\t\t};")
    add("/* End PBXNativeTarget section */")
    add("")

    # ---------------- PBXProject ----------------
    add("/* Begin PBXProject section */")
    add(f"\t\t{project_obj} /* Project object */ = {{")
    add("\t\t\tisa = PBXProject;")
    add("\t\t\tattributes = {")
    add("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    add("\t\t\t\tLastUpgradeCheck = 1600;")
    add("\t\t\t\tTargetAttributes = {")
    add(f"\t\t\t\t\t{target} = {{")
    add("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    add("\t\t\t\t\t};")
    add("\t\t\t\t};")
    add("\t\t\t};")
    add(f"\t\t\tbuildConfigurationList = {uid('cfglist', 'project')} /* Build configuration list for PBXProject \"{PROJECT_NAME}\" */;")
    add("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    add("\t\t\tdevelopmentRegion = \"zh-Hans\";")
    add("\t\t\thasScannedForEncodings = 0;")
    add("\t\t\tknownRegions = (")
    add("\t\t\t\t\"zh-Hans\",")
    add("\t\t\t\ten,")
    add("\t\t\t\tBase,")
    add("\t\t\t);")
    add(f"\t\t\tmainGroup = {main_group};")
    add(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
    add("\t\t\tprojectDirPath = \"\";")
    add("\t\t\tprojectRoot = \"\";")
    add("\t\t\ttargets = (")
    add(f"\t\t\t\t{target} /* {PROJECT_NAME} */,")
    add("\t\t\t);")
    add("\t\t};")
    add("/* End PBXProject section */")
    add("")

    # ---------------- PBXResourcesBuildPhase ----------------
    # 收集 Assets/ 下的资源目录（.xcassets 与散落的 bundle 文件）。
    # 图标、本地化都在这里，不加入 Resources 阶段的话不会打进 app 包。
    resource_files = collect_resources()
    add("/* Begin PBXResourcesBuildPhase section */")
    add(f"\t\t{resources_phase} /* Resources */ = {{")
    add("\t\t\tisa = PBXResourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    for rpath in resource_files:
        add(f"\t\t\t\t{uid('buildfile', rpath)} /* {os.path.basename(rpath)} in Resources */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXResourcesBuildPhase section */")
    add("")

    # ---------------- PBXShellScriptBuildPhase ----------------
    # Java 启动核心：编 → 自证（jar 内不得有 Pojav/Boardwalk 类）→ 拷进 Air2.app/Java/。
    add("/* Begin PBXShellScriptBuildPhase section */")
    add(f"\t\t{java_phase} /* {JAVA_PHASE_NAME} */ = {{")
    add("\t\t\tisa = PBXShellScriptBuildPhase;")
    add("\t\t\talwaysOutOfDate = 1;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    add("\t\t\t);")
    add("\t\t\tinputPaths = (")
    add("\t\t\t);")
    add(f"\t\t\tname = \"{JAVA_PHASE_NAME}\";")
    add("\t\t\toutputPaths = (")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t\tshellPath = /bin/sh;")
    add(f"\t\t\tshellScript = \"{pbx_escape_script(JAVA_PHASE_SCRIPT)}\";")
    add("\t\t};")
    add("")
    # 运行时随包阶段：把 Libraries/ 下「启动必需 + 必要渲染器」放进 <App>/{Frameworks,libs,java_runtimes}。
    # ★独立函数 runtime_stage_script()，不改上面的 Java 阶段与任何公共段落。★
    add(f"\t\t{runtime_phase} /* {RUNTIME_PHASE_NAME} */ = {{")
    add("\t\t\tisa = PBXShellScriptBuildPhase;")
    add("\t\t\talwaysOutOfDate = 1;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    add("\t\t\t);")
    add("\t\t\tinputPaths = (")
    add("\t\t\t);")
    add(f"\t\t\tname = \"{RUNTIME_PHASE_NAME}\";")
    add("\t\t\toutputPaths = (")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t\tshellPath = /bin/sh;")
    add(f"\t\t\tshellScript = \"{pbx_escape_script(runtime_stage_script())}\";")
    add("\t\t};")
    add("/* End PBXShellScriptBuildPhase section */")
    add("")

    # ---------------- PBXSourcesBuildPhase ----------------
    add("/* Begin PBXSourcesBuildPhase section */")
    add(f"\t\t{sources_phase} /* Sources */ = {{")
    add("\t\t\tisa = PBXSourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    for f in impl_files:
        add(f"\t\t\t\t{uid('buildfile', f)} /* {os.path.basename(f)} in Sources */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXSourcesBuildPhase section */")
    add("")

    # ---------------- XCBuildConfiguration ----------------
    def common_settings(is_target):
        s = {}
        if is_target:
            s.update({
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "CODE_SIGN_STYLE": "Automatic",
                # ★ 保留原生层符号：Air2/Bridge 目前为空（启动链尚未接线），
                #   a2_launch_* / A2JVMContext / A2ArgBuilder 等**暂时没有调用者**，
                #   而 Xcode Release 默认 DEAD_CODE_STRIPPING=YES ⇒ 链接期把这些
                #   入口整段剥掉，产物包里扫不到（「编了也不进包」）。这里关闭
                #   dead_strip，确保原生层真正随包；待 Bridge 接线后即可恢复默认。
                "DEAD_CODE_STRIPPING": "NO",
                # ★ 脚本阶段要跑 make/javac 并把 jar 写进 .app ⇒ 必须关掉用户脚本沙箱，
                #   否则 Xcode 26 默认在沙箱里执行脚本，写 $BUILT_PRODUCTS_DIR 会被拒。
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                # 原生层头搜索路径（Natives 代码按裸文件名互相引用）。
                "HEADER_SEARCH_PATHS": "(\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t"
                    + ",\n\t\t\t\t\t".join('"%s"' % d for d in NATIVES_INCLUDE_DIRS)
                    + ",\n\t\t\t\t)",
                "CURRENT_PROJECT_VERSION": BUILD_VERSION,
                "GENERATE_INFOPLIST_FILE": "NO",
                "INFOPLIST_FILE": "Air2/Info.plist",
                "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)',
                "OTHER_LDFLAGS": terracotta_ldflags(),
                "MARKETING_VERSION": MARKETING_VERSION,
                "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "SWIFT_EMIT_LOC_STRINGS": "YES",
                "TARGETED_DEVICE_FAMILY": "1,2",
            })
        else:
            s.update({
                "ALWAYS_SEARCH_USER_PATHS": "NO",
                "CLANG_ANALYZER_NONNULL": "YES",
                "CLANG_ENABLE_MODULES": "YES",
                "CLANG_ENABLE_OBJC_ARC": "YES",
                "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
                "CLANG_WARN_BOOL_CONVERSION": "YES",
                "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
                "CLANG_WARN_EMPTY_BODY": "YES",
                "CLANG_WARN_ENUM_CONVERSION": "YES",
                "CLANG_WARN_INT_CONVERSION": "YES",
                "CLANG_WARN_UNREACHABLE_CODE": "YES",
                "COPY_PHASE_STRIP": "NO",
                "ENABLE_STRICT_OBJC_MSGSEND": "YES",
                "GCC_C_LANGUAGE_STANDARD": "gnu17",
                "GCC_NO_COMMON_BLOCKS": "YES",
                "GCC_WARN_UNDECLARED_SELECTOR": "YES",
                "GCC_WARN_UNINITIALIZED_AUTOS": "YES",
                "GCC_WARN_UNUSED_FUNCTION": "YES",
                "GCC_WARN_UNUSED_VARIABLE": "YES",
                "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
                "SDKROOT": "iphoneos",
            })
        return s

    def emit_config(uuid_str, name, settings, comment):
        add(f"\t\t{uuid_str} /* {comment} */ = {{")
        add("\t\t\tisa = XCBuildConfiguration;")
        add("\t\t\tbuildSettings = {")
        for k in sorted(settings.keys()):
            v = settings[k]
            # 字符串值一律加引号。旧式 plist 里不加引号的值
            # 遇到 $( ) @ / 等字符会解析失败。
            if isinstance(v, str) and not v.startswith(("(", '"')):
                v = '"' + v + '"'
            add(f"\t\t\t\t{k} = {v};")
        add("\t\t\t};")
        add(f"\t\t\tname = {name};")
        add("\t\t};")

    add("/* Begin XCBuildConfiguration section */")

    dbg_proj = uid("cfg", "project", "Debug")
    rel_proj = uid("cfg", "project", "Release")
    dbg_tgt = uid("cfg", "target", "Debug")
    rel_tgt = uid("cfg", "target", "Release")

    proj_dbg = common_settings(False)
    proj_dbg.update({
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": '(\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t)',
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
    })
    emit_config(dbg_proj, "Debug", proj_dbg, f'Build configuration list for PBXProject "{PROJECT_NAME}"')

    proj_rel = common_settings(False)
    proj_rel.update({
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "VALIDATE_PRODUCT": "YES",
    })
    emit_config(rel_proj, "Release", proj_rel, f'Build configuration list for PBXProject "{PROJECT_NAME}"')

    emit_config(dbg_tgt, "Debug", common_settings(True), f'Build configuration list for PBXNativeTarget "{PROJECT_NAME}"')
    emit_config(rel_tgt, "Release", common_settings(True), f'Build configuration list for PBXNativeTarget "{PROJECT_NAME}"')

    add("/* End XCBuildConfiguration section */")
    add("")

    # ---------------- XCConfigurationList ----------------
    add("/* Begin XCConfigurationList section */")
    add(f"\t\t{uid('cfglist', 'project')} /* Build configuration list for PBXProject \"{PROJECT_NAME}\" */ = {{")
    add("\t\t\tisa = XCConfigurationList;")
    add("\t\t\tbuildConfigurations = (")
    add(f"\t\t\t\t{dbg_proj} /* Debug */,")
    add(f"\t\t\t\t{rel_proj} /* Release */,")
    add("\t\t\t);")
    add("\t\t\tdefaultConfigurationIsVisible = 0;")
    add("\t\t\tdefaultConfigurationName = Release;")
    add("\t\t};")
    add("")
    add(f"\t\t{uid('cfglist', 'target')} /* Build configuration list for PBXNativeTarget \"{PROJECT_NAME}\" */ = {{")
    add("\t\t\tisa = XCConfigurationList;")
    add("\t\t\tbuildConfigurations = (")
    add(f"\t\t\t\t{dbg_tgt} /* Debug */,")
    add(f"\t\t\t\t{rel_tgt} /* Release */,")
    add("\t\t\t);")
    add("\t\t\tdefaultConfigurationIsVisible = 0;")
    add("\t\t\tdefaultConfigurationName = Release;")
    add("\t\t};")
    add("/* End XCConfigurationList section */")
    add("")

    # ---------------- 收尾 ----------------
    add("\t};")
    add(f"\trootObject = {project_obj} /* Project object */;")
    add("}")

    return "\n".join(L) + "\n"


def main():
    content = build()
    if isinstance(content, int):
        return content

    proj_dir = os.path.join(ROOT, f"{PROJECT_NAME}.xcodeproj")
    os.makedirs(proj_dir, exist_ok=True)

    out = os.path.join(proj_dir, "project.pbxproj")
    with open(out, "w") as f:
        f.write(content)

    # 回填 scheme 里的 target UUID。
    # CI 用 -scheme 构建，BlueprintIdentifier 必须与 pbxproj 里的
    # native target UUID 一致，否则 xcodebuild 报 "scheme not found"。
    scheme = os.path.join(proj_dir, "xcshareddata", "xcschemes", f"{PROJECT_NAME}.xcscheme")
    if os.path.exists(scheme):
        target_uuid = uid("target", PROJECT_NAME)
        s = open(scheme).read()
        s = s.replace("PLACEHOLDER_TARGET_UUID", target_uuid)
        open(scheme, "w").write(s)
        print(f"  已回填 scheme target UUID: {target_uuid}")

    impl, headers = scan_sources()
    print(f"已生成 {os.path.relpath(out, ROOT)}")
    print(f"  编译单元 {len(impl)} 个")
    print(f"  头文件   {len(headers)} 个")
    print(f"  Bundle ID: {BUNDLE_ID}")
    print(f"  部署目标:  iOS {DEPLOYMENT_TARGET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
