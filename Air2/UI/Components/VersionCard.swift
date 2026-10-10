//
//  VersionCard.swift
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
//  Mapping: A2VersionCard : A2GlassCard + A2VersionCardStatus
//  (versionName/meta/status/pinned/versionIcon/selected/onSelect/onLongPress)
//  -> VersionCard + VersionCardStatus. L3 detail card (r16): icon box with
//  initial fallback OR unified remote icon, name/meta, status dot, pin badge
//  in container, selection ring. Tap selects (primary action, plain Button);
//  long-press only supplements with a context menu, never hides the action.
//  Tri-states: loading (skeleton) / content / deleted|inaccessible (dimmed).
//

import SwiftUI

public enum VersionCardStatus: Equatable {
    case loading
    case available
    case deleted
    case inaccessible
}

public struct VersionCard: View {
    public var versionName: String
    public var meta: String?
    public var status: VersionCardStatus
    public var isPinned: Bool
    /// Local icon; remote icons go through A2RemoteIcon phase below.
    public var versionIcon: UIImage?
    public var remotePhase: A2RemotePhase?
    public var isSelected: Bool
    public var onSelect: (() -> Void)?
    public var onLongPress: (() -> Void)?

    public init(
        versionName: String, meta: String? = nil, status: VersionCardStatus = .available,
        isPinned: Bool = false, versionIcon: UIImage? = nil, remotePhase: A2RemotePhase? = nil,
        isSelected: Bool = false, onSelect: (() -> Void)? = nil, onLongPress: (() -> Void)? = nil
    ) {
        self.versionName = versionName
        self.meta = meta
        self.status = status
        self.isPinned = isPinned
        self.versionIcon = versionIcon
        self.remotePhase = remotePhase
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onLongPress = onLongPress
    }

    private var initial: String {
        versionName.isEmpty ? "?" : String(versionName.prefix(1)).uppercased()
    }

    private var dimmed: Bool { status == .deleted || status == .inaccessible }

    private var effectiveMeta: String? {
        switch status {
        case .deleted: return meta?.isEmpty == false ? meta : "Version deleted"
        case .inaccessible: return "Directory inaccessible"
        case .loading: return "Checking..."
        case .available: return meta
        }
    }

    public var body: some View {
        GlassCard(level: .l3, insets: EdgeInsets(top: A2SpaceM, leading: A2SpaceM, bottom: A2SpaceM, trailing: A2SpaceM)) {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                HStack {
                    iconBox
                    Spacer(minLength: A2SpaceS)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.cPrimary)
                            .frame(width: 22, height: 22)
                    }
                }
                Text(versionName)
                    .font(A2Type.titleCard)
                    .foregroundStyle(Color.cOnSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(spacing: A2SpaceXS) {
                    if let effectiveMeta, !effectiveMeta.isEmpty {
                        Text(effectiveMeta)
                            .font(A2Type.caption)
                            .foregroundStyle(Color.cOnSurfaceVariant)
                            .lineLimit(1)
                    }
                    Spacer(minLength: A2SpaceXS)
                    if status == .deleted || status == .inaccessible {
                        Circle()
                            .fill(status == .deleted ? Color.cError : Color.cOutline)
                            .frame(width: 7, height: 7)
                    }
                }
            }
            .opacity(status == .loading ? 0.7 : (dimmed ? (status == .deleted ? 0.62 : 0.45) : 1.0))
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: A2RadiusL, style: .continuous)
                    .stroke(Color.cPrimary, lineWidth: 1.8)
            }
        }
        .onTapGesture {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            onSelect?()
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            onLongPress?()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(versionName)
        .onAppear {
            if status == .inaccessible {
                A2ComponentLog("VersionCard '\(versionName)': directory inaccessible; showing dimmed error state")
            } else if status == .deleted {
                A2ComponentLog("VersionCard '\(versionName)': version deleted; showing dimmed deleted state")
            }
        }
    }

    @ViewBuilder
    private var iconBox: some View {
        if let remotePhase {
            A2RemoteIcon(phase: remotePhase, size: 34)
        } else if let versionIcon {
            Image(uiImage: versionIcon)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: A2RadiusS, style: .continuous))
        } else {
            Text(initial)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.cPrimary.opacity(0.85), in: RoundedRectangle(cornerRadius: A2RadiusS, style: .continuous))
        }
    }
}
