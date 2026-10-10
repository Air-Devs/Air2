//
//  Toast.swift
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
//  Mapping: A2Toast +show:inView: (fire-and-forget, 1.4s) -> ToastMessage +
//  Toast view + .toast(item:) modifier. Scope unchanged: transient
//  "action happened" feedback only; confirmations use dialogs, not toasts.
//  No UIKit host needed.
//

import SwiftUI

/// Transient message. Identifiable so `.toast(item:)` auto-dismisses per item.
public struct ToastMessage: Identifiable, Equatable {
    public let id = UUID()
    public var text: String
    public init(_ text: String) { self.text = text }
}

public struct Toast: View {
    public var message: ToastMessage
    public init(_ message: ToastMessage) { self.message = message }
    public var body: some View {
        Text(message.text)
            .font(A2Type.caption)
            .foregroundStyle(Color.cInverseOnSurface)
            .padding(.horizontal, A2SpaceL)
            .frame(height: 36)
            .background(Color.cInverseSurface.opacity(0.92), in: Capsule(style: .continuous))
            .accessibilityAddTraits(.isStaticText)
    }
}

public extension View {
    /// Presents a Toast above bottom safe area while `item` is non-nil,
    /// clearing it after 1.4s. Callers set `item = ToastMessage("...")`.
    func toast(item: Binding<ToastMessage?>) -> some View {
        overlay(alignment: .bottom) {
            if let message = item.wrappedValue {
                Toast(message)
                    .padding(.bottom, 40)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .task(id: message.id) {
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        withAnimation(.easeOut(duration: 0.22)) { item.wrappedValue = nil }
                    }
            }
        }
        .animation(.easeOut(duration: 0.22), value: item.wrappedValue)
    }
}
