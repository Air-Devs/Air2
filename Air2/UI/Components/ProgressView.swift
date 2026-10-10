//
//  ProgressView.swift
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
//  Mapping: A2ProgressView.h was an aggregate header only
//  (#import RingProgress + ProgressBar + TaskProgressView, no logic).
//  There is deliberately NO new `ProgressView` type here: SwiftUI already
//  owns that name, and redeclaring it would shadow the framework.
//  Import the three component files directly instead:
//    RingProgress.swift  (single-task ring)
//    ProgressBar.swift   (linear bar with glow head)
//    TaskProgressView.swift (task row incl. state dot + bar)
//

import SwiftUI

/// Documentation-only namespace for the progress family.
/// See RingProgress / ProgressBar / TaskProgressView.
public enum ProgressFamily {
    /// Single-task ring for install-style flows.
    public static var ringDescription: String { "RingProgress" }
    /// Linear bar with glow head for downloads.
    public static var barDescription: String { "ProgressBar" }
    /// Task row combining state dot, text and bar.
    public static var taskDescription: String { "TaskProgressView" }
}
