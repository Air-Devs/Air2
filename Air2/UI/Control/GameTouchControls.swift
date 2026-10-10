//
//  GameTouchControls.swift
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
//  In-game touch controls (Control layer had no ObjC originals):
//  left virtual joystick, right look area, jump/sneak/action button
//  cluster, pause entry. Input events leave through the delegate
//  protocol; this layer never touches the JVM bridge directly.

import SwiftUI

/// Control events, decoupled from any concrete bridge.
protocol GameControlsDelegate {
    func moveStick(_ dx: Double, _ dy: Double)
    func look(by dx: Double, dy: Double)
    func tapJump()
    func tapSneak()
    func tapAction(_ id: String)
    func tapPause()
}

struct GameTouchControls: View {
    var delegate: GameControlsDelegate?
    @State private var stickOffset = CGSize.zero
    @State private var sneakOn = false

    private let stickRadius: CGFloat = 56

    var body: some View {
        GeometryReader { _ in
            ZStack {
                // Right side: look area (drag to look around).
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                delegate?.look(
                                    by: Double(value.translation.width),
                                    dy: Double(value.translation.height)
                                )
                            }
                    )
                HStack {
                    // Left: virtual joystick.
                    joystick
                        .padding(.leading, A2SpaceXL)
                    Spacer()
                    // Right: button cluster.
                    buttonCluster
                        .padding(.trailing, A2SpaceXL)
                }
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { delegate?.tapPause() }) {
                            Image(systemName: "pause.fill")
                                .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
                                .foregroundStyle(.white)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(.trailing, A2SpaceL)
                    }
                    Spacer()
                }
            }
        }
    }

    private var joystick: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: stickRadius * 2, height: stickRadius * 2)
            Circle()
                .fill(Color.cSecondaryContainer)
                .frame(width: 56, height: 56)
                .offset(stickOffset)
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    let t = value.translation
                    let len = max(1, sqrt(t.width * t.width + t.height * t.height))
                    let clamped = min(1, len / stickRadius)
                    stickOffset = CGSize(
                        width: t.width / len * stickRadius * clamped,
                        height: t.height / len * stickRadius * clamped
                    )
                    delegate?.moveStick(
                        Double(stickOffset.width / stickRadius),
                        Double(-stickOffset.height / stickRadius)
                    )
                }
                .onEnded { _ in
                    stickOffset = .zero
                    delegate?.moveStick(0, 0)
                }
        )
    }

    private var buttonCluster: some View {
        VStack(spacing: A2SpaceM) {
            controlButton("arrow.up", id: "jump") { delegate?.tapJump() }
            HStack(spacing: A2SpaceM) {
                controlButton("hand.tap", id: "action") { delegate?.tapAction("use") }
                sneakButton
            }
        }
    }

    private func controlButton(_ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.impact()
            action()
        }) {
            Image(systemName: symbol)
                .frame(width: 64, height: 64)
                .foregroundStyle(.white)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private var sneakButton: some View {
        Button(action: {
            sneakOn.toggle()
            delegate?.tapSneak()
        }) {
            Image(systemName: sneakOn ? "eye.slash.fill" : "eye.fill")
                .frame(width: 64, height: 64)
                .foregroundStyle(.white)
                .background(
                    sneakOn ? Color.cPrimary : Color.cSecondaryContainer,
                    in: Circle()
                )
        }
    }
}
