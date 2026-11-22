/*
 * MinecraftAccount.java
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
package net.kdt.pojavlaunch.value;
import net.kdt.pojavlaunch.*;
import java.io.*;
import com.google.gson.*;

public class MinecraftAccount
{
    public String accessToken = "0"; // access token
    public String clientToken = "0"; // clientID: refresh and invalidate
    public String profileId = "00000000-0000-0000-0000-000000000000"; // authenticate UUID
    public String username = "Steve";
    public String xuid;
    // 账户唯一标识：微软账户=xuid，第三方账户=profileId，本地账户=UUID
    // 与原生端 BaseAuthenticator.authData[@"accountId"] 一致，用作账户文件名
    public String accountId = "";

    public String save(String outPath) throws IOException {
        Tools.write(outPath, Tools.GLOBAL_GSON.toJson(this));
        return outPath;
    }

    public String save() throws IOException {
        // 文件名使用 accountId（唯一标识），同名账户不再冲突
        String id = (accountId != null && !accountId.isEmpty()) ? accountId : username;
        return save(Tools.DIR_ACCOUNT_NEW + "/" + id + ".json");
    }

    public static MinecraftAccount parse(String content) throws JsonSyntaxException {
        MinecraftAccount account = Tools.GLOBAL_GSON.fromJson(content, MinecraftAccount.class);
        // Read access token from keychain
        if (account.xuid != null) {
            account.accessToken = getAccessTokenFromKeychain(account.xuid);
        }
        return account;
    }

    public static MinecraftAccount load(String name) throws IOException, JsonSyntaxException {
        // name 即 accountId（由原生端 launchJVM 的 args[0] 传入）。
        //
        // ★ 文件名可能与 accountId 不同 ★
        //
        // 原生端 A2AccountManager.persistAccount: 用 account.uniqueID 作文件名
        //     <POJAV_HOME>/account/<uniqueID>.json
        // 而 launchJVM 传给 args[0] 的是 accountId（很可能等于 profileID）。
        // 两者不等时直接拼 "<accountId>.json" 必然 FileNotFoundException：
        //     java.io.FileNotFoundException: .../account/f3801073....json
        //     at MinecraftAccount.load -> PojavLauncher.launchMinecraft
        // 上机日志已实锤（目录里实际是 145e1e88... / 97a50668... 这类文件）。
        //
        // 因此按优先级找：accountId 同名文件 → 扫描目录里哪个 JSON 的
        // accountId/profileId/xuid/username 命中 → 最后才用第一个可解析的账号。
        File direct = new File(Tools.DIR_ACCOUNT_NEW + "/" + name + ".json");
        String content;
        if (direct.isFile()) {
            content = Tools.read(direct.getAbsolutePath());
        } else {
            content = findAccountJsonByField(name);
            if (content == null) {
                // 兜底：目录里任意一个能解析的账号（单账号场景下就是它）
                content = firstAccountJson();
            }
            if (content == null) {
                throw new FileNotFoundException("no usable account json in " + Tools.DIR_ACCOUNT_NEW);
            }
            System.out.println("[MinecraftAccount] accountId " + name
                    + " 未直接命中文件，已按字段匹配/兜底读取");
        }
        MinecraftAccount acc = parse(content);
        if (acc.accessToken == null) {
            acc.accessToken = "0";
        } if (acc.clientToken == null) {
            acc.clientToken = "0";
        } if (acc.profileId == null) {
            acc.profileId = "0";
        } if (acc.username == null) {
            acc.username = "0";
        } if (acc.xuid == null) {
            acc.xuid = "0";
        }
        // 兜底 accountId：优先用入参 name（原生端传入的 accountId），其次 xuid，最后 profileId
        if (acc.accountId == null || acc.accountId.isEmpty()) {
            acc.accountId = name;
        }
        return acc;
    }

    /// 在 account 目录里找 JSON：其 accountId / profileId / xuid / username
    /// 任一等于 name 即算命中。找不到返回 null。
    private static String findAccountJsonByField(String name) {
        File dir = new File(Tools.DIR_ACCOUNT_NEW);
        File[] files = dir.listFiles();
        if (files == null) return null;
        Gson gson = Tools.GLOBAL_GSON;
        for (File f : files) {
            if (!f.isFile() || !f.getName().endsWith(".json")) continue;
            try {
                String raw = Tools.read(f.getAbsolutePath());
                MinecraftAccount a = gson.fromJson(raw, MinecraftAccount.class);
                if (a == null) continue;
                if (name.equals(a.accountId) || name.equals(a.profileId)
                        || name.equals(a.xuid) || name.equals(a.username)) {
                    return raw;
                }
            } catch (Throwable ignored) {
                // 坏文件跳过，继续找
            }
        }
        return null;
    }

    /// 目录里第一个可解析的账号 JSON（单账号场景的兜底）。
    private static String firstAccountJson() {
        File dir = new File(Tools.DIR_ACCOUNT_NEW);
        File[] files = dir.listFiles();
        if (files == null) return null;
        Gson gson = Tools.GLOBAL_GSON;
        for (File f : files) {
            if (!f.isFile() || !f.getName().endsWith(".json")) continue;
            try {
                String raw = Tools.read(f.getAbsolutePath());
                if (gson.fromJson(raw, MinecraftAccount.class) != null) return raw;
            } catch (Throwable ignored) {
            }
        }
        return null;
    }

    static {
        System.loadLibrary("AmethystAccountJNI");
    }
    public static native String getAccessTokenFromKeychain(String xuid);
}
