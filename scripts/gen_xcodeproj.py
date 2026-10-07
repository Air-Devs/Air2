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
DEPLOYMENT_TARGET = "15.0"
MARKETING_VERSION = "0.1.0"
BUILD_VERSION = "1"


def uid(*parts):
    """由内容生成稳定的 24 位十六进制 UUID。

    用确定性哈希而不是随机数：重新生成工程时 UUID 不变，
    git diff 才不会因为 UUID 抖动而炸开。
    """
    h = hashlib.sha1("|".join(parts).encode()).hexdigest()
    return h[:24].upper()


def scan_sources():
    """扫描 Air2/ 下的所有编译单元与头文件"""
    impl, headers = [], []
    base = os.path.join(ROOT, "Air2")
    for dirpath, _, files in os.walk(base):
        for f in sorted(files):
            if f.endswith(".m") or f.endswith(".mm"):
                impl.append(os.path.relpath(os.path.join(dirpath, f), ROOT))
            elif f.endswith(".h"):
                headers.append(os.path.relpath(os.path.join(dirpath, f), ROOT))
    return sorted(impl), sorted(headers)


def group_tree(paths):
    """把平铺的路径组织成 {group: [files]} 的字典"""
    groups = {}
    for p in paths:
        parts = p.split("/")
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

    add(f"\t\t{main_group} = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{app_group} /* {PROJECT_NAME} */,")
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

    # Air2 组：按目录建子组
    groups = group_tree(all_files)
    sub_group_ids = {}
    for g in sorted(groups.keys()):
        sub_group_ids[g] = uid("group", g)

    add(f"\t\t{app_group} /* {PROJECT_NAME} */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    # 顶层直接子项 + 子组
    top_level_files = groups.get("Air2", [])
    for f in top_level_files:
        add(f"\t\t\t\t{uid('fileref', f)} /* {os.path.basename(f)} */,")
    add(f"\t\t\t\t{plist_ref} /* Info.plist */,")
    # 子组按目录层级排序，先浅后深
    for g in sorted(sub_group_ids.keys(), key=lambda x: (x.count("/"), x)):
        if g == "Air2":
            continue
        add(f"\t\t\t\t{sub_group_ids[g]} /* {os.path.basename(g)} */,")
    add("\t\t\t);")
    add(f"\t\t\tpath = {PROJECT_NAME};")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")
    add("")

    # 每个子组
    for g in sorted(sub_group_ids.keys(), key=lambda x: (x.count("/"), x)):
        if g == "Air2":
            continue
        add(f"\t\t{sub_group_ids[g]} /* {os.path.basename(g)} */ = {{")
        add("\t\t\tisa = PBXGroup;")
        add("\t\t\tchildren = (")
        # 目录内的文件
        for f in groups.get(g, []):
            add(f"\t\t\t\t{uid('fileref', f)} /* {os.path.basename(f)} */,")
        # 直接子目录
        prefix = g + "/"
        for g2 in sorted(sub_group_ids.keys()):
            if g2.startswith(prefix) and g2.count("/") == g.count("/") + 1:
                add(f"\t\t\t\t{sub_group_ids[g2]} /* {os.path.basename(g2)} */,")
        add("\t\t\t);")
        add(f"\t\t\tpath = {os.path.basename(g)};")
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
    add("/* Begin PBXResourcesBuildPhase section */")
    add(f"\t\t{resources_phase} /* Resources */ = {{")
    add("\t\t\tisa = PBXResourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
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
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "CODE_SIGN_STYLE": "Automatic",
                "CURRENT_PROJECT_VERSION": BUILD_VERSION,
                "GENERATE_INFOPLIST_FILE": "NO",
                "INFOPLIST_FILE": "Air2/Info.plist",
                "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)',
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
