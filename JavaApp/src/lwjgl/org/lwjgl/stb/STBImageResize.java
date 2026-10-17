/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 *
 * iOS 兼容性补丁：
 * LWJGL 3.4.1 将 nstbir_resize_uint8（返回 int）拆分为
 * nstbir_resize_uint8_srgb / nstbir_resize_uint8_linear（返回 long）。
 * MC 1.21.1（编译于 LWJGL 3.3.3-SNAPSHOT）仍调用旧方法签名
 * int nstbir_resize_uint8(long, int, int, int, long, int, int, int, int)，
 * 导致 NoSuchMethodError 每秒刷屏数百次。
 *
 * 本类完整复制上游 LWJGL 3.4.1 的 STBImageResize，并添加兼容方法
 * nstbir_resize_uint8 委托给 nstbir_resize_uint8_srgb。
 */
package org.lwjgl.stb;

import java.nio.Buffer;
import java.nio.ByteBuffer;
import java.nio.FloatBuffer;

import org.lwjgl.system.Checks;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.system.Pointer;

public class STBImageResize {
    public static final int STBIR_1CHANNEL = 1;
    public static final int STBIR_2CHANNEL = 2;
    public static final int STBIR_RGB = 3;
    public static final int STBIR_BGR = 0;
    public static final int STBIR_4CHANNEL = 5;
    public static final int STBIR_RGBA = 4;
    public static final int STBIR_BGRA = 6;
    public static final int STBIR_ARGB = 7;
    public static final int STBIR_ABGR = 8;
    public static final int STBIR_RA = 9;
    public static final int STBIR_AR = 10;
    public static final int STBIR_RGBA_PM = 11;
    public static final int STBIR_BGRA_PM = 12;
    public static final int STBIR_ARGB_PM = 13;
    public static final int STBIR_ABGR_PM = 14;
    public static final int STBIR_RA_PM = 15;
    public static final int STBIR_AR_PM = 16;
    public static final int STBIR_RGBA_NO_AW = 11;
    public static final int STBIR_BGRA_NO_AW = 12;
    public static final int STBIR_ARGB_NO_AW = 13;
    public static final int STBIR_ABGR_NO_AW = 14;
    public static final int STBIR_RA_NO_AW = 15;
    public static final int STBIR_AR_NO_AW = 16;
    public static final int STBIR_EDGE_CLAMP = 0;
    public static final int STBIR_EDGE_REFLECT = 1;
    public static final int STBIR_EDGE_WRAP = 2;
    public static final int STBIR_EDGE_ZERO = 3;
    public static final int STBIR_FILTER_DEFAULT = 0;
    public static final int STBIR_FILTER_BOX = 1;
    public static final int STBIR_FILTER_TRIANGLE = 2;
    public static final int STBIR_FILTER_CUBICBSPLINE = 3;
    public static final int STBIR_FILTER_CATMULLROM = 4;
    public static final int STBIR_FILTER_MITCHELL = 5;
    public static final int STBIR_FILTER_POINT_SAMPLE = 6;
    public static final int STBIR_FILTER_OTHER = 7;
    public static final int STBIR_TYPE_UINT8 = 0;
    public static final int STBIR_TYPE_UINT8_SRGB = 1;
    public static final int STBIR_TYPE_UINT8_SRGB_ALPHA = 2;
    public static final int STBIR_TYPE_UINT16 = 3;
    public static final int STBIR_TYPE_FLOAT = 4;
    public static final int STBIR_TYPE_HALF_FLOAT = 5;

    private static final int[] stbir_pixel_layout_channels;
    private static final int[] stbir_type_size;

    protected STBImageResize() {
        throw new UnsupportedOperationException();
    }

    // ========================================================================
    // 兼容性方法：MC 1.21.1 调用的旧 API 签名
    // 旧 LWJGL: int nstbir_resize_uint8(long, int, int, int, long, int, int, int, int)
    // 新 LWJGL 3.4.1: long nstbir_resize_uint8_srgb(同参数)
    // 委托给 srgb 变体，将 long 指针返回值转为 int（0=失败, 1=成功）
    // ========================================================================
    public static int nstbir_resize_uint8(long input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                           long output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                           int pixel_type) {
        long result = nstbir_resize_uint8_srgb(input_pixels, input_w, input_h, input_stride_in_bytes,
                                                output_pixels, output_w, output_h, output_stride_in_bytes,
                                                pixel_type);
        return result != 0L ? 1 : 0;
    }

    // ========================================================================
    // 上游 LWJGL 3.4.1 native 方法（保持原样）
    // ========================================================================

    public static native long nstbir_resize_uint8_srgb(long var0, int var2, int var3, int var4, long var5, int var7, int var8, int var9, int var10);

    public static ByteBuffer stbir_resize_uint8_srgb(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_type) {
        int length = calculateBufferSize(output_w, output_h, output_stride_in_bytes, pixel_type, 1);
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (int)length);
        }
        long __result = nstbir_resize_uint8_srgb(MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_type);
        return MemoryUtil.memByteBufferSafe((long)__result, (int)length);
    }

    public static ByteBuffer stbir_resize_uint8_srgb(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_type, long length) {
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (long)length);
        }
        long __result = nstbir_resize_uint8_srgb(MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_type);
        return MemoryUtil.memByteBufferSafe((long)__result, (int)((int)length));
    }

    public static native long nstbir_resize_uint8_linear(long var0, int var2, int var3, int var4, long var5, int var7, int var8, int var9, int var10);

    public static ByteBuffer stbir_resize_uint8_linear(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_type) {
        int length = calculateBufferSize(output_w, output_h, output_stride_in_bytes, pixel_type, 1);
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (int)length);
        }
        long __result = nstbir_resize_uint8_linear(MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_type);
        return MemoryUtil.memByteBufferSafe((long)__result, (int)length);
    }

    public static ByteBuffer stbir_resize_uint8_linear(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_type, long length) {
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (long)length);
        }
        long __result = nstbir_resize_uint8_linear(MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_type);
        return MemoryUtil.memByteBufferSafe((long)__result, (int)((int)length));
    }

    public static native long nstbir_resize_float_linear(long var0, int var2, int var3, int var4, long var5, int var7, int var8, int var9, int var10);

    public static FloatBuffer stbir_resize_float_linear(FloatBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, FloatBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_type) {
        int length = calculateBufferSize(output_w, output_h, output_stride_in_bytes, pixel_type, 4);
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (int)length);
        }
        long __result = nstbir_resize_float_linear(MemoryUtil.memAddress((FloatBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((FloatBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_type);
        return MemoryUtil.memFloatBufferSafe((long)__result, (int)length);
    }

    public static FloatBuffer stbir_resize_float_linear(FloatBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, FloatBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_type, long length) {
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (long)length);
        }
        long __result = nstbir_resize_float_linear(MemoryUtil.memAddress((FloatBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((FloatBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_type);
        return MemoryUtil.memFloatBufferSafe((long)__result, (int)((int)length));
    }

    public static native long nstbir_resize(long var0, int var2, int var3, int var4, long var5, int var7, int var8, int var9, int var10, int var11, int var12, int var13);

    public static ByteBuffer stbir_resize(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_layout, int data_type, int edge, int filter) {
        int length = calculateBufferSize(output_w, output_h, output_stride_in_bytes, pixel_layout, stbir_type_size[data_type]);
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (int)length);
        }
        long __result = nstbir_resize(MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_layout, data_type, edge, filter);
        return MemoryUtil.memByteBufferSafe((long)__result, (int)length);
    }

    public static ByteBuffer stbir_resize(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_layout, int data_type, int edge, int filter, long length) {
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (long)length);
        }
        long __result = nstbir_resize(MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_layout, data_type, edge, filter);
        return MemoryUtil.memByteBufferSafe((long)__result, (int)((int)length));
    }

    public static native void nstbir_resize_init(long var0, long var2, int var4, int var5, int var6, long var7, int var9, int var10, int var11, int var12, int var13);

    public static void stbir_resize_init(STBIR_RESIZE resize, ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_layout, int data_type) {
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (int)calculateBufferSize(output_w, output_h, output_stride_in_bytes, pixel_layout, stbir_type_size[data_type]));
        }
        nstbir_resize_init(resize.address(), MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_layout, data_type);
    }

    public static native void nstbir_set_datatypes(long var0, int var2, int var3);

    public static void stbir_set_datatypes(STBIR_RESIZE resize, int input_type, int output_type) {
        nstbir_set_datatypes(resize.address(), input_type, output_type);
    }

    public static native void nstbir_set_pixel_callbacks(long var0, long var2, long var4);

    public static void stbir_set_pixel_callbacks(STBIR_RESIZE resize, STBIRInputCallbackI input_cb, STBIROutputCallbackI output_cb) {
        nstbir_set_pixel_callbacks(resize.address(), MemoryUtil.memAddressSafe((Pointer)input_cb), MemoryUtil.memAddressSafe((Pointer)output_cb));
    }

    public static native void nstbir_set_user_data(long var0, long var2);

    public static void stbir_set_user_data(STBIR_RESIZE resize, long user_data) {
        nstbir_set_user_data(resize.address(), user_data);
    }

    public static native void nstbir_set_buffer_ptrs(long var0, long var2, int var4, long var5, int var7);

    public static void stbir_set_buffer_ptrs(STBIR_RESIZE resize, ByteBuffer input_pixels, int input_stride_in_bytes, ByteBuffer output_pixels, int output_stride_in_bytes) {
        nstbir_set_buffer_ptrs(resize.address(), MemoryUtil.memAddress((ByteBuffer)input_pixels), input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_stride_in_bytes);
    }

    public static native int nstbir_set_pixel_layouts(long var0, int var2, int var3);

    public static int stbir_set_pixel_layouts(STBIR_RESIZE resize, int input_pixel_layout, int output_pixel_layout) {
        return nstbir_set_pixel_layouts(resize.address(), input_pixel_layout, output_pixel_layout);
    }

    public static native int nstbir_set_edgemodes(long var0, int var2, int var3);

    public static int stbir_set_edgemodes(STBIR_RESIZE resize, int horizontal_edge, int vertical_edge) {
        return nstbir_set_edgemodes(resize.address(), horizontal_edge, vertical_edge);
    }

    public static native int nstbir_set_filters(long var0, int var2, int var3);

    public static int stbir_set_filters(STBIR_RESIZE resize, int horizontal_filter, int vertical_filter) {
        return nstbir_set_filters(resize.address(), horizontal_filter, vertical_filter);
    }

    public static native int nstbir_set_filter_callbacks(long var0, long var2, long var4, long var6, long var8);

    public static int stbir_set_filter_callbacks(STBIR_RESIZE resize, STBIRKernelCallbackI horizontal_filter, STBIRSupportCallbackI horizontal_support, STBIRKernelCallbackI vertical_filter, STBIRSupportCallbackI vertical_support) {
        return nstbir_set_filter_callbacks(resize.address(), MemoryUtil.memAddressSafe((Pointer)horizontal_filter), MemoryUtil.memAddressSafe((Pointer)horizontal_support), MemoryUtil.memAddressSafe((Pointer)vertical_filter), MemoryUtil.memAddressSafe((Pointer)vertical_support));
    }

    public static native int nstbir_set_pixel_subrect(long var0, int var2, int var3, int var4, int var5);

    public static int stbir_set_pixel_subrect(STBIR_RESIZE resize, int subx, int suby, int subw, int subh) {
        return nstbir_set_pixel_subrect(resize.address(), subx, suby, subw, subh);
    }

    public static native int nstbir_set_input_subrect(long var0, double var2, double var4, double var6, double var8);

    public static int stbir_set_input_subrect(STBIR_RESIZE resize, double s0, double t0, double s1, double t1) {
        return nstbir_set_input_subrect(resize.address(), s0, t0, s1, t1);
    }

    public static native int nstbir_set_output_pixel_subrect(long var0, int var2, int var3, int var4, int var5);

    public static int stbir_set_output_pixel_subrect(STBIR_RESIZE resize, int subx, int suby, int subw, int subh) {
        return nstbir_set_output_pixel_subrect(resize.address(), subx, suby, subw, subh);
    }

    public static native int nstbir_set_non_pm_alpha_speed_over_quality(long var0, int var2);

    public static int stbir_set_non_pm_alpha_speed_over_quality(STBIR_RESIZE resize, boolean non_pma_alpha_speed_over_quality) {
        return nstbir_set_non_pm_alpha_speed_over_quality(resize.address(), non_pma_alpha_speed_over_quality ? 1 : 0);
    }

    public static native int nstbir_build_samplers(long var0);

    public static int stbir_build_samplers(STBIR_RESIZE resize) {
        return nstbir_build_samplers(resize.address());
    }

    public static native void nstbir_free_samplers(long var0);

    public static void stbir_free_samplers(STBIR_RESIZE resize) {
        nstbir_free_samplers(resize.address());
    }

    public static native int nstbir_resize_extended(long var0);

    public static int stbir_resize_extended(STBIR_RESIZE resize) {
        return nstbir_resize_extended(resize.address());
    }

    public static native int nstbir_build_samplers_with_splits(long var0, int var2);

    public static int stbir_build_samplers_with_splits(STBIR_RESIZE resize, int try_splits) {
        return nstbir_build_samplers_with_splits(resize.address(), try_splits);
    }

    public static native int nstbir_resize_extended_split(long var0, int var2, int var3);

    public static int stbir_resize_extended_split(STBIR_RESIZE resize, int split_start, int split_count) {
        return nstbir_resize_extended_split(resize.address(), split_start, split_count);
    }

    private static int calculateBufferSize(int width, int height, int stride_in_bytes, int pixel_type, int type_size) {
        return height * (stride_in_bytes == 0 ? width * stbir_pixel_layout_channels[pixel_type] * type_size : stride_in_bytes);
    }

    static {
        LibSTB.initialize();
        stbir_pixel_layout_channels = new int[]{3, 1, 2, 3, 4, 4, 4, 4, 4, 2, 2, 4, 4, 4, 4, 2, 2};
        stbir_type_size = new int[]{1, 1, 1, 2, 4, 2};
    }
}
