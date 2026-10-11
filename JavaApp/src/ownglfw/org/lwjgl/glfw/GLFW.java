/*
 * Air2 —— org.lwjgl.glfw.GLFW（自研净室实现 · 阶段 1 最小集）
 * ============================================================================
 * 来源与许可（净室声明）
 *   本文件由 Air2 自研线独立编写（[A2-OWNGLFW-1]），**未参考、未复制**任何
 *   Pojav / Boardwalk / Amethyst / LWJGL 的源码。仅依据两类公开资料：
 *     (1) GLFW 官方 C 头文件 glfw3.h（3.4，zlib 许可）——常量与语义；
 *     (2) LWJGL 官方 javadoc（https://javadoc.lwjgl.org/org/lwjgl/glfw/GLFW.html）
 *         ——Java 侧公共签名，用于「与官方对齐」。
 *   常量值即官方 glfw3.h 原文数值（事实性数据），非他人代码。
 *   自研部分版权归 Air2 项目本人所有；无 GPL 血缘。
 * ============================================================================
 * 目标
 *   「进主界面必需」的 org.lwjgl.glfw.* 最小集，签名/行为与官方对齐，
 *   以便日后整块替换（替换时只换本入口，不动 MC 调用方）。
 *   引擎相关操作（窗口/上下文/事件泵）经 11 个私有 native 打到 native 侧；
 *   其余全部为 Java 侧状态（对齐既有 iOS 端「Java 假窗口对象」的做法）。
 * ============================================================================
 */
package org.lwjgl.glfw;

import java.nio.ByteBuffer;
import java.nio.DoubleBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import org.lwjgl.PointerBuffer;
import org.lwjgl.system.MemoryUtil;

public class GLFW {

    // ======================= 常量（源自官方 glfw3.h 3.4） =======================
    public static final int GLFW_VERSION_MAJOR = 3;
    public static final int GLFW_VERSION_MINOR = 4;
    public static final int GLFW_VERSION_REVISION = 0;
    public static final int GLFW_TRUE = 1;
    public static final int GLFW_FALSE = 0;
    public static final int GLFW_RELEASE = 0;
    public static final int GLFW_PRESS = 1;
    public static final int GLFW_REPEAT = 2;
    public static final int GLFW_HAT_CENTERED = 0;
    public static final int GLFW_HAT_UP = 1;
    public static final int GLFW_HAT_RIGHT = 2;
    public static final int GLFW_HAT_DOWN = 4;
    public static final int GLFW_HAT_LEFT = 8;
    public static final int GLFW_HAT_RIGHT_UP = GLFW_HAT_RIGHT | GLFW_HAT_UP;
    public static final int GLFW_HAT_RIGHT_DOWN = GLFW_HAT_RIGHT | GLFW_HAT_DOWN;
    public static final int GLFW_HAT_LEFT_UP = GLFW_HAT_LEFT  | GLFW_HAT_UP;
    public static final int GLFW_HAT_LEFT_DOWN = GLFW_HAT_LEFT  | GLFW_HAT_DOWN;
    public static final int GLFW_KEY_UNKNOWN = -1;
    public static final int GLFW_KEY_SPACE = 32;
    public static final int GLFW_KEY_APOSTROPHE = 39;
    public static final int GLFW_KEY_COMMA = 44;
    public static final int GLFW_KEY_MINUS = 45;
    public static final int GLFW_KEY_PERIOD = 46;
    public static final int GLFW_KEY_SLASH = 47;
    public static final int GLFW_KEY_0 = 48;
    public static final int GLFW_KEY_1 = 49;
    public static final int GLFW_KEY_2 = 50;
    public static final int GLFW_KEY_3 = 51;
    public static final int GLFW_KEY_4 = 52;
    public static final int GLFW_KEY_5 = 53;
    public static final int GLFW_KEY_6 = 54;
    public static final int GLFW_KEY_7 = 55;
    public static final int GLFW_KEY_8 = 56;
    public static final int GLFW_KEY_9 = 57;
    public static final int GLFW_KEY_SEMICOLON = 59;
    public static final int GLFW_KEY_EQUAL = 61;
    public static final int GLFW_KEY_A = 65;
    public static final int GLFW_KEY_B = 66;
    public static final int GLFW_KEY_C = 67;
    public static final int GLFW_KEY_D = 68;
    public static final int GLFW_KEY_E = 69;
    public static final int GLFW_KEY_F = 70;
    public static final int GLFW_KEY_G = 71;
    public static final int GLFW_KEY_H = 72;
    public static final int GLFW_KEY_I = 73;
    public static final int GLFW_KEY_J = 74;
    public static final int GLFW_KEY_K = 75;
    public static final int GLFW_KEY_L = 76;
    public static final int GLFW_KEY_M = 77;
    public static final int GLFW_KEY_N = 78;
    public static final int GLFW_KEY_O = 79;
    public static final int GLFW_KEY_P = 80;
    public static final int GLFW_KEY_Q = 81;
    public static final int GLFW_KEY_R = 82;
    public static final int GLFW_KEY_S = 83;
    public static final int GLFW_KEY_T = 84;
    public static final int GLFW_KEY_U = 85;
    public static final int GLFW_KEY_V = 86;
    public static final int GLFW_KEY_W = 87;
    public static final int GLFW_KEY_X = 88;
    public static final int GLFW_KEY_Y = 89;
    public static final int GLFW_KEY_Z = 90;
    public static final int GLFW_KEY_LEFT_BRACKET = 91;
    public static final int GLFW_KEY_BACKSLASH = 92;
    public static final int GLFW_KEY_RIGHT_BRACKET = 93;
    public static final int GLFW_KEY_GRAVE_ACCENT = 96;
    public static final int GLFW_KEY_WORLD_1 = 161;
    public static final int GLFW_KEY_WORLD_2 = 162;
    public static final int GLFW_KEY_ESCAPE = 256;
    public static final int GLFW_KEY_ENTER = 257;
    public static final int GLFW_KEY_TAB = 258;
    public static final int GLFW_KEY_BACKSPACE = 259;
    public static final int GLFW_KEY_INSERT = 260;
    public static final int GLFW_KEY_DELETE = 261;
    public static final int GLFW_KEY_RIGHT = 262;
    public static final int GLFW_KEY_LEFT = 263;
    public static final int GLFW_KEY_DOWN = 264;
    public static final int GLFW_KEY_UP = 265;
    public static final int GLFW_KEY_PAGE_UP = 266;
    public static final int GLFW_KEY_PAGE_DOWN = 267;
    public static final int GLFW_KEY_HOME = 268;
    public static final int GLFW_KEY_END = 269;
    public static final int GLFW_KEY_CAPS_LOCK = 280;
    public static final int GLFW_KEY_SCROLL_LOCK = 281;
    public static final int GLFW_KEY_NUM_LOCK = 282;
    public static final int GLFW_KEY_PRINT_SCREEN = 283;
    public static final int GLFW_KEY_PAUSE = 284;
    public static final int GLFW_KEY_F1 = 290;
    public static final int GLFW_KEY_F2 = 291;
    public static final int GLFW_KEY_F3 = 292;
    public static final int GLFW_KEY_F4 = 293;
    public static final int GLFW_KEY_F5 = 294;
    public static final int GLFW_KEY_F6 = 295;
    public static final int GLFW_KEY_F7 = 296;
    public static final int GLFW_KEY_F8 = 297;
    public static final int GLFW_KEY_F9 = 298;
    public static final int GLFW_KEY_F10 = 299;
    public static final int GLFW_KEY_F11 = 300;
    public static final int GLFW_KEY_F12 = 301;
    public static final int GLFW_KEY_F13 = 302;
    public static final int GLFW_KEY_F14 = 303;
    public static final int GLFW_KEY_F15 = 304;
    public static final int GLFW_KEY_F16 = 305;
    public static final int GLFW_KEY_F17 = 306;
    public static final int GLFW_KEY_F18 = 307;
    public static final int GLFW_KEY_F19 = 308;
    public static final int GLFW_KEY_F20 = 309;
    public static final int GLFW_KEY_F21 = 310;
    public static final int GLFW_KEY_F22 = 311;
    public static final int GLFW_KEY_F23 = 312;
    public static final int GLFW_KEY_F24 = 313;
    public static final int GLFW_KEY_F25 = 314;
    public static final int GLFW_KEY_KP_0 = 320;
    public static final int GLFW_KEY_KP_1 = 321;
    public static final int GLFW_KEY_KP_2 = 322;
    public static final int GLFW_KEY_KP_3 = 323;
    public static final int GLFW_KEY_KP_4 = 324;
    public static final int GLFW_KEY_KP_5 = 325;
    public static final int GLFW_KEY_KP_6 = 326;
    public static final int GLFW_KEY_KP_7 = 327;
    public static final int GLFW_KEY_KP_8 = 328;
    public static final int GLFW_KEY_KP_9 = 329;
    public static final int GLFW_KEY_KP_DECIMAL = 330;
    public static final int GLFW_KEY_KP_DIVIDE = 331;
    public static final int GLFW_KEY_KP_MULTIPLY = 332;
    public static final int GLFW_KEY_KP_SUBTRACT = 333;
    public static final int GLFW_KEY_KP_ADD = 334;
    public static final int GLFW_KEY_KP_ENTER = 335;
    public static final int GLFW_KEY_KP_EQUAL = 336;
    public static final int GLFW_KEY_LEFT_SHIFT = 340;
    public static final int GLFW_KEY_LEFT_CONTROL = 341;
    public static final int GLFW_KEY_LEFT_ALT = 342;
    public static final int GLFW_KEY_LEFT_SUPER = 343;
    public static final int GLFW_KEY_RIGHT_SHIFT = 344;
    public static final int GLFW_KEY_RIGHT_CONTROL = 345;
    public static final int GLFW_KEY_RIGHT_ALT = 346;
    public static final int GLFW_KEY_RIGHT_SUPER = 347;
    public static final int GLFW_KEY_MENU = 348;
    public static final int GLFW_KEY_LAST = GLFW_KEY_MENU;
    public static final int GLFW_MOD_SHIFT = 0x0001;
    public static final int GLFW_MOD_CONTROL = 0x0002;
    public static final int GLFW_MOD_ALT = 0x0004;
    public static final int GLFW_MOD_SUPER = 0x0008;
    public static final int GLFW_MOD_CAPS_LOCK = 0x0010;
    public static final int GLFW_MOD_NUM_LOCK = 0x0020;
    public static final int GLFW_MOUSE_BUTTON_1 = 0;
    public static final int GLFW_MOUSE_BUTTON_2 = 1;
    public static final int GLFW_MOUSE_BUTTON_3 = 2;
    public static final int GLFW_MOUSE_BUTTON_4 = 3;
    public static final int GLFW_MOUSE_BUTTON_5 = 4;
    public static final int GLFW_MOUSE_BUTTON_6 = 5;
    public static final int GLFW_MOUSE_BUTTON_7 = 6;
    public static final int GLFW_MOUSE_BUTTON_8 = 7;
    public static final int GLFW_MOUSE_BUTTON_LAST = GLFW_MOUSE_BUTTON_8;
    public static final int GLFW_MOUSE_BUTTON_LEFT = GLFW_MOUSE_BUTTON_1;
    public static final int GLFW_MOUSE_BUTTON_RIGHT = GLFW_MOUSE_BUTTON_2;
    public static final int GLFW_MOUSE_BUTTON_MIDDLE = GLFW_MOUSE_BUTTON_3;
    public static final int GLFW_JOYSTICK_1 = 0;
    public static final int GLFW_JOYSTICK_2 = 1;
    public static final int GLFW_JOYSTICK_3 = 2;
    public static final int GLFW_JOYSTICK_4 = 3;
    public static final int GLFW_JOYSTICK_5 = 4;
    public static final int GLFW_JOYSTICK_6 = 5;
    public static final int GLFW_JOYSTICK_7 = 6;
    public static final int GLFW_JOYSTICK_8 = 7;
    public static final int GLFW_JOYSTICK_9 = 8;
    public static final int GLFW_JOYSTICK_10 = 9;
    public static final int GLFW_JOYSTICK_11 = 10;
    public static final int GLFW_JOYSTICK_12 = 11;
    public static final int GLFW_JOYSTICK_13 = 12;
    public static final int GLFW_JOYSTICK_14 = 13;
    public static final int GLFW_JOYSTICK_15 = 14;
    public static final int GLFW_JOYSTICK_16 = 15;
    public static final int GLFW_JOYSTICK_LAST = GLFW_JOYSTICK_16;
    public static final int GLFW_GAMEPAD_BUTTON_A = 0;
    public static final int GLFW_GAMEPAD_BUTTON_B = 1;
    public static final int GLFW_GAMEPAD_BUTTON_X = 2;
    public static final int GLFW_GAMEPAD_BUTTON_Y = 3;
    public static final int GLFW_GAMEPAD_BUTTON_LEFT_BUMPER = 4;
    public static final int GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER = 5;
    public static final int GLFW_GAMEPAD_BUTTON_BACK = 6;
    public static final int GLFW_GAMEPAD_BUTTON_START = 7;
    public static final int GLFW_GAMEPAD_BUTTON_GUIDE = 8;
    public static final int GLFW_GAMEPAD_BUTTON_LEFT_THUMB = 9;
    public static final int GLFW_GAMEPAD_BUTTON_RIGHT_THUMB = 10;
    public static final int GLFW_GAMEPAD_BUTTON_DPAD_UP = 11;
    public static final int GLFW_GAMEPAD_BUTTON_DPAD_RIGHT = 12;
    public static final int GLFW_GAMEPAD_BUTTON_DPAD_DOWN = 13;
    public static final int GLFW_GAMEPAD_BUTTON_DPAD_LEFT = 14;
    public static final int GLFW_GAMEPAD_BUTTON_LAST = GLFW_GAMEPAD_BUTTON_DPAD_LEFT;
    public static final int GLFW_GAMEPAD_BUTTON_CROSS = GLFW_GAMEPAD_BUTTON_A;
    public static final int GLFW_GAMEPAD_BUTTON_CIRCLE = GLFW_GAMEPAD_BUTTON_B;
    public static final int GLFW_GAMEPAD_BUTTON_SQUARE = GLFW_GAMEPAD_BUTTON_X;
    public static final int GLFW_GAMEPAD_BUTTON_TRIANGLE = GLFW_GAMEPAD_BUTTON_Y;
    public static final int GLFW_GAMEPAD_AXIS_LEFT_X = 0;
    public static final int GLFW_GAMEPAD_AXIS_LEFT_Y = 1;
    public static final int GLFW_GAMEPAD_AXIS_RIGHT_X = 2;
    public static final int GLFW_GAMEPAD_AXIS_RIGHT_Y = 3;
    public static final int GLFW_GAMEPAD_AXIS_LEFT_TRIGGER = 4;
    public static final int GLFW_GAMEPAD_AXIS_RIGHT_TRIGGER = 5;
    public static final int GLFW_GAMEPAD_AXIS_LAST = GLFW_GAMEPAD_AXIS_RIGHT_TRIGGER;
    public static final int GLFW_NO_ERROR = 0;
    public static final int GLFW_NOT_INITIALIZED = 0x00010001;
    public static final int GLFW_NO_CURRENT_CONTEXT = 0x00010002;
    public static final int GLFW_INVALID_ENUM = 0x00010003;
    public static final int GLFW_INVALID_VALUE = 0x00010004;
    public static final int GLFW_OUT_OF_MEMORY = 0x00010005;
    public static final int GLFW_API_UNAVAILABLE = 0x00010006;
    public static final int GLFW_VERSION_UNAVAILABLE = 0x00010007;
    public static final int GLFW_PLATFORM_ERROR = 0x00010008;
    public static final int GLFW_FORMAT_UNAVAILABLE = 0x00010009;
    public static final int GLFW_NO_WINDOW_CONTEXT = 0x0001000A;
    public static final int GLFW_CURSOR_UNAVAILABLE = 0x0001000B;
    public static final int GLFW_FEATURE_UNAVAILABLE = 0x0001000C;
    public static final int GLFW_FEATURE_UNIMPLEMENTED = 0x0001000D;
    public static final int GLFW_PLATFORM_UNAVAILABLE = 0x0001000E;
    public static final int GLFW_FOCUSED = 0x00020001;
    public static final int GLFW_ICONIFIED = 0x00020002;
    public static final int GLFW_RESIZABLE = 0x00020003;
    public static final int GLFW_VISIBLE = 0x00020004;
    public static final int GLFW_DECORATED = 0x00020005;
    public static final int GLFW_AUTO_ICONIFY = 0x00020006;
    public static final int GLFW_FLOATING = 0x00020007;
    public static final int GLFW_MAXIMIZED = 0x00020008;
    public static final int GLFW_CENTER_CURSOR = 0x00020009;
    public static final int GLFW_TRANSPARENT_FRAMEBUFFER = 0x0002000A;
    public static final int GLFW_HOVERED = 0x0002000B;
    public static final int GLFW_FOCUS_ON_SHOW = 0x0002000C;
    public static final int GLFW_MOUSE_PASSTHROUGH = 0x0002000D;
    public static final int GLFW_POSITION_X = 0x0002000E;
    public static final int GLFW_POSITION_Y = 0x0002000F;
    public static final int GLFW_RED_BITS = 0x00021001;
    public static final int GLFW_GREEN_BITS = 0x00021002;
    public static final int GLFW_BLUE_BITS = 0x00021003;
    public static final int GLFW_ALPHA_BITS = 0x00021004;
    public static final int GLFW_DEPTH_BITS = 0x00021005;
    public static final int GLFW_STENCIL_BITS = 0x00021006;
    public static final int GLFW_ACCUM_RED_BITS = 0x00021007;
    public static final int GLFW_ACCUM_GREEN_BITS = 0x00021008;
    public static final int GLFW_ACCUM_BLUE_BITS = 0x00021009;
    public static final int GLFW_ACCUM_ALPHA_BITS = 0x0002100A;
    public static final int GLFW_AUX_BUFFERS = 0x0002100B;
    public static final int GLFW_STEREO = 0x0002100C;
    public static final int GLFW_SAMPLES = 0x0002100D;
    public static final int GLFW_SRGB_CAPABLE = 0x0002100E;
    public static final int GLFW_REFRESH_RATE = 0x0002100F;
    public static final int GLFW_DOUBLEBUFFER = 0x00021010;
    public static final int GLFW_CLIENT_API = 0x00022001;
    public static final int GLFW_CONTEXT_VERSION_MAJOR = 0x00022002;
    public static final int GLFW_CONTEXT_VERSION_MINOR = 0x00022003;
    public static final int GLFW_CONTEXT_REVISION = 0x00022004;
    public static final int GLFW_CONTEXT_ROBUSTNESS = 0x00022005;
    public static final int GLFW_OPENGL_FORWARD_COMPAT = 0x00022006;
    public static final int GLFW_CONTEXT_DEBUG = 0x00022007;
    public static final int GLFW_OPENGL_DEBUG_CONTEXT = GLFW_CONTEXT_DEBUG;
    public static final int GLFW_OPENGL_PROFILE = 0x00022008;
    public static final int GLFW_CONTEXT_RELEASE_BEHAVIOR = 0x00022009;
    public static final int GLFW_CONTEXT_NO_ERROR = 0x0002200A;
    public static final int GLFW_CONTEXT_CREATION_API = 0x0002200B;
    public static final int GLFW_SCALE_TO_MONITOR = 0x0002200C;
    public static final int GLFW_SCALE_FRAMEBUFFER = 0x0002200D;
    public static final int GLFW_COCOA_RETINA_FRAMEBUFFER = 0x00023001;
    public static final int GLFW_COCOA_FRAME_NAME = 0x00023002;
    public static final int GLFW_COCOA_GRAPHICS_SWITCHING = 0x00023003;
    public static final int GLFW_X11_CLASS_NAME = 0x00024001;
    public static final int GLFW_X11_INSTANCE_NAME = 0x00024002;
    public static final int GLFW_WIN32_KEYBOARD_MENU = 0x00025001;
    public static final int GLFW_WIN32_SHOWDEFAULT = 0x00025002;
    public static final int GLFW_WAYLAND_APP_ID = 0x00026001;
    public static final int GLFW_NO_API = 0;
    public static final int GLFW_OPENGL_API = 0x00030001;
    public static final int GLFW_OPENGL_ES_API = 0x00030002;
    public static final int GLFW_NO_ROBUSTNESS = 0;
    public static final int GLFW_NO_RESET_NOTIFICATION = 0x00031001;
    public static final int GLFW_LOSE_CONTEXT_ON_RESET = 0x00031002;
    public static final int GLFW_OPENGL_ANY_PROFILE = 0;
    public static final int GLFW_OPENGL_CORE_PROFILE = 0x00032001;
    public static final int GLFW_OPENGL_COMPAT_PROFILE = 0x00032002;
    public static final int GLFW_CURSOR = 0x00033001;
    public static final int GLFW_STICKY_KEYS = 0x00033002;
    public static final int GLFW_STICKY_MOUSE_BUTTONS = 0x00033003;
    public static final int GLFW_LOCK_KEY_MODS = 0x00033004;
    public static final int GLFW_RAW_MOUSE_MOTION = 0x00033005;
    public static final int GLFW_CURSOR_NORMAL = 0x00034001;
    public static final int GLFW_CURSOR_HIDDEN = 0x00034002;
    public static final int GLFW_CURSOR_DISABLED = 0x00034003;
    public static final int GLFW_CURSOR_CAPTURED = 0x00034004;
    public static final int GLFW_ANY_RELEASE_BEHAVIOR = 0;
    public static final int GLFW_RELEASE_BEHAVIOR_FLUSH = 0x00035001;
    public static final int GLFW_RELEASE_BEHAVIOR_NONE = 0x00035002;
    public static final int GLFW_NATIVE_CONTEXT_API = 0x00036001;
    public static final int GLFW_EGL_CONTEXT_API = 0x00036002;
    public static final int GLFW_OSMESA_CONTEXT_API = 0x00036003;
    public static final int GLFW_ANGLE_PLATFORM_TYPE_NONE = 0x00037001;
    public static final int GLFW_ANGLE_PLATFORM_TYPE_OPENGL = 0x00037002;
    public static final int GLFW_ANGLE_PLATFORM_TYPE_OPENGLES = 0x00037003;
    public static final int GLFW_ANGLE_PLATFORM_TYPE_D3D9 = 0x00037004;
    public static final int GLFW_ANGLE_PLATFORM_TYPE_D3D11 = 0x00037005;
    public static final int GLFW_ANGLE_PLATFORM_TYPE_VULKAN = 0x00037007;
    public static final int GLFW_ANGLE_PLATFORM_TYPE_METAL = 0x00037008;
    public static final int GLFW_WAYLAND_PREFER_LIBDECOR = 0x00038001;
    public static final int GLFW_WAYLAND_DISABLE_LIBDECOR = 0x00038002;
    public static final int GLFW_ANY_POSITION = 0x80000000;
    public static final int GLFW_ARROW_CURSOR = 0x00036001;
    public static final int GLFW_IBEAM_CURSOR = 0x00036002;
    public static final int GLFW_CROSSHAIR_CURSOR = 0x00036003;
    public static final int GLFW_POINTING_HAND_CURSOR = 0x00036004;
    public static final int GLFW_RESIZE_EW_CURSOR = 0x00036005;
    public static final int GLFW_RESIZE_NS_CURSOR = 0x00036006;
    public static final int GLFW_RESIZE_NWSE_CURSOR = 0x00036007;
    public static final int GLFW_RESIZE_NESW_CURSOR = 0x00036008;
    public static final int GLFW_RESIZE_ALL_CURSOR = 0x00036009;
    public static final int GLFW_NOT_ALLOWED_CURSOR = 0x0003600A;
    public static final int GLFW_HRESIZE_CURSOR = GLFW_RESIZE_EW_CURSOR;
    public static final int GLFW_VRESIZE_CURSOR = GLFW_RESIZE_NS_CURSOR;
    public static final int GLFW_HAND_CURSOR = GLFW_POINTING_HAND_CURSOR;
    public static final int GLFW_CONNECTED = 0x00040001;
    public static final int GLFW_DISCONNECTED = 0x00040002;
    public static final int GLFW_JOYSTICK_HAT_BUTTONS = 0x00050001;
    public static final int GLFW_ANGLE_PLATFORM_TYPE = 0x00050002;
    public static final int GLFW_PLATFORM = 0x00050003;
    public static final int GLFW_COCOA_CHDIR_RESOURCES = 0x00051001;
    public static final int GLFW_COCOA_MENUBAR = 0x00051002;
    public static final int GLFW_X11_XCB_VULKAN_SURFACE = 0x00052001;
    public static final int GLFW_WAYLAND_LIBDECOR = 0x00053001;
    public static final int GLFW_ANY_PLATFORM = 0x00060000;
    public static final int GLFW_PLATFORM_WIN32 = 0x00060001;
    public static final int GLFW_PLATFORM_COCOA = 0x00060002;
    public static final int GLFW_PLATFORM_WAYLAND = 0x00060003;
    public static final int GLFW_PLATFORM_X11 = 0x00060004;
    public static final int GLFW_PLATFORM_NULL = 0x00060005;
    public static final int GLFW_DONT_CARE = -1;
    public static final int GLFW_UNLIMITED_MOUSE_BUTTONS = 208902;
    public static final int GLFW_IME = 208903;
    public static final int GLFW_MANAGE_PREEDIT_CANDIDATE = 327684;
    public static final int GLFW_SOFT_FULLSCREEN = 131088;
    public static final int GLFW_X11_ONTHESPOT = 335874;

    // ======================= 内部状态 =======================
    private static boolean initialized;
    private static int lastError;
    private static final Map<Long, Window> WINDOWS = new ConcurrentHashMap<Long, Window>();
    private static final Map<Integer, Integer> WINDOW_HINTS = new HashMap<Integer, Integer>();
    private static long nextWindowId = 0x1000L;
    private static long currentContext;
    private static double timeOrigin = System.nanoTime() / 1.0e9;
    private static double timeOffset;
    private static String clipboard = "";
    private static final Object[] CB_ERROR = new Object[1];

    // 显示器：iOS 只有一个主显示器，用固定句柄表示（对齐「Java 假对象」做法）。
    private static final long MONITOR_PRIMARY = 0xA0000000L;

    // 引擎侧最小 native（阶段 1 仅这 11 个符号；窗口/上下文/事件循环）
    private static native boolean nInit();
    private static native void nTerminate();
    private static native boolean nCreateWindow(long window, int width, int height, String title);
    private static native void nDestroyWindow(long window);
    private static native void nMakeContextCurrent(long window);
    private static native void nSwapBuffers(long window);
    private static native void nSwapInterval(int interval);
    private static native void nPollEvents();
    private static native void nWaitEvents();
    private static native void nWaitEventsTimeout(double timeout);
    private static native void nPostEmptyEvent();

    /** 每个窗口的 Java 侧状态（native 侧后续经回调桥回写；阶段 1 由本类维护）。 */
    static final class Window {
        final long handle;
        int width, height, fbWidth, fbHeight, xpos, ypos;
        String title;
        boolean shouldClose, visible = true, focused = true;
        float scaleX = 1.0f, scaleY = 1.0f;
        double cursorX, cursorY;
        long cursor;
        final Map<Integer, Integer> inputModes = new HashMap<Integer, Integer>();
        final Map<Integer, Integer> attribs = new HashMap<Integer, Integer>();
        final Map<Integer, Integer> keys = new HashMap<Integer, Integer>();
        final Map<Integer, Integer> buttons = new HashMap<Integer, Integer>();
        final Object[] cbKey = new Object[1];
        final Object[] cbChar = new Object[1];
        final Object[] cbCharMods = new Object[1];
        final Object[] cbMouseButton = new Object[1];
        final Object[] cbScroll = new Object[1];
        final Object[] cbCursorPos = new Object[1];
        final Object[] cbCursorEnter = new Object[1];
        final Object[] cbFramebufferSize = new Object[1];
        final Object[] cbWindowSize = new Object[1];
        final Object[] cbWindowPos = new Object[1];
        final Object[] cbWindowFocus = new Object[1];
        final Object[] cbWindowRefresh = new Object[1];
        final Object[] cbWindowClose = new Object[1];
        final Object[] cbWindowIconify = new Object[1];
        final Object[] cbWindowMaximize = new Object[1];
        final Object[] cbWindowContentScale = new Object[1];
        final Object[] cbDrop = new Object[1];
        final Object[] cbPreedit = new Object[1];
        final Object[] cbImeStatus = new Object[1];
        final Object[] cbPreeditCandidate = new Object[1];

        Window(long handle, int width, int height, String title) {
            this.handle = handle;
            this.width = width;
            this.height = height;
            this.fbWidth = width;
            this.fbHeight = height;
            this.title = title;
        }
    }

    @SuppressWarnings("unchecked")
    private static <T> T swap(Object[] slot, Object value) {
        T prev = (T) slot[0];
        slot[0] = value;
        return prev;
    }

    static Window state(long window) {
        return WINDOWS.get(window);
    }

    // ======================= 初始化 / 版本 / 错误 =======================
    public static boolean glfwInit() {
        if (initialized) {
            return true;
        }
        boolean ok = nInit();
        initialized = ok;
        return ok;
    }

    public static void glfwTerminate() {
        nTerminate();
        WINDOWS.clear();
        currentContext = 0L;
        initialized = false;
    }

    public static void glfwGetVersion(int[] major, int[] minor, int[] rev) {
        if (major != null && major.length > 0) major[0] = GLFW_VERSION_MAJOR;
        if (minor != null && minor.length > 0) minor[0] = GLFW_VERSION_MINOR;
        if (rev != null && rev.length > 0) rev[0] = GLFW_VERSION_REVISION;
    }

    public static String glfwGetVersionString() {
        return "3.4.0 Air2-ownglfw";
    }

    public static int glfwGetError(PointerBuffer description) {
        if (description != null && description.remaining() > 0) {
            description.put(0, 0L);
        }
        int err = lastError;
        lastError = GLFW_NO_ERROR;
        return err;
    }

    public static GLFWErrorCallback glfwSetErrorCallback(GLFWErrorCallbackI cbfun) {
        return swap(CB_ERROR, cbfun);
    }

    public static int glfwGetPlatform() {
        return GLFW_PLATFORM_NULL;
    }

    public static boolean glfwPlatformSupported(int platform) {
        return platform == GLFW_PLATFORM_NULL;
    }

    // ======================= 窗口提示 / 创建 / 生命周期 =======================
    public static void glfwDefaultWindowHints() {
        WINDOW_HINTS.clear();
    }

    public static void glfwWindowHint(int hint, int value) {
        WINDOW_HINTS.put(Integer.valueOf(hint), Integer.valueOf(value));
    }

    public static long glfwCreateWindow(int width, int height, CharSequence title, long monitor, long share) {
        if (!initialized) {
            lastError = GLFW_NOT_INITIALIZED;
            return 0L;
        }
        String t = title == null ? "" : title.toString();
        long handle = nextWindowId++;
        if (!nCreateWindow(handle, width, height, t)) {
            lastError = GLFW_PLATFORM_ERROR;
            return 0L;
        }
        Window w = new Window(handle, width, height, t);
        WINDOWS.put(Long.valueOf(handle), w);
        return handle;
    }

    public static void glfwDestroyWindow(long window) {
        if (!WINDOWS.containsKey(Long.valueOf(window))) {
            return;
        }
        nDestroyWindow(window);
        WINDOWS.remove(Long.valueOf(window));
        if (currentContext == window) {
            currentContext = 0L;
        }
    }

    public static boolean glfwWindowShouldClose(long window) {
        Window w = state(window);
        return w != null && w.shouldClose;
    }

    public static void glfwSetWindowShouldClose(long window, boolean value) {
        Window w = state(window);
        if (w != null) {
            w.shouldClose = value;
        }
    }

    public static void glfwSetWindowTitle(long window, CharSequence title) {
        Window w = state(window);
        if (w != null) {
            w.title = title == null ? "" : title.toString();
        }
    }

    public static void glfwShowWindow(long window) {
        Window w = state(window);
        if (w != null) {
            w.visible = true;
        }
    }

    // ======================= 几何 / 属性 =======================
    public static void glfwGetFramebufferSize(long window, IntBuffer width, IntBuffer height) {
        Window w = state(window);
        if (w == null) return;
        if (width != null && width.remaining() > 0) width.put(0, w.fbWidth);
        if (height != null && height.remaining() > 0) height.put(0, w.fbHeight);
    }

    public static void glfwGetWindowSize(long window, IntBuffer width, IntBuffer height) {
        Window w = state(window);
        if (w == null) return;
        if (width != null && width.remaining() > 0) width.put(0, w.width);
        if (height != null && height.remaining() > 0) height.put(0, w.height);
    }

    public static void glfwGetWindowPos(long window, IntBuffer xpos, IntBuffer ypos) {
        Window w = state(window);
        if (w == null) return;
        if (xpos != null && xpos.remaining() > 0) xpos.put(0, w.xpos);
        if (ypos != null && ypos.remaining() > 0) ypos.put(0, w.ypos);
    }

    public static void glfwSetWindowSize(long window, int width, int height) {
        Window w = state(window);
        if (w == null) return;
        w.width = width;
        w.height = height;
        w.fbWidth = (int) (width * w.scaleX);
        w.fbHeight = (int) (height * w.scaleY);
    }

    public static int glfwGetWindowAttrib(long window, int attrib) {
        Window w = state(window);
        if (w == null) {
            return 0;
        }
        switch (attrib) {
            case GLFW_VISIBLE: return w.visible ? GLFW_TRUE : GLFW_FALSE;
            case GLFW_FOCUSED: return w.focused ? GLFW_TRUE : GLFW_FALSE;
            case GLFW_CLIENT_API: return GLFW_OPENGL_API;
            default:
                Integer v = w.attribs.get(Integer.valueOf(attrib));
                return v == null ? GLFW_FALSE : v.intValue();
        }
    }

    public static void glfwSetWindowAttrib(long window, int attrib, int value) {
        Window w = state(window);
        if (w != null) {
            w.attribs.put(Integer.valueOf(attrib), Integer.valueOf(value));
        }
    }

    public static void glfwGetWindowContentScale(long window, FloatBuffer xscale, FloatBuffer yscale) {
        Window w = state(window);
        if (w == null) return;
        if (xscale != null && xscale.remaining() > 0) xscale.put(0, w.scaleX);
        if (yscale != null && yscale.remaining() > 0) yscale.put(0, w.scaleY);
    }

    // ======================= 事件循环 =======================
    public static void glfwPollEvents() {
        nPollEvents();
    }

    public static void glfwWaitEvents() {
        nWaitEvents();
    }

    public static void glfwWaitEventsTimeout(double timeout) {
        nWaitEventsTimeout(timeout);
    }

    public static void glfwPostEmptyEvent() {
        nPostEmptyEvent();
    }

    // ======================= 输入模式 =======================
    public static int glfwGetInputMode(long window, int mode) {
        Window w = state(window);
        if (w == null) return 0;
        Integer v = w.inputModes.get(Integer.valueOf(mode));
        if (v != null) return v.intValue();
        if (mode == GLFW_IME) return GLFW_FALSE;
        return GLFW_FALSE;
    }

    public static void glfwSetInputMode(long window, int mode, int value) {
        Window w = state(window);
        if (w != null) {
            w.inputModes.put(Integer.valueOf(mode), Integer.valueOf(value));
        }
    }

    // ======================= 键 / 鼠标 状态查询 =======================
    public static int glfwGetKey(long window, int key) {
        Window w = state(window);
        if (w == null) return GLFW_RELEASE;
        Integer v = w.keys.get(Integer.valueOf(key));
        return v == null ? GLFW_RELEASE : v.intValue();
    }

    public static int glfwGetMouseButton(long window, int button) {
        Window w = state(window);
        if (w == null) return GLFW_RELEASE;
        Integer v = w.buttons.get(Integer.valueOf(button));
        return v == null ? GLFW_RELEASE : v.intValue();
    }

    public static void glfwGetCursorPos(long window, DoubleBuffer xpos, DoubleBuffer ypos) {
        Window w = state(window);
        if (w == null) return;
        if (xpos != null && xpos.remaining() > 0) xpos.put(0, w.cursorX);
        if (ypos != null && ypos.remaining() > 0) ypos.put(0, w.cursorY);
    }

    public static void glfwSetCursorPos(long window, double xpos, double ypos) {
        Window w = state(window);
        if (w != null) {
            w.cursorX = xpos;
            w.cursorY = ypos;
        }
    }

    public static String glfwGetKeyName(int key, int scancode) {
        // 阶段 1：不维护布局表；官方语义允许对无名字的键返回 null。
        return null;
    }

    public static int glfwGetKeyScancode(int key) {
        return key;
    }

    public static boolean glfwRawMouseMotionSupported() {
        return false;
    }

    // ======================= 回调注册（20 窗口回调 + 3 IME 回调） =======================
    public static GLFWKeyCallback glfwSetKeyCallback(long window, GLFWKeyCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWKeyCallback>swap(w.cbKey, cbfun);
    }

    public static GLFWCharCallback glfwSetCharCallback(long window, GLFWCharCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWCharCallback>swap(w.cbChar, cbfun);
    }

    public static GLFWCharModsCallback glfwSetCharModsCallback(long window, GLFWCharModsCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWCharModsCallback>swap(w.cbCharMods, cbfun);
    }

    public static GLFWMouseButtonCallback glfwSetMouseButtonCallback(long window, GLFWMouseButtonCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWMouseButtonCallback>swap(w.cbMouseButton, cbfun);
    }

    public static GLFWScrollCallback glfwSetScrollCallback(long window, GLFWScrollCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWScrollCallback>swap(w.cbScroll, cbfun);
    }

    public static GLFWCursorPosCallback glfwSetCursorPosCallback(long window, GLFWCursorPosCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWCursorPosCallback>swap(w.cbCursorPos, cbfun);
    }

    public static GLFWCursorEnterCallback glfwSetCursorEnterCallback(long window, GLFWCursorEnterCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWCursorEnterCallback>swap(w.cbCursorEnter, cbfun);
    }

    public static GLFWFramebufferSizeCallback glfwSetFramebufferSizeCallback(long window, GLFWFramebufferSizeCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWFramebufferSizeCallback>swap(w.cbFramebufferSize, cbfun);
    }

    public static GLFWWindowSizeCallback glfwSetWindowSizeCallback(long window, GLFWWindowSizeCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWWindowSizeCallback>swap(w.cbWindowSize, cbfun);
    }

    public static GLFWWindowPosCallback glfwSetWindowPosCallback(long window, GLFWWindowPosCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWWindowPosCallback>swap(w.cbWindowPos, cbfun);
    }

    public static GLFWWindowFocusCallback glfwSetWindowFocusCallback(long window, GLFWWindowFocusCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWWindowFocusCallback>swap(w.cbWindowFocus, cbfun);
    }

    public static GLFWWindowRefreshCallback glfwSetWindowRefreshCallback(long window, GLFWWindowRefreshCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWWindowRefreshCallback>swap(w.cbWindowRefresh, cbfun);
    }

    public static GLFWWindowCloseCallback glfwSetWindowCloseCallback(long window, GLFWWindowCloseCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWWindowCloseCallback>swap(w.cbWindowClose, cbfun);
    }

    public static GLFWWindowIconifyCallback glfwSetWindowIconifyCallback(long window, GLFWWindowIconifyCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWWindowIconifyCallback>swap(w.cbWindowIconify, cbfun);
    }

    public static GLFWWindowMaximizeCallback glfwSetWindowMaximizeCallback(long window, GLFWWindowMaximizeCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWWindowMaximizeCallback>swap(w.cbWindowMaximize, cbfun);
    }

    public static GLFWWindowContentScaleCallback glfwSetWindowContentScaleCallback(long window, GLFWWindowContentScaleCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWWindowContentScaleCallback>swap(w.cbWindowContentScale, cbfun);
    }

    public static GLFWDropCallback glfwSetDropCallback(long window, GLFWDropCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWDropCallback>swap(w.cbDrop, cbfun);
    }

    public static GLFWPreeditCallback glfwSetPreeditCallback(long window, GLFWPreeditCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWPreeditCallback>swap(w.cbPreedit, cbfun);
    }

    public static GLFWIMEStatusCallback glfwSetIMEStatusCallback(long window, GLFWIMEStatusCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWIMEStatusCallback>swap(w.cbImeStatus, cbfun);
    }

    public static GLFWPreeditCandidateCallback glfwSetPreeditCandidateCallback(long window, GLFWPreeditCandidateCallbackI cbfun) {
        Window w = state(window);
        return w == null ? null : GLFW.<GLFWPreeditCandidateCallback>swap(w.cbPreeditCandidate, cbfun);
    }

    // ======================= 时间 =======================
    public static double glfwGetTime() {
        return System.nanoTime() / 1.0e9 - timeOrigin + timeOffset;
    }

    public static void glfwSetTime(double time) {
        timeOffset = time - (System.nanoTime() / 1.0e9 - timeOrigin);
    }

    public static long glfwGetTimerValue() {
        return System.nanoTime();
    }

    public static long glfwGetTimerFrequency() {
        return 1000000000L;
    }

    // ======================= 显示器 =======================
    public static long glfwGetPrimaryMonitor() {
        return MONITOR_PRIMARY;
    }

    public static PointerBuffer glfwGetMonitors() {
        PointerBuffer buf = MemoryUtil.memAllocPointer(1);
        buf.put(0, MONITOR_PRIMARY);
        buf.limit(1);
        return buf;
    }

    public static String glfwGetMonitorName(long monitor) {
        return "Air2 Display";
    }

    public static GLFWVidMode glfwGetVideoMode(long monitor) {
        Window w = null;
        for (Window candidate : WINDOWS.values()) {
            w = candidate;
            break;
        }
        int width = w != null ? w.width : 1920;
        int height = w != null ? w.height : 1080;
        long mem = MemoryUtil.nmemAlloc(GLFWVidMode.SIZEOF);
        MemoryUtil.memPutInt(mem + GLFWVidMode.WIDTH, width);
        MemoryUtil.memPutInt(mem + GLFWVidMode.HEIGHT, height);
        MemoryUtil.memPutInt(mem + GLFWVidMode.REDBITS, 8);
        MemoryUtil.memPutInt(mem + GLFWVidMode.GREENBITS, 8);
        MemoryUtil.memPutInt(mem + GLFWVidMode.BLUEBITS, 8);
        MemoryUtil.memPutInt(mem + GLFWVidMode.REFRESHRATE, 60);
        return GLFWVidMode.create(mem);
    }

    // ======================= 剪贴板 =======================
    public static String glfwGetClipboardString(long window) {
        return clipboard;
    }

    public static void glfwSetClipboardString(long window, CharSequence string) {
        clipboard = string == null ? "" : string.toString();
    }

    public static void glfwSetClipboardString(long window, ByteBuffer string) {
        clipboard = string == null ? "" : StandardCharsets.UTF_8.decode(string.duplicate()).toString();
    }

    // ======================= 上下文 / 呈现 =======================
    public static void glfwMakeContextCurrent(long window) {
        nMakeContextCurrent(window);
        currentContext = window;
    }

    public static long glfwGetCurrentContext() {
        return currentContext;
    }

    public static void glfwSwapBuffers(long window) {
        nSwapBuffers(window);
    }

    public static void glfwSwapInterval(int interval) {
        nSwapInterval(interval);
    }

    public static boolean glfwExtensionSupported(CharSequence extension) {
        return false;
    }

    public static long glfwGetProcAddress(CharSequence procname) {
        return 0L;
    }

    // ======================= 光标 =======================
    public static long glfwCreateStandardCursor(int shape) {
        return 0xC0000000L | (shape & 0xFFFF);
    }

    public static void glfwDestroyCursor(long cursor) {
        // 阶段 1：句柄无底层资源，空实现。
    }

    public static void glfwSetCursor(long window, long cursor) {
        Window w = state(window);
        if (w != null) {
            w.cursor = cursor;
        }
    }
}
