/*
 * JSONUtils.java
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
package net.kdt.pojavlaunch.utils;

import java.util.*;

public class JSONUtils {
    public static String[] insertJSONValueList(String[] args, Map<String, String> keyValueMap) {
        for (int i = 0; i < args.length; i++) {
            args[i] = insertSingleJSONValue(args[i], keyValueMap);
        }
        return args;
    }
    
    public static String insertSingleJSONValue(String value, Map<String, String> keyValueMap) {
        String valueInserted = value;
        for (Map.Entry<String, String> keyValue : keyValueMap.entrySet()) {
            if (keyValue.getValue() == null) {
                keyValue.setValue("");
            }
            valueInserted = valueInserted.replace("${" + keyValue.getKey() + "}", keyValue.getValue());
        }
        return valueInserted;
    }
}
