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
        if entry.endswith(".xcassets"):
            # 归一化为 POSIX 分隔符：Windows 下 os.path.join 会产出反斜杠，
            # 后续 group_tree() 按 "/" 切分，反斜杠会让所有路径落进空路径孤儿组
            resources.append(os.path.join("Assets", entry).replace(os.sep, "/"))
    return resources


def scan_sources():
    """扫描所有需要编译的源码。

    **两个来源**：
      · Air2/     —— 我们的应用层（UI、Core、App）
      · Air2/Player/  —— 移植自 Air1 的 pojav 启动核心与原生层

    之前只扫 Air2/，导致 Air2/Player 下 549 个源文件根本没进工程 ——
    这也是为什么打出来的 IPA 只有 711KB（只有 UI 代码）。

    **排除规则**：
      · Libraries/external/   —— 第三方库，由 CMake 单独编译
                               或作为 submodule 引入
      · Air2/Player/shader_glslang/ —— 着色器资源，不是编译单元
      · Assets/runtime/  —— 资源，走 Resources 阶段
    """
    impl, headers = [], []

    # Air2/Player 只编译 pojav 启动核心的 4 个目录。
    # 其余（external 是第三方、resources/shader_glslang 是资源）
    # 不参与编译，resources 由打包阶段的 Resources 处理。
    NATIVES_CORE_DIRS = (
        "Air2/Player/Context/",
        "Air2/Player/Renderer/",
        "Air2/Player/Input/",
        "Air2/Player/Support/",
    )

    for base_name in ("Air2", "Air2/Player"):
        base = os.path.join(ROOT, base_name)
        if not os.path.isdir(base):
            continue

        for dirpath, dirnames, files in os.walk(base):
            rel_dir = os.path.relpath(dirpath, ROOT).replace(os.sep, "/")

            # Air2/Player 只保留核心的 4 个目录
            if base_name == "Air2/Player":
                keep = any(rel_dir == d.rstrip("/") or rel_dir.startswith(d)
                           for d in NATIVES_CORE_DIRS)
                if not keep:
                    dirnames[:] = []
                    continue

            for f in sorted(files):
                rel = os.path.relpath(os.path.join(dirpath, f), ROOT).replace(os.sep, "/")
                if f.endswith(".m") or f.endswith(".mm"):
                    impl.append(rel)
                elif f.endswith(".h"):
                    headers.append(rel)
                elif f.endswith(".c"):
                    # Air2/Player 里有 .c（shim、sandbox 等），要编进来
                    if base_name == "Air2/Player":
                        impl.append(rel)

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
        ftype = "folder.assetcatalog" if name.endswith(".xcassets") else "file"
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
    app_group = uid("group", "Air2")

    # 根组在 PBXGroup 段的【最后】输出 —— 它的 children 需要
    # 先算出所有顶层目录（Air2 / Air2/Player / ...），不能写死。
    # 这里只留下 id 定义，实际输出见下方 main_group_placeholder
    # 的说明。

    add(f"\t\t{products_group} /* Products */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{app_ref} /* {PROJECT_NAME}.app */,")
    add("\t\t\t);")
    add("\t\t\tname = Products;")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")
    add("")

    # Air2 组：按真实目录层级嵌套。
    #
    # 关键：PBXGroup 的 path 是相对父组的。
    #
    # 之前把【所有顶层目录】都当成 Air2 的子组 ——
    # 于是 Air2/Player 变成了 Air2/Air2/Player，而它实际在根目录下。
    # Xcode 拼出来的路径是 /repo/Air2/vk_bridge.m（少了一层 Air2/Player），
    # 报 "Build input file cannot be found"。
    #
    # 正确结构：
    #   根组
    #     ├── Air2     (path=Air2)      ← 应用层
    #     ├── Air2/Player  (path=Air2/Player)   ← 原生层
    #     └── Products
    groups = group_tree(all_files)

    # 顶层目录（无 "/" 的组名）
    TOP_LEVEL = sorted({g for g in groups if "/" not in g})
    if not TOP_LEVEL:
        TOP_LEVEL = ["Air2"]

    def parent_group(g):
        """返回 g 的父组名；顶层目录返回 None（挂到根组）"""
        if "/" not in g:
            return None
        return g.rsplit("/", 1)[0]

    def child_groups(g):
        """g 的直接子目录组"""
        out = []
        prefix = g + "/"
        for g2 in sorted(groups.keys()):
            if g2.startswith(prefix) and "/" not in g2[len(prefix):]:
                out.append(g2)
        return out

    all_dirs = sorted(groups.keys(), key=lambda x: (x.count("/"), x))
    dir_group_ids = {g: uid("group", g) for g in all_dirs}

    # 逐目录输出组定义
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

    # ---- 根组 ----
    # children = 所有顶层目录 + Products。
    # 顶层目录是动态的（Air2、Air2/Player，将来可能还有别的），
    # 写死会导致新增目录时文件路径解析错。
    add(f"\t\t{main_group} = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for top in TOP_LEVEL:
        add(f"\t\t\t\t{dir_group_ids[top]} /* {top} */,")
    add(f"\t\t\t\t{products_group} /* Products */,")
    add("\t\t\t);")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")
    add("")

    add("/* End PBXGroup section */")
    add("")

    # ---------------- PBXNativeTarget ----------------
    target = uid("target", PROJECT_NAME)
    sources_phase = uid("phase", "sources")
    resources_phase = uid("phase", "resources")
    project_obj = uid("project", PROJECT_NAME)

    add("/* Begin PBXNativeTarget section */")
    add(f"\t\t{target} /* {PROJECT_NAME} */ = {{")
    add("\t\t\tisa = PBXNativeTarget;")
    add(f"\t\t\tbuildConfigurationList = {uid('cfglist', 'target')} /* Build configuration list for PBXNativeTarget \"{PROJECT_NAME}\" */;")
    add("\t\t\tbuildPhases = (")
    add(f"\t\t\t\t{sources_phase} /* Sources */,")
    add(f"\t\t\t\t{frameworks_phase} /* Frameworks */,")
    add(f"\t\t\t\t{resources_phase} /* Resources */,")
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
                # AppIcon 尚未设计 —— 当前 Assets 里没有图标集。
                # 不设 ASSETCATALOG_COMPILER_APPICON_NAME，actool 就不会
                # 强制要求图标，编译能过；装到设备上显示系统默认图标。
                # 设计好图标后放进 Assets/Images.xcassets/AppIcon.appiconset，
                # 并在这里加回这一行。
                "CODE_SIGN_STYLE": "Automatic",
                "CURRENT_PROJECT_VERSION": BUILD_VERSION,
                "GENERATE_INFOPLIST_FILE": "NO",
                # natives 层引用第三方头，路径写法有四套：
                #   · "Libraries/external/mach/mach_excServer.h" —— 相对仓库根
                #   · "external/fishhook/fishhook.h"           —— 相对 Libraries/
                #   · <EGL/egl.h>、<GL/osmesa.h>               —— 需要 mesa 目录本身
                #   · "glslang/Include/...h"                   —— 需要 MobileGlues 的 include 根
                # 搜索路径取自 cmake/CMakeLists.txt 的 include_directories。
                # 之前工程里没写，Air2/Player 一直编不过。
                "HEADER_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"$(SRCROOT)",\n\t\t\t\t\t"$(SRCROOT)/Libraries",\n\t\t\t\t\t"$(SRCROOT)/Libraries/external/mesa",\n\t\t\t\t\t"$(SRCROOT)/Libraries/external/MobileGlues/src/main/cpp/include",\n\t\t\t\t)',
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
