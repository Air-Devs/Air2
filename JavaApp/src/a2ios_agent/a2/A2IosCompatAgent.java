package a2;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import java.util.HashSet;
import java.util.Set;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Label;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/**
 * Air2 iOS 兼容 javaagent —— 清掉 MC 里所有走 macOS AppKit 的方法体。
 *
 * 真机根因（1.20.1 → lastlog-111，1.19.2 → lastlog-131）：
 *   MC 在「Initializing game」阶段会调 macOS 专属路径
 *   （vanilla 的 MacosUtil.disableCloseWindowMenuItem、应用图标设置等），
 *   它们最终走 ca.weblite.objc.RuntimeUtils.&lt;clinit&gt; → System.load(libjcocoa*.dylib)，
 *   iOS 上 dlopen 到的是 macOS Mach-O，必然失败并中断启动。
 *
 * ★为什么不再按混淆名逐个修★
 *   1.20.1 是 ehg，1.19.2 是 dzm；每个版本的混淆名都不同，硬编码等于每次都补一个。
 *   现在改为【通用规则 C】：扫描每个类，凡是方法体里调用了
 *     ca/weblite/objc/**、com/apple/eawt/**、com/sun/jna/platform/mac/**
 *   的方法，一律把方法体替换成「返回默认值」（void → RETURN，基本类型 → 0，
 *   引用类型 → null）。构造函数 &lt;init&gt; / 静态块 &lt;clinit&gt; 不动
 *   （置空会留下未初始化对象 ⇒ VerifyError）。
 *
 * 规则 A（ehg 精确置空）与规则 B（NarratorMac 定义失败）保留：
 *   A 是已知的 1.20.1 两个方法，语义明确；B 让 MC 自己降级到 Narrator.EMPTY。
 */
public final class A2IosCompatAgent implements ClassFileTransformer {

    /** 规则 A：1.20.1 的 ehg 两个 macOS 方法（菜单 / 应用图标）。 */
    private static final String TARGET_CLASS = "ehg";
    private static final String TARGET_METHOD = "a";
    private static final String[] TARGET_DESCS = { "(J)V", "(Lakp;)V" };

    /** 规则 B：MC 的 macOS 朗读器实现。 */
    private static final String NARRATORMAC_CLASS = "com/mojang/text2speech/NarratorMac";
    /** 规则 D：LWJGL 原生库哈希校验。 */
    private static final String LWJGL_LIBRARY_CLASS = "org/lwjgl/system/Library";
    /** 规则 F：★[A2-GL2-PROBE] 固定管线入口绑定取证★（GL11 的 <clinit> 末尾插一条探针调用）。 */
    private static final String GL11_CLASS = "org/lwjgl/opengl/GL11";

    /** 规则 C：只要方法体碰了这些包，就判定为 macOS 专属实现。 */
    private static final String[] FORBIDDEN_OWNER_PREFIXES = {
        "ca/weblite/objc/",
        "com/apple/eawt/",
        "com/sun/jna/platform/mac/",
    };

    public static void premain(String args, Instrumentation inst) {
        inst.addTransformer(new A2IosCompatAgent());
    }

    public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
                            ProtectionDomain protectionDomain, byte[] classfileBuffer) {
        if (className == null) {
            return null;
        }
        // 规则 B：把 NarratorMac 变成「合法但空实现」的类。
        //   ★2026-11-01 真机（1.19.2, lastlog-134）★ 旧做法是返回 0xCAFEBABE 让它定义失败，
        //   1.20.1 的 Narrator.getNarrator 用 catch(Throwable) 能接住；1.19.2 只 catch Exception，
        //   ClassFormatError 直接冒到 Main.main ⇒ 启动崩。
        //   ⇒ 改成：类正常加载，但构造只调 super()、其余方法返回默认值 ⇒ 不会碰 AppKit，也不会抛 Error。
        if (NARRATORMAC_CLASS.equals(className)) {
            byte[] patched = patchInertClass(className, classfileBuffer);
            if (patched != null) {
                System.out.println("[A2IOS-AGENT] NarratorMac 已置为合法空实现（不碰 AppKit）");
                return patched;
            }
            return null;
        }
        // 规则 A：ehg 精确置空。
        if (TARGET_CLASS.equals(className)) {
            byte[] patched = patchEhg(classfileBuffer);
            if (patched != null) {
                return patched;
            }
        }
        // 规则 D：跳过 LWJGL 的原生库哈希校验。
        //   换过 LWJGL 二进制（我们经常换）或启动器解包后字节有差异时，
        //   org.lwjgl.system.Library.checkHash 会直接抛异常终止启动。
        //   这里把 checkHash(String,String) 方法体置空（void，无需返回值）。
        if (LWJGL_LIBRARY_CLASS.equals(className)) {
            byte[] patched = patchCheckHash(classfileBuffer);
            if (patched != null) {
                return patched;
            }
        }
        // 规则 F：★[A2-GL2-PROBE] 固定管线入口绑定取证★
        //   为什么钉 GL11：MC ≤1.12.2 的 glBegin/glEnd/glVertex3f/glColor4f/glMatrixMode/
        //   glLoadIdentity 都是 `org.lwjgl.opengl.GL11` 的 public static native
        //   （javap 实测；glDrawArrays 的 native 声明在 GL11C 上）。取证要在「类刚初始化完」
        //   这一刻做：此时 JNI 尚未绑定到我们的实现，看到的就是原路径。
        //   ★只插一条 INVOKESTATIC a2/A2Gl2Probe.run()V，不改任何原有指令★。
        if (GL11_CLASS.equals(className)) {
            byte[] patched = patchGl11Probe(classfileBuffer);
            if (patched != null) {
                return patched;
            }
            return null;   // GL11 不碰 AppKit，不必再走规则 C
        }
        // 规则 C：通用 AppKit 方法体置空。
        return patchAppKitMethods(className, classfileBuffer);
    }

    /** 规则 A：ehg 的两个 (J)V、(Lakp;)V 方法体置空。 */
    private static byte[] patchEhg(byte[] classfileBuffer) {
        try {
            ClassReader cr = new ClassReader(classfileBuffer);
            ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_MAXS);
            final boolean[] hit = { false };
            cr.accept(new ClassVisitor(Opcodes.ASM9, cw) {
                @Override
                public MethodVisitor visitMethod(int access, String name, String descriptor,
                                                 String signature, String[] exceptions) {
                    MethodVisitor mv = super.visitMethod(access, name, descriptor, signature, exceptions);
                    boolean wanted = false;
                    if (TARGET_METHOD.equals(name)) {
                        for (String d : TARGET_DESCS) {
                            if (d.equals(descriptor)) {
                                wanted = true;
                                break;
                            }
                        }
                    }
                    if (!wanted) {
                        return mv;
                    }
                    hit[0] = true;
                    return new EmptyBody(mv, descriptor);
                }
            }, 0);
            if (!hit[0]) {
                return null;
            }
            System.out.println("[A2IOS-AGENT] ehg.a 已置空（macOS AppKit 菜单/图标）");
            return cw.toByteArray();
        } catch (Throwable t) {
            System.out.println("[A2IOS-AGENT] ehg 改写失败: " + t);
            return null;
        }
    }

    /** 规则 D：把 org/lwjgl/system/Library.checkHash(String,String) 置空。 */
    private static byte[] patchCheckHash(byte[] classfileBuffer) {
        try {
            ClassReader cr = new ClassReader(classfileBuffer);
            ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_MAXS);
            final boolean[] hit = { false };
            cr.accept(new ClassVisitor(Opcodes.ASM9, cw) {
                @Override
                public MethodVisitor visitMethod(int access, String name, String descriptor,
                                                 String signature, String[] exceptions) {
                    MethodVisitor mv = super.visitMethod(access, name, descriptor, signature, exceptions);
                    if ("checkHash".equals(name)) {
                        hit[0] = true;
                        return new EmptyBody(mv, descriptor);
                    }
                    return mv;
                }
            }, 0);
            if (!hit[0]) {
                return null;
            }
            System.out.println("[A2IOS-AGENT] LWJGL checkHash 已跳过（换过原生库不再因哈希校验中止）");
            return cw.toByteArray();
        } catch (Throwable t) {
            System.out.println("[A2IOS-AGENT] checkHash 改写失败: " + t);
            return null;
        }
    }

    /**
     * 规则 F：在 {@code GL11.<clinit>} 的每个 RETURN 之前插 {@code a2/A2Gl2Probe.run()V}。
     *
     * 只增一条 static 调用、不改任何原有指令 ⇒ 语义与没有探针时一致（探针自身也只打印）。
     * 为什么选 {@code <clinit>}：GL11 的静态初始化只跑一次，且发生在 MC 第一次 GL 调用之前，
     * 此时还没走到我们的 RegisterNatives，看到的就是**原绑定路径**。
     */
    private static byte[] patchGl11Probe(byte[] classfileBuffer) {
        try {
            ClassReader cr = new ClassReader(classfileBuffer);
            ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_MAXS);
            final boolean[] hit = { false };
            cr.accept(new ClassVisitor(Opcodes.ASM9, cw) {
                @Override
                public MethodVisitor visitMethod(int access, String name, String descriptor,
                                                 String signature, String[] exceptions) {
                    MethodVisitor mv = super.visitMethod(access, name, descriptor, signature, exceptions);
                    if (!"<clinit>".equals(name)) {
                        return mv;
                    }
                    hit[0] = true;
                    return new MethodVisitor(Opcodes.ASM9, mv) {
                        @Override
                        public void visitInsn(int opcode) {
                            if (opcode == Opcodes.RETURN) {
                                super.visitMethodInsn(Opcodes.INVOKESTATIC,
                                        "a2/A2Gl2Probe", "run", "()V", false);
                            }
                            super.visitInsn(opcode);
                        }
                    };
                }
            }, 0);
            if (!hit[0]) {
                System.out.println("[A2IOS-AGENT] GL11 没有 <clinit> ⇒ [A2-GL2-PROBE] 探针未注入");
                return null;
            }
            System.out.println("[A2IOS-AGENT] GL11.<clinit> 已注入 [A2-GL2-PROBE] 探针");
            return cw.toByteArray();
        } catch (Throwable t) {
            System.out.println("[A2IOS-AGENT] 规则 F（GL11 探针）改写失败: " + t);
            return null;
        }
    }

    /** 规则 B 用：整类方法体置空；构造只调 super()，保证类合法可加载。 */
    private static byte[] patchInertClass(String className, byte[] classfileBuffer) {
        try {
            ClassReader cr = new ClassReader(classfileBuffer);
            final String superName = cr.getSuperName();   // ★真实父类★，不能写死 Object（曾导致 VerifyError）
            ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_MAXS);
            cr.accept(new ClassVisitor(Opcodes.ASM9, cw) {
                @Override
                public MethodVisitor visitMethod(int access, String name, String descriptor,
                                                 String signature, String[] exceptions) {
                    MethodVisitor mv = super.visitMethod(access, name, descriptor, signature, exceptions);
                    if ("<init>".equals(name)) {
                        return new CtorBody(mv, superName);
                    }
                    if ("<clinit>".equals(name)) {
                        return mv;   // 静态初始化保持原样（NarratorMac 的静态块不含 AppKit 调用）
                    }
                    return new EmptyBody(mv, descriptor);
                }
            }, 0);
            return cw.toByteArray();
        } catch (Throwable t) {
            System.out.println("[A2IOS-AGENT] 空实现改写失败 " + className + ": " + t);
            return null;
        }
    }

    /** 构造函数：aload_0; invokespecial Object.<init>; return */
    private static final class CtorBody extends MethodVisitor {
        private final String superName;

        CtorBody(MethodVisitor mv, String superName) {
            super(Opcodes.ASM9, mv);
            this.superName = superName;
        }
        @Override
        public void visitCode() {
            super.visitCode();
            super.visitVarInsn(Opcodes.ALOAD, 0);
            super.visitMethodInsn(Opcodes.INVOKESPECIAL, superName, "<init>", "()V", false);
            super.visitInsn(Opcodes.RETURN);
            super.visitMaxs(1, 1);
            super.visitEnd();
        }
        @Override public void visitInsn(int opcode) { }
        @Override public void visitIntInsn(int opcode, int operand) { }
        @Override public void visitVarInsn(int opcode, int varIndex) { }
        @Override public void visitTypeInsn(int opcode, String type) { }
        @Override public void visitFieldInsn(int opcode, String owner, String name, String descriptor) { }
        @Override public void visitMethodInsn(int opcode, String owner, String name, String descriptor, boolean isInterface) { }
        @Override public void visitInvokeDynamicInsn(String name, String descriptor,
                                                    org.objectweb.asm.Handle bsm, Object... bsmArgs) { }
        @Override public void visitJumpInsn(int opcode, Label label) { }
        @Override public void visitLabel(Label label) { }
        @Override public void visitLdcInsn(Object value) { }
        @Override public void visitIincInsn(int varIndex, int increment) { }
        @Override public void visitTableSwitchInsn(int min, int max, Label dflt, Label... labels) { }
        @Override public void visitLookupSwitchInsn(Label dflt, int[] keys, Label[] labels) { }
        @Override public void visitMultiANewArrayInsn(String descriptor, int numDimensions) { }
        @Override public void visitTryCatchBlock(Label start, Label end, Label handler, String type) { }
        @Override public void visitLocalVariable(String name, String descriptor, String signature,
                                                 Label start, Label end, int index) { }
        @Override public void visitLineNumber(int line, Label start) { }
        @Override public void visitFrame(int type, int numLocal, Object[] local, int numStack, Object[] stack) { }
        @Override public void visitMaxs(int maxStack, int maxLocals) { }
        @Override public void visitEnd() { }
    }

    /**
     * 规则 C：先扫一遍这个类，记下所有调用了被禁包的方法（name+desc）；
     * 有命中就重写一遍，把这些方法的方法体换成返回默认值。
     */
    private static byte[] patchAppKitMethods(String className, byte[] classfileBuffer) {
        try {
            ClassReader cr = new ClassReader(classfileBuffer);
            final Set<String> offenders = new HashSet<String>();
            cr.accept(new ClassVisitor(Opcodes.ASM9) {
                @Override
                public MethodVisitor visitMethod(int access, String name, String descriptor,
                                                 String signature, String[] exceptions) {
                    if ("<init>".equals(name) || "<clinit>".equals(name)) {
                        return null;   // 构造函数/静态块不参与判定
                    }
                    final String key = name + descriptor;
                    return new MethodVisitor(Opcodes.ASM9) {
                        @Override
                        public void visitMethodInsn(int opcode, String owner, String mName,
                                                    String mDesc, boolean isInterface) {
                            if (isForbiddenOwner(owner)) {
                                offenders.add(key);
                            }
                        }
                        @Override
                        public void visitFieldInsn(int opcode, String owner, String fName, String fDesc) {
                            if (isForbiddenOwner(owner)) {
                                offenders.add(key);
                            }
                        }
                    };
                }
            }, ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);

            if (offenders.isEmpty()) {
                return null;
            }

            ClassReader cr2 = new ClassReader(classfileBuffer);
            ClassWriter cw = new ClassWriter(cr2, ClassWriter.COMPUTE_MAXS);
            cr2.accept(new ClassVisitor(Opcodes.ASM9, cw) {
                @Override
                public MethodVisitor visitMethod(int access, String name, String descriptor,
                                                 String signature, String[] exceptions) {
                    MethodVisitor mv = super.visitMethod(access, name, descriptor, signature, exceptions);
                    if (offenders.contains(name + descriptor)) {
                        System.out.println("[A2IOS-AGENT] 置空 macOS 方法: " + className + "." + name + descriptor);
                        return new EmptyBody(mv, descriptor);
                    }
                    return mv;
                }
            }, 0);
            return cw.toByteArray();
        } catch (Throwable t) {
            System.out.println("[A2IOS-AGENT] 规则 C 改写失败 " + className + ": " + t);
            return null;
        }
    }

    private static boolean isForbiddenOwner(String owner) {
        if (owner == null) {
            return false;
        }
        for (String p : FORBIDDEN_OWNER_PREFIXES) {
            if (owner.startsWith(p)) {
                return true;
            }
        }
        return false;
    }

    /** 丢弃原方法体，只写「返回默认值」。 */
    private static final class EmptyBody extends MethodVisitor {

        private final String descriptor;

        EmptyBody(MethodVisitor mv, String descriptor) {
            super(Opcodes.ASM9, mv);
            this.descriptor = descriptor;
        }

        @Override
        public void visitCode() {
            super.visitCode();
            String ret = descriptor.substring(descriptor.indexOf(')') + 1);
            char c = ret.charAt(0);
            switch (c) {
                case 'V':
                    super.visitInsn(Opcodes.RETURN);
                    break;
                case 'Z':
                case 'B':
                case 'C':
                case 'S':
                case 'I':
                    super.visitInsn(Opcodes.ICONST_0);
                    super.visitInsn(Opcodes.IRETURN);
                    break;
                case 'J':
                    super.visitInsn(Opcodes.LCONST_0);
                    super.visitInsn(Opcodes.LRETURN);
                    break;
                case 'F':
                    super.visitInsn(Opcodes.FCONST_0);
                    super.visitInsn(Opcodes.FRETURN);
                    break;
                case 'D':
                    super.visitInsn(Opcodes.DCONST_0);
                    super.visitInsn(Opcodes.DRETURN);
                    break;
                default:   // Lxxx; 或 [xxx
                    super.visitInsn(Opcodes.ACONST_NULL);
                    super.visitInsn(Opcodes.ARETURN);
                    break;
            }
            super.visitMaxs(2, 8);
            super.visitEnd();
        }

        @Override public void visitInsn(int opcode) { }
        @Override public void visitIntInsn(int opcode, int operand) { }
        @Override public void visitVarInsn(int opcode, int varIndex) { }
        @Override public void visitTypeInsn(int opcode, String type) { }
        @Override public void visitFieldInsn(int opcode, String owner, String name, String descriptor) { }
        @Override public void visitMethodInsn(int opcode, String owner, String name, String descriptor, boolean isInterface) { }
        @Override public void visitInvokeDynamicInsn(String name, String descriptor,
                                                    org.objectweb.asm.Handle bsm, Object... bsmArgs) { }
        @Override public void visitJumpInsn(int opcode, Label label) { }
        @Override public void visitLabel(Label label) { }
        @Override public void visitLdcInsn(Object value) { }
        @Override public void visitIincInsn(int varIndex, int increment) { }
        @Override public void visitTableSwitchInsn(int min, int max, Label dflt, Label... labels) { }
        @Override public void visitLookupSwitchInsn(Label dflt, int[] keys, Label[] labels) { }
        @Override public void visitMultiANewArrayInsn(String descriptor, int numDimensions) { }
        @Override public void visitTryCatchBlock(Label start, Label end, Label handler, String type) { }
        @Override public void visitLocalVariable(String name, String descriptor, String signature,
                                                 Label start, Label end, int index) { }
        @Override public void visitLineNumber(int line, Label start) { }
        @Override public void visitFrame(int type, int numLocal, Object[] local, int numStack, Object[] stack) { }
        @Override public void visitMaxs(int maxStack, int maxLocals) { }
        @Override public void visitEnd() { }
    }
}
