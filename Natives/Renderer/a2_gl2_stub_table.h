// ============================================================================
//  Natives/Renderer/a2_gl2_stub_table.h
//  ★自动生成，不要手改★  生成器：scripts/gen_gl2_stub_table.py
//  签名来源：javap -s -p Libraries/Jars/lwjgl-2/lwjgl-opengl-3.2.3.jar
//            org.lwjgl.opengl.GL11 / org.lwjgl.opengl.GL11C
// ----------------------------------------------------------------------------
//  这张表是「GL11/GL11C 上全部 static native」的**安全空实现（no-op）**清单：
//  本层没有真实实现的入口，一律注册成这里的空函数，而不是留给
//  `liblwjgl_opengl.dylib` 去走它那张**已被我们置空**的函数指针表。
//  为什么必须这么做（真机证据）：MC 1.12.2 会调 glLogicOp / glPointSize / glHint /
//  glPolygonMode / glLineWidth / glAccum 这类桌面专用入口；没接管的入口 ⇒ LWJGL
//  函数表里是 NULL ⇒ `liblwjgl_opengl.dylib+0xbbbc` 一次间接调用踩空 ⇒ SIGSEGV + os::abort。
//
//  命名：a2gl2_stub_<返回类型码><形参类型码串>（v=void，其余同 Java 描述符；
//        数组→A、引用→O）
//        (I)V   → a2gl2_stub_vI        ()V       → a2gl2_stub_v
//        (FFF)V → a2gl2_stub_vFFF      (IF)V     → a2gl2_stub_vIF
//        (Z)V   → a2gl2_stub_vZ        (J)Z      → a2gl2_stub_ZZ
//  空实现的语义：**不改 GL 状态、不抛异常、返回默认值（0 / JNI_FALSE / NULL）**。
//  它只保证「调用不踩空」，不保证「这条入口的效果被模拟」—— 需要效果的入口
//  必须在 a2_gl2_shim.m 里有真实现（真实现优先，见 a2_gl2_jni_bind.m ⑦b 的去重）。
//
//  条数：336 条 native（GL11 274 / GL11C 62），归为 55 类描述符。
//  覆盖代：1.12.2 及更早（Libraries/Jars/lwjgl-2/lwjgl-opengl-3.2.3.jar）＋1.13–1.16（3.3.3）逐条一致
// ============================================================================
#ifndef A2_GL2_STUB_TABLE_H
#define A2_GL2_STUB_TABLE_H

#include <jni.h>

/// 一条空实现登记项。declClass 取值同 a2_gl2_jni_bind.m 的 A2GL2_CLASS_*（0=GL11 1=GL11C）。
typedef struct {
    int         declClass;
    const char *name;
    const char *sig;
    void       *fn;
} A2GL2StubMethod;

// ----------------------------------------------------------------------------
//  stub 实现（每个「描述符类」一个；同一描述符的所有入口共用同一个函数）
// ----------------------------------------------------------------------------
/// ()I —— 1 条入口：glGetError
static jint a2gl2_stub_I(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return 0;
}

/// ()V —— 11 条入口：glEnd, glInitNames, glLoadIdentity, glEndList, glPopAttrib, glPopClientAttrib …
static void a2gl2_stub_v(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
}

/// (B)V —— 1 条入口：glIndexub
static void a2gl2_stub_vB(JNIEnv *env, jclass cls, jbyte a0) {
    (void)env;
    (void)cls;
    (void)a0;
}

/// (D)V —— 4 条入口：glEvalCoord1d, glIndexd, glTexCoord1d, glClearDepth
static void a2gl2_stub_vD(JNIEnv *env, jclass cls, jdouble a0) {
    (void)env;
    (void)cls;
    (void)a0;
}

/// (F)V —— 7 条入口：glClearIndex, glEvalCoord1f, glIndexf, glPassThrough, glTexCoord1f, glLineWidth …
static void a2gl2_stub_vF(JNIEnv *env, jclass cls, jfloat a0) {
    (void)env;
    (void)cls;
    (void)a0;
}

/// (I)I —— 2 条入口：glGenLists, glRenderMode
static jint a2gl2_stub_II(JNIEnv *env, jclass cls, jint a0) {
    (void)env;
    (void)cls;
    (void)a0;
    return 0;
}

/// (I)J —— 1 条入口：nglGetString
static jlong a2gl2_stub_JI(JNIEnv *env, jclass cls, jint a0) {
    (void)env;
    (void)cls;
    (void)a0;
    return 0;
}

/// (I)V —— 27 条入口：glArrayElement, glBegin, glCallList, glDisableClientState, glEnableClientState, glEvalPoint1 …
static void a2gl2_stub_vI(JNIEnv *env, jclass cls, jint a0) {
    (void)env;
    (void)cls;
    (void)a0;
}

/// (I)Z —— 3 条入口：glIsList, glIsEnabled, glIsTexture
static jboolean a2gl2_stub_ZI(JNIEnv *env, jclass cls, jint a0) {
    (void)env;
    (void)cls;
    (void)a0;
    return JNI_FALSE;
}

/// (J)V —— 77 条入口：nglColor3bv, nglColor3sv, nglColor3iv, nglColor3fv, nglColor3dv, nglColor3ubv …
static void a2gl2_stub_vJ(JNIEnv *env, jclass cls, jlong a0) {
    (void)env;
    (void)cls;
    (void)a0;
}

/// (S)V —— 2 条入口：glIndexs, glTexCoord1s
static void a2gl2_stub_vS(JNIEnv *env, jclass cls, jshort a0) {
    (void)env;
    (void)cls;
    (void)a0;
}

/// (Z)V —— 2 条入口：glEdgeFlag, glDepthMask
static void a2gl2_stub_vZ(JNIEnv *env, jclass cls, jboolean a0) {
    (void)env;
    (void)cls;
    (void)a0;
}

/// (DD)V —— 5 条入口：glEvalCoord2d, glRasterPos2d, glTexCoord2d, glVertex2d, glDepthRange
static void a2gl2_stub_vDD(JNIEnv *env, jclass cls, jdouble a0, jdouble a1) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
}

/// (FF)V —— 6 条入口：glEvalCoord2f, glPixelZoom, glRasterPos2f, glTexCoord2f, glVertex2f, glPolygonOffset
static void a2gl2_stub_vFF(JNIEnv *env, jclass cls, jfloat a0, jfloat a1) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
}

/// (IF)V —— 6 条入口：glAccum, glAlphaFunc, glFogf, glLightModelf, glPixelTransferf, glPixelStoref
static void a2gl2_stub_vIF(JNIEnv *env, jclass cls, jint a0, jfloat a1) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
}

/// (II)V —— 15 条入口：glColorMaterial, glDeleteLists, glEvalPoint2, glFogi, glLightModeli, glNewList …
static void a2gl2_stub_vII(JNIEnv *env, jclass cls, jint a0, jint a1) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
}

/// (IJ)V —— 18 条入口：nglClipPlane, nglEdgeFlagPointer, nglFogiv, nglFogfv, nglGetClipPlane, nglGetPixelMapfv …
static void a2gl2_stub_vIJ(JNIEnv *env, jclass cls, jint a0, jlong a1) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
}

/// (IS)V —— 1 条入口：glLineStipple
static void a2gl2_stub_vIS(JNIEnv *env, jclass cls, jint a0, jshort a1) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
}

/// (JJ)V —— 4 条入口：nglRectiv, nglRectsv, nglRectfv, nglRectdv
static void a2gl2_stub_vJJ(JNIEnv *env, jclass cls, jlong a0, jlong a1) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
}

/// (SS)V —— 3 条入口：glRasterPos2s, glTexCoord2s, glVertex2s
static void a2gl2_stub_vSS(JNIEnv *env, jclass cls, jshort a0, jshort a1) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
}

/// (BBB)V —— 3 条入口：glColor3b, glColor3ub, glNormal3b
static void a2gl2_stub_vBBB(JNIEnv *env, jclass cls, jbyte a0, jbyte a1, jbyte a2) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
}

/// (DDD)V —— 7 条入口：glColor3d, glNormal3d, glRasterPos3d, glScaled, glTexCoord3d, glTranslated …
static void a2gl2_stub_vDDD(JNIEnv *env, jclass cls, jdouble a0, jdouble a1, jdouble a2) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
}

/// (FFF)V —— 7 条入口：glColor3f, glNormal3f, glRasterPos3f, glScalef, glTexCoord3f, glTranslatef …
static void a2gl2_stub_vFFF(JNIEnv *env, jclass cls, jfloat a0, jfloat a1, jfloat a2) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
}

/// (IDD)V —— 1 条入口：glMapGrid1d
static void a2gl2_stub_vIDD(JNIEnv *env, jclass cls, jint a0, jdouble a1, jdouble a2) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
}

/// (IFF)V —— 1 条入口：glMapGrid1f
static void a2gl2_stub_vIFF(JNIEnv *env, jclass cls, jint a0, jfloat a1, jfloat a2) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
}

/// (IID)V —— 1 条入口：glTexGend
static void a2gl2_stub_vIID(JNIEnv *env, jclass cls, jint a0, jint a1, jdouble a2) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
}

/// (IIF)V —— 5 条入口：glLightf, glMaterialf, glTexEnvf, glTexGenf, glTexParameterf
static void a2gl2_stub_vIIF(JNIEnv *env, jclass cls, jint a0, jint a1, jfloat a2) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
}

/// (III)V —— 15 条入口：glColor3i, glColor3ui, glEvalMesh1, glLighti, glMateriali, glNormal3i …
static void a2gl2_stub_vIII(JNIEnv *env, jclass cls, jint a0, jint a1, jint a2) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
}

/// (IIJ)V —— 33 条入口：nglCallLists, nglFeedbackBuffer, nglGetLightiv, nglGetLightfv, nglGetMapiv, nglGetMapfv …
static void a2gl2_stub_vIIJ(JNIEnv *env, jclass cls, jint a0, jint a1, jlong a2) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
}

/// (IJJ)V —— 1 条入口：nglPrioritizeTextures
static void a2gl2_stub_vIJJ(JNIEnv *env, jclass cls, jint a0, jlong a1, jlong a2) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
}

/// (IJJ)Z —— 1 条入口：nglAreTexturesResident
static jboolean a2gl2_stub_ZIJJ(JNIEnv *env, jclass cls, jint a0, jlong a1, jlong a2) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    return JNI_FALSE;
}

/// (SSS)V —— 6 条入口：glColor3s, glColor3us, glNormal3s, glRasterPos3s, glTexCoord3s, glVertex3s
static void a2gl2_stub_vSSS(JNIEnv *env, jclass cls, jshort a0, jshort a1, jshort a2) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
}

/// (BBBB)V —— 2 条入口：glColor4b, glColor4ub
static void a2gl2_stub_vBBBB(JNIEnv *env, jclass cls, jbyte a0, jbyte a1, jbyte a2, jbyte a3) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
}

/// (DDDD)V —— 6 条入口：glColor4d, glRasterPos4d, glRectd, glRotated, glTexCoord4d, glVertex4d
static void a2gl2_stub_vDDDD(JNIEnv *env, jclass cls, jdouble a0, jdouble a1, jdouble a2, jdouble a3) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
}

/// (FFFF)V —— 8 条入口：glClearAccum, glColor4f, glRasterPos4f, glRectf, glRotatef, glTexCoord4f …
static void a2gl2_stub_vFFFF(JNIEnv *env, jclass cls, jfloat a0, jfloat a1, jfloat a2, jfloat a3) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
}

/// (IIII)V —— 8 条入口：glColor4i, glColor4ui, glRasterPos4i, glRecti, glTexCoord4i, glVertex4i …
static void a2gl2_stub_vIIII(JNIEnv *env, jclass cls, jint a0, jint a1, jint a2, jint a3) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
}

/// (IIIJ)V —— 6 条入口：nglColorPointer, nglTexCoordPointer, nglVertexPointer, nglDrawElements, nglGetTexLevelParameteriv, nglGetTexLevelParameterfv
static void a2gl2_stub_vIIIJ(JNIEnv *env, jclass cls, jint a0, jint a1, jint a2, jlong a3) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
}

/// (SSSS)V —— 6 条入口：glColor4s, glColor4us, glRasterPos4s, glRects, glTexCoord4s, glVertex4s
static void a2gl2_stub_vSSSS(JNIEnv *env, jclass cls, jshort a0, jshort a1, jshort a2, jshort a3) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
}

/// (ZZZZ)V —— 1 条入口：glColorMask
static void a2gl2_stub_vZZZZ(JNIEnv *env, jclass cls, jboolean a0, jboolean a1, jboolean a2, jboolean a3) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
}

/// (IIIII)V —— 2 条入口：glCopyPixels, glEvalMesh2
static void a2gl2_stub_vIIIII(JNIEnv *env, jclass cls, jint a0, jint a1, jint a2, jint a3, jint a4) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
}

/// (IIIIJ)V —— 2 条入口：nglDrawPixels, nglGetTexImage
static void a2gl2_stub_vIIIIJ(JNIEnv *env, jclass cls, jint a0, jint a1, jint a2, jint a3, jlong a4) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
}

/// (DDDDDD)V —— 2 条入口：glFrustum, glOrtho
static void a2gl2_stub_vDDDDDD(JNIEnv *env, jclass cls, jdouble a0, jdouble a1, jdouble a2, jdouble a3, jdouble a4, jdouble a5) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
}

/// (IDDIDD)V —— 1 条入口：glMapGrid2d
static void a2gl2_stub_vIDDIDD(JNIEnv *env, jclass cls, jint a0, jdouble a1, jdouble a2, jint a3, jdouble a4, jdouble a5) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
}

/// (IDDIIJ)V —— 1 条入口：nglMap1d
static void a2gl2_stub_vIDDIIJ(JNIEnv *env, jclass cls, jint a0, jdouble a1, jdouble a2, jint a3, jint a4, jlong a5) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
}

/// (IFFIFF)V —— 1 条入口：glMapGrid2f
static void a2gl2_stub_vIFFIFF(JNIEnv *env, jclass cls, jint a0, jfloat a1, jfloat a2, jint a3, jfloat a4, jfloat a5) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
}

/// (IFFIIJ)V —— 1 条入口：nglMap1f
static void a2gl2_stub_vIFFIIJ(JNIEnv *env, jclass cls, jint a0, jfloat a1, jfloat a2, jint a3, jint a4, jlong a5) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
}

/// (IIIIII)V —— 1 条入口：glCopyTexSubImage1D
static void a2gl2_stub_vIIIIII(JNIEnv *env, jclass cls, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
}

/// (IIFFFFJ)V —— 1 条入口：nglBitmap
static void a2gl2_stub_vIIFFFFJ(JNIEnv *env, jclass cls, jint a0, jint a1, jfloat a2, jfloat a3, jfloat a4, jfloat a5, jlong a6) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
    (void)a6;
}

/// (IIIIIII)V —— 1 条入口：glCopyTexImage1D
static void a2gl2_stub_vIIIIIII(JNIEnv *env, jclass cls, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5, jint a6) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
    (void)a6;
}

/// (IIIIIIJ)V —— 2 条入口：nglReadPixels, nglTexSubImage1D
static void a2gl2_stub_vIIIIIIJ(JNIEnv *env, jclass cls, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5, jlong a6) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
    (void)a6;
}

/// (IIIIIIII)V —— 2 条入口：glCopyTexImage2D, glCopyTexSubImage2D
static void a2gl2_stub_vIIIIIIII(JNIEnv *env, jclass cls, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5, jint a6, jint a7) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
    (void)a6;
    (void)a7;
}

/// (IIIIIIIJ)V —— 1 条入口：nglTexImage1D
static void a2gl2_stub_vIIIIIIIJ(JNIEnv *env, jclass cls, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5, jint a6, jlong a7) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
    (void)a6;
    (void)a7;
}

/// (IIIIIIIIJ)V —— 2 条入口：nglTexImage2D, nglTexSubImage2D
static void a2gl2_stub_vIIIIIIIIJ(JNIEnv *env, jclass cls, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5, jint a6, jint a7, jlong a8) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
    (void)a6;
    (void)a7;
    (void)a8;
}

/// (IDDIIDDIIJ)V —— 1 条入口：nglMap2d
static void a2gl2_stub_vIDDIIDDIIJ(JNIEnv *env, jclass cls, jint a0, jdouble a1, jdouble a2, jint a3, jint a4, jdouble a5, jdouble a6, jint a7, jint a8, jlong a9) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
    (void)a6;
    (void)a7;
    (void)a8;
    (void)a9;
}

/// (IFFIIFFIIJ)V —— 1 条入口：nglMap2f
static void a2gl2_stub_vIFFIIFFIIJ(JNIEnv *env, jclass cls, jint a0, jfloat a1, jfloat a2, jint a3, jint a4, jfloat a5, jfloat a6, jint a7, jint a8, jlong a9) {
    (void)env;
    (void)cls;
    (void)a0;
    (void)a1;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
    (void)a6;
    (void)a7;
    (void)a8;
    (void)a9;
}

// ----------------------------------------------------------------------------
//  登记表（按 类 + 方法名 排序；★顺序不影响语义★，但必须是确定的，便于 diff 审阅）
// ----------------------------------------------------------------------------
static const A2GL2StubMethod kA2GL2Stubs[] = {
    // ---- GL11
    { 0, "glAccum", "(IF)V", (void *)a2gl2_stub_vIF },
    { 0, "glAlphaFunc", "(IF)V", (void *)a2gl2_stub_vIF },
    { 0, "glArrayElement", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glBegin", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glCallList", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glClearAccum", "(FFFF)V", (void *)a2gl2_stub_vFFFF },
    { 0, "glClearIndex", "(F)V", (void *)a2gl2_stub_vF },
    { 0, "glColor3b", "(BBB)V", (void *)a2gl2_stub_vBBB },
    { 0, "glColor3d", "(DDD)V", (void *)a2gl2_stub_vDDD },
    { 0, "glColor3f", "(FFF)V", (void *)a2gl2_stub_vFFF },
    { 0, "glColor3i", "(III)V", (void *)a2gl2_stub_vIII },
    { 0, "glColor3s", "(SSS)V", (void *)a2gl2_stub_vSSS },
    { 0, "glColor3ub", "(BBB)V", (void *)a2gl2_stub_vBBB },
    { 0, "glColor3ui", "(III)V", (void *)a2gl2_stub_vIII },
    { 0, "glColor3us", "(SSS)V", (void *)a2gl2_stub_vSSS },
    { 0, "glColor4b", "(BBBB)V", (void *)a2gl2_stub_vBBBB },
    { 0, "glColor4d", "(DDDD)V", (void *)a2gl2_stub_vDDDD },
    { 0, "glColor4f", "(FFFF)V", (void *)a2gl2_stub_vFFFF },
    { 0, "glColor4i", "(IIII)V", (void *)a2gl2_stub_vIIII },
    { 0, "glColor4s", "(SSSS)V", (void *)a2gl2_stub_vSSSS },
    { 0, "glColor4ub", "(BBBB)V", (void *)a2gl2_stub_vBBBB },
    { 0, "glColor4ui", "(IIII)V", (void *)a2gl2_stub_vIIII },
    { 0, "glColor4us", "(SSSS)V", (void *)a2gl2_stub_vSSSS },
    { 0, "glColorMaterial", "(II)V", (void *)a2gl2_stub_vII },
    { 0, "glCopyPixels", "(IIIII)V", (void *)a2gl2_stub_vIIIII },
    { 0, "glDeleteLists", "(II)V", (void *)a2gl2_stub_vII },
    { 0, "glDisableClientState", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glEdgeFlag", "(Z)V", (void *)a2gl2_stub_vZ },
    { 0, "glEnableClientState", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glEnd", "()V", (void *)a2gl2_stub_v },
    { 0, "glEndList", "()V", (void *)a2gl2_stub_v },
    { 0, "glEvalCoord1d", "(D)V", (void *)a2gl2_stub_vD },
    { 0, "glEvalCoord1f", "(F)V", (void *)a2gl2_stub_vF },
    { 0, "glEvalCoord2d", "(DD)V", (void *)a2gl2_stub_vDD },
    { 0, "glEvalCoord2f", "(FF)V", (void *)a2gl2_stub_vFF },
    { 0, "glEvalMesh1", "(III)V", (void *)a2gl2_stub_vIII },
    { 0, "glEvalMesh2", "(IIIII)V", (void *)a2gl2_stub_vIIIII },
    { 0, "glEvalPoint1", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glEvalPoint2", "(II)V", (void *)a2gl2_stub_vII },
    { 0, "glFogf", "(IF)V", (void *)a2gl2_stub_vIF },
    { 0, "glFogi", "(II)V", (void *)a2gl2_stub_vII },
    { 0, "glFrustum", "(DDDDDD)V", (void *)a2gl2_stub_vDDDDDD },
    { 0, "glGenLists", "(I)I", (void *)a2gl2_stub_II },
    { 0, "glIndexMask", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glIndexd", "(D)V", (void *)a2gl2_stub_vD },
    { 0, "glIndexf", "(F)V", (void *)a2gl2_stub_vF },
    { 0, "glIndexi", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glIndexs", "(S)V", (void *)a2gl2_stub_vS },
    { 0, "glIndexub", "(B)V", (void *)a2gl2_stub_vB },
    { 0, "glInitNames", "()V", (void *)a2gl2_stub_v },
    { 0, "glIsList", "(I)Z", (void *)a2gl2_stub_ZI },
    { 0, "glLightModelf", "(IF)V", (void *)a2gl2_stub_vIF },
    { 0, "glLightModeli", "(II)V", (void *)a2gl2_stub_vII },
    { 0, "glLightf", "(IIF)V", (void *)a2gl2_stub_vIIF },
    { 0, "glLighti", "(III)V", (void *)a2gl2_stub_vIII },
    { 0, "glLineStipple", "(IS)V", (void *)a2gl2_stub_vIS },
    { 0, "glListBase", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glLoadIdentity", "()V", (void *)a2gl2_stub_v },
    { 0, "glLoadName", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glMapGrid1d", "(IDD)V", (void *)a2gl2_stub_vIDD },
    { 0, "glMapGrid1f", "(IFF)V", (void *)a2gl2_stub_vIFF },
    { 0, "glMapGrid2d", "(IDDIDD)V", (void *)a2gl2_stub_vIDDIDD },
    { 0, "glMapGrid2f", "(IFFIFF)V", (void *)a2gl2_stub_vIFFIFF },
    { 0, "glMaterialf", "(IIF)V", (void *)a2gl2_stub_vIIF },
    { 0, "glMateriali", "(III)V", (void *)a2gl2_stub_vIII },
    { 0, "glMatrixMode", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glNewList", "(II)V", (void *)a2gl2_stub_vII },
    { 0, "glNormal3b", "(BBB)V", (void *)a2gl2_stub_vBBB },
    { 0, "glNormal3d", "(DDD)V", (void *)a2gl2_stub_vDDD },
    { 0, "glNormal3f", "(FFF)V", (void *)a2gl2_stub_vFFF },
    { 0, "glNormal3i", "(III)V", (void *)a2gl2_stub_vIII },
    { 0, "glNormal3s", "(SSS)V", (void *)a2gl2_stub_vSSS },
    { 0, "glOrtho", "(DDDDDD)V", (void *)a2gl2_stub_vDDDDDD },
    { 0, "glPassThrough", "(F)V", (void *)a2gl2_stub_vF },
    { 0, "glPixelTransferf", "(IF)V", (void *)a2gl2_stub_vIF },
    { 0, "glPixelTransferi", "(II)V", (void *)a2gl2_stub_vII },
    { 0, "glPixelZoom", "(FF)V", (void *)a2gl2_stub_vFF },
    { 0, "glPopAttrib", "()V", (void *)a2gl2_stub_v },
    { 0, "glPopClientAttrib", "()V", (void *)a2gl2_stub_v },
    { 0, "glPopMatrix", "()V", (void *)a2gl2_stub_v },
    { 0, "glPopName", "()V", (void *)a2gl2_stub_v },
    { 0, "glPushAttrib", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glPushClientAttrib", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glPushMatrix", "()V", (void *)a2gl2_stub_v },
    { 0, "glPushName", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glRasterPos2d", "(DD)V", (void *)a2gl2_stub_vDD },
    { 0, "glRasterPos2f", "(FF)V", (void *)a2gl2_stub_vFF },
    { 0, "glRasterPos2i", "(II)V", (void *)a2gl2_stub_vII },
    { 0, "glRasterPos2s", "(SS)V", (void *)a2gl2_stub_vSS },
    { 0, "glRasterPos3d", "(DDD)V", (void *)a2gl2_stub_vDDD },
    { 0, "glRasterPos3f", "(FFF)V", (void *)a2gl2_stub_vFFF },
    { 0, "glRasterPos3i", "(III)V", (void *)a2gl2_stub_vIII },
    { 0, "glRasterPos3s", "(SSS)V", (void *)a2gl2_stub_vSSS },
    { 0, "glRasterPos4d", "(DDDD)V", (void *)a2gl2_stub_vDDDD },
    { 0, "glRasterPos4f", "(FFFF)V", (void *)a2gl2_stub_vFFFF },
    { 0, "glRasterPos4i", "(IIII)V", (void *)a2gl2_stub_vIIII },
    { 0, "glRasterPos4s", "(SSSS)V", (void *)a2gl2_stub_vSSSS },
    { 0, "glRectd", "(DDDD)V", (void *)a2gl2_stub_vDDDD },
    { 0, "glRectf", "(FFFF)V", (void *)a2gl2_stub_vFFFF },
    { 0, "glRecti", "(IIII)V", (void *)a2gl2_stub_vIIII },
    { 0, "glRects", "(SSSS)V", (void *)a2gl2_stub_vSSSS },
    { 0, "glRenderMode", "(I)I", (void *)a2gl2_stub_II },
    { 0, "glRotated", "(DDDD)V", (void *)a2gl2_stub_vDDDD },
    { 0, "glRotatef", "(FFFF)V", (void *)a2gl2_stub_vFFFF },
    { 0, "glScaled", "(DDD)V", (void *)a2gl2_stub_vDDD },
    { 0, "glScalef", "(FFF)V", (void *)a2gl2_stub_vFFF },
    { 0, "glShadeModel", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glTexCoord1d", "(D)V", (void *)a2gl2_stub_vD },
    { 0, "glTexCoord1f", "(F)V", (void *)a2gl2_stub_vF },
    { 0, "glTexCoord1i", "(I)V", (void *)a2gl2_stub_vI },
    { 0, "glTexCoord1s", "(S)V", (void *)a2gl2_stub_vS },
    { 0, "glTexCoord2d", "(DD)V", (void *)a2gl2_stub_vDD },
    { 0, "glTexCoord2f", "(FF)V", (void *)a2gl2_stub_vFF },
    { 0, "glTexCoord2i", "(II)V", (void *)a2gl2_stub_vII },
    { 0, "glTexCoord2s", "(SS)V", (void *)a2gl2_stub_vSS },
    { 0, "glTexCoord3d", "(DDD)V", (void *)a2gl2_stub_vDDD },
    { 0, "glTexCoord3f", "(FFF)V", (void *)a2gl2_stub_vFFF },
    { 0, "glTexCoord3i", "(III)V", (void *)a2gl2_stub_vIII },
    { 0, "glTexCoord3s", "(SSS)V", (void *)a2gl2_stub_vSSS },
    { 0, "glTexCoord4d", "(DDDD)V", (void *)a2gl2_stub_vDDDD },
    { 0, "glTexCoord4f", "(FFFF)V", (void *)a2gl2_stub_vFFFF },
    { 0, "glTexCoord4i", "(IIII)V", (void *)a2gl2_stub_vIIII },
    { 0, "glTexCoord4s", "(SSSS)V", (void *)a2gl2_stub_vSSSS },
    { 0, "glTexEnvf", "(IIF)V", (void *)a2gl2_stub_vIIF },
    { 0, "glTexEnvi", "(III)V", (void *)a2gl2_stub_vIII },
    { 0, "glTexGend", "(IID)V", (void *)a2gl2_stub_vIID },
    { 0, "glTexGenf", "(IIF)V", (void *)a2gl2_stub_vIIF },
    { 0, "glTexGeni", "(III)V", (void *)a2gl2_stub_vIII },
    { 0, "glTranslated", "(DDD)V", (void *)a2gl2_stub_vDDD },
    { 0, "glTranslatef", "(FFF)V", (void *)a2gl2_stub_vFFF },
    { 0, "glVertex2d", "(DD)V", (void *)a2gl2_stub_vDD },
    { 0, "glVertex2f", "(FF)V", (void *)a2gl2_stub_vFF },
    { 0, "glVertex2i", "(II)V", (void *)a2gl2_stub_vII },
    { 0, "glVertex2s", "(SS)V", (void *)a2gl2_stub_vSS },
    { 0, "glVertex3d", "(DDD)V", (void *)a2gl2_stub_vDDD },
    { 0, "glVertex3f", "(FFF)V", (void *)a2gl2_stub_vFFF },
    { 0, "glVertex3i", "(III)V", (void *)a2gl2_stub_vIII },
    { 0, "glVertex3s", "(SSS)V", (void *)a2gl2_stub_vSSS },
    { 0, "glVertex4d", "(DDDD)V", (void *)a2gl2_stub_vDDDD },
    { 0, "glVertex4f", "(FFFF)V", (void *)a2gl2_stub_vFFFF },
    { 0, "glVertex4i", "(IIII)V", (void *)a2gl2_stub_vIIII },
    { 0, "glVertex4s", "(SSSS)V", (void *)a2gl2_stub_vSSSS },
    { 0, "nglAreTexturesResident", "(IJJ)Z", (void *)a2gl2_stub_ZIJJ },
    { 0, "nglBitmap", "(IIFFFFJ)V", (void *)a2gl2_stub_vIIFFFFJ },
    { 0, "nglCallLists", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglClipPlane", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 0, "nglColor3bv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor3dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor3fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor3iv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor3sv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor3ubv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor3uiv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor3usv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor4bv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor4dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor4fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor4iv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor4sv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor4ubv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor4uiv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColor4usv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglColorPointer", "(IIIJ)V", (void *)a2gl2_stub_vIIIJ },
    { 0, "nglDrawPixels", "(IIIIJ)V", (void *)a2gl2_stub_vIIIIJ },
    { 0, "nglEdgeFlagPointer", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 0, "nglEdgeFlagv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglEvalCoord1dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglEvalCoord1fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglEvalCoord2dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglEvalCoord2fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglFeedbackBuffer", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglFogfv", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 0, "nglFogiv", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 0, "nglGetClipPlane", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 0, "nglGetLightfv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglGetLightiv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglGetMapdv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglGetMapfv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglGetMapiv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglGetMaterialfv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglGetMaterialiv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglGetPixelMapfv", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 0, "nglGetPixelMapuiv", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 0, "nglGetPixelMapusv", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 0, "nglGetPolygonStipple", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglGetTexEnvfv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglGetTexEnviv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglGetTexGendv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglGetTexGenfv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglGetTexGeniv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglIndexPointer", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglIndexdv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglIndexfv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglIndexiv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglIndexsv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglIndexubv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglInterleavedArrays", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglLightModelfv", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 0, "nglLightModeliv", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 0, "nglLightfv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglLightiv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglLoadMatrixd", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglLoadMatrixf", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglMap1d", "(IDDIIJ)V", (void *)a2gl2_stub_vIDDIIJ },
    { 0, "nglMap1f", "(IFFIIJ)V", (void *)a2gl2_stub_vIFFIIJ },
    { 0, "nglMap2d", "(IDDIIDDIIJ)V", (void *)a2gl2_stub_vIDDIIDDIIJ },
    { 0, "nglMap2f", "(IFFIIFFIIJ)V", (void *)a2gl2_stub_vIFFIIFFIIJ },
    { 0, "nglMaterialfv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglMaterialiv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglMultMatrixd", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglMultMatrixf", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglNormal3bv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglNormal3dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglNormal3fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglNormal3iv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglNormal3sv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglNormalPointer", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglPixelMapfv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglPixelMapuiv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglPixelMapusv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglPolygonStipple", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglPrioritizeTextures", "(IJJ)V", (void *)a2gl2_stub_vIJJ },
    { 0, "nglRasterPos2dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglRasterPos2fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglRasterPos2iv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglRasterPos2sv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglRasterPos3dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglRasterPos3fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglRasterPos3iv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglRasterPos3sv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglRasterPos4dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglRasterPos4fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglRasterPos4iv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglRasterPos4sv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglRectdv", "(JJ)V", (void *)a2gl2_stub_vJJ },
    { 0, "nglRectfv", "(JJ)V", (void *)a2gl2_stub_vJJ },
    { 0, "nglRectiv", "(JJ)V", (void *)a2gl2_stub_vJJ },
    { 0, "nglRectsv", "(JJ)V", (void *)a2gl2_stub_vJJ },
    { 0, "nglSelectBuffer", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 0, "nglTexCoord1dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord1fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord1iv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord1sv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord2dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord2fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord2iv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord2sv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord3dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord3fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord3iv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord3sv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord4dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord4fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord4iv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoord4sv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglTexCoordPointer", "(IIIJ)V", (void *)a2gl2_stub_vIIIJ },
    { 0, "nglTexEnvfv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglTexEnviv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglTexGendv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglTexGenfv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglTexGeniv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 0, "nglVertex2dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglVertex2fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglVertex2iv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglVertex2sv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglVertex3dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglVertex3fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglVertex3iv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglVertex3sv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglVertex4dv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglVertex4fv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglVertex4iv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglVertex4sv", "(J)V", (void *)a2gl2_stub_vJ },
    { 0, "nglVertexPointer", "(IIIJ)V", (void *)a2gl2_stub_vIIIJ },
    // ---- GL11C
    { 1, "glBindTexture", "(II)V", (void *)a2gl2_stub_vII },
    { 1, "glBlendFunc", "(II)V", (void *)a2gl2_stub_vII },
    { 1, "glClear", "(I)V", (void *)a2gl2_stub_vI },
    { 1, "glClearColor", "(FFFF)V", (void *)a2gl2_stub_vFFFF },
    { 1, "glClearDepth", "(D)V", (void *)a2gl2_stub_vD },
    { 1, "glClearStencil", "(I)V", (void *)a2gl2_stub_vI },
    { 1, "glColorMask", "(ZZZZ)V", (void *)a2gl2_stub_vZZZZ },
    { 1, "glCopyTexImage1D", "(IIIIIII)V", (void *)a2gl2_stub_vIIIIIII },
    { 1, "glCopyTexImage2D", "(IIIIIIII)V", (void *)a2gl2_stub_vIIIIIIII },
    { 1, "glCopyTexSubImage1D", "(IIIIII)V", (void *)a2gl2_stub_vIIIIII },
    { 1, "glCopyTexSubImage2D", "(IIIIIIII)V", (void *)a2gl2_stub_vIIIIIIII },
    { 1, "glCullFace", "(I)V", (void *)a2gl2_stub_vI },
    { 1, "glDepthFunc", "(I)V", (void *)a2gl2_stub_vI },
    { 1, "glDepthMask", "(Z)V", (void *)a2gl2_stub_vZ },
    { 1, "glDepthRange", "(DD)V", (void *)a2gl2_stub_vDD },
    { 1, "glDisable", "(I)V", (void *)a2gl2_stub_vI },
    { 1, "glDrawArrays", "(III)V", (void *)a2gl2_stub_vIII },
    { 1, "glDrawBuffer", "(I)V", (void *)a2gl2_stub_vI },
    { 1, "glEnable", "(I)V", (void *)a2gl2_stub_vI },
    { 1, "glFinish", "()V", (void *)a2gl2_stub_v },
    { 1, "glFlush", "()V", (void *)a2gl2_stub_v },
    { 1, "glFrontFace", "(I)V", (void *)a2gl2_stub_vI },
    { 1, "glGetError", "()I", (void *)a2gl2_stub_I },
    { 1, "glHint", "(II)V", (void *)a2gl2_stub_vII },
    { 1, "glIsEnabled", "(I)Z", (void *)a2gl2_stub_ZI },
    { 1, "glIsTexture", "(I)Z", (void *)a2gl2_stub_ZI },
    { 1, "glLineWidth", "(F)V", (void *)a2gl2_stub_vF },
    { 1, "glLogicOp", "(I)V", (void *)a2gl2_stub_vI },
    { 1, "glPixelStoref", "(IF)V", (void *)a2gl2_stub_vIF },
    { 1, "glPixelStorei", "(II)V", (void *)a2gl2_stub_vII },
    { 1, "glPointSize", "(F)V", (void *)a2gl2_stub_vF },
    { 1, "glPolygonMode", "(II)V", (void *)a2gl2_stub_vII },
    { 1, "glPolygonOffset", "(FF)V", (void *)a2gl2_stub_vFF },
    { 1, "glReadBuffer", "(I)V", (void *)a2gl2_stub_vI },
    { 1, "glScissor", "(IIII)V", (void *)a2gl2_stub_vIIII },
    { 1, "glStencilFunc", "(III)V", (void *)a2gl2_stub_vIII },
    { 1, "glStencilMask", "(I)V", (void *)a2gl2_stub_vI },
    { 1, "glStencilOp", "(III)V", (void *)a2gl2_stub_vIII },
    { 1, "glTexParameterf", "(IIF)V", (void *)a2gl2_stub_vIIF },
    { 1, "glTexParameteri", "(III)V", (void *)a2gl2_stub_vIII },
    { 1, "glViewport", "(IIII)V", (void *)a2gl2_stub_vIIII },
    { 1, "nglDeleteTextures", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 1, "nglDrawElements", "(IIIJ)V", (void *)a2gl2_stub_vIIIJ },
    { 1, "nglGenTextures", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 1, "nglGetBooleanv", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 1, "nglGetDoublev", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 1, "nglGetFloatv", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 1, "nglGetIntegerv", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 1, "nglGetPointerv", "(IJ)V", (void *)a2gl2_stub_vIJ },
    { 1, "nglGetString", "(I)J", (void *)a2gl2_stub_JI },
    { 1, "nglGetTexImage", "(IIIIJ)V", (void *)a2gl2_stub_vIIIIJ },
    { 1, "nglGetTexLevelParameterfv", "(IIIJ)V", (void *)a2gl2_stub_vIIIJ },
    { 1, "nglGetTexLevelParameteriv", "(IIIJ)V", (void *)a2gl2_stub_vIIIJ },
    { 1, "nglGetTexParameterfv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 1, "nglGetTexParameteriv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 1, "nglReadPixels", "(IIIIIIJ)V", (void *)a2gl2_stub_vIIIIIIJ },
    { 1, "nglTexImage1D", "(IIIIIIIJ)V", (void *)a2gl2_stub_vIIIIIIIJ },
    { 1, "nglTexImage2D", "(IIIIIIIIJ)V", (void *)a2gl2_stub_vIIIIIIIIJ },
    { 1, "nglTexParameterfv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 1, "nglTexParameteriv", "(IIJ)V", (void *)a2gl2_stub_vIIJ },
    { 1, "nglTexSubImage1D", "(IIIIIIJ)V", (void *)a2gl2_stub_vIIIIIIJ },
    { 1, "nglTexSubImage2D", "(IIIIIIIIJ)V", (void *)a2gl2_stub_vIIIIIIIIJ },
};

#define A2GL2_STUB_COUNT ((int)(sizeof(kA2GL2Stubs) / sizeof(kA2GL2Stubs[0])))

#endif  // A2_GL2_STUB_TABLE_H
