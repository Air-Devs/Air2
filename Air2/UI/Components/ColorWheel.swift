//
//  ColorWheel.swift
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
//  Mapping: A2ColorWheel + A2ColorWheelDelegate
//  (color/setColor:animated:/showsBrightnessSlider/didChange/didFinish) ->
//  ColorWheel (hue/saturation/brightness Bindings + onChange/onFinish +
//  showsBrightnessSlider). 2-D hue×saturation palette + brightness strip,
//  same rationale as the original: continuous, predictable picking.
//  Pure SwiftUI drag gestures; no UIKit host needed.
//

import SwiftUI

public struct ColorWheel: View {
    @Binding public var hue: CGFloat
    @Binding public var saturation: CGFloat
    @Binding public var brightness: CGFloat
    public var showsBrightnessSlider: Bool
    public var onChange: ((Color) -> Void)?
    public var onFinish: ((Color) -> Void)?

    public init(
        hue: Binding<CGFloat>, saturation: Binding<CGFloat>, brightness: Binding<CGFloat>,
        showsBrightnessSlider: Bool = true,
        onChange: ((Color) -> Void)? = nil, onFinish: ((Color) -> Void)? = nil
    ) {
        self._hue = hue
        self._saturation = saturation
        self._brightness = brightness
        self.showsBrightnessSlider = showsBrightnessSlider
        self.onChange = onChange
        self.onFinish = onFinish
    }

    /// Convenience state-owning init from a starting Color.
    public init(color: Color = .red, showsBrightnessSlider: Bool = true, onChange: ((Color) -> Void)? = nil, onFinish: ((Color) -> Void)? = nil) {
        let comps = Self.hsb(of: color)
        self._hue = .constant(comps.h)
        self._saturation = .constant(comps.s)
        self._brightness = .constant(comps.b)
        self.showsBrightnessSlider = showsBrightnessSlider
        self.onChange = onChange
        self.onFinish = onFinish
    }

    public var current: Color {
        Color(hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness))
    }

    public var body: some View {
        VStack(spacing: A2SpaceM) {
            GeometryReader { geo in
                ZStack {
                    LinearGradient(
                        gradient: Gradient(colors: stride(from: 0, through: 1, by: 0.1).map {
                            Color(hue: $0, saturation: 1, brightness: 1)
                        }),
                        startPoint: .leading, endPoint: .trailing
                    )
                    LinearGradient(
                        gradient: Gradient(colors: [.white.opacity(0), .white]),
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: A2RadiusM, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Circle()
                        .strokeBorder(.white, lineWidth: 2.5)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .frame(width: 18, height: 18)
                        .offset(
                            x: geo.size.width * hue - 9,
                            y: geo.size.height * (1 - saturation) - 9
                        )
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    hue = max(0, min(1, value.location.x / max(1, geo.size.width)))
                    saturation = max(0, min(1, 1 - value.location.y / max(1, geo.size.height)))
                    onChange?(current)
                }.onEnded { _ in onFinish?(current) })
                .frame(minHeight: A2MinTouchTarget)
            }
            .aspectRatio(1.6, contentMode: .fit)

            if showsBrightnessSlider {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.black, Color(hue: Double(hue), saturation: Double(saturation), brightness: 1)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: A2RadiusS, style: .continuous))
                    .overlay(alignment: .leading) {
                        Circle()
                            .strokeBorder(.white, lineWidth: 2.5)
                            .shadow(color: .black.opacity(0.4), radius: 3)
                            .frame(width: 16, height: 16)
                            .offset(x: geo.size.width * brightness - 8)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        brightness = max(0, min(1, value.location.x / max(1, geo.size.width)))
                        onChange?(current)
                    }.onEnded { _ in onFinish?(current) })
                }
                .frame(height: max(32, A2MinTouchTarget))
            }
        }
    }

    private static func hsb(of color: Color) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0.8, b: CGFloat = 0.6, a: CGFloat = 0
        if !ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            A2ComponentLog("ColorWheel: grayscale color has no hue; keeping selector hue, taking brightness only")
            s = 0
        }
        return (h, s, b)
    }
}
