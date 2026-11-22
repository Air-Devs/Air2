/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 *
 * iOS 适配版：兼容 LWJGL 3.3.x（iOS 旧版）和 3.4.1（标准新版）两种 Callback API。
 *
 * 背景：
 *   iOS PojavLauncher 的 LWJGL 模块（GLFW/OpenGL/STB 等）使用旧版 3.3.x API，
 *   CallbackI 接口要求实现 getCallInterface() 返回 FFICIF。
 *   但 MC 26.3+ 的 SDL 模块（lwjgl-sdl.jar）使用标准 3.4.1 API，
 *   CallbackI 接口要求实现 getDescriptor() 返回 Callback.Descriptor。
 *   两者在运行时类路径上共存，导致 SDL callback 触发 AbstractMethodError。
 *
 * 崩溃链（修复前）：
 *   SdlDebug.<clinit> → SDL_LogOutputFunction.create(I) → i.address()
 *   → CallbackI.address() default → this.getCallInterface()  // 旧版 API
 *   → SDL_LogOutputFunctionI 没实现此方法 → AbstractMethodError
 *
 * 兼容策略：
 *   1. getCallInterface() 改为 default，默认从 getDescriptor().cif 取 FFICIF
 *      - 旧版 callback 覆盖 getCallInterface() 返回静态 CIF（保持原行为）
 *      - 新版 callback 覆盖 getDescriptor() 返回静态 DESCRIPTOR，
 *        getCallInterface() 默认实现自动从中取 cif
 *   2. getDescriptor() 改为 default，默认把 getCallInterface() 包装为 Descriptor
 *      - 新版 callback 覆盖此方法
 *      - 旧版 callback 用默认实现（但实际不会被调用，因为 address() 走 getCallInterface()）
 *   3. address() default 保持调用 getCallInterface()（与 iOS 旧版一致）
 *
 * 编译期要求：
 *   Callback.Descriptor 类型必须可识别。Callback.java 源码中已声明 Descriptor
 *   内部类（public static final），javac 编译时会生成 Callback$Descriptor.class，
 *   覆盖 lwjgl-callback-descriptor.jar 中的版本。
 */
package org.lwjgl.system;

import org.lwjgl.system.libffi.FFICIF;

import java.lang.invoke.MethodHandles;

public interface CallbackI extends Pointer {

    /**
     * 旧版 API（LWJGL 3.3.x）：返回 FFICIF。
     * iOS GLFW/OpenGL/STB 等模块覆盖此方法返回静态 CIF。
     * 新版 SDL 等模块不覆盖此方法，默认实现从 getDescriptor().cif 取值。
     */
    default FFICIF getCallInterface() {
        return getDescriptor().cif;
    }

    /**
     * 新版 API（LWJGL 3.4.1）：返回 Callback.Descriptor。
     * 标准 3.4.1 的 SDL 等模块覆盖此方法返回静态 DESCRIPTOR。
     * 默认实现：把旧版 getCallInterface() 的 FFICIF 包装为 Descriptor。
     * 注意：旧版 callback 走到此处会递归调用 getCallInterface()，
     * 但实际旧版 callback 会覆盖 getCallInterface()，不会走到默认实现，
     * 因此不会递归。仅当某 callback 既没覆盖 getCallInterface() 也没覆盖
     * getDescriptor() 时才会无限递归（这种实现是错误的）。
     */
    default Callback.Descriptor getDescriptor() {
        return new Callback.Descriptor(MethodHandles.lookup(), getCallInterface());
    }

    /**
     * 创建并返回 native closure 的地址。
     * 直接用 getCallInterface() 获取 FFICIF（兼容新旧两种 CallbackI 实现）。
     */
    default long address() {
        return Callback.create(getCallInterface(), this);
    }

    /** 由具体 callback 实现的 native 调用入口。 */
    void callback(long ret, long args);
}
