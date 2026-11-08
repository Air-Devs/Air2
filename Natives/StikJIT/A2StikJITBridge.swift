//
//  A2StikJITBridge.swift
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Natives/StikJIT —— 内建 JIT 引擎的**唯一** Swift 桥（@_cdecl 导出 C 函数）
// ----------------------------------------------------------------------------
//  ★为什么要有这一层★：StikJIT.framework 只暴露 Swift API（127 个 $s7StikJIT 符号，
//  唯一的非 mangled 符号是两个版本全局）。ObjC 侧不可能直接调 Swift 结构体/枚举/
//  逃逸闭包参数 ⇒ 用一层极薄的 Swift 桥把入参全部压成「原始类型 + char*」，
//  把错误压成返回码 + 文本缓冲。
//
//  ★接口桩★：`import StikJIT` 能用是因为同目录 StikJIT.swift 编出的 .swiftmodule
//  （框架本身不随包 Modules/）。详见那个文件的头注释。
//
//  ★调用点★：Air2/Player/A2StikJITProvider.m
//    · a2_stikjit_set_log_sink    ← 首次 enable 之前
//    · a2_stikjit_enable_jit      ← `+enableBuiltInJITWithBudget:reason:`
//
//  ★线程★：a2_stikjit_enable_jit 是**阻塞**的（RSD 握手 + debugserver attach +
//  跑完 JIT 脚本）；调用方保证不在主线程。本层不自己开线程（开了就无法把错误
//  同步回给调用方）。
//

import Foundation
import StikJIT

/// C 侧日志出口（@convention(c)：不能逃逸、不能捕获上下文）。
public typealias A2StikJITLogSink = @convention(c) (UnsafePointer<CChar>) -> Void

private var gA2StikJITLogSink: A2StikJITLogSink?

/// 一行进度：系统日志 + 调用方注入的出口（两条都发，缺一不致命）。
private func a2stikjit_log(_ line: String) {
    NSLog("[A2-JIT-BUILTIN] %@", line)
    guard let sink = gA2StikJITLogSink else { return }
    line.withCString { sink($0) }
}

/// 把可读原因写进 C 缓冲（失败也要能看见原因：不许空返回）。
private func a2stikjit_write_error(_ out: UnsafeMutablePointer<CChar>?, _ cap: Int, _ text: String) {
    guard let out = out, cap > 0 else { return }
    let bytes = Array(text.utf8.prefix(cap - 1))
    for (i, b) in bytes.enumerated() { out[i] = CChar(bitPattern: b) }
    out[bytes.count] = 0
}

/// `preparationProgress` 的阶段名（判据日志用；★只读不改状态★）。
private func a2stikjit_stage_name(_ stage: StikJIT.PreparationStage) -> String {
    switch stage {
    case .checkingReachability:      return "checkingReachability"
    case .checkingDDI:               return "checkingDDI"
    case .downloadingDDI(let p, let s): return String(format: "downloadingDDI(%.0f%%, %@)", p * 100, s)
    case .verifyingDDI:              return "verifyingDDI"
    case .mountingDDI(let p):        return String(format: "mountingDDI(%.0f%%)", p * 100)
    case .ready:                     return "ready"
    }
}

@_cdecl("a2_stikjit_set_log_sink")
public func a2_stikjit_set_log_sink(_ sink: A2StikJITLogSink?) {
    gA2StikJITLogSink = sink
}

@_cdecl("a2_stikjit_enable_jit")
public func a2_stikjit_enable_jit(_ pid: Int32,
                                  _ pairingPath: UnsafePointer<CChar>?,
                                  _ address: UnsafePointer<CChar>?,
                                  _ rsdPort: UInt16,
                                  _ scriptPath: UnsafePointer<CChar>?,
                                  _ forceScript: Int32,
                                  _ outErr: UnsafeMutablePointer<CChar>?,
                                  _ errCap: Int) -> Int32 {
    guard let pairingPath = pairingPath, let address = address else {
        a2stikjit_write_error(outErr, errCap, "参数为空（pairingPath/address 至少有一个是 NULL）")
        return -1
    }
    let pairingURL = URL(fileURLWithPath: String(cString: pairingPath))
    guard FileManager.default.fileExists(atPath: pairingURL.path) else {
        a2stikjit_write_error(outErr, errCap,
                              "配对文件不存在：\(pairingURL.path)（先在设置页导入 pairingFile.plist）")
        return -1
    }
    let addr = String(cString: address)
    guard !addr.isEmpty else {
        a2stikjit_write_error(outErr, errCap, "RSD 端点地址为空（未发现 _remotepairing._tcp？）")
        return -1
    }

    // 脚本：给了路径且文件在 ⇒ custom（我们自己的 Air2JIT69.js / 框架自带 universal.js）；
    // 否则用框架内建的 universal。★case 顺序见 StikJIT.swift 文件头约束 ②★。
    var script: StikJIT.Script = .universal
    if let scriptPath = scriptPath {
        let path = String(cString: scriptPath)
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            script = .custom(URL(fileURLWithPath: path))
            a2stikjit_log("script=custom(\(path)) force=\(forceScript != 0)")
        } else {
            a2stikjit_log("script=universal（自定义脚本不可用：\(path)）")
        }
    } else {
        a2stikjit_log("script=universal（未指定自定义脚本）")
    }

    var configuration = StikJIT.Configuration(deviceAddress: addr,
                                             rsdPort: rsdPort,
                                             connectionTimeout: 30)
    configuration.deviceAddress = addr
    // DDI 放配对文件同目录（容器内可写；框架会自己下载/挂载它需要的东西）。
    let ddiPaths = DDIPaths.default(in: pairingURL.deletingLastPathComponent())

    a2stikjit_log("enableJIT 开始 pid=\(pid) rsd=\(addr):\(rsdPort) pairing=\(pairingURL.lastPathComponent)")

    do {
        try StikJIT.enableJIT(targetPID: pid,
                              pairingFile: pairingURL,
                              ddiPaths: ddiPaths,
                              configuration: configuration,
                              script: script,
                              forceScript: forceScript != 0,
                              preparationProgress: { stage in
                                  a2stikjit_log("prep: \(a2stikjit_stage_name(stage))")
                              },
                              progress: { line in
                                  a2stikjit_log("progress: \(line)")
                              })
        a2stikjit_log("enableJIT 返回成功")
        return 0
    } catch {
        let text: String
        if let e = error as? StikJITError, let desc = e.errorDescription {
            text = desc
        } else {
            text = String(describing: error)
        }
        a2stikjit_log("enableJIT 失败：\(text)")
        a2stikjit_write_error(outErr, errCap, text)
        return -3
    }
}
