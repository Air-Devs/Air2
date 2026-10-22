/*
 * OperatingSystem.java
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
 * Task 73：复刻真实 text2speech 1.19.12 的 OperatingSystem 枚举。
 *
 * ModernFix（suppress_narrator_stacktrace，Fabulously Optimized v14.x 自带）
 * 的 GameNarratorMixin 引用 OperatingSystem.get()/ordinal()，其内部 switch-map
 * 合成类调用 values()；桩包缺失该枚举会在运行期抛
 * NoClassDefFoundError: com/mojang/text2speech/OperatingSystem。
 *
 * 真实检测逻辑（自 1.19.12 jar 反编译确认）：os.name 转小写后
 * contains("linux") → LINUX、contains("win") → WINDOWS、contains("mac") → MAC_OS，
 * 其余 UNSUPPORTED。iOS 上 os.name = "Mac OS X" → MAC_OS（走 dummy 叙述器路径，
 * 平台叙述器不会被构造）。detectWith 字段仅为 API 形状对齐，无外部调用方。
 */
public enum OperatingSystem {
    LINUX("linux"),
    WINDOWS("win"),
    MAC_OS("mac"),
    UNSUPPORTED("");

    private final String detectWith;

    OperatingSystem(final String detectWith) {
        this.detectWith = detectWith;
    }

    public static OperatingSystem get() {
        final String name = System.getProperty("os.name", "").toLowerCase();
        if (name.contains("linux")) {
            return LINUX;
        }
        if (name.contains("win")) {
            return WINDOWS;
        }
        if (name.contains("mac")) {
            return MAC_OS;
        }
        return UNSUPPORTED;
    }
}
