/*
 * LauncherProfiles.java
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
package net.kdt.pojavlaunch.value.launcherprofiles;
import com.google.gson.*;
import net.kdt.pojavlaunch.*;
import java.io.*;

public class LauncherProfiles
{
    public static MinecraftLauncherProfiles mainProfileJson;
    public static File launcherProfilesFile = new File(Tools.DIR_GAME_NEW + "/launcher_profiles.json");
    public static MinecraftLauncherProfiles update() {
        try {
            if (mainProfileJson == null) {
                if (launcherProfilesFile.exists()) {
                    mainProfileJson = Tools.GLOBAL_GSON.fromJson(Tools.read(launcherProfilesFile.getAbsolutePath()), MinecraftLauncherProfiles.class);
                } else {
                    mainProfileJson = new MinecraftLauncherProfiles();
                }
            } else {
                Tools.write(launcherProfilesFile.getAbsolutePath(), mainProfileJson.toJson());
            }

            // insertMissing();
            return mainProfileJson;
        } catch (Throwable th) {
            throw new RuntimeException(th);
        }
    }
    /*
     public static String insert;

     private static void insertMissing() {
     if (mainProfileJson.authenticationDatabase == null) {
     MinecraftAuthenticationDatabase mad = new MinecraftAuthenticationDatabase();
     mainProfileJson.authenticationDatabase = mad;
     }
     }
     */
}
