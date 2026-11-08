//
//  StikJIT.swift
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: MIT
//
//  Natives/StikJIT —— ★StikJIT.framework 的「模块接口桩」★（不是实现）
// ----------------------------------------------------------------------------
//  为什么需要这个文件（真机/打包事实，不是设想）：
//    · 内建 JIT 的引擎是随包的 StikJIT.framework（Rust+Swift 二进制，MPL-2.0，
//      来自 Henge.ipa，见 docs/JIT-BUILTIN-STIKJIT.md）。
//    · 该框架**发布包里没有 Modules/StikJIT.swiftmodule**（Henge 自己的 helper
//      appex 在构建期才有）⇒ Air2 侧无法 `import StikJIT`。
//    · 故本文件按框架**实际导出**的 mangled 符号逐条重建声明，用
//        swiftc -emit-module -module-name StikJIT
//      编出 .swiftmodule 供 A2StikJITBridge.swift `import StikJIT`。
//
//  ★本文件不产出任何实现★：它只被 -emit-module 读接口，.o 永不参与链接。
//    函数体一律 fatalError()；import 方每次调用都被编译成对框架真实符号的引用
//    （$s7StikJIT…VMa / …tcfC / …vg）。⇒ 某条声明与框架不符时，链接期直接
//    `undefined symbol`（这就是 ABI 判据，不需要真机就能验）。
//
//  ★调用链（谁用它）★
//    Natives/StikJIT/A2StikJITBridge.swift（唯一 import 点）
//      ← Air2/Player/A2StikJITProvider.m `+enableBuiltInJITWithBudget:reason:`
//      ← Natives/Support/A2JITEnabler.m `a2jit_start_preferred_run`（钩子）
//      ← Air2/App/A2AppDelegate.m 注册钩子
//
//  ★声明的两条硬约束★
//    ① 闭包参数必须写 `@escaping`：公共 API 里不写 @escaping 的闭包参数会被编成
//       `XE`（escaping），而框架导出的是 `c`；这一条是实测出来的（见 docs 证据）。
//    ② Script 的 case 顺序 = 框架 EnumCase 标签值：custom=0 / customBase64=1 /
//       legacy=2 / universal=3。换顺序 ⇒ 传给框架的标签错位（选错脚本）。
//

import Foundation

// MARK: - DDIPaths

public struct DDIPaths {
    public var imagePath: String
    public var trustcachePath: String
    public var manifestPath: String
    /// ★框架里这两个属性的 getter 是非可选 String（`SSvg`，不是 `SSSgvg`）★，
    /// 但初始化器收的是可选（缺省 nil）。按框架实际形状声明，否则引用不到 getter。
    public var cryptexInfoPath: String
    public var rootHashPath: String

    public init(imagePath: String,
                trustcachePath: String,
                manifestPath: String,
                cryptexInfoPath: String? = nil,
                rootHashPath: String? = nil) {
        fatalError("StikJIT 接口桩：本文件的 .o 不参与链接")
    }

    public static func `default`(in base: URL) -> DDIPaths {
        fatalError("StikJIT 接口桩：本文件的 .o 不参与链接")
    }
}

// MARK: - StikJITError

public enum StikJITError: Error {
    case device(Int32, Int32, String)
    case pairingFile(String)
    case ddiDownload(String)
    case ddiNotMounted
    case ddiFilesMissing(String)
    case deviceNotReady(String)
    case debugProxyUnavailable
    case scriptUnavailable
    case scriptExecution(String)
    case customScript(String)
    case txmDetectionUnavailable
}

extension StikJITError: LocalizedError {
    public var errorDescription: String? { fatalError("StikJIT 接口桩：本文件的 .o 不参与链接") }
}

// MARK: - StikJIT 命名空间

public enum StikJIT {

    public struct Configuration {
        public var deviceAddress: String
        public var rsdPort: UInt16
        public var connectionTimeout: Double

        public init(deviceAddress: String, rsdPort: UInt16, connectionTimeout: Double = 10) {
            fatalError("StikJIT 接口桩：本文件的 .o 不参与链接")
        }

        public static var `default`: Configuration {
            fatalError("StikJIT 接口桩：本文件的 .o 不参与链接")
        }
    }

    public struct DeviceSecurityState {
        public var isTXMPresent: Bool?

        public init(isTXMPresent: Bool?) {
            fatalError("StikJIT 接口桩：本文件的 .o 不参与链接")
        }
    }

    public enum JITReadiness {
        case ready(DeviceSecurityState)
        case preparationFailed(String)
        case unreachable(String)

        public var isReady: Bool { fatalError("StikJIT 接口桩：本文件的 .o 不参与链接") }
    }

    public enum PreparationStage {
        case checkingReachability
        case checkingDDI
        case downloadingDDI(Double, String)
        case verifyingDDI
        case mountingDDI(Double)
        case ready
    }

    /// ★顺序不许动★：见文件头约束 ②（custom=0 / customBase64=1 / legacy=2 / universal=3）。
    public enum Script {
        case custom(URL)
        case customBase64(String)
        case legacy
        case universal
    }

    public static var isTXMPresent: Bool? { fatalError("StikJIT 接口桩：本文件的 .o 不参与链接") }

    public static func isDDIMounted(pairingFile: URL,
                                    configuration: Configuration) throws -> Bool {
        fatalError("StikJIT 接口桩：本文件的 .o 不参与链接")
    }

    public static func mountDDI(pairingFile: URL,
                                configuration: Configuration,
                                paths: DDIPaths,
                                progress: @escaping (Double) -> Void) throws {
        fatalError("StikJIT 接口桩：本文件的 .o 不参与链接")
    }

    public static func prepareDevice(pairingFile: URL,
                                     paths: DDIPaths,
                                     configuration: Configuration,
                                     progress: @escaping (PreparationStage) -> Void) -> JITReadiness {
        fatalError("StikJIT 接口桩：本文件的 .o 不参与链接")
    }

    public static func downloadDDIIfNeeded(to paths: DDIPaths,
                                           progress: @escaping (Double, String) -> Void) async throws {
        fatalError("StikJIT 接口桩：本文件的 .o 不参与链接")
    }

    public static func resetCachedDDI(at paths: DDIPaths) throws {
        fatalError("StikJIT 接口桩：本文件的 .o 不参与链接")
    }

    public static func enableJIT(targetPID: Int32,
                                 pairingFile: URL,
                                 configuration: Configuration,
                                 script: Script,
                                 forceScript: Bool,
                                 progress: @escaping (String) -> Void) throws {
        fatalError("StikJIT 接口桩：本文件的 .o 不参与链接")
    }

    public static func enableJIT(targetPID: Int32,
                                 pairingFile: URL,
                                 ddiPaths: DDIPaths,
                                 configuration: Configuration,
                                 script: Script,
                                 forceScript: Bool,
                                 preparationProgress: @escaping (PreparationStage) -> Void,
                                 progress: @escaping (String) -> Void) throws {
        fatalError("StikJIT 接口桩：本文件的 .o 不参与链接")
    }
}
