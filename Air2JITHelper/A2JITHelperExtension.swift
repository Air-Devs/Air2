// SPDX-License-Identifier: GPL-3.0-or-later
//  Air2 — 内建 JIT 的 helper appex 本体（NSExtensionPrincipalClass）
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  ★来源★：Henge ios/HengeJITHelper/HengeJITHelper.swift:1-106
//  （SPDX: GPL-2.0-or-later，作者 Leviidev）的移植；调用序列与错误文案逐条对齐。
//
//  ★为什么必须是一个独立进程★
//    一个进程不能同步地调试自己（自 attach 会死锁），所以主 App 永远拿不到自己的 JIT。
//    本 appex 由主 App 用私有 NSExtension API 拉起（见 Air2/Bridge/A2JITHelperBridge.m），
//    收到主 App 的 pid + 配对文件 + JIT 脚本 base64，然后用 StikJIT.framework 反向 attach
//    主 App，并持续服务脚本里的 brk 请求，直到脚本 detach。
//
//  ★谁调它★
//    iOS 进程宿主 → Info.plist 的 NSExtensionPrincipalClass("Air2JITHelperHandler")
//                 → `-beginRequest(with:)`（每次请求一个新进程，_MultipleInstances=true）
//    `-beginRequest(with:)` → `A2JITHelperWork.handle(_:)` → StikJIT.framework
//
//  ★硬前置★
//    ① iOS 26+（扩展点 com.apple.ar.viewer + XPCService 形态在更低版本不可用；
//       主 App 侧的版本判据在 A2JITHelperBridge.m `+unavailableReason`）。
//    ② 本机 LocalDevVPN 已连（StikJIT 通过它把 RSD 暴露到回环）。
//    ③ 主 App 带 get-task-allow 且没被容器套着（LiveContainer 内不可用）。

import Foundation
import StikJIT

/// 真正的 JIT 工作。和 Henge 一样串行化：enable 期间这个队列一直被占着
/// （调试器 attach 着主 App 的时候不能再接第二个请求）。
private enum A2JITHelperWork {

    /// 一次只处理一个请求。label 用主 App 的 bundle id 前缀，便于 os_log / Instruments 里认。
    static let queue = DispatchQueue(label: "dev.airdevs.air2.jit-helper")

    static func handle(_ request: A2JITHelperRequest) -> A2JITHelperRequest.Response {
        let manager = FileManager.default
        // DDI 缓存与临时配对文件都落在本进程的 Library/StikJIT 下（= HengeJITHelper.swift:16-18
        // 的同一口径）。★这是 appex 自己的容器★，主 App 不读它。
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)
        var configuration = StikJIT.Configuration.default
        if let rsdPort = request.rsdPort {
            configuration.rsdPort = rsdPort
        }
        // ★LocalDevVPN 回环★：默认 127.0.0.1（Henge 同款）。
        configuration.deviceAddress = request.deviceAddress ?? "127.0.0.1"

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return .init(success: true, code: 0, txmPresent: StikJIT.isTXMPresent)
            }

            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                throw NSError(domain: "Air2JITHelper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The pairing file was not provided."])
            }
            // 配对文件按请求落地成临时文件（StikJIT 只吃 URL），请求结束即删。
            let pairingURL = root.appendingPathComponent("pairingFile-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            switch request.operation {
            case .prepare:
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL, paths: paths, configuration: configuration,
                    progress: { NSLog("[A2JITHelper] prepare: %@", String(describing: $0)) })
                switch readiness {
                case .ready(let security):
                    return .init(success: true, code: 10, txmPresent: security.isTXMPresent)
                case .unreachable:
                    return .init(success: false, code: 11, txmPresent: StikJIT.isTXMPresent)
                case .preparationFailed:
                    return .init(success: false, code: 12, txmPresent: StikJIT.isTXMPresent)
                @unknown default:
                    return .init(success: false, code: 13, txmPresent: StikJIT.isTXMPresent)
                }
            case .enable:
                guard let targetPID = request.targetPID,
                      let scriptBase64 = request.scriptBase64, !scriptBase64.isEmpty else {
                    throw NSError(domain: "Air2JITHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "The target process or Air2's JIT script was not provided."])
                }
                // ★阻塞直到脚本 detach★：主 App 的 enableJIT 请求会一直挂着，
                // 也就是本进程一直活着（保活责任在 A2JITHelperBridge.m 的会话数组）。
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingURL,
                    ddiPaths: paths,
                    configuration: configuration,
                    script: .customBase64(scriptBase64),
                    forceScript: true,
                    preparationProgress: { NSLog("[A2JITHelper] prepare: %@", String(describing: $0)) },
                    progress: { NSLog("[A2JITHelper] %@", $0) })
                return .init(success: true, code: 20, txmPresent: StikJIT.isTXMPresent)
            case .resetDDI:
                preconditionFailure("Handled above")
            }
        } catch {
            return .init(success: false, code: 30, txmPresent: StikJIT.isTXMPresent)
        }
    }
}

/// Info.plist 的 NSExtensionPrincipalClass。请求以 JSON 装在第一个 input item 里，
/// 响应也以 JSON 装在 completeRequest 带回去的那个 item 里。
/// enable 只在脚本 detach 之后才 complete ⇒ 这个请求、以及本进程，与调试器同寿。
@objc(Air2JITHelperHandler)
final class Air2JITHelperHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[A2JITHelperRequest.itemKey] as? Data
        A2JITHelperWork.queue.async {
            let response: A2JITHelperRequest.Response
            if let data, let request = try? JSONDecoder().decode(A2JITHelperRequest.self, from: data) {
                response = A2JITHelperWork.handle(request)
            } else {
                // 主 App 一定要带 JSON 来；走到这里说明 IPC 坏了（或版本不匹配）。
                response = .init(success: false, code: 1, txmPresent: nil)
            }
            let item = NSExtensionItem()
            item.userInfo = [A2JITHelperRequest.Response.itemKey:
                                (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
