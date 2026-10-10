//
//  TaskProgressView.swift
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
//  Mapping: A2TaskProgressView + A2TaskState
//  (title/subtitle/state/progress/speedText/onTogglePause/onTap) ->
//  TaskState + TaskItem model + TaskProgressView. Running dot pulses;
//  toggle shows pause/play/checkmark/retry symbols in a >=44 container.
//  No UIKit host needed.
//

import SwiftUI

public enum TaskState: Equatable {
    case pending
    case running
    case paused
    case completed
    case failed

    var dot: Color {
        switch self {
        case .running: return .cPrimary
        case .completed: return .cSuccess
        case .failed: return .cError
        case .paused: return .cOutline
        case .pending: return Color.white.opacity(0.3)
        }
    }

    var symbol: String? {
        switch self {
        case .running: return "pause.fill"
        case .paused: return "play.fill"
        case .completed: return "checkmark"
        case .failed: return "arrow.clockwise"
        case .pending: return nil
        }
    }
}

public struct TaskItem: Identifiable {
    public let id = UUID()
    public var title: String
    public var subtitle: String?
    public var state: TaskState
    public var progress: CGFloat
    public var speedText: String?
    public init(title: String, subtitle: String? = nil, state: TaskState = .pending, progress: CGFloat = 0, speedText: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.progress = progress
        self.speedText = speedText
    }
}

public struct TaskProgressView: View {
    public var task: TaskItem
    public var onTogglePause: (() -> Void)?
    public var onTap: (() -> Void)?

    @State private var pulsing = false

    public init(task: TaskItem, onTogglePause: (() -> Void)? = nil, onTap: (() -> Void)? = nil) {
        self.task = task
        self.onTogglePause = onTogglePause
        self.onTap = onTap
    }

    public var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: A2SpaceM) {
                HStack(spacing: A2SpaceS) {
                    Circle()
                        .fill(task.state.dot)
                        .frame(width: 8, height: 8)
                        .opacity(task.state == .running && pulsing ? 0.35 : 1.0)
                        .onAppear {
                            if task.state == .running {
                                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                                    pulsing = true
                                }
                            }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(A2Type.titleCard)
                            .foregroundStyle(Color.cOnSurface)
                            .lineLimit(1)
                        if let subtitle = task.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(A2Type.caption)
                                .foregroundStyle(Color.cOnSurfaceVariant)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: A2SpaceS)
                    if let symbol = task.state.symbol {
                        Button {
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()
                            onTogglePause?()
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.cOnSurfaceVariant)
                                .frame(width: A2MinTouchTarget, height: 36)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ProgressBar(progress: task.progress, speedText: task.speedText, detailText: "\(Int(task.progress * 100))%")
            }
        }
        .buttonStyle(.plain)
    }
}
