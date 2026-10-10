//
//  SkinHeadView.swift
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
//  Mapping: A2SkinHeadView (skinPath/fallbackText) -> SkinHeadView.
//  deliberate API change: the View takes the already-cropped headImage,
//  never a file path. Cropping + downloading stay in Core (A2Wardrobe);
//  Views do no file IO. The 8x8 face + hat overlay + nearest-neighbor rule
//  are preserved in Wardrobe's crop helper contract documented below.
//  No UIKit host needed.
//

import SwiftUI

/// Player avatar. Pass the cropped 8x8-overlaid head image (face + hat layer,
/// composited at source pixels, upscaled with nearest-neighbor only).
/// Nil image falls back to the initial placeholder and logs why.
public struct SkinHeadView: View {
    public var headImage: UIImage?
    public var fallbackText: String?
    public var size: CGFloat

    public init(headImage: UIImage? = nil, fallbackText: String? = nil, size: CGFloat = 46) {
        self.headImage = headImage
        self.fallbackText = fallbackText
        self.size = size
    }

    private var initial: String {
        guard let fallbackText, !fallbackText.isEmpty else { return "?" }
        return String(fallbackText.prefix(1)).uppercased()
    }

    public var body: some View {
        Group {
            if let headImage {
                Image(uiImage: headImage)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fill)
            } else {
                Text(initial)
                    .font(.system(size: max(11, size * 0.41), weight: .semibold))
                    .foregroundStyle(Color.cOnPrimaryContainer)
                    .frame(width: size, height: size)
                    .background(Color.cPrimaryContainer)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .onAppear {
            if headImage == nil {
                A2ComponentLog("SkinHeadView: no head image; showing '\(initial)' placeholder (owner resolves via Wardrobe)")
            }
        }
    }
}
