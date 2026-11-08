// SPDX-License-Identifier: GPL-3.0-or-later
//  Air2 — 内建 JIT 的 helper appex 消息格式（请求 / 响应）
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  ★来源★：本文件是 Henge 的 ios/HengeJITHelper/HengeJITMessages.swift:1-48
//  （SPDX: GPL-2.0-or-later，作者 Leviidev）的移植，字段与 JSON 形状逐条对齐；
//  按 GPL-3.0-or-later 第 3 条整包作 GPL-3.0-or-later 分发，原版权归 Leviidev。
//
//  ★这一层是什么★：主 App 与 helper appex 之间**唯一的线上格式**定义。
//  两边的载荷都装在一个 NSExtensionItem 的 userInfo 里：
//    · 请求 userInfo["henge-jit-request"] = JSON(本文件的 Request)
//    · 响应 userInfo["henge-jit-response"] = JSON(本文件的 Response)
//  之所以**不自己发明 key**：itemKey 是这条 KVC 约定的字面量，改名要两边同时改，
//  而字段集（operation/targetPID/pairingData/scriptBase64/rsdPort）本身就是语义契约；
//  与 Henge 保持逐字一致 ⇒ 行为、诊断与参考实现可以逐条对照（见交付说明）。
//
//  ★谁读它★
//    Request  ← Air2JITHelper/A2JITHelperExtension.swift `A2JITHelperWork.handle(_:)`
//               （由 A2JITHelperHandler.beginRequest(with:) 解码）
//    Response ← 同上，编码后回给主 App
//    ★两侧的编解码都不在本文件★：JSON 的**写**在主 App 的 ObjC 侧
//    （Air2/Bridge/A2JITHelperBridge.m `+requestDataWithOperation:...`），
//    **读**在 appex 侧（本文件的 Codable）。故这里只留 Codable + itemKey，
//    不提供 `Request.enable(...)` 这类构造快捷方式——那会成为无人调用的死代码。

import Foundation

/// 发给 helper appex 的请求。
struct A2JITHelperRequest: Codable, Sendable {
    /// userInfo 里请求载荷的 key（= HengeJITMessages.swift:8 同名常量）。
    static let itemKey = "henge-jit-request"

    enum Operation: String, Codable, Sendable {
        /// 探 LocalDevVPN 是否可达，并下载 / 挂载 / 校验 Developer Disk Image。
        case prepare
        /// attach 到 `targetPID` 并跑 JIT 脚本，直到调试器自己 detach（请求会一直挂着）。
        case enable
        case resetDDI
    }

    let operation: Operation
    let targetPID: Int32?
    let pairingData: Data?
    let scriptBase64: String?
    /// 设备当前为 RemotePairing 广播的端口；iOS 每次启动会换，nil = 用 StikJIT 的默认值。
    let rsdPort: UInt16?
    /// ★LocalDevVPN 回环地址★（默认 127.0.0.1）。Henge 也是走这条：
    ///   RSD 的 Bonjour 名字（Zhous-iPhone.local）在 appex 里连不上，必须用回环。
    let deviceAddress: String?

    /// helper appex 回给主 App 的应答（`Response` 是 Henge 的嵌套类型名，这里上提一层，
    /// 字段与 HengeJITMessages.swift:42-47 一一对应）。
    struct Response: Codable, Sendable {
        /// userInfo 里响应载荷的 key（= HengeJITMessages.swift:43 同名常量）。
        static let itemKey = "henge-jit-response"
        let success: Bool
        /// ★只回整数码，不回字符串★：2026-11-08 真机 ips 显示
        ///   JSONEncoder 在处理 Response.message 时崩在 StringObject.getSharedUTF8Start
        ///   （错误链带出来的 String 底层指针不可信）。改成码之后编码路径不再碰任意字符串，
        ///   文本由主 App 侧按码映射（A2JITHelperBridge.m 的 code→文案表）。
        let code: Int
        let txmPresent: Bool?
    }
}
