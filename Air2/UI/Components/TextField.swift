//
//  TextField.swift
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
//  Mapping: A2TextField (labelText/text/secure/keyboardType/
//  autocapitalizationType/errorText/supportText/onTextChange/onReturn/
//  clearError) -> A2TextField. Named A2TextField (not TextField) to avoid
//  shadowing SwiftUI.TextField. MD3 filled style: highest-container fill,
//  top-only r4 corners, 1-2pt underline, floating label, error/support line.
//  No UIKit host needed.
//

import SwiftUI

public struct A2TextField: View {
    public var labelText: String
    @Binding public var text: String
    public var isSecure: Bool
    public var keyboardType: UIKeyboardType
    public var autocapitalization: TextInputAutocapitalization?
    public var errorText: String?
    public var supportText: String?
    public var onReturn: (() -> Void)?

    @FocusState private var focused: Bool

    public init(
        labelText: String, text: Binding<String>, isSecure: Bool = false,
        keyboardType: UIKeyboardType = .default,
        autocapitalization: TextInputAutocapitalization? = .never,
        errorText: String? = nil, supportText: String? = nil,
        onReturn: (() -> Void)? = nil
    ) {
        self.labelText = labelText
        self._text = text
        self.isSecure = isSecure
        self.keyboardType = keyboardType
        self.autocapitalization = autocapitalization
        self.errorText = errorText
        self.supportText = supportText
        self.onReturn = onReturn
    }

    private var hasError: Bool { !(errorText ?? "").isEmpty }
    private var floating: Bool { focused || !text.isEmpty }
    private var supportMessage: String? {
        if hasError { return errorText }
        return supportText
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: A2SpaceXS) {
            VStack(alignment: .leading, spacing: 0) {
                Text(labelText)
                    .font(floating ? .system(size: 12, weight: .medium) : .system(size: 15, weight: .regular))
                    .foregroundStyle(hasError ? Color.cError : (floating && focused ? Color.cPrimary : Color.cOnSurfaceVariant))
                    .padding(.leading, A2SpaceM)
                    .padding(.top, floating ? 7 : 0)
                    .animation(.a2Press, value: floating)
                Group {
                    if isSecure {
                        SecureField("", text: $text)
                    } else {
                        SwiftUI.TextField("", text: $text)
                            .keyboardType(keyboardType)
                            .textInputAutocapitalization(autocapitalization)
                    }
                }
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.cOnSurface)
                .tint(hasError ? Color.cError : Color.cPrimary)
                .focused($focused)
                .padding(.horizontal, A2SpaceM)
                .padding(.top, floating ? 0 : -2)
                .padding(.bottom, 6)
                .submitLabel(.done)
                .onSubmit { onReturn?() }
                Rectangle()
                    .fill(hasError ? Color.cError : (focused ? Color.cPrimary : Color.cOutlineVariant))
                    .frame(height: (hasError || focused) ? 2 : 1)
            }
            .frame(height: 56, alignment: floating ? .top : .center)
            .background(Color.cSurfaceContainerHighest)
            .clipShape(A2TopRoundedShape(radius: A2RadiusXS))
            if let supportMessage, !supportMessage.isEmpty {
                Text(supportMessage)
                    .font(A2Type.caption)
                    .foregroundStyle(hasError ? Color.cError : Color.cOnSurfaceVariant)
                    .padding(.horizontal, A2SpaceM)
            }
        }
    }
}

/// MD3 filled-field top corners (iOS 15: UIBezierPath subset rounding
/// instead of UnevenRoundedRectangle).
public struct A2TopRoundedShape: Shape {
    public var radius: CGFloat

    public init(radius: CGFloat) { self.radius = radius }

    public func path(in rect: CGRect) -> Path {
        let bezier = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(bezier.cgPath)
    }
}
