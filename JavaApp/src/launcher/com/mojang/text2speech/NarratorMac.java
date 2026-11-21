/*
 * NarratorMac.java
 * Air2
 *
 * Copyright (C) 2026 Air-Devs and contributors.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package com.mojang.text2speech;

/**
 * Task 73：真实 text2speech 1.19.12 的 macOS 叙述器类名为 NarratorMac
 * （旧版桩误命名为 NarratorOSX，与真实 jar 不符）。
 *
 * 当前 client 26.2/26.3 与 FO v14.1.0 的 51 个 mod 均未直接引用该类，
 * 此处仅为 API 形状对齐的防御性补齐：若未来 mod（或 ModernFix 新版本）
 * 按 OperatingSystem.get()==MAC_OS 分支构造 NarratorMac，不再缺符号。
 * 行为与 NarratorDummy 一致——iOS 无 AppKit 语音合成，叙述器始终为空实现。
 */
public class NarratorMac extends NarratorDummy {
}
