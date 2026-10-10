//
//  RingProgress.swift
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
//  Mapping: A2RingProgress (progress/lineWidth/centerText/captionText/
//  setProgress:animated:) -> RingProgress. 12-o'clock start, round caps,
//  center percent + caption. No UIKit host needed.
//

import SwiftUI

public struct RingProgress: View {
    public var progress: CGFloat
    public var lineWidth: CGFloat
    public var centerText: String?
    public var captionText: String?
    public var diameter: CGFloat

    public init(progress: CGFloat, lineWidth: CGFloat = 6, centerText: String? = nil, captionText: String? = nil, diameter: CGFloat = 120) {
        self.progress = max(0, min(1, progress))
        self.lineWidth = lineWidth
        self.centerText = centerText
        self.captionText = captionText
        self.diameter = diameter
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.cPrimary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.a2Standard, value: progress)
            VStack(spacing: 2) {
                if let centerText {
                    Text(centerText)
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.cOnSurface)
                }
                if let captionText {
                    Text(captionText)
                        .font(A2Type.caption)
                        .foregroundStyle(Color.cOnSurfaceVariant)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}
