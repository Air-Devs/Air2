//
//  CrashGuard.swift
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  崩溃兜底 —— 把异常信息写进统一日志（见 A2Log），便于在没有 Xcode 的
//  环境里定位闪退。崩溃发生在本次会话，所以它会被追加到 lastlog.txt；
//  下次启动轮转后即变成 lastlog.old.txt，用户可在「文件」App 里取走。
//
//  不另开崩溃文件：一个日志系统就够，多了只会让人不知道看哪个。
//  日志轮转本身仍在 A2Log.startSession 里，这里只负责追加。
//
//  信号处理器里的取舍：信号上下文只能做异步信号安全的事，且 Swift 可见的
//  C API 有限，因此信号崩溃只写一行定位头（信号号 + 时间戳），堆栈以系统
//  崩溃报告为准；ObjC 未捕获异常不受此限，保留完整堆栈。
//

import Foundation

// MARK: - 信号上下文的静态材料

/// 信号崩溃行的静态片段。启动时一次备好，崩溃时只读不分配。
private let signalReportHead = Array("\n=== 信号崩溃 ===\n信号: ".utf8)
private let signalReportMiddle = Array("\n时间戳: ".utf8)
private let signalReportTail = Array("\n\n上一次会话见 lastlog.old.txt；堆栈见系统崩溃报告。\n".utf8)

/// 数字转写的草稿区。只在信号处理器里读写（崩溃时单线程语境），平时不用。
private var signalScratch = [CChar](repeating: 0, count: 32)

/// 日志路径的进程期拷贝。路径与轮转无关（恒为 Documents/lastlog.txt），
///
/// 因此 install 时快照一次即可；常驻不释放，随进程结束回收。
private var signalLogPath: UnsafePointer<CChar>?

private func signalWriteBytes(_ fd: Int32, _ bytes: [UInt8]) {
    bytes.withUnsafeBufferPointer { buf in
        guard let base = buf.baseAddress else { return }
        _ = write(fd, base, buf.count)
    }
}

private func signalWriteDecimal(_ fd: Int32, _ value: Int) {
    // 信号号与时间戳恒为非负；防御性钳零，避免负号处理分支。
    var rest = max(0, value)
    var count = 0
    repeat {
        signalScratch[count] = CChar(48 + rest % 10)
        rest /= 10
        count += 1
    } while rest > 0 && count < signalScratch.count - 1
    while count > 0 {
        count -= 1
        var digit = signalScratch[count]
        withUnsafeBytes(of: &digit) { raw in
            _ = write(fd, raw.baseAddress!, 1)
        }
    }
}

/// 信号处理器：只用 open / write / close，不碰 ObjC；
/// 写完恢复默认处理器后重新触发，让系统也记录一份。
private let crashSignalHandler: @convention(c) (Int32) -> Void = { number in
    if let path = signalLogPath {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        if fd >= 0 {
            signalWriteBytes(fd, signalReportHead)
            signalWriteDecimal(fd, Int(number))
            signalWriteBytes(fd, signalReportMiddle)
            signalWriteDecimal(fd, Int(time(nil)))
            signalWriteBytes(fd, signalReportTail)
            close(fd)
        }
    }
    signal(number, SIG_DFL)
    raise(number)
}

/// ObjC 未捕获异常处理器：可拿完整信息，走统一日志。
/// 用 %@ 透传，避免堆栈里的 % 被当成格式符。
private let uncaughtExceptionHandler: @convention(c) (NSException?) -> Void = { exception in
    guard let exception else {
        A2Log.log("%@", "=== 未捕获异常 ===（异常对象为空）")
        return
    }
    var lines = [
        "=== 未捕获异常 ===",
        "名称: \(exception.name.rawValue)",
        "原因: \(exception.reason ?? "无")",
        "调用栈:",
    ]
    for frame in exception.callStackSymbols {
        lines.append("  \(frame)")
    }
    lines.append("用户信息: \(exception.userInfo.map(String.init(describing:)) ?? "无")")
    A2Log.log("%@", lines.joined(separator: "\n"))
}

// MARK: - 崩溃兜底

/// 崩溃兜底。ObjC 侧写作 A2CrashGuard。
@objc(A2CrashGuard)
public final class CrashGuard: NSObject {
    /// 注册异常与信号处理器。应在启动流程最早期调用，早于日志轮转。
    /// install 本身不写日志：此时日志会话尚未开始，无处可写。
    @objc public static func install() {
        A2Log.currentLogPath.withCString { fresh in
            if let copy = strdup(fresh) {
                signalLogPath = UnsafePointer(copy)
            }
        }
        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
        signal(SIGABRT, crashSignalHandler)
        signal(SIGSEGV, crashSignalHandler)
        signal(SIGBUS, crashSignalHandler)
        signal(SIGILL, crashSignalHandler)
        signal(SIGFPE, crashSignalHandler)
        signal(SIGTRAP, crashSignalHandler)
    }
}
