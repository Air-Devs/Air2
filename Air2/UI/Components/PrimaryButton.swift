//
//  PrimaryButton.swift
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
//  Mapping: A2PrimaryButton + A2ButtonStyle (Primary/Secondary/Danger),
//  title/style/loading/minHeight/icon -> ButtonStyle_ + PrimaryButton.
//  Primary actions stay plain visible buttons; nothing hides in long-press.
//  No UIKit host needed.
//

import SwiftUI

public enum ButtonStyle_: Equatable {
    case primary
    case secondary
    case danger
}

/// Core-action button: gradient primary, outlined secondary, danger red.
/// Loading shows a spinner and disables interaction instead of hiding.
public struct PrimaryButton: View {
    public var title: String
    public var style: ButtonStyle_
    public var isLoading: Bool
    public var minHeight: CGFloat
    public var symbolName: String?
    public var action: () -> Void

    public init(title: String, style: ButtonStyle_ = .primary, isLoading: Bool = false, minHeight: CGFloat = A2ButtonHeight, symbolName: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.isLoading = isLoading
        self.minHeight = minHeight
        self.symbolName = symbolName
        self.action = action
    }

    public var body: some View {
        Button {
            if !isLoading {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                action()
            }
        } label: {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(labelColor)
                } else {
                    HStack(spacing: A2SpaceS) {
                        if let symbolName {
                            Image(systemName: symbolName)
                                .font(.system(size: 18, weight: .medium))
                        }
                        Text(title)
                            .font(A2Type.button)
                    }
                }
            }
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity, minHeight: max(minHeight, A2MinTouchTarget))
            .padding(.horizontal, A2SpaceXL)
        }
        .buttonStyle(A2PressButtonStyle())
        .background {
            switch style {
            case .primary:
                RoundedRectangle(cornerRadius: A2RadiusM, style: .continuous)
                    .fill(LinearGradient(colors: [.cPrimary, .cPrimaryContainer], startPoint: .topLeading, endPoint: .bottomTrailing))
            case .secondary:
                RoundedRectangle(cornerRadius: A2RadiusM, style: .continuous)
                    .stroke(Color.cOutline.opacity(0.45), lineWidth: 1.2)
            case .danger:
                RoundedRectangle(cornerRadius: A2RadiusM, style: .continuous)
                    .fill(LinearGradient(colors: [.cError, .cError.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .disabled(isLoading)
        .accessibilityAddTraits(isLoading ? [.updatesFrequently] : [.isButton])
    }

    private var labelColor: Color {
        switch style {
        case .primary: return .cOnPrimary
        case .secondary: return .cOnSurface
        case .danger: return .white
        }
    }
}
