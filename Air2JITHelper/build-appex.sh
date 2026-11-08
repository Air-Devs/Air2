#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#  Air2 — 内建 JIT 的 helper appex（PlugIns/Air2JITHelper.appex）构建脚本
#  Copyright (C) 2026 Air-Devs and contributors.
# ----------------------------------------------------------------------------
#  ★为什么需要这个脚本★：Air2 没有 xcodeproj（CMake 构建），而 Xcode 的 appex
#  目标做的四件事（-e _NSExtensionMain / 扩展点 plist / @rpath 指向宿主 Frameworks /
#  Swift 运行时链接）CMake 不会替你做。这里把它们逐条手写出来，是可复现的单一配方：
#  cmake/Air2JITHelper.cmake 只是把这个脚本挂到 POST_BUILD 上，不另写一份。
#
#  ★谁调它★
#    cmake/Air2JITHelper.cmake 里 `a2_jit_helper_embed(<target>)` 的 POST_BUILD
#    （手工调试时也可直接跑，见 --help）
#
#  ★产物★
#    <out>/Air2JITHelper.appex/
#      ├── Air2JITHelper        可执行（arm64，入口 _NSExtensionMain）
#      ├── Info.plist           扩展点 com.apple.ar.viewer + XPCService(Application)
#      └── _CodeSignature/      ad-hoc 签名（侧载器会用自己的证书整包重签）
#
#  ★与 Henge 的对应关系★
#    链接形态（Foundation + rpath=@executable_path/../../Frameworks + StikJIT.framework）
#    = Henge 的 appex 实测 LC_LOAD_DYLIB / LC_RPATH（我这边用 otool 逐条对齐过，
#    见交付说明「构建证据」）。
# ----------------------------------------------------------------------------
set -euo pipefail

HELPER_NAME="Air2JITHelper"
BUNDLE_NAME="${HELPER_NAME}.appex"
DEFAULT_DEPLOYMENT_TARGET="26.0"   # NSExtension(ExtensionFoundation) 形态只在 iOS 26+ 可用

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SELF_DIR}/.." && pwd)

OUT_DIR=""
SDK=""
SWIFTC=""
DEPLOYMENT_TARGET="${DEFAULT_DEPLOYMENT_TARGET}"
SIGN_IDENTITY="-"        # ad-hoc；想用真证书就 --sign-identity "Apple Development: ..."
KEEP_WORK=0

usage() {
    cat <<'EOF'
用法: build-appex.sh --out <dir> [--sdk <iPhoneOS.sdk>] [--swiftc <path>]
                    [--deployment-target 26.0] [--sign-identity <-|name>] [--keep]

  --out               输出目录；脚本会在其下建 Air2JITHelper.appex/
                      （CMake 传 <App>.app/PlugIns）
  --sdk               iPhoneOS SDK 路径，缺省 `xcrun --sdk iphoneos --show-sdk-path`
  --swiftc            swiftc 路径，缺省 `xcrun -f swiftc`
  --deployment-target 扩展的 -target 版本（缺省 26.0）
  --sign-identity     codesign 身份，缺省 "-"（ad-hoc）
  --keep              保留中间产物目录（排查用）
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out)                OUT_DIR="$2"; shift 2 ;;
        --sdk)                SDK="$2"; shift 2 ;;
        --swiftc)             SWIFTC="$2"; shift 2 ;;
        --deployment-target)  DEPLOYMENT_TARGET="$2"; shift 2 ;;
        --sign-identity)      SIGN_IDENTITY="$2"; shift 2 ;;
        --keep)               KEEP_WORK=1; shift ;;
        -h|--help)            usage; exit 0 ;;
        *) echo "build-appex.sh: 未知参数 $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "${OUT_DIR}" ]; then
    echo "build-appex.sh: 必须给 --out <dir>" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# ① 工具链解析（非交互 SSH 下 PATH 里不一定有 xcrun/swiftc）
# ---------------------------------------------------------------------------
if [ -z "${SDK}" ]; then
    SDK=$(xcrun --sdk iphoneos --show-sdk-path)
fi
if [ -z "${SWIFTC}" ]; then
    SWIFTC=$(xcrun -f swiftc)
fi
[ -d "${SDK}" ] || { echo "build-appex.sh: SDK 不存在：${SDK}" >&2; exit 1; }
[ -x "${SWIFTC}" ] || { echo "build-appex.sh: swiftc 不可执行：${SWIFTC}" >&2; exit 1; }

TRIPLET="arm64-apple-ios${DEPLOYMENT_TARGET}"
SWIFTC_DIR=$(cd "$(dirname "${SWIFTC}")" && pwd)
if [ -n "${SWIFT_TC_LIB_DIR:-}" ] && [ -d "${SWIFT_TC_LIB_DIR}" ]; then
    SWIFT_TC_LIB="${SWIFT_TC_LIB_DIR}"
else
    SWIFT_TC_LIB=$(cd "${SWIFTC_DIR}/../lib/swift/iphoneos" 2>/dev/null && pwd) || SWIFT_TC_LIB=""
fi
[ -n "${SWIFT_TC_LIB}" ] || { echo "build-appex.sh: 找不到 iOS Swift 运行时目录；用 SWIFT_TC_LIB_DIR=… 指定" >&2; exit 1; }

STUB_SWIFT="${REPO_ROOT}/Natives/StikJIT/StikJIT.swift"     # 只读：接口桩 → .swiftmodule
FW_PARENT_DIR="${REPO_ROOT}/Natives/StikJIT"                # 内含 StikJIT.framework
SRC_DIR="${SELF_DIR}"

[ -f "${STUB_SWIFT}" ] || { echo "build-appex.sh: 缺少接口桩 ${STUB_SWIFT}" >&2; exit 1; }
[ -f "${FW_PARENT_DIR}/StikJIT.framework/StikJIT" ] || {
    echo "build-appex.sh: 缺少 ${FW_PARENT_DIR}/StikJIT.framework/StikJIT" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/air2-jit-helper.XXXXXX")
cleanup() {
    if [ "${KEEP_WORK}" -eq 1 ]; then
        echo "[build-appex] 中间产物保留在 ${WORK}"
    else
        rm -rf "${WORK}"
    fi
}
trap cleanup EXIT

echo "[build-appex] SDK        = ${SDK}"
echo "[build-appex] swiftc     = ${SWIFTC}"
echo "[build-appex] target     = ${TRIPLET}"
echo "[build-appex] 中间目录   = ${WORK}"

# ---------------------------------------------------------------------------
# ② 模块：直接用真框架自带的 Modules/（★不再编接口桩★）
#   2026-11-08 真机崩溃根因：手写桩的 Configuration/DDIPaths 布局与真框架不一致
#   ⇒ appex 传参被框架当指针解引用 ⇒ EXC_BAD_ACCESS @0xf000…078。
# ---------------------------------------------------------------------------
A2_STIKJIT_MODULES="${FW_PARENT_DIR}/StikJIT.framework/Modules"
[ -f "${A2_STIKJIT_MODULES}/StikJIT.swiftmodule" ] || {
    echo "build-appex.sh: 框架缺 Modules/StikJIT.swiftmodule（需用源码构建的框架）" >&2; exit 1; }

# ---------------------------------------------------------------------------
# ③ 编译 + 链接 appex 可执行
#    · -parse-as-library：不生成 main（入口由 -e _NSExtensionMain 指定，
#      iOS 的 appex 就是这么起的；_NSExtensionMain 由 Foundation 导出）
#    · -application-extension：与 Xcode 的 APPLICATION_EXTENSION_API_ONLY 等价
#    · -rpath @executable_path/../../Frameworks：appex 在 <App>.app/PlugIns/<X>.appex/，
#      往上两层正好是 <App>.app/Frameworks —— StikJIT.framework 就嵌在那里
#      （主 App 的 CMakeLists.txt:190-197 负责嵌入）
# ---------------------------------------------------------------------------
"${SWIFTC}" -O -parse-as-library -application-extension \
    -module-name "${HELPER_NAME}" \
    -target "${TRIPLET}" -sdk "${SDK}" \
    -I "${A2_STIKJIT_MODULES}" \
    -F "${FW_PARENT_DIR}" -framework StikJIT \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -Xlinker -rpath -Xlinker "@executable_path/../../Frameworks" \
    -L "${SDK}/usr/lib/swift" -L "${SWIFT_TC_LIB}" \
    "${SRC_DIR}/A2JITHelperMessages.swift" \
    "${SRC_DIR}/A2JITHelperExtension.swift" \
    -o "${WORK}/${HELPER_NAME}"

# ---------------------------------------------------------------------------
# ④ 组织 bundle
# ---------------------------------------------------------------------------
APPEX_OUT="${OUT_DIR}/${BUNDLE_NAME}"
rm -rf "${APPEX_OUT}"
mkdir -p "${APPEX_OUT}"
cp "${WORK}/${HELPER_NAME}" "${APPEX_OUT}/${HELPER_NAME}"
cp "${SRC_DIR}/Info.plist" "${APPEX_OUT}/Info.plist"
chmod 755 "${APPEX_OUT}/${HELPER_NAME}"

plutil -lint "${APPEX_OUT}/Info.plist" >/dev/null

# ---------------------------------------------------------------------------
# ⑤ 签名
#    ad-hoc 只是为了让包结构自洽（有 LC_CODE_SIGNATURE）；侧载器（SideStore /
#    iloader / Plume）会用用户自己的证书把整包（含 PlugIns 下的 appex）重签一遍。
# ---------------------------------------------------------------------------
codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "${APPEX_OUT}" >/dev/null

# ---------------------------------------------------------------------------
# ⑥ 自证（每条都是可复核的事实，不是「应该没问题」）
# ---------------------------------------------------------------------------
BIN="${APPEX_OUT}/${HELPER_NAME}"
echo
echo "==== 产物 ===="
echo "bundle : ${APPEX_OUT}"
ls -l "${APPEX_OUT}"
echo
echo "---- Mach-O 类型（应为 EXECUTE / arm64）----"
otool -hv "${BIN}" | tail -2
echo
echo "---- 入口点（必须 resolved 到 Foundation 的 _NSExtensionMain）----"
nm -m "${BIN}" | grep -E 'NSExtensionMain' || {
    echo "!! 找不到 _NSExtensionMain：扩展点不会被宿主拉起" >&2; exit 1; }
echo
echo "---- 依赖库（StikJIT 必须是 @rpath 形式）----"
otool -L "${BIN}"
echo
echo "---- LC_RPATH（必须有 @executable_path/../../Frameworks）----"
otool -l "${BIN}" | awk '/cmd LC_RPATH/{print; for (i = 0; i < 2; i++) { getline; print }}'
if ! otool -l "${BIN}" | grep -q '@executable_path/../../Frameworks'; then
    echo "!! 缺 rpath @executable_path/../../Frameworks：真机上 StikJIT.framework 解析不到，appex 起不来" >&2
    exit 1
fi
echo
echo "---- IPC key 是否真的编进了二进制 ----"
strings -a "${BIN}" | grep -E '^henge-jit-(request|response)$' | sort -u
echo
echo "---- Info.plist 关键段 ----"
plutil -extract CFBundleIdentifier raw "${APPEX_OUT}/Info.plist"
plutil -extract NSExtension.NSExtensionPointIdentifier raw "${APPEX_OUT}/Info.plist"
plutil -extract NSExtension.NSExtensionPrincipalClass raw "${APPEX_OUT}/Info.plist"
plutil -extract XPCService.ServiceType raw "${APPEX_OUT}/Info.plist"
echo
echo "[build-appex] OK"
