//
//  DownloadTasksView.swift
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
//  Download task list (replaces A2DownloadTasksViewController): 进行中 /
//  已完成 two groups, with per-row 暂停 / 继续 / 重试 / 取消. Data comes from
//  A2DownloadTaskCenter; the center throttles progress notifications, so we
//  simply re-read active/finished and let SwiftUI's identity diffing keep each
//  row alive while its progress ticks.
//
//  State is read straight from the engine's A2DownloadState (Cancelled
//  included) so the retry/cancel availability follows the machine exactly.

import SwiftUI
import Combine

/// 引擎态 → 状态文案。
private func a2DownloadStateText(_ state: A2DownloadState) -> String {
    switch state {
    case .running: return "进行中"
    case .paused: return "已暂停"
    case .completed: return "已完成"
    case .failed: return "失败"
    case .cancelled: return "已取消"
    @unknown default: return ""
    }
}

/// 引擎态 → 状态文案的强调色。
private func a2DownloadStateColor(_ state: A2DownloadState) -> Color {
    switch state {
    case .running: return .cPrimary
    case .paused: return .cWarning
    case .completed: return .cSuccess
    case .failed: return .cError
    case .cancelled: return .cOnSurfaceVariant
    @unknown default: return .cOnSurfaceVariant
    }
}

/// 字节数 → 人类可读文本（与 ObjC 侧 A2DownloadFormatBytes 同规则）。
private func a2DownloadFormatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < 3 {
        value /= 1024
        unit += 1
    }
    if unit == 0 { return "\(bytes) B" }
    let names = ["B", "KB", "MB", "GB"]
    return String(format: "%.1f %@", value, names[unit])
}

@MainActor
final class DownloadTasksViewModel: ObservableObject {
    @Published var active: [A2DownloadTask] = []
    @Published var finished: [A2DownloadTask] = []

    var isEmpty: Bool { active.isEmpty && finished.isEmpty }

    func reload() {
        let center = A2DownloadTaskCenter.shared()
        active = center.activeTasks()
        finished = center.finishedTasks()
    }

    func togglePause(_ task: A2DownloadTask) {
        A2ComponentLog("download-task: \(task.state == .running ? "暂停" : "继续") \(task.taskID)")
        A2DownloadTaskCenter.shared().togglePauseTask(withID: task.taskID)
    }

    func retry(_ task: A2DownloadTask) {
        A2ComponentLog("download-task: 重试 \(task.taskID)")
        A2DownloadTaskCenter.shared().retryTask(withID: task.taskID)
    }

    func cancel(_ task: A2DownloadTask) {
        A2ComponentLog("download-task: 取消 \(task.taskID)")
        A2DownloadTaskCenter.shared().cancelTask(withID: task.taskID)
    }

    func clearFinished() {
        A2ComponentLog("download-task: 清空已结束任务 count=\(finished.count)")
        A2DownloadTaskCenter.shared().clearFinishedTasks()
    }
}

/// 行内小胶囊按钮：主操作（暂停/继续、重试）实心主色，取消为中性容器色。
private struct TaskPillButton: View {
    let title: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(A2Type.button)
                .foregroundStyle(filled ? Color.cOnPrimary : Color.cOnSurfaceVariant)
                .padding(.horizontal, A2SpaceM)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: A2RadiusS, style: .continuous)
                        .fill(filled ? Color.cPrimary : Color.cSurfaceContainerHigh)
                )
        }
        .buttonStyle(.plain)
        .frame(minHeight: A2MinTouchTarget)
    }
}

struct DownloadTasksView: View {
    @ObservedObject var router: A2Router = A2Router()
    @StateObject private var model = DownloadTasksViewModel()
    @State private var toast: ToastMessage?

    var body: some View {
        A2PageScaffold("下载任务") {
            if model.isEmpty {
                emptyCard.a2CardEntrance(0)
            } else {
                if !model.active.isEmpty {
                    section(title: "进行中", tasks: model.active).a2CardEntrance(0)
                }
                if !model.finished.isEmpty {
                    section(title: "已完成", tasks: model.finished).a2CardEntrance(1)
                }
            }
        }
        .toolbar {
            Button(action: {
                model.clearFinished()
                toast = ToastMessage("已清空已完成任务")
            }) {
                Image(systemName: "trash")
                    .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
            }
            .disabled(model.finished.isEmpty)
            .opacity(model.finished.isEmpty ? 0.35 : 1)
        }
        .toast(item: $toast)
        .onReceive(NotificationCenter.default.publisher(for: A2DownloadTasksDidChangeNotification)) { _ in
            model.reload()
        }
        .onAppear { model.reload() }
    }

    private var emptyCard: some View {
        GlassCard {
            A2StateView(
                state: .empty,
                emptyTitle: "暂无下载任务",
                emptyHint: "去下载页挑一个资源，任务会出现在这里。"
            )
        }
    }

    private func section(title: String, tasks: [A2DownloadTask]) -> some View {
        VStack(alignment: .leading, spacing: A2CardSpacing) {
            Text(title)
                .font(A2Type.titleCard)
                .foregroundStyle(Color.cOnSurface)
                .padding(.leading, A2SpaceXS)
            ForEach(tasks, id: \.taskID) { task in
                taskCard(task)
            }
        }
    }

    private func taskCard(_ task: A2DownloadTask) -> some View {
        GlassCard(level: .l2) {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                HStack(spacing: A2SpaceS) {
                    Text(task.title.isEmpty ? task.taskID : task.title)
                        .font(A2Type.titleCard)
                        .foregroundStyle(Color.cOnSurface)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: A2SpaceS)
                    Text(a2DownloadStateText(task.state))
                        .font(A2Type.caption)
                        .foregroundStyle(a2DownloadStateColor(task.state))
                }
                if let subtitle = task.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(A2Type.subtitleCard)
                        .foregroundStyle(Color.cOnSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                ProgressBar(
                    progress: CGFloat(task.progress),
                    speedText: task.speedText(),
                    detailText: progressDetailText(task)
                )
                if task.state == .failed, let message = task.errorMessage, !message.isEmpty {
                    Text(message)
                        .font(A2Type.caption)
                        .foregroundStyle(Color.cError)
                }
                actionRow(task)
            }
        }
    }

    /// 进度：总大小已知时展示「已下 / 总量」，否则只留进度条本体。
    private func progressDetailText(_ task: A2DownloadTask) -> String? {
        guard task.totalBytes > 0 else { return nil }
        return "\(a2DownloadFormatBytes(task.downloadedBytes)) / \(a2DownloadFormatBytes(task.totalBytes))"
    }

    /// 按钮矩阵：Running/Paused → 暂停或继续 + 取消；Failed/Cancelled → 重试；Completed → 无。
    @ViewBuilder
    private func actionRow(_ task: A2DownloadTask) -> some View {
        let active = (task.state == .running || task.state == .paused)
        let retryable = (task.state == .failed || task.state == .cancelled)
        if active || retryable {
            HStack(spacing: A2SpaceS) {
                if active {
                    TaskPillButton(title: task.state == .running ? "暂停" : "继续", filled: true) {
                        model.togglePause(task)
                    }
                }
                if retryable {
                    TaskPillButton(title: "重试", filled: true) { model.retry(task) }
                }
                if active {
                    TaskPillButton(title: "取消", filled: false) { model.cancel(task) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
