// ============================================================================
//  Natives/Input/a2_glfw_window.h
//  Air2 —— 自研 GLFW 窗口/事件层（阶段 A）· 中立公共接口
// ----------------------------------------------------------------------------
//  归属决策（docs/ARCHITECTURE.md §Natives）：
//    `Input/` = 「触摸、键盘、鼠标、手柄、陀螺仪的事件注入」。
//    本文件正是这一层的对外面：窗口生命周期 + 事件总线 + 中立表面描述。
//
//  ★与渲染器解耦（本层的硬约束）★
//    · 本层【不认识任何图形 API】：源码里不出现任何图形后端的专有名 / 后端头文件
//      （机器判据见 scripts/verify_ownglfw_native.py），只做窗口记录、事件与输入。
//    · 对渲染器只暴露一个【中立表面描述】（A2GlfwSurface）：原生视图句柄、
//      宿主窗口句柄、点/像素尺寸、内容缩放、像素格式编号。
//      渲染器自己决定往这个 UIView 上挂什么 layer、用什么上下文。
//    · 因此「换渲染后端」不需要改本层一行。
//
//  净室声明：本文件与同名 .m 由 Air2 自研线独立编写（[A2-OWNGLFW-NATIVE-1]），
//    未参考、未复制 Pojav / Boardwalk / Amethyst / LWJGL 的 native 源码；
//    仅依据 GLFW 官方公开行为约定（窗口/输入语义、GLFW_PRESS/RELEASE 数值）
//    与 Apple 公开的 UIKit 文档。常量值即官方 glfw3.h 的事实性数值。
//
//  许可证：归 Air2 项目本人；无 GPL 血缘。
// ============================================================================
#ifndef A2_GLFW_WINDOW_H
#define A2_GLFW_WINDOW_H

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// GLFW 动作常量（官方 glfw3.h 的事实性数值；本层只用这三个）
// ---------------------------------------------------------------------------
enum {
    A2_GLFW_RELEASE = 0,
    A2_GLFW_PRESS   = 1,
    A2_GLFW_REPEAT  = 2,
};

// ---------------------------------------------------------------------------
// 中立「宿主表面」描述 —— ★渲染器解耦的唯一交接面★
// ---------------------------------------------------------------------------
// 本层不承诺任何具体像素格式：`pixelFormat` 只给一个中立编号，渲染器可忽略它、
// 按自己的后端决定。字段存在的意义是让渲染器**只靠这一份
// 结构**就能接上，而不必知道本层的任何内部类型。
typedef enum {
    A2_GLFW_PIXEL_FORMAT_HOST_DEFAULT = 0,  // 宿主视图默认（本层不指定具体后端）
} A2GlfwPixelFormat;

typedef struct A2GlfwSurface {
    void  *nativeView;    // iOS 上为 UIView*（本层创建并持有；渲染器只读不改所有权）
    void  *nativeWindow;  // iOS 上为 UIWindow*（宿主）
    int    widthPoints;   // 逻辑宽（点）
    int    heightPoints;  // 逻辑高（点）
    int    widthPixels;   // 帧缓冲宽（像素）
    int    heightPixels;  // 帧缓冲高（像素）
    float  contentScaleX; // 内容缩放 X（Retina 常见 2.0 / 3.0）
    float  contentScaleY; // 内容缩放 Y
    int    pixelFormat;   // A2GlfwPixelFormat（中立编号）
} A2GlfwSurface;

// ---------------------------------------------------------------------------
// 事件 —— GLFW 语义，与具体渲染器无关
// ---------------------------------------------------------------------------
// 事件由本层的平台观察者（尺寸/旋转/焦点）与输入层（触摸/按键）投递进队列，
// 由 a2_glfw_event_pump() 在**调用线程**（= Java 侧 glfwPollEvents 所在线程）上
// 逐个回调 sink。因此 sink 内部做 JNI upcall 是安全的（同线程）。
typedef enum {
    A2_GLFW_EVENT_NONE = 0,

    // 光标位置：d0=x, d1=y（相对视图左上角，单位=逻辑点，对齐 GLFW 语义）
    A2_GLFW_EVENT_CURSOR_POS = 1,
    // 鼠标/触摸按键：i0=button(GLFW_MOUSE_BUTTON_*), i1=action(PRESS/RELEASE), i2=mods
    A2_GLFW_EVENT_MOUSE_BUTTON = 2,
    // 键盘按键：i0=key(GLFW_KEY_*), i1=scancode, i2=action(PRESS/RELEASE/REPEAT), i3=mods
    A2_GLFW_EVENT_KEY = 3,
    // 帧缓冲尺寸：i0=w(像素), i1=h(像素)
    A2_GLFW_EVENT_FRAMEBUFFER_SIZE = 4,
    // 窗口尺寸：i0=w(点), i1=h(点)
    A2_GLFW_EVENT_WINDOW_SIZE = 5,
    // 窗口焦点：i0=1(获得)/0(失去)
    A2_GLFW_EVENT_WINDOW_FOCUS = 6,
    // 内容缩放：d0=xscale, d1=yscale
    A2_GLFW_EVENT_CONTENT_SCALE = 7,
    // 光标进入/离开：i0=1(进入)/0(离开)
    A2_GLFW_EVENT_CURSOR_ENTER = 8,
    // 文本输入（字符）：i0=Unicode 码点, i1=mods
    // 投递点：a2_glfw_input.m 的 -pressesBegan:withEvent:（外接键盘 UIKey.characters）
    A2_GLFW_EVENT_CHAR = 9,
    // 滚动：d0=xoffset, d1=yoffset（GLFW 语义：y 正 = 向上/远离用户）
    // 投递点：a2_glfw_input.m 的 -a2_scroll:（间接输入：外接鼠标滚轮 / 触控板两指滚动）
    A2_GLFW_EVENT_SCROLL = 10,
} A2GlfwEventType;

typedef struct A2GlfwEvent {
    long   window;        // 窗口句柄（GLFW.java 侧 nextWindowId）
    int    type;          // A2GlfwEventType
    int    i0, i1, i2, i3; // 整数载荷（按 type 解释；未用置 0）
    double d0, d1;        // 浮点载荷（按 type 解释；未用置 0）
} A2GlfwEvent;

// 事件下沉回调。由 JNI 薄层注册（Natives/OwnGlfw/a2_own_glfw_bridge.m），
// 在 pump 线程上被逐个调用。
typedef void (*A2GlfwEventSinkFn)(const A2GlfwEvent *event, void *user);

// ---------------------------------------------------------------------------
// 事件总线
// ---------------------------------------------------------------------------
// 调用点：全部在 Natives/OwnGlfw/a2_own_glfw_bridge.m 的 11 个 JNI 符号体内。
void a2_glfw_event_set_sink(A2GlfwEventSinkFn sink, void *user);  // <- nInit
void a2_glfw_event_pump(void);                                   // <- nPollEvents
void a2_glfw_event_wait(void);                                   // <- nWaitEvents
void a2_glfw_event_wait_timeout(double seconds);                 // <- nWaitEventsTimeout
void a2_glfw_event_post_empty(void);                             // <- nPostEmptyEvent

// 投递一条事件（线程安全）。调用点：本层内部各平台观察者/输入处理。
void a2_glfw_event_post(const A2GlfwEvent *event);

// ---------------------------------------------------------------------------
// 窗口生命周期
// ---------------------------------------------------------------------------
// 调用点：Natives/OwnGlfw/a2_own_glfw_bridge.m 的 nInit / nTerminate /
//          nCreateWindow / nDestroyWindow。
int  a2_glfw_window_platform_init(void);
void a2_glfw_window_platform_terminate(void);
int  a2_glfw_window_create(long window, int width, int height, const char *title);
void a2_glfw_window_destroy(long window);

// 中立查询面 —— 本层内部（窗口就绪日志）与渲染器共用（本层不认识任何图形 API）。
// 调用点：a2_glfw_window.m 的「窗口就绪」分支（a2_glfw_window_surface / is_focused），
//         以及未来渲染器的交接（surface）。尺寸/缩放全部经 surface 描述带回，
//         本层不另设一批「没人调」的单字段 getter（石山纪律）。
int   a2_glfw_window_is_focused(long window);
int   a2_glfw_window_surface(long window, A2GlfwSurface *out);

/// ★游戏宿主视图的稳定访问（不需要窗口句柄）★ —— 返回**最近创建**的窗口的宿主视图
/// （iOS 上为 UIView*；所有权归本层，调用方只读不改）。
///
/// ★为什么需要它★ 渲染桥（`Natives/Renderer/a2_gl_bridge.m`）只认表面、不认识 GLFW 窗口句柄：
///   它在 JVM 启动前附着到启动器根视图，而游戏页是本层稍后建出的全屏宿主视图 —— 桥要在
///   「首次 make_current」时把自己的 surface 改挂到这张视图上，就必须能不带句柄拿到它。
///   与 `a2_glfw_window_surface()` 给的是同一个 `hostView`（同一份状态，不另存一份）。
///
/// ★调用点★ `Natives/Renderer/a2_gl_bridge.m` 的 `a2_gl_bridge_ensure_game_view_surface`
///   （attach 之后第一次 make_current；以及其后的重试），以及本层测试。
/// 无就绪窗口（视图尚未在主队列建出）时返回 NULL。
void *a2_glfw_window_game_view(void);

/// JVM 创建方回填 JavaVM（发布 UIView 地址给 metallum 时要用）。
void  a2_glfw_window_set_java_vm(void *vm);

#ifdef __cplusplus
}
#endif
#endif /* A2_GLFW_WINDOW_H */
