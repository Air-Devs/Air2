//
//  TaskDrawer.swift
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
//  Mapping: A2TaskDrawer (collapsedHeight/expandedHeight/expanded/
//  addTaskView:/removeTaskView:/setSummaryTitle:progress:speed:/
//  setExpanded:animated:/updateVisibility) -> TaskDrawer (tasks model +
//  summary + isExpanded binding + tri-state empty/list). Bottom sheet, not
//  side panel: one-hand reachable. No UIKit host needed; drag via SwiftUI.
//

import SwiftUI

public struct TaskDrawer: View {
    public var tasks: [TaskItem]
    @Binding public var isExpanded: Bool
    public var collapsedHeight: CGFloat
    public var expandedHeight: CGFloat
    public var summaryTitle: String
    public var summaryProgress: CGFloat
    public var summarySpeed: String?
    public var onTogglePause: ((TaskItem) -> Void)?
    public var onRemove: ((TaskItem) -> Void)?

    public init(
        tasks: [TaskItem], isExpanded: Binding<Bool>,
        collapsedHeight: CGFloat = 56, expandedHeight: CGFloat = 280,
        summaryTitle: String = "No tasks", summaryProgress: CGFloat = 0, summarySpeed: String? = nil,
        onTogglePause: ((TaskItem) -> Void)? = nil, onRemove: ((TaskItem) -> Void)? = nil
    ) {
        self.tasks = tasks
        self._isExpanded = isExpanded
        self.collapsedHeight = collapsedHeight
        self.expandedHeight = expandedHeight
        self.summaryTitle = summaryTitle
        self.summaryProgress = summaryProgress
        self.summarySpeed = summarySpeed
        self.onTogglePause = onTogglePause
        self.onRemove = onRemove
    }

    public var body: some View {
        // Empty state: the drawer hides itself; owners render nothing.
        if !tasks.isEmpty {
            VStack(spacing: 0) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)
                Button {
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                    withAnimation(.a2Standard) { isExpanded.toggle() }
                } label: {
                    HStack {
                        Text(summaryTitle)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Color.cOnSurface)
                            .lineLimit(1)
                        Spacer(minLength: A2SpaceS)
                        Text(summarySpeed ?? "\(Int(summaryProgress * 100))%")
                            .font(A2Type.numeric)
                            .foregroundStyle(Color.cPrimary)
                            .frame(minWidth: A2MinTouchTarget)
                    }
                    .padding(.horizontal, A2SpaceXL)
                    .frame(height: collapsedHeight)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits([.isButton, .isHeader])
                if isExpanded {
                    ScrollView {
                        LazyVStack(spacing: A2SpaceL) {
                            ForEach(tasks) { task in
                                TaskProgressView(task: task, onTogglePause: { onTogglePause?(task) })
                                    .transition(.opacity.combined(with: .scale(0.96)))
                            }
                        }
                        .padding(.horizontal, A2SpaceXL)
                        .padding(.bottom, A2SpaceXL)
                    }
                    .frame(height: expandedHeight - collapsedHeight)
                }
                GeometryReader { geo in
                    Color.white.opacity(0.14).frame(height: 2.5)
                    Color.cPrimary.frame(width: geo.size.width * max(0, min(1, summaryProgress)), height: 2.5)
                }
                .frame(height: 2.5)
            }
            .frame(height: isExpanded ? expandedHeight : collapsedHeight, alignment: .top)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .gesture(DragGesture().onEnded { value in
                if abs(value.velocity.height) > 400 {
                    withAnimation(.a2Standard) { isExpanded = value.velocity.height < 0 }
                } else {
                    withAnimation(.a2Standard) { isExpanded.toggle() }
                }
            })
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
