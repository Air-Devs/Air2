/*
 * PatchJNAAgent.java
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
package net.kdt.patchjna;

import java.io.*;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.IllegalClassFormatException;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.InvocationTargetException;
import java.security.ProtectionDomain;

public class PatchJNAAgent implements ClassFileTransformer {
    public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
    ProtectionDomain protectionDomain, byte[] classfileBuffer) throws IllegalClassFormatException {
        byte[] transformeredByteCode = classfileBuffer;
        if (className.equals("com/sun/jna/Platform")) {
            System.out.println("PatchJNAAgent: Replacing class");
            try {
                InputStream inputStream = PatchJNAAgent.class.getClassLoader().getResourceAsStream("com/sun/jna/Platform.class.patch");
                transformeredByteCode = new byte[inputStream.available()];
                DataInputStream dataInputStream = new DataInputStream(inputStream);
                dataInputStream.readFully(transformeredByteCode);
            } catch (Exception e) {
                e.printStackTrace();
            }
        }
        return transformeredByteCode;
    }

    public static void premain(String args, Instrumentation instrumentation) {
        System.out.println("PatchJNAAgent: premain called");
        instrumentation.addTransformer(new PatchJNAAgent());
    }
}
