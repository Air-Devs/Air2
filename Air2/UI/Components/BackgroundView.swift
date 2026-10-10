//
//  BackgroundView.swift
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
//  Mapping: A2BackgroundView (fadeRatio/applyBackgroundAnimated:) ->
//  BackgroundView (fadeRatio + image + blurTier inputs; no file IO here — the
//  owner resolves/loads the image via ThemeManager/Core and injects it).
//  Pipeline preserved: image -> aspect fill -> blur tier -> dark dim ->
//  right-edge fade into cSurface. No UIKit host needed.
//

import SwiftUI

/// Personalization backdrop. Non-interactive; cards carry depth, never the bg.
public struct BackgroundView: View {
    /// Right-fade width as a fraction. 0 disables the fade.
    public var fadeRatio: CGFloat
    /// Injected backdrop image, or nil for the plain MD3 surface state.
    public var image: UIImage?
    /// Blur tier 0...100 (mirrors ThemeManager.backgroundBlur).
    public var blurTier: Int
    /// Dark-mode dim alpha (mirrors ThemeManager.backgroundDarkOverlay).
    public var darkOverlay: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(fadeRatio: CGFloat = 0.35, image: UIImage? = nil, blurTier: Int = 0, darkOverlay: CGFloat = 0.28) {
        self.fadeRatio = max(0, min(1, fadeRatio))
        self.image = image
        self.blurTier = blurTier
        self.darkOverlay = darkOverlay
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.cSurface
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: effectiveBlur)
                }
                // 暗色遮罩：有图时按 darkOverlay 压暗；无图时也压一点，让卡片更分明（对齐 A2BackgroundView）。
                if colorScheme.isDark {
                    Color.black.opacity(image != nil ? darkOverlay : 0.18)
                }
                if fadeRatio > 0 {
                    LinearGradient(
                        stops: [
                            .init(color: Color.cSurface.opacity(0), location: 0),
                            .init(color: Color.cSurface.opacity(0.45), location: 0.6),
                            .init(color: Color.cSurface.opacity(colorScheme.isDark ? 0.92 : 0.88), location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * fadeRatio)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .onAppear {
                if image == nil {
                    A2ComponentLog("BackgroundView: no backdrop image; using plain MD3 surface state")
                } else if reduceTransparency, blurTier > 0 {
                    A2ComponentLog("BackgroundView: blur suppressed because Reduce Transparency is on; image stays unblurred")
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var effectiveBlur: CGFloat {
        guard !reduceTransparency else { return 0 }
        if blurTier <= 0 { return 0 }
        if blurTier < 30 { return 4 }
        if blurTier < 70 { return 10 }
        return 20
    }
}
