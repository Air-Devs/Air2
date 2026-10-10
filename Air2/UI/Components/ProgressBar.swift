//
//  ProgressBar.swift
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
//  Mapping: A2ProgressBar (progress/speedText/detailText/setProgress:animated:)
//  -> ProgressBar. Linear track + fill + glow head + numeric detail/speed.
//  Glow is an overlay shadow, never clipped (masksToBounds stays false).
//

import SwiftUI

public struct ProgressBar: View {
    /// 0...1, clamped.
    public var progress: CGFloat
    public var speedText: String?
    public var detailText: String?

    public init(progress: CGFloat, speedText: String? = nil, detailText: String? = nil) {
        self.progress = max(0, min(1, progress))
        self.speedText = speedText
        self.detailText = detailText
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: A2SpaceS) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.13))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.cPrimary)
                        .frame(width: geo.size.width * progress)
                        .animation(.a2Standard, value: progress)
                    if progress > 0.01, progress < 0.99 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.cPrimary.opacity(0.55))
                            .frame(width: 24, height: 6)
                            .shadow(color: .cPrimary.opacity(0.8), radius: 6)
                            .offset(x: max(0, geo.size.width * progress - 12))
                    }
                }
            }
            .frame(height: 6)
            .accessibilityValue("\(Int(progress * 100)) percent")
            HStack {
                if let detailText {
                    Text(detailText).font(A2Type.numeric).foregroundStyle(Color.cOnSurfaceVariant)
                }
                Spacer(minLength: A2SpaceS)
                if let speedText {
                    Text(speedText).font(A2Type.numeric).foregroundStyle(Color.cPrimary)
                }
            }
        }
    }
}
