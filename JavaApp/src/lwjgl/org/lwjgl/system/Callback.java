/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 *
 * iOS 适配版：基于 iOS PojavLauncher 的 Callback.class（LWJGL 3.3.x 旧版）反编译重写，
 * 并添加 LWJGL 3.4.1 新增的 Descriptor 内部类和 Callback(Descriptor) 构造函数。
 *
 * 背景：
 *   iOS PojavLauncher 的 LWJGL 模块（GLFW/OpenGL/STB 等）使用旧版 3.3.x API，
 *   Callback 构造函数接受 FFICIF。
 *   但 MC 26.3+ 的 SDL 模块（lwjgl-sdl.jar）使用标准 3.4.1 API，
 *   SDL_LogOutputFunction 的构造函数调用 super(DESCRIPTOR)，即
 *   Callback.<init>(Callback$Descriptor)。iOS 旧版 Callback 无此构造函数，
 *   会导致 NoSuchMethodError。
 *
 *   同时，标准 3.4.1 的 SDL_LogOutputFunctionI 覆盖 getDescriptor() 返回
 *   Callback$Descriptor 类型。如果 CallbackI 接口的 getDescriptor() 返回类型
 *   与之不匹配，JVM 会抛 AbstractMethodError。故 Callback.Descriptor 类型
 *   必须在编译期可识别，需要在此源码中声明。
 *
 * 保留的 iOS 旧版逻辑：
 *   - native 方法 getCallbackHandler(Method) 由 liblwjgl.dylib 提供
 *   - create(FFICIF, Object) 使用 ffi_closure_alloc + ffi_prep_closure_loc
 *   - ClosureRegistry 两种实现（Simple / ConcurrentHashMap）
 *   - static {} 检测 closure 地址布局并初始化 CALLBACK_HANDLER
 *
 * 新增的 3.4.1 兼容：
 *   - Descriptor 内部类（public static final，含 lookup + cif 字段）
 *   - Callback(Descriptor) 构造函数（从 descriptor 取 cif 委托给 Callback(FFICIF)）
 */
package org.lwjgl.system;

import org.lwjgl.PointerBuffer;
import org.lwjgl.system.libffi.FFICIF;
import org.lwjgl.system.libffi.FFIClosure;
import org.lwjgl.system.libffi.LibFFI;
import org.lwjgl.system.jni.JNINativeInterface;

import java.lang.invoke.MethodHandles;
import java.lang.reflect.Method;
import java.util.concurrent.ConcurrentHashMap;

public abstract class Callback implements Pointer, NativeResource {

    private static final boolean DEBUG_ALLOCATOR;
    private static final ClosureRegistry CLOSURE_REGISTRY;
    private static final long CALLBACK_HANDLER;

    private long address;

    // === LWJGL 3.4.1 新增：Descriptor 内部类 ===
    public static final class Descriptor {
        final MethodHandles.Lookup lookup;
        final FFICIF cif;

        public Descriptor(MethodHandles.Lookup lookup, FFICIF cif) {
            this.lookup = lookup;
            this.cif = cif;
        }
    }

    // === LWJGL 3.4.1 新增：Callback(Descriptor) 构造函数 ===
    protected Callback(Descriptor descriptor) {
        this(descriptor.cif);
    }

    // === iOS 旧版：Callback(FFICIF) 构造函数 ===
    protected Callback(FFICIF cif) {
        this.address = create(cif, this);
    }

    protected Callback(long address) {
        if (Checks.CHECKS) {
            Checks.check(address);
        }
        this.address = address;
    }

    @Override
    public long address() {
        return address;
    }

    @Override
    public void free() {
        free(address());
    }

    private static native long getCallbackHandler(Method method);

    static long create(FFICIF cif, Object target) {
        MemoryStack stack = MemoryStack.stackPush();
        try {
            PointerBuffer codes = stack.mallocPointer(1);
            FFIClosure closure = LibFFI.ffi_closure_alloc(FFIClosure.SIZEOF, codes);
            if (closure == null) {
                throw new OutOfMemoryError();
            }
            long nativeAddress = codes.get(0);
            if (DEBUG_ALLOCATOR) {
                MemoryManage.DebugAllocator.track(nativeAddress, FFIClosure.SIZEOF);
            }
            long globalRef = JNINativeInterface.NewGlobalRef(target);
            int errcode = LibFFI.ffi_prep_closure_loc(closure, cif, CALLBACK_HANDLER, globalRef, nativeAddress);
            if (errcode != 0) {
                JNINativeInterface.DeleteGlobalRef(globalRef);
                LibFFI.ffi_closure_free(closure);
                throw new RuntimeException("Failed to prepare the libffi closure");
            }
            CLOSURE_REGISTRY.put(nativeAddress, closure);
            return nativeAddress;
        } finally {
            stack.close();
        }
    }

    @SuppressWarnings("unchecked")
    public static <T extends CallbackI> T get(long address) {
        FFIClosure closure = CLOSURE_REGISTRY.get(address);
        return (T) MemoryUtil.memGlobalRefToObject(closure.user_data());
    }

    public static <T extends CallbackI> T getSafe(long address) {
        return address == 0L ? null : get(address);
    }

    public static void free(long address) {
        if (DEBUG_ALLOCATOR) {
            MemoryManage.DebugAllocator.untrack(address);
        }
        FFIClosure closure = CLOSURE_REGISTRY.get(address);
        JNINativeInterface.DeleteGlobalRef(closure.user_data());
        LibFFI.ffi_closure_free(closure);
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Callback)) return false;
        return address == ((Callback) o).address();
    }

    @Override
    public int hashCode() {
        return (int) (address ^ (address >>> 32));
    }

    @Override
    public String toString() {
        return String.format("%s pointer [0x%X]", getClass().getSimpleName(), address);
    }

    // === ClosureRegistry 接口及两种实现（与 iOS 旧版字节码一致） ===
    interface ClosureRegistry {
        void put(long address, FFIClosure closure);
        FFIClosure get(long address);
        FFIClosure remove(long address);
    }

    // Simple 实现：closure 地址 == Java FFIClosure 包装对象地址时使用
    static final class SimpleClosureRegistry implements ClosureRegistry {
        @Override
        public void put(long address, FFIClosure closure) {
            // 空实现：依赖 FFIClosure 内部布局，无需维护映射
        }

        @Override
        public FFIClosure get(long address) {
            return FFIClosure.create(address);
        }

        @Override
        public FFIClosure remove(long address) {
            return get(address);
        }
    }

    // ConcurrentHashMap 实现：通用方案
    static final class ConcurrentHashMapClosureRegistry implements ClosureRegistry {
        private final ConcurrentHashMap<Long, FFIClosure> map = new ConcurrentHashMap<>();

        @Override
        public void put(long address, FFIClosure closure) {
            map.put(address, closure);
        }

        @Override
        public FFIClosure get(long address) {
            return map.get(address);
        }

        @Override
        public FFIClosure remove(long address) {
            return map.remove(address);
        }
    }

    static {
        // 1. 读取 DEBUG_MEMORY_ALLOCATOR 配置
        DEBUG_ALLOCATOR = Configuration.DEBUG_MEMORY_ALLOCATOR.get(false);

        // 2. 检测 closure 地址布局，选择 Registry 实现
        MemoryStack stack = MemoryStack.stackPush();
        FFIClosure testClosure;
        try {
            PointerBuffer codes = stack.mallocPointer(1);
            testClosure = LibFFI.ffi_closure_alloc(FFIClosure.SIZEOF, codes);
            if (testClosure == null) {
                throw new OutOfMemoryError();
            }
            long nativeAddress = codes.get(0);
            if (nativeAddress == testClosure.address()) {
                APIUtil.apiLog("Closure Registry: simple");
                CLOSURE_REGISTRY = new SimpleClosureRegistry();
            } else {
                APIUtil.apiLog("Closure Registry: ConcurrentHashMap");
                CLOSURE_REGISTRY = new ConcurrentHashMapClosureRegistry();
            }
            LibFFI.ffi_closure_free(testClosure);
        } finally {
            stack.close();
        }

        // 3. 初始化 native callback handler
        try {
            Method callbackMethod = CallbackI.class.getDeclaredMethod("callback", long.class, long.class);
            CALLBACK_HANDLER = getCallbackHandler(callbackMethod);
        } catch (Exception e) {
            throw new IllegalStateException("Failed to initialize the native callback handler.", e);
        }

        // 4. 触发 MemoryUtil 类初始化（与 iOS 旧版一致）
        MemoryUtil.getAllocator();
    }
}
