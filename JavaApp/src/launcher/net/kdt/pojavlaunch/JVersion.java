/*
 * JVersion.java
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
package net.kdt.pojavlaunch;

public class JVersion extends Object
{
    private String version;
    private JVersion(String version)
    {
        this.version = version;
    }
    public static JVersion from(String version)
    {
        return new JVersion(version);
    }
    public boolean isVersionCode()
    {
        return !version.contains(".");
    }
    public JVersion toVersionCode()
    {
        if(!isVersionCode()){
            version = version.replace(".", "");
            return this;
        } else throw new RuntimeException("Can't convert version code to itself");
    }
    public JVersion toVersionName()
    {
        if(isVersionCode()){
            StringBuilder charList = new StringBuilder();
            for(int i=0; i<version.length(); i++){
                charList.append(version.substring(i, i+1));
                if(i != version.length() - 1){
                    charList.append(".");
                }
            }
            version = charList.toString();
            return this;
        } else throw new RuntimeException("Can't convert version name to itself");
    }
    public String getVersion()
    {
        return version;
    }
}
