package a2;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Label;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/**
 * Air2 iOS 兼容 javaagent —— 清空 MC 1.20.1 的 macOS 专属 AppKit 菜单调用。
 *
 * 真机根因：1.20.1 在「Initializing game」阶段，vanilla 的
 * {@code MacosUtil.disableCloseWindowMenuItem} 路径（混淆后 ehg.a(long)）会走
 * ca.weblite.objc.RuntimeUtils.&lt;clinit&gt; → System.load(libjcocoa*.dylib)，
 * iOS 上 dlopen 到的是 macOS Mach-O，必然失败并中断启动。
 *
 * 唯一改动的点：类 ehg 的 {@code public static void a(long)}（描述符 (J)V）
 * 方法体替换为单条 RETURN。ehg 里同名的 {@code a(akp<InputStream>)} 是资源包
 * 加载入口，绝不触碰（按 name+desc 精确匹配）。
 */
public final class A2IosCompatAgent implements ClassFileTransformer {

    private static final String TARGET_CLASS = "ehg";
    private static final String TARGET_METHOD = "a";
    /** 两个目标：菜单（long）与应用图标（akp = 混淆后的 InputStream 子类）。 */
    private static final String[] TARGET_DESCS = { "(J)V", "(Lakp;)V" };

    /** MC 的 macOS 朗读器实现（规则 B）。 */
    private static final String NARRATORMAC_CLASS = "com/mojang/text2speech/NarratorMac";


    public static void premain(String args, Instrumentation inst) {
        inst.addTransformer(new A2IosCompatAgent());
    }

    public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
                            ProtectionDomain protectionDomain, byte[] classfileBuffer) {
        if (className == null) {
            return null;
        }
        // 规则 B：MC 的 macOS 朗读器 ⇒ 让这个类【定义失败】，MC 自己降级为 Narrator.EMPTY。
        //   真机证据（lastlog-115，24f842e）：上一版用「transform 里抛异常」——日志打了，
        //   但 JVM 把 transformer 的异常吞掉，类照样加载 ⇒ NarratorMac.<init> 仍旧跑到
        //   NSObject → Client.sendPointer → RuntimeUtils.<clinit> → libjcocoa 崩。
        //   ⇒ 改法：返回非法 class 字节，让 define 阶段抛 ClassFormatError（Error 也是 Throwable，
        //     Narrator.getNarrator 的 catch(Throwable) 会捕获并 return Narrator.EMPTY）。
        if (NARRATORMAC_CLASS.equals(className)) {
            System.out.println("[A2IOS-AGENT] NarratorMac 已禁用（返回非法字节使其定义失败）⇒ MC 自动降级为空朗读器");
            return new byte[] { (byte) 0xCA, (byte) 0xFE, (byte) 0xBA, (byte) 0xBE };
        }
        // 规则 A：ehg 的两个 macOS AppKit 方法置空。
        if (!TARGET_CLASS.equals(className)) {
            return null;
        }
        try {
            ClassReader cr = new ClassReader(classfileBuffer);
            ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_MAXS);
            final boolean[] hit = {false};
            cr.accept(new ClassVisitor(Opcodes.ASM9, cw) {
                @Override
                public MethodVisitor visitMethod(int access, String name, String descriptor,
                                                 String signature, String[] exceptions) {
                    MethodVisitor mv = super.visitMethod(access, name, descriptor, signature, exceptions);
                    boolean wanted = false;
                    if (TARGET_METHOD.equals(name)) {
                        for (String d : TARGET_DESCS) {
                            if (d.equals(descriptor)) { wanted = true; break; }
                        }
                    }
                    if (!wanted) {
                        return mv;
                    }
                    hit[0] = true;
                    return new EmptyBody(mv);
                }
            }, 0);
            if (!hit[0]) {
                return null;
            }
            byte[] patched = cw.toByteArray();
            System.out.println("[A2IOS-AGENT] ehg.a(J)V 已置空（macOS AppKit 菜单调用）");
            return patched;
        } catch (Throwable t) {
            System.out.println("[A2IOS-AGENT] 改写失败: " + t);
            return null;
        }
    }

    /** 丢弃原方法体，只写一条 RETURN。 */
    private static final class EmptyBody extends MethodVisitor {

        EmptyBody(MethodVisitor mv) {
            super(Opcodes.ASM9, mv);
        }

        @Override
        public void visitCode() {
            super.visitCode();
            super.visitInsn(Opcodes.RETURN);
            super.visitMaxs(0, 0);
            super.visitEnd();
        }

        @Override
        public void visitInsn(int opcode) {
        }

        @Override
        public void visitIntInsn(int opcode, int operand) {
        }

        @Override
        public void visitVarInsn(int opcode, int varIndex) {
        }

        @Override
        public void visitTypeInsn(int opcode, String type) {
        }

        @Override
        public void visitFieldInsn(int opcode, String owner, String name, String descriptor) {
        }

        @Override
        public void visitMethodInsn(int opcode, String owner, String name, String descriptor, boolean isInterface) {
        }

        @Override
        public void visitInvokeDynamicInsn(String name, String descriptor,
                                           org.objectweb.asm.Handle bootstrapMethodHandle,
                                           Object... bootstrapMethodArguments) {
        }

        @Override
        public void visitJumpInsn(int opcode, Label label) {
        }

        @Override
        public void visitLabel(Label label) {
        }

        @Override
        public void visitLdcInsn(Object value) {
        }

        @Override
        public void visitIincInsn(int varIndex, int increment) {
        }

        @Override
        public void visitTableSwitchInsn(int min, int max, Label dflt, Label... labels) {
        }

        @Override
        public void visitLookupSwitchInsn(Label dflt, int[] keys, Label[] labels) {
        }

        @Override
        public void visitMultiANewArrayInsn(String descriptor, int numDimensions) {
        }

        @Override
        public void visitTryCatchBlock(Label start, Label end, Label handler, String type) {
        }

        @Override
        public void visitLocalVariable(String name, String descriptor, String signature,
                                       Label start, Label end, int index) {
        }

        @Override
        public void visitLineNumber(int line, Label start) {
        }

        @Override
        public void visitFrame(int type, int numLocal, Object[] local, int numStack, Object[] stack) {
        }

        @Override
        public void visitMaxs(int maxStack, int maxLocals) {
        }

        @Override
        public void visitEnd() {
        }
    }
}
