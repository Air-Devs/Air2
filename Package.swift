// swift-tools-version: 5.9
// ============================================================
// Air2 — SwiftPM 清单（真相源之一）
//
// 真相源 = 文件系统 + 本文件。`Air2.xcodeproj/project.pbxproj`
// 只是瞬时产物：CI / 本地在需要 Xcode 构建时由
// `scripts/gen_xcodeproj.py` 按需重生成，不再依赖入库副本。
// （删除入库的 pbxproj 是另一次 PR 的决策，本次仅停止依赖它。）
//
// 过渡期说明（App + UI Swift 优先）：
//   - 各 target 的 `path` 指向真实源码目录；`exclude` 只列**盘上还存在**的
//     ObjC 残留（SwiftPM 会因 exclude 不存在的路径而报错）。
//     新增 .swift 文件自动被拾取；当某个 ObjC 文件被删 / 被 Swift 重写后，
//     把它从 exclude 里拿掉（本次已按盘上状态核对过一遍）。
//   - Core 的子目录目前全是 ObjC，所以按目录整个 exclude。
//     某子目录落下第一个 .swift 文件时，把该目录移出 exclude，
//     改为逐个列出其中剩余的 ObjC 文件（登记规则同
//     docs/ARCHITECTURE.md「新增即登记」）。
//   - SwiftPM 不允许 target 为空（无 .swift 即报错），也不允许两个
//     target 的 path 互相嵌套。所以只有**盘上有 .swift** 的目录才建
//     target：Utils/Core 目前零 Swift，先不建，等首个 .swift 落地时
//     按 docs/ARCHITECTURE.md「新增即登记」加回（届时同步登记
//     products 与本注释）。UI 层不设 Air2UI 总 target；
//     先迁移的岛（Theme、App）各自独立成 target，后续
//     Screens/Components 等按目录各自建 target。
//
// iOS .app 打包限制（SwiftPM 做不到的事）：
//   SwiftPM 能编译逻辑 target、跑单测，但产不出可安装的 iOS .app：
//   它不管 Info.plist / entitlements / 资源目录 / asset catalog，
//   也不做代码签名。所以最终 .app/.ipa 仍走
//   `gen_xcodeproj.py`（瞬时工程）+ `xcodebuild -scheme` + 打包，
//   详见 .github/workflows/build.yml 的 ios-build 任务。
//
// Natives/（CMake）、JavaApp/ 不在 SwiftPM 内，原流程不动。
// ============================================================

import PackageDescription

let package = Package(
    name: "Air2",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(name: "Air2Theme", targets: ["Air2Theme"]),
    ],
    targets: [
        // UI 层最先迁移的岛：MD3 语义色板。
        // 盘上已无 ObjC 残留（全量 Swift），故无 exclude。
        .target(
            name: "Air2Theme",
            path: "Air2/UI/Theme"
        ),
        // 应用入口与根装配。
        // 盘上已无 ObjC 残留（全量 Swift），故无 exclude。
        .target(
            name: "Air2App",
            path: "Air2/App"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
