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
    private static final String RENDERSYSTEM_CLASS = "com/mojang/blaze3d/systems/RenderSystem";
    private static final String TARGET_METHOD = "a";
    private static final String[] TARGET_DESCS = { "(J)V", "(Lakp;)V" };

    /** 规则 B：MC 的 macOS 朗读器实现。 */
    private static final String NARRATORMAC_CLASS = "com/mojang/text2speech/NarratorMac";
    /// ★2026-11-07 真机 lastlog-209★ MC 1.12.2 用的是 NarratorOSX（macOS 版）：
    ///   Narrator.getNarrator → NarratorOSX.<init> → ca.weblite.objc.NSObject → JNA
    ///   ⇒ JNA 版本冲突（jar 5.1.0 vs 包内原生 6.1.6）⇒ Error 直接终止启动。
    ///   与 NarratorMac 同样处理：类正常加载，但不碰 AppKit/JNA。
    private static final String NARRATOROSX_CLASS = "com/mojang/text2speech/NarratorOSX";
    /// ★2026-11-07 lastlog-210★ 只把 NarratorOSX 置空不够：构造函数必须调 super()，
    ///   super 又走 NSObject → JNA ⇒ 版本冲突照样发生。
    ///   ⇒ 在**工厂**处拦截：Narrator.getNarrator() 直接返回 null（MC 对 null 旁白有判空）。
    private static final String NARRATOR_CLASS = "com/mojang/text2speech/Narrator";
    /** 规则 D：LWJGL 原生库哈希校验。 */
    private static final String GL11C_CLASS = "org/lwjgl/opengl/GL11C";

    private static final String LWJGL_LIBRARY_CLASS = "org/lwjgl/system/Library";
    /** 规则 F：★[A2-GL2-PROBE] 固定管线入口绑定取证★（GL11 的 <clinit> 末尾插一条探针调用）。 */
    private static final String GL11_CLASS = "org/lwjgl/opengl/GL11";

    /** 规则 C：只要方法体碰了这些包，就判定为 macOS 专属实现。 */
    private static final String[] FORBIDDEN_OWNER_PREFIXES = {
        "ca/weblite/objc/",
        "com/apple/eawt/",
        "com/sun/jna/platform/mac/",
    };

    /// ★2026-11-07★ 真机 1.20.1 证据：agent 往 GL11.<clinit> 插的探针调用
    ///   a2/A2Gl2Probe 在游戏侧类加载器里找不到（NoClassDefFoundError）⇒ GL11 初始化失败。
    ///   这里把 agent 自己的 jar 追加到系统类加载器搜索路径，让 a2.* 可被解析。
    private static void a2AppendSelfToSystemSearch(Instrumentation inst) {
        try {
            java.security.CodeSource cs = A2IosCompatAgent.class.getProtectionDomain().getCodeSource();
            if (cs == null || cs.getLocation() == null) {
                System.out.println("[A2IOS-AGENT] agent jar 路径未知 ⇒ 跳过类路径追加");
                return;
            }
            java.io.File f = new java.io.File(cs.getLocation().toURI());
            inst.appendToSystemClassLoaderSearch(new java.util.jar.JarFile(f));
            System.out.println("[A2IOS-AGENT] 已把 agent jar 追加进系统类加载器：" + f.getName());
        } catch (Throwable t) {
            System.out.println("[A2IOS-AGENT] 类路径追加失败（不影响启动）：" + t);
        }
    }

    /// GL2 探针/改写只在启动器真正启用自研 GL2 层（≤1.12）时才有意义；
    /// 其它版本注入会污染 GL11 初始化（1.17+ 的崩溃就是这么来的）。
    private static final boolean A2_GL2_ON = "1".equals(System.getProperty("a2.gl2.shim"));

    /// ★2026-11-08★ MC 版本决定 Narrator 怎么处理：
    ///   1.17+ 调用方对 getNarrator() 的 null 有防御 ⇒ 可以返回 null；
    ///   1.16 及更早没防御（1.16.5 实测：NPE this.d is null）⇒ 不能拦，让它正常创建，
    ///   而 macOS 实现类已由本 agent 改成惰性空实现。
    private static final int A2_MC_MINOR = a2ParseMinor(System.getProperty("a2.mc.version"));

    private static int a2ParseMinor(String v) {
        if (v == null) return 0;
        try {
            String[] parts = v.split("[.]");
            if (parts.length >= 2 && "1".equals(parts[0])) return Integer.parseInt(parts[1]);
        } catch (Throwable ignored) { }
        return 0;
    }

    public static void premain(String args, Instrumentation inst) {
        a2AppendSelfToSystemSearch(inst);
        inst.addTransformer(new A2IosCompatAgent());
        System.out.println("[A2IOS-AGENT] 就位（GL2 注入=" + (A2_GL2_ON ? "开" : "关") + "）");
    }

    /// ★2026-11-07 加固★ 真机 1.19.2 曾出现 ClassFormatError: Truncated class file /
    ///   VerifyError: Bad <init> method call —— 都是本 agent 产出的字节不合法。
    ///   现在：任何异常只记日志并返回 null（等于不转换）；产出前用 ASM 复解析一次，
    ///   解析不过同样丢弃。宁可少改，也绝不把坏字节交给 JVM。
    public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
                            ProtectionDomain protectionDomain, byte[] classfileBuffer) {
        try {
            byte[] out = transformImpl(loader, className, classBeingRedefined, protectionDomain, classfileBuffer);
            if (out != null && !a2VerifyClass(out)) {
                System.out.println("[A2IOS-AGENT] 跳过 " + className + "：改写结果不合法（已丢弃）");
                return null;
            }
            return out;
        } catch (Throwable t) {
            System.out.println("[A2IOS-AGENT] 跳过 " + className + "：" + t);
            return null;
        }
    }

    private static boolean a2VerifyClass(byte[] bytes) {
        try {
            new ClassReader(bytes).getClassName();
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    private byte[] transformImpl(ClassLoader loader, String className, Class<?> classBeingRedefined,
                                 ProtectionDomain protectionDomain, byte[] classfileBuffer) {
        if (className == null) {
            return null;
        }
        // ★规则 I（2026-11-08 1.16.5 真机）★ RenderSystem.fog(...) 在 GLES 下没有
        //   固定管线入口（GL11.glFogfv 指针为空 ⇒ LWJGL Checks.check 抛 NPE）。
        //   雾只影响观感，1.13–1.16 直接置空。
        if (RENDERSYSTEM_CLASS.equals(className) && A2_MC_MINOR >= 13 && A2_MC_MINOR <= 16) {
            byte[] noFog = patchVoidMethod(classfileBuffer, "fog");
            if (noFog != null) {
                System.out.println("[A2IOS-AGENT] RenderSystem.fog 已置空（GLES 无 glFogfv）");
                return noFog;
            }
        }

        // 规则 B：把 NarratorMac 变成「合法但空实现」的类。
        //   ★2026-11-01 真机（1.19.2, lastlog-134）★ 旧做法是返回 0xCAFEBABE 让它定义失败，
        //   1.20.1 的 Narrator.getNarrator 用 catch(Throwable) 能接住；1.19.2 只 catch Exception，
        //   ClassFormatError 直接冒到 Main.main ⇒ 启动崩。
        //   ⇒ 改成：类正常加载，但构造只调 super()、其余方法返回默认值 ⇒ 不会碰 AppKit，也不会抛 Error。
        if (NARRATOR_CLASS.equals(className) && A2_MC_MINOR >= 17) {
            byte[] patchedFactory = patchNarratorFactory(classfileBuffer);
            if (patchedFactory != null) {
                System.out.println("[A2IOS-AGENT] Narrator.getNarrator 已改为返回 null（不实例化 macOS 旁白）");
                return patchedFactory;
            }
            return null;
        }
        if (NARRATOROSX_CLASS.equals(className)) {
            byte[] patchedOsx = patchInertClass(className, classfileBuffer);
            if (patchedOsx != null) {
                System.out.println("[A2IOS-AGENT] NarratorOSX 已置为合法空实现（不碰 AppKit/JNA）");
                return patchedOsx;
            }
            return null;
        }
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
        if (GL11_CLASS.equals(className) && !A2_GL2_ON) {
            return null;   // 非 GL2 链路：不碰 GL11（否则探针类缺失会让 GL11 初始化失败）
        }
        if (GL11_CLASS.equals(className)) {
            byte[] patched = patchGl11Probe(classfileBuffer);
            if (patched != null) {
                return patched;
            }
            return null;   // GL11 不碰 AppKit，不必再走规则 C
        }
        // ★规则 G（2026-11-06）★ GL11C.glGetInteger 字节码级改写。
        //   真机 lastlog-200/201：无论我们怎么 RegisterNatives，MC 读到
        //   MAX_TEXTURE_SIZE 仍是 0 ⇒ 图集 0x0 ⇒ "Unable to fit"。
        //   ⇒ 直接在字节码层改写这个方法：按能力表返回，并打 pname 取证。
        if (GL11_CLASS.equals(className)) {
            // ★规则 H★ GL11.glGetInteger 是 Java 包装（内部转 GL11C），
            //   真机证明 GL11C 那条改写没被命中 ⇒ 包装层也改一份，双路径覆盖。
            byte[] patchedH = patchGl11GlobalGetInteger(classfileBuffer);
            if (patchedH != null) {
                System.out.println("[A2IOS-AGENT] GL11.glGetInteger 已按能力表改写（规则 H）");
            }
            // 规则 F 的探针仍要注入：两者都改，然后一起返回
            byte[] withProbe = patchGl11Probe(patchedH != null ? patchedH : classfileBuffer);
            if (withProbe != null) return withProbe;
            return patchedH;
        }
        if (GL11C_CLASS.equals(className) && !A2_GL2_ON) {
            return null;   // 非 GL2 链路：不碰 GL11C
        }
        if (GL11C_CLASS.equals(className)) {
            byte[] patched = patchGl11cGetInteger(classfileBuffer);
            if (patched != null) {
                System.out.println("[A2IOS-AGENT] GL11C.glGetInteger 已按能力表改写");
                return patched;
            }
            return null;
        }
        // 规则 C：通用 AppKit 方法体置空。
        return patchAppKitMethods(className, classfileBuffer);
    }

    /**
     * 规则 G：把 {@code GL11C.glGetInteger(int)} 改写成「按能力表返回值」。
     *
     * <p>为什么要在字节码层做：这条方法是 Java 实现，内部调 nglGetIntegerv；
     * 我们对该 native 的 RegisterNatives 在真机上始终没被调用到（lastlog-199/200），
     * 而 MC 1.12.2 的图集尺寸完全依赖它 ⇒ 读到 0 就抛 StitcherException。
     *
     * <p>值取自与 a2gl2_stub_nglGetIntegerv 同一张能力表（两边必须一致）：
     * 3379(GL_MAX_TEXTURE_SIZE)=16384、34921=16、34930=16、35660=16、35661=32、
     * 34024=16384；未知 pname ⇒ 0（保持原语义）。
     */
    private static byte[] patchGl11cGetInteger(byte[] classfileBuffer) {
        try {
            ClassReader cr = new ClassReader(classfileBuffer);
            // ★必须 COMPUTE_FRAMES★：改写后方法里有条件跳转，缺 stackmap frame 会在
            //   类校验阶段直接 VerifyError（真机 lastlog-202 实证）。
            ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_FRAMES) {
                @Override
                protected String getCommonSuperClass(String type1, String type2) {
                    return "java/lang/Object";   // 本方法只涉及 int，不需要真实继承关系
                }
            };
            final boolean[] hit = { false };
            cr.accept(new ClassVisitor(Opcodes.ASM9, cw) {
                @Override
                public MethodVisitor visitMethod(int access, String name, String descriptor,
                                                 String signature, String[] exceptions) {
                    if (!"glGetInteger".equals(name) || !"(I)I".equals(descriptor)) {
                        return super.visitMethod(access, name, descriptor, signature, exceptions);
                    }
                    hit[0] = true;
                    final MethodVisitor out = super.visitMethod(access, name, descriptor, signature, exceptions);
                    // ★原方法体全部丢弃★：只保留我们生成的这一段。
                    //   上一版把新指令插在 visitCode 里、原方法体照旧输出 ⇒ 两段拼在一起，
                    //   校验器直接报 VerifyError（lastlog-202）。
                    return new MethodVisitor(Opcodes.ASM9) {
                        @Override
                        public void visitEnd() {
                            out.visitCode();
                            out.visitVarInsn(Opcodes.ILOAD, 0);
                            out.visitMethodInsn(Opcodes.INVOKESTATIC, "a2/A2Gl2Probe",
                                                "noteGetInteger", "(I)V", false);
                            int[][] table = {
                                { 3379, 16384 },   // GL_MAX_TEXTURE_SIZE
                                { 34921, 16 },     // GL_MAX_VERTEX_ATTRIBS
                                { 34930, 16 },     // GL_MAX_TEXTURE_IMAGE_UNITS
                                { 35660, 16 },     // GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS
                                { 35661, 32 },     // GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS
                                { 34024, 16384 },  // GL_MAX_RENDERBUFFER_SIZE
                            };
                            for (int[] row : table) {
                                org.objectweb.asm.Label next = new org.objectweb.asm.Label();
                                out.visitVarInsn(Opcodes.ILOAD, 0);
                                out.visitLdcInsn(row[0]);
                                out.visitJumpInsn(Opcodes.IF_ICMPNE, next);
                                out.visitLdcInsn(row[1]);
                                out.visitInsn(Opcodes.IRETURN);
                                out.visitLabel(next);
                            }
                            out.visitInsn(Opcodes.ICONST_0);
                            out.visitInsn(Opcodes.IRETURN);
                            out.visitMaxs(0, 0);
                            out.visitEnd();
                        }
                    };
                }
            }, 0);
            return hit[0] ? cw.toByteArray() : null;
        } catch (Throwable t) {
            System.out.println("[A2IOS-AGENT] patchGl11cGetInteger 失败：" + t);
            return null;
        }
    }

    /** 规则 H：把 GL11.glGetInteger(I)I 也改写成能力表返回值（包装层兜底）。 */
    private static byte[] patchGl11GlobalGetInteger(byte[] classfileBuffer) {
        try {
            ClassReader cr = new ClassReader(classfileBuffer);
            ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_FRAMES) {
                @Override
                protected String getCommonSuperClass(String t1, String t2) { return "java/lang/Object"; }
            };
            final boolean[] hit = { false };
            cr.accept(new ClassVisitor(Opcodes.ASM9, cw) {
                @Override
                public MethodVisitor visitMethod(int access, String name, String descriptor,
                                                 String signature, String[] exceptions) {
                    if (!"glGetInteger".equals(name) || !"(I)I".equals(descriptor)) {
                        return super.visitMethod(access, name, descriptor, signature, exceptions);
                    }
                    hit[0] = true;
                    final MethodVisitor out = super.visitMethod(access, name, descriptor, signature, exceptions);
                    return new MethodVisitor(Opcodes.ASM9) {
                        @Override
                        public void visitEnd() {
                            out.visitCode();
                            out.visitVarInsn(Opcodes.ILOAD, 0);
                            out.visitMethodInsn(Opcodes.INVOKESTATIC, "a2/A2Gl2Probe",
                                                "noteGetInteger", "(I)V", false);
                            int[][] table = {
                                { 3379, 16384 }, { 34921, 16 }, { 34930, 16 },
                                { 35660, 16 }, { 35661, 32 }, { 34024, 16384 },
                            };
                            for (int[] row : table) {
                                org.objectweb.asm.Label next = new org.objectweb.asm.Label();
                                out.visitVarInsn(Opcodes.ILOAD, 0);
                                out.visitLdcInsn(row[0]);
                                out.visitJumpInsn(Opcodes.IF_ICMPNE, next);
                                out.visitLdcInsn(row[1]);
                                out.visitInsn(Opcodes.IRETURN);
                                out.visitLabel(next);
                            }
                            out.visitInsn(Opcodes.ICONST_0);
                            out.visitInsn(Opcodes.IRETURN);
                            out.visitMaxs(0, 0);
                            out.visitEnd();
                        }
                    };
                }
            }, 0);
            return hit[0] ? cw.toByteArray() : null;
        } catch (Throwable t) {
            System.out.println("[A2IOS-AGENT] patchGl11GlobalGetInteger 失败：" + t);
            return null;
        }
    }

    /** 规则 I：把 Narrator.getNarrator() 整个方法体改成 `return null`。 */
    private static byte[] patchNarratorFactory(byte[] classfileBuffer) {
        try {
            ClassReader cr = new ClassReader(classfileBuffer);
            ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_MAXS);
            final boolean[] hit = { false };
            cr.accept(new ClassVisitor(Opcodes.ASM9, cw) {
                @Override
                public MethodVisitor visitMethod(int access, String name, String descriptor,
                                                 String signature, String[] exceptions) {
                    if (!"getNarrator".equals(name) || !descriptor.startsWith("()L")) {
                        return super.visitMethod(access, name, descriptor, signature, exceptions);
                    }
                    hit[0] = true;
                    final MethodVisitor out = super.visitMethod(access, name, descriptor, signature, exceptions);
                    return new MethodVisitor(Opcodes.ASM9) {
                        @Override
                        public void visitEnd() {
                            out.visitCode();
                            out.visitInsn(Opcodes.ACONST_NULL);
                            out.visitInsn(Opcodes.ARETURN);
                            out.visitMaxs(0, 0);
                            out.visitEnd();
                        }
                    };
                }
            }, 0);
            return hit[0] ? cw.toByteArray() : null;
        } catch (Throwable t) {
            System.out.println("[A2IOS-AGENT] patchNarratorFactory 失败：" + t);
            return null;
        }
    }

    /// 把指定名字、返回 void 的方法体整体替换成 return（规则 I 用）。
    private static byte[] patchVoidMethod(byte[] classfileBuffer, final String methodName) {
        try {
            ClassReader cr = new ClassReader(classfileBuffer);
            ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_MAXS);
            final boolean[] hit = { false };
            cr.accept(new ClassVisitor(Opcodes.ASM9, cw) {
                @Override
                public MethodVisitor visitMethod(int access, String name, String descriptor,
                                                 String signature, String[] exceptions) {
                    if (!methodName.equals(name) || !descriptor.endsWith(")V")) {
                        return super.visitMethod(access, name, descriptor, signature, exceptions);
                    }
                    hit[0] = true;
                    final MethodVisitor out = super.visitMethod(access, name, descriptor, signature, exceptions);
                    return new MethodVisitor(Opcodes.ASM9) {
                        @Override
                        public void visitEnd() {
                            out.visitCode();
                            out.visitInsn(Opcodes.RETURN);
                            out.visitMaxs(0, 0);
                            out.visitEnd();
                        }
                    };
                }
            }, 0);
            return hit[0] ? cw.toByteArray() : null;
        } catch (Throwable t) {
            System.out.println("[A2IOS-AGENT] patchVoidMethod 失败：" + t);
            return null;
        }
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
