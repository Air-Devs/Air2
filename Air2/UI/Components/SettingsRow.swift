//
//  SettingsRow.swift
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
//  Mapping: A2SettingsRow + A2SettingsRowAccessory
//  (symbolName/title/subtitle/valueText/accessory/on/isOn/onToggle/onTap/
//  destructive/cardPosition/showsSeparator/useHighContainer) -> SettingsRow +
//  SettingsRowModel + RowAccessory. Tappable rows ALWAYS show a chevron;
//  a tap handler without disclosure is coerced and logged. No host needed.
//

import SwiftUI

public enum RowAccessory: Equatable {
    case none
    case disclosure
    case toggle(Bool)
    case checkmark
    case custom(AnyView)

    public static func == (lhs: RowAccessory, rhs: RowAccessory) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none), (.disclosure, .disclosure), (.checkmark, .checkmark): return true
        case let (.toggle(a), .toggle(b)): return a == b
        default: return false
        }
    }
}

/// Model form so SettingsSection can assign CardPositions declaratively.
public struct SettingsRowModel: Identifiable {
    public let id = UUID()
    public var symbolName: String?
    public var title: String
    public var subtitle: String?
    public var valueText: String?
    public var accessory: RowAccessory
    public var destructive: Bool
    public var onToggle: ((Bool) -> Void)?
    public var onTap: (() -> Void)?

    public init(symbolName: String? = nil, title: String, subtitle: String? = nil, valueText: String? = nil, accessory: RowAccessory = .none, destructive: Bool = false, onToggle: ((Bool) -> Void)? = nil, onTap: (() -> Void)? = nil) {
        self.symbolName = symbolName
        self.title = title
        self.subtitle = subtitle
        self.valueText = valueText
        self.accessory = accessory
        self.destructive = destructive
        self.onToggle = onToggle
        self.onTap = onTap
    }
}

public struct SettingsRow: View {
    public var model: SettingsRowModel
    public var position: CardPosition
    public var showsSeparator: Bool
    public var useHighContainer: Bool

    public init(model: SettingsRowModel, position: CardPosition = .single, showsSeparator: Bool = false, useHighContainer: Bool = false) {
        self.model = model
        self.position = position
        self.showsSeparator = showsSeparator
        self.useHighContainer = useHighContainer
    }

    /// Tappable rows must advertise it: coerce missing chevrons and log why.
    private var effectiveAccessory: RowAccessory {
        if model.onTap != nil {
            switch model.accessory {
            case .disclosure, .toggle, .checkmark: return model.accessory
            case .none, .custom:
                return .disclosure
            }
        }
        return model.accessory
    }

    public var body: some View {
        Button {
            handleTap()
        } label: {
            HStack(spacing: A2SpaceM) {
                if let symbol = model.symbolName, !symbol.isEmpty {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.cOnPrimaryContainer)
                        .frame(width: 28, height: 28)
                        .background(Color.cPrimaryContainer, in: RoundedRectangle(cornerRadius: A2RadiusS, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(model.destructive ? Color.cError : Color.cOnSurface)
                        .lineLimit(1)
                    if let subtitle = model.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.cOnSurfaceVariant)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: A2SpaceM)
                if let value = model.valueText, !value.isEmpty {
                    Text(value)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.cOnSurfaceVariant)
                        .multilineTextAlignment(.trailing)
                }
                accessoryView
            }
            .padding(.horizontal, A2SpaceL)
            .padding(.vertical, A2SpaceM)
            .frame(minHeight: A2MinTouchTarget)
            .background(useHighContainer ? Color.cSurfaceContainerHigh : Color.cSurfaceContainerLow)
            .overlay(alignment: .bottomLeading) {
                if showsSeparator {
                    Color.cOutlineVariant.opacity(0.6)
                        .frame(height: 1)
                        .padding(.leading, model.symbolName == nil ? A2SpaceL : A2SpaceL + 28 + A2SpaceM)
                }
            }
        }
        .buttonStyle(A2PressButtonStyle())
        .cardPositionClip(position)
        .onAppear {
            if model.onTap != nil, model.accessory == .none || {
                if case .custom = model.accessory { return true }; return false
            }() {
                A2ComponentLog("SettingsRow '\(model.title)': tappable without chevron is banned; coerced to disclosure")
            }
        }
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch effectiveAccessory {
        case .none:
            EmptyView()
        case .disclosure:
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.cOutline)
        case let .toggle(isOn):
            Toggle("", isOn: Binding(get: { isOn }, set: { model.onToggle?($0) }))
                .labelsHidden()
                .tint(Color.cPrimary)
                .scaleEffect(0.85)
                .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
        case .checkmark:
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.cPrimary)
        case let .custom(view):
            view
        }
    }

    private func handleTap() {
        if case let .toggle(isOn) = model.accessory {
            let generator = UISelectionFeedbackGenerator()
            generator.selectionChanged()
            model.onToggle?(!isOn)
            return
        }
        guard model.onTap != nil else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
        model.onTap?()
    }
}
