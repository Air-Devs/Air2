// ============================================================================
//  Natives/Input/a2_glfw_window.m
//  Air2 —— 自研 GLFW 窗口/事件层（阶段 A）· 实现
// ----------------------------------------------------------------------------
//  分层（docs/ARCHITECTURE.md §Natives）：`Input/` = 事件注入。
//  本文件承担：窗口记录 + 事件总线 + 尺寸/旋转/焦点观察。
//  触摸/按键的翻译在 a2_glfw_input.m。
//
//  ★渲染器解耦（本层硬约束）★
//    本文件不 include 任何图形后端头，源码里不出现任何后端专有名（机器判据见
//    scripts/verify_ownglfw_native.py）。渲染器要接进来时，只用 a2_glfw_window_surface() 拿到
//    A2GlfwSurface（原生视图句柄 + 尺寸 + 缩放），自己决定挂什么 layer；
//    需要「不带窗口句柄」拿到游戏宿主视图时用 a2_glfw_window_game_view()（GL 桥首次
//    make_current 改绑表面用的就是它）。
//
//  ★线程模型（关键，写在最前）★
//    · MC 从 **Java 线程**调用 glfwCreateWindow / glfwPollEvents；
//      iOS 的 UIKit 必须在 **主线程**。
//    · 因此：窗口「记录」在调用线程同步建好（这样 create 立即有尺寸可查）；
//      真正的 UIWindow/UIView 及观察者注册 **异步派发到主队列**，就绪后回填
//      尺寸/缩放并投递一次 WINDOW_SIZE / FRAMEBUFFER_SIZE / CONTENT_SCALE。
//    · 事件只在 a2_glfw_event_pump()（Java 线程）上被 sink 消费 ⇒ JNI upcall 同线程安全。
//
//  ★锁序（避免死锁）★
//    · gEventLock 与 gWindowLock 是两把独立的锁。
//    · 规则：**持 gWindowLock 时绝不调用 a2_glfw_event_post()**（先取值、解锁、再投递）。
//      这样 pump 线程（gEventLock → sink → gWindowLock）与主线程不会构成环。
//
//  净室：独立编写，未参考 Pojav / Boardwalk / Amethyst / LWJGL 源码。
// ============================================================================
#import "a2_glfw_window.h"
#import "A2GameControlsView.h"
#import "a2_glfw_input.h"
#import "a2_glfw_trace.h"
#import "a2_log.h"

#import <UIKit/UIKit.h>
#include <jni.h>
#include <dlfcn.h>
#import <pthread.h>
#import <time.h>
#import <math.h>
#import <string.h>

#define A2_GLFW_MAX_WINDOWS     16
#define A2_GLFW_EVENT_CAPACITY  4096

// ============================================================================
//  事件总线
// ============================================================================
static pthread_mutex_t   gEventLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t    gEventCond = PTHREAD_COND_INITIALIZER;
static A2GlfwEvent       gEventQueue[A2_GLFW_EVENT_CAPACITY];
static int               gEventHead  = 0;   // 下一个出队下标
static int               gEventCount = 0;   // 当前条数
static A2GlfwEventSinkFn gEventSink  = NULL;
static void             *gEventSinkUser = NULL;
static int               gEmptyEventPending = 0;
static int               gEventOverflowLogged = 0;

void a2_glfw_event_set_sink(A2GlfwEventSinkFn sink, void *user) {
    pthread_mutex_lock(&gEventLock);
    gEventSink = sink;
    gEventSinkUser = user;
    pthread_mutex_unlock(&gEventLock);
}

void a2_glfw_event_post(const A2GlfwEvent *event) {
    if (event == NULL) {
        return;
    }
    pthread_mutex_lock(&gEventLock);
    if (gEventCount >= A2_GLFW_EVENT_CAPACITY) {
        // 队列满：丢**新**事件（保留已积压的，避免状态倒序）；只提示一次。
        if (!gEventOverflowLogged) {
            gEventOverflowLogged = 1;
            pthread_mutex_unlock(&gEventLock);
            a2_log_f(@"[A2-GLFW] 事件队列溢出（cap=%d），已丢弃后续事件直到排空",
                     A2_GLFW_EVENT_CAPACITY);
            return;
        }
        pthread_mutex_unlock(&gEventLock);
        return;
    }
    gEventQueue[(gEventHead + gEventCount) % A2_GLFW_EVENT_CAPACITY] = *event;
    gEventCount++;
    pthread_cond_signal(&gEventCond);
    pthread_mutex_unlock(&gEventLock);
}

// 取出一条（持锁调用）。成功返回 1。
static int a2_glfw_event_pop_locked(A2GlfwEvent *out) {
    if (gEventCount == 0) {
        return 0;
    }
    *out = gEventQueue[gEventHead];
    gEventHead = (gEventHead + 1) % A2_GLFW_EVENT_CAPACITY;
    gEventCount--;
    return 1;
}

void a2_glfw_event_pump(void) {
    for (;;) {
        A2GlfwEvent ev;
        A2GlfwEventSinkFn sink = NULL;
        void *user = NULL;

        pthread_mutex_lock(&gEventLock);
        if (!a2_glfw_event_pop_locked(&ev)) {
            gEventOverflowLogged = 0;
            pthread_mutex_unlock(&gEventLock);
            break;
        }
        sink = gEventSink;
        user = gEventSinkUser;
        pthread_mutex_unlock(&gEventLock);   // ★解锁后再回调：sink 可安全取 gWindowLock

        if (sink != NULL) {
            sink(&ev, user);
        }
    }
}

void a2_glfw_event_wait(void) {
    pthread_mutex_lock(&gEventLock);
    while (gEventCount == 0 && !gEmptyEventPending) {
        pthread_cond_wait(&gEventCond, &gEventLock);
    }
    gEmptyEventPending = 0;
    pthread_mutex_unlock(&gEventLock);
    a2_glfw_event_pump();
}

void a2_glfw_event_wait_timeout(double seconds) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec  += (time_t) seconds;
    ts.tv_nsec += (long) ((seconds - (double) (time_t) seconds) * 1e9);
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec  += 1;
        ts.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&gEventLock);
    while (gEventCount == 0 && !gEmptyEventPending) {
        if (pthread_cond_timedwait(&gEventCond, &gEventLock, &ts) != 0) {
            break;   // 超时（或错误）：按 GLFW 语义到点即返
        }
    }
    gEmptyEventPending = 0;
    pthread_mutex_unlock(&gEventLock);
    a2_glfw_event_pump();
}

void a2_glfw_event_post_empty(void) {
    pthread_mutex_lock(&gEventLock);
    gEmptyEventPending = 1;
    pthread_cond_broadcast(&gEventCond);
    pthread_mutex_unlock(&gEventLock);
}

// ============================================================================
//  窗口记录
// ============================================================================
// 用 ObjC 宿主对象持有强引用（ARC 下 C 结构体里的裸指针不会 retain UIWindow/UIView）。
// 标量缓存字段在 gWindowLock 下读写；pump 线程只读标量。
@interface A2GlfwHost : NSObject
@property (nonatomic, assign) long      handle;
@property (nonatomic, strong) UIWindow *hostWindow;
@property (nonatomic, strong) UIViewController *gameViewController;   // 整屏游戏页（防释放）
@property (nonatomic, strong) UIView   *hostView;
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, assign) int       widthPoints;
@property (nonatomic, assign) int       heightPoints;
@property (nonatomic, assign) int       widthPixels;
@property (nonatomic, assign) int       heightPixels;
@property (nonatomic, assign) float     scaleX;
@property (nonatomic, assign) float     scaleY;
@property (nonatomic, assign) BOOL      focused;
@property (nonatomic, assign) BOOL      uikitReady;
@end

@implementation A2GlfwHost
@end

static NSMutableArray<A2GlfwHost *> *gHosts = nil;
static pthread_mutex_t gWindowLock = PTHREAD_MUTEX_INITIALIZER;
static int gPlatformInitialized = 0;

// 持 gWindowLock 调用。
static A2GlfwHost *a2_glfw_host_locked(long handle) {
    for (A2GlfwHost *h in gHosts) {
        if (h.handle == handle) {
            return h;
        }
    }
    return nil;
}

// 不持锁调用：取一份尺寸快照（host 不存在时全部回 0，避免调用方拿到未初始化值）。
static void a2_glfw_host_snapshot(long handle, int *wp, int *hp, int *wpx, int *hpx,
                                  float *sx, float *sy, int *focused, int *ready) {
    if (wp)  *wp  = 0;
    if (hp)  *hp  = 0;
    if (wpx) *wpx = 0;
    if (hpx) *hpx = 0;
    if (sx)  *sx  = 0.0f;
    if (sy)  *sy  = 0.0f;
    if (focused) *focused = 0;
    if (ready)   *ready   = 0;
    pthread_mutex_lock(&gWindowLock);
    A2GlfwHost *h = a2_glfw_host_locked(handle);
    if (h != nil) {
        if (wp)  *wp  = h.widthPoints;
        if (hp)  *hp  = h.heightPoints;
        if (wpx) *wpx = h.widthPixels;
        if (hpx) *hpx = h.heightPixels;
        if (sx)  *sx  = h.scaleX;
        if (sy)  *sy  = h.scaleY;
        if (focused) *focused = h.focused ? 1 : 0;
        if (ready)   *ready   = h.uikitReady ? 1 : 0;
    }
    pthread_mutex_unlock(&gWindowLock);
}

// ---- 事件投递助手（★一律在锁外调用★）----
static void a2_glfw_emit_size(long handle, int wp, int hp, int wpx, int hpx) {
    // ★[A2-GLFW-TRACE]★ glfwGetFramebufferSize 在本仓【没有 native 入口】：两套 Java GLFW
    //   （JavaApp/src/{lwjgl,ownglfw}/org/lwjgl/glfw/GLFW.java）都直接用 Java 侧状态返回该值，
    //   而那份状态的值就产生在**这里**。⇒ 在「供值点」打 enter/exit（真实来源，不假装是每次调用），
    //   用于回答「MC 拿到的帧缓冲尺寸是多少、什么时候变成这个值的」。
    long long trT0 = a2_glfw_tr_us();
    unsigned long long trTid = a2_glfw_tr_tid();
    a2_log_f(@"[A2-GLFW-TRACE] enter glfwGetFramebufferSize tid=%llu window=%ld pts=%dx%d fb=%dx%d",
             trTid, handle, wp, hp, wpx, hpx);
    A2GlfwEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.window = handle;

    ev.type = A2_GLFW_EVENT_WINDOW_SIZE;
    ev.i0 = wp; ev.i1 = hp;
    a2_glfw_event_post(&ev);

    ev.type = A2_GLFW_EVENT_FRAMEBUFFER_SIZE;
    ev.i0 = wpx; ev.i1 = hpx;
    a2_glfw_event_post(&ev);

    a2_log_f(@"[A2-GLFW-TRACE] exit glfwGetFramebufferSize tid=%llu rc=1 ms=%lld fb=%dx%d",
             trTid, a2_glfw_tr_ms(trT0), wpx, hpx);
}

/// ★iPhone Duo / 分屏 / 折叠展开★ 宿主视图尺寸变了（不只是旋转）时重算并上报。
/// 调用点：A2GlfwView 的 layoutSubviews（bounds 变化即触发）。
/// 为什么不用旋转通知：Duo 展开/折叠、Split View 拖动都不会发 UIDeviceOrientationDidChange。

#pragma mark - iPhone Duo 形态模拟

/// 模拟配置（NSUserDefaults，UI 在 设置→诊断 里改）：
///   A2DuoSimMode        0=关闭 1=内屏整屏 2=内屏分屏(我们占一半) 3=折叠外屏
///   A2DuoSimOrientation 0=跟随 1=竖屏 2=横屏
static CGRect a2_duo_sim_target_rect(CGSize available) {
    NSInteger mode = [NSUserDefaults.standardUserDefaults integerForKey:@"A2DuoSimMode"];
    if (mode <= 0) return CGRectZero;
    NSInteger orient = [NSUserDefaults.standardUserDefaults integerForKey:@"A2DuoSimOrientation"];

    // 目标纵横比（宽/高）。Duo 内屏≈4:3；分屏占一半⇒2:3；折叠外屏≈9:19.5
    CGFloat aspect = 4.0 / 3.0;
    if (mode == 2) aspect = 2.0 / 3.0;
    if (mode == 3) aspect = 9.0 / 19.5;

    BOOL wantPortrait = (orient == 1);
    if (orient == 0) wantPortrait = (available.height > available.width);
    if (wantPortrait) aspect = 1.0 / aspect;      // 竖屏时取倒数

    CGFloat w = available.width;
    CGFloat h = w / aspect;
    if (h > available.height) {                   // 高度放不下 ⇒ 按高反推
        h = available.height;
        w = h * aspect;
    }
    return CGRectMake((available.width - w) * 0.5, (available.height - h) * 0.5, w, h);
}

/// 把宿主视图框成模拟形态（mode=0 时不动）。
static void a2_duo_sim_apply(long window) {
    pthread_mutex_lock(&gWindowLock);
    A2GlfwHost *h = a2_glfw_host_locked(window);
    UIView *view = h.hostView;
    UIView *root = view.superview;
    pthread_mutex_unlock(&gWindowLock);
    if (view == nil || root == nil) return;

    CGRect target = a2_duo_sim_target_rect(root.bounds.size);
    if (CGRectIsEmpty(target)) {
        view.frame = root.bounds;                 // 关闭模拟 ⇒ 还原整屏
        a2_log_f(@"[A2-DUO] 形态模拟=关（整屏）");
        return;
    }
    view.frame = target;
    a2_log_f(@"[A2-DUO] 形态模拟：mode=%ld orient=%ld ⇒ %.0f×%.0f（可用 %.0f×%.0f）",
             (long) [NSUserDefaults.standardUserDefaults integerForKey:@"A2DuoSimMode"],
             (long) [NSUserDefaults.standardUserDefaults integerForKey:@"A2DuoSimOrientation"],
             target.size.width, target.size.height,
             root.bounds.size.width, root.bounds.size.height);
}

void a2_glfw_window_handle_host_resize(long handle) {
    pthread_mutex_lock(&gWindowLock);
    A2GlfwHost *h = a2_glfw_host_locked(handle);
    UIView *view = h.hostView;
    pthread_mutex_unlock(&gWindowLock);
    if (view == nil) return;

    CGFloat scale = view.window.screen.scale > 0 ? view.window.screen.scale : 1.0;
    CGRect b = view.bounds;
    int wp = (int) lround(b.size.width);
    int hp = (int) lround(b.size.height);
    int wpx = (int) lround(b.size.width  * scale);
    int hpx = (int) lround(b.size.height * scale);
    if (wp <= 0 || hp <= 0) return;
    a2_glfw_emit_size(handle, wp, hp, wpx, hpx);
    a2_log_f(@"[A2-GLFW] 宿主尺寸变化 → %dx%d pt（%dx%d px，scale=%.2f）",
             wp, hp, wpx, hpx, scale);
}

static void a2_glfw_emit_scale(long handle, float sx, float sy) {
    A2GlfwEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.window = handle;
    ev.type = A2_GLFW_EVENT_CONTENT_SCALE;
    ev.d0 = (double) sx;
    ev.d1 = (double) sy;
    a2_glfw_event_post(&ev);
}

static void a2_glfw_emit_focus(long handle, int focused) {
    A2GlfwEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.window = handle;
    ev.type = A2_GLFW_EVENT_WINDOW_FOCUS;
    ev.i0 = focused;
    a2_glfw_event_post(&ev);
}

// ============================================================================
//  平台观察者（尺寸/旋转/焦点）—— 主线程回调
// ============================================================================
// 焦点批量更新（主线程）；前向声明必须在 A2GlfwObserverHub 之前（其方法要调它）。
static void a2_glfw_observer_focus(int focused);

@interface A2GlfwObserverHub : NSObject
- (void)a2_orientationChanged:(NSNotification *)note;
- (void)a2_didBecomeActive:(NSNotification *)note;
- (void)a2_willResignActive:(NSNotification *)note;
@end


static A2GlfwObserverHub *gObserverHub = nil;

@implementation A2GlfwObserverHub

// 尺寸/旋转：设备方向变化 ⇒ 全屏窗口 bounds 变化 ⇒ 重算并投递。
// 用 bounds（点）× contentScaleFactor（缩放）得像素，避免依赖具体屏幕 API。
- (void)a2_orientationChanged:(NSNotification *)note {
    (void) note;
    NSArray<A2GlfwHost *> *snapshot;
    pthread_mutex_lock(&gWindowLock);
    snapshot = [gHosts copy];
    pthread_mutex_unlock(&gWindowLock);

    for (A2GlfwHost *h in snapshot) {
        UIWindow *win = h.hostWindow;
        if (win == nil) {
            continue;
        }
        CGRect b = win.bounds;
        CGFloat scale = (win.screen != nil) ? win.screen.scale : 1.0;
        int wp = (int) lround(b.size.width);
        int hp = (int) lround(b.size.height);

        int wpx = (int) lround(b.size.width * scale);
        int hpx = (int) lround(b.size.height * scale);

        pthread_mutex_lock(&gWindowLock);
        A2GlfwHost *cur = a2_glfw_host_locked(h.handle);
        int changed = (cur != nil) &&
                      (cur.widthPoints != wp || cur.heightPoints != hp ||
                       cur.widthPixels != wpx || cur.heightPixels != hpx);
        if (cur != nil) {
            cur.widthPoints = wp;  cur.heightPoints = hp;
            cur.widthPixels = wpx; cur.heightPixels = hpx;
            cur.scaleX = (float) scale; cur.scaleY = (float) scale;
        }
        pthread_mutex_unlock(&gWindowLock);

        if (changed) {
            a2_glfw_emit_size(h.handle, wp, hp, wpx, hpx);
            a2_glfw_emit_scale(h.handle, (float) scale, (float) scale);
            a2_log_f(@"[A2-GLFW] 尺寸/旋转变化 window=%ld pts=%dx%d px=%dx%d scale=%.2f",
                     h.handle, wp, hp, wpx, hpx, (double) scale);
        }
    }
}

- (void)a2_didBecomeActive:(NSNotification *)note {
    (void) note;
    a2_glfw_observer_focus(1);
}

- (void)a2_willResignActive:(NSNotification *)note {
    (void) note;
    a2_glfw_observer_focus(0);
}

@end

// ★2026-10-18★ 把宿主 UIView 的地址发布成 JVM 系统属性。
//   来源：metallum 的 MetalBackend.readIOSSurfacePointer() 在 iOS 上**不读 GLFW**，
//   而是读 `metallum.ios.view.pointer` / `pojav.view.pointer`（十六进制地址），
//   都没有才调 metallum_ios_find_surface_view()（找 +[SurfaceViewController surface]，
//   我们类名不同 ⇒ 找不到）。不发布 ⇒ BackendCreationException ⇒ 黑屏。
//   时机：MC 调 glfwCreateWindow 之后、它创建 MetalBackend 之前（本函数就是那一刻）。
/// 由 JVM 创建方（a2_launch / a2_vmloader）回填的 JavaVM；窗口层只读。
/// ★为什么必须回填★ dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs") 在 libjvm
///   以局部作用域 dlopen 时取不到 ⇒ 发布 UIView 地址那段会静默 return，
///   真机表现为「没有 [A2-METAL] 日志 + 黑屏」。
static void *gA2JavaVM = NULL;

void a2_glfw_window_set_java_vm(void *vm) {
    gA2JavaVM = vm;
}

static void a2_publish_ios_view_pointer(void *view, double scale) {
    if (view == NULL) return;
    JavaVM *vm = (JavaVM *) gA2JavaVM;
    if (vm == NULL) {
        // 兜底：JVM 创建方还没回填时，试一次全局符号（多数情况下取不到，只作防御）
        typedef jint (*a2_get_vms_fn)(JavaVM **, jsize, jsize *);
        a2_get_vms_fn getVMs = (a2_get_vms_fn) dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs");
        if (getVMs != NULL) {
            JavaVM *vms[1] = { NULL };
            jsize count = 0;
            if (getVMs(vms, 1, &count) == JNI_OK && count >= 1) vm = vms[0];
        }
    }
    if (vm == NULL) return;
    JNIEnv *env = NULL;
    jint getEnvRc = (*vm)->GetEnv(vm, (void **) &env, JNI_VERSION_1_8);
    BOOL attachedHere = NO;
    if (getEnvRc == JNI_EDETACHED || env == NULL) {
        // ★2026-10-18★ 建窗发生在渲染线程/主线程，都没挂到 JVM 上 ⇒ 先 Attach，
        //   否则 GetEnv 返回 JNI_EDETACHED，导致 UIView 地址从来没发布出去
        //   （真机表现：日志无 [A2-METAL]，metallum 回落到自己的视图 ⇒ 黑屏）。
        if ((*vm)->AttachCurrentThread(vm, (void **) &env, NULL) != JNI_OK || env == NULL) return;
        attachedHere = YES;
    }
    jclass sysCls = (*env)->FindClass(env, "java/lang/System");
    if (sysCls == NULL) return;
    jmethodID setProp = (*env)->GetStaticMethodID(
        env, sysCls, "setProperty",
        "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    if (setProp == NULL) return;
    char hex[40];
    snprintf(hex, sizeof(hex), "0x%llx", (unsigned long long) (uintptr_t) view);
    const char *keys[] = { "metallum.ios.view.pointer", "pojav.view.pointer" };
    for (int i = 0; i < 2; i++) {
        jstring k = (*env)->NewStringUTF(env, keys[i]);
        jstring v = (*env)->NewStringUTF(env, hex);
        (*env)->CallStaticObjectMethod(env, sysCls, setProp, k, v);
        if (k) (*env)->DeleteLocalRef(env, k);
        if (v) (*env)->DeleteLocalRef(env, v);
    }
    a2_log_f(@"[A2-METAL] 已发布 UIView 地址 %s（scale=%.3f）给 metallum", hex, scale);
    if (attachedHere) {
        (*vm)->DetachCurrentThread(vm);
    }
}

static void a2_glfw_observer_focus(int focused) {
    NSArray<A2GlfwHost *> *snapshot;
    pthread_mutex_lock(&gWindowLock);
    snapshot = [gHosts copy];
    pthread_mutex_unlock(&gWindowLock);

    for (A2GlfwHost *h in snapshot) {
        pthread_mutex_lock(&gWindowLock);
        A2GlfwHost *cur = a2_glfw_host_locked(h.handle);
        int changed = (cur != nil) && (cur.focused != (focused ? YES : NO));
        if (cur != nil) {
            cur.focused = focused ? YES : NO;
        }
        pthread_mutex_unlock(&gWindowLock);

        if (changed) {
            a2_glfw_emit_focus(h.handle, focused);
            a2_log_f(@"[A2-GLFW] 焦点变化 window=%ld focused=%d", h.handle, focused);
        }
    }
}

// ============================================================================
//  平台生命周期
// ============================================================================
int a2_glfw_window_platform_init(void) {
    pthread_mutex_lock(&gWindowLock);
    if (gPlatformInitialized) {
        pthread_mutex_unlock(&gWindowLock);
        return 1;
    }
    if (gHosts == nil) {
        gHosts = [NSMutableArray array];
    }
    gPlatformInitialized = 1;
    pthread_mutex_unlock(&gWindowLock);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (gObserverHub == nil) {
            gObserverHub = [A2GlfwObserverHub new];
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc addObserver:gObserverHub
                   selector:@selector(a2_orientationChanged:)
                       name:UIDeviceOrientationDidChangeNotification
                     object:nil];
            [nc addObserver:gObserverHub
                   selector:@selector(a2_didBecomeActive:)
                       name:UIApplicationDidBecomeActiveNotification
                     object:nil];
            [nc addObserver:gObserverHub
                   selector:@selector(a2_willResignActive:)
                       name:UIApplicationWillResignActiveNotification
                     object:nil];
            [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        }
    });

    a2_log_f(@"[A2-GLFW] 平台初始化完成（窗口层/事件总线就绪；渲染后端与本层无关）");
    return 1;
}

void a2_glfw_window_platform_terminate(void) {
    NSUInteger count = 0;
    pthread_mutex_lock(&gWindowLock);
    count = [gHosts count];
    pthread_mutex_unlock(&gWindowLock);

    // ★全部在主队列做★：UIKit 对象（UIWindow/UIView）必须在主线程释放，
    //   否则在 Java 线程上 removeAllObjects 会跨线程析构 UIKit 对象。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gObserverHub != nil) {
            [[NSNotificationCenter defaultCenter] removeObserver:gObserverHub];
            [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
            gObserverHub = nil;
        }
        pthread_mutex_lock(&gWindowLock);
        NSArray<A2GlfwHost *> *snapshot = [gHosts copy];
        [gHosts removeAllObjects];
        gPlatformInitialized = 0;
        pthread_mutex_unlock(&gWindowLock);

        for (A2GlfwHost *h in snapshot) {
            h.hostWindow.hidden = YES;
            h.hostWindow.rootViewController = nil;
            h.hostWindow = nil;
            h.hostView = nil;
        }
    });
    a2_log_f(@"[A2-GLFW] 平台已结束（%lu 个窗口待清理）", (unsigned long) count);
}

// ============================================================================
//  窗口创建 / 销毁
// ============================================================================
int a2_glfw_window_create(long window, int width, int height, const char *title) {
    pthread_mutex_lock(&gWindowLock);
    if (!gPlatformInitialized) {
        pthread_mutex_unlock(&gWindowLock);
        a2_log_f(@"[A2-GLFW] 建窗失败：平台未初始化（window=%ld）", window);
        return 0;
    }
    if (a2_glfw_host_locked(window) != nil) {
        pthread_mutex_unlock(&gWindowLock);
        a2_log_f(@"[A2-GLFW] 建窗失败：句柄重复（window=%ld）", window);
        return 0;
    }
    if ([gHosts count] >= A2_GLFW_MAX_WINDOWS) {
        pthread_mutex_unlock(&gWindowLock);
        a2_log_f(@"[A2-GLFW] 建窗失败：窗口数超上限 %d", A2_GLFW_MAX_WINDOWS);
        return 0;
    }

    A2GlfwHost *h = [A2GlfwHost new];
    h.handle = window;
    h.title = (title != NULL) ? [NSString stringWithUTF8String:title] : @"";
    h.widthPoints = width;
    h.heightPoints = height;
    h.widthPixels = width;
    h.heightPixels = height;
    h.scaleX = 1.0f;
    h.scaleY = 1.0f;
    h.focused = YES;
    h.uikitReady = NO;
    [gHosts addObject:h];
    pthread_mutex_unlock(&gWindowLock);

    // ★UIKit 部分异步到主队列（见文件头「线程模型」）★
    dispatch_async(dispatch_get_main_queue(), ^{
        // ★2026-10-18 真机定位★ 逐行判据证明崩溃发生在「另建 UIWindow → addSubview」这条老路上
        //   （日志停在 4/6 容器挂好，下一步 addSubview 即 objc_retain 崩）。
        //   iOS 13+ 场景模型下，再建一个 UIWindow 并 makeKeyAndVisible 会与现有 scene 打架。
        //   ⇒ 改成：直接把游戏视图挂到【现有 key window 的根视图】上，不再新建窗口。
        UIWindow *keyWin = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { keyWin = w; break; }
            }
            if (keyWin != nil) break;
        }
        if (keyWin == nil) keyWin = UIApplication.sharedApplication.windows.firstObject;
        UIViewController *rootVC = keyWin.rootViewController;
        UIView *container = rootVC.view;
        if (container == nil) {
            a2_log_f(@"[A2-GLFW] 建窗失败：没有可用的根视图（window=%ld）", window);
            return;
        }
        a2_log_criterion(@"[A2-GLFW] 建窗 1/6 取到现有 key window=%p rootView=%p", keyWin, container);

        UIView *view = (UIView *) a2_glfw_input_make_view(window);
        if (view == nil) {
            a2_log_f(@"[A2-GLFW] 建窗失败：宿主视图创建失败（window=%ld）", window);
            return;
        }
        a2_log_criterion(@"[A2-GLFW] 建窗 2/6 视图创建完成 view=%p", view);

        view.frame = container.bounds;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        a2_log_criterion(@"[A2-GLFW] 建窗 3/6 视图 frame 设好 %.0fx%.0f",
                         container.bounds.size.width, container.bounds.size.height);

        [container addSubview:view];
        a2_log_criterion(@"[A2-GLFW] 建窗 4/6 已加入根视图");

        // ★2026-10-18★ 整屏呈现游戏页：否则启动器仍盖在上面，用户只看到启动器。
        //   用「容器 VC + 子视图」的方式（不再把自定义视图当 rootView，那条路会崩）。
        UIViewController *gameVC = [UIViewController new];
        UIView *gameRoot = [[UIView alloc] initWithFrame:keyWin.bounds];
        gameRoot.backgroundColor = [UIColor blackColor];
        gameVC.view = gameRoot;
        view.frame = gameRoot.bounds;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [gameRoot addSubview:view];
        gameVC.modalPresentationStyle = UIModalPresentationFullScreen;
        UIViewController *presenter = rootVC;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        [presenter presentViewController:gameVC animated:NO completion:nil];
        a2_log_criterion(@"[A2-GLFW] 建窗 4c/6 游戏页已整屏呈现 gameVC=%p", gameVC);
        [container bringSubviewToFront:view];
        [view becomeFirstResponder];
        a2_log_criterion(@"[A2-GLFW] 建窗 5/6 becomeFirstResponder 完成");

        UIWindow *win = keyWin;   // 后续代码沿用 win 变量名（不再新建窗口）

        CGRect b = win.bounds;
        CGFloat scale = (win.screen != nil) ? win.screen.scale : 1.0;
        int wp = (int) lround(b.size.width);
        int hp = (int) lround(b.size.height);
        int wpx = (int) lround(b.size.width * scale);
        int hpx = (int) lround(b.size.height * scale);

        int present = 0;
        pthread_mutex_lock(&gWindowLock);
        A2GlfwHost *cur = a2_glfw_host_locked(window);
        present = (cur != nil) ? 1 : 0;
        if (cur != nil) {
            cur.hostWindow = win;
            cur.hostView = view;

            // ★游戏内控件★
            //   ⚠️ 必须在主线程创建：控件层内部用 Auto Layout，而这段代码跑在建窗线程
            //   （真机崩溃：NSInternalInconsistencyException "Modifications to the layout engine
            //   must not be performed from a background thread"）。
            dispatch_async(dispatch_get_main_queue(), ^{
                A2GameControlsView *controls = [[A2GameControlsView alloc] initWithWindowHandle:window];
                controls.frame = view.bounds;
                controls.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [view addSubview:controls];

                // ★这里不做任何窗口搬运★
                //   26.2 及更早走 GLFW 宿主视图，控件加在自己的 view 里本来就正常；
                //   之前那段「搬到最顶层窗口」会把 26.2 的控件搬走（真机：控件出现后消失）。
                //   26.3（SDL 窗口栈）由 Natives/Input/a2_controls_overlay.m 单独负责。

                // ★26.3 控件可见性★ MC 26.3 用 SDL3 会再建一层 UIWindow，把我们的宿主窗口
                //   压在下面 ⇒ 控件直接没了。这里把宿主窗口抬到状态栏之上；
                //   并在 1.5s/4s 再抬两次（SDL 窗口往往是稍后才建出来的）。
                void (^raiseHost)(void) = ^{
                    UIWindow *w = view.window;
                    if (w != nil) w.windowLevel = UIWindowLevelStatusBar + 1.0;
                };
                raiseHost();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), raiseHost);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), raiseHost);
            });
            a2_publish_ios_view_pointer((__bridge void *) view, scale);
            // ⚠️ 必须主线程：改 view.frame = 改 Auto Layout 引擎，建窗线程上做会崩
            //   （真机：Modifications to the layout engine must not be performed from a background thread）
            dispatch_async(dispatch_get_main_queue(), ^{
                a2_duo_sim_apply(window);
                a2_glfw_window_handle_host_resize(window);
            });

            [[NSNotificationCenter defaultCenter] addObserverForName:@"A2DuoSimChanged"
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *n) {
                a2_duo_sim_apply(window);
                a2_glfw_window_handle_host_resize(window);
            }];
            cur.gameViewController = gameVC;
            cur.widthPoints = wp;  cur.heightPoints = hp;
            cur.widthPixels = wpx; cur.heightPixels = hpx;
            cur.scaleX = (float) scale;
            cur.scaleY = (float) scale;
            cur.focused = (UIApplication.sharedApplication.applicationState ==
                           UIApplicationStateActive);
            cur.uikitReady = YES;
        }
        pthread_mutex_unlock(&gWindowLock);

        if (present) {
            // 就绪后补一次尺寸/缩放/焦点，让 Java 侧拿到真实值（初始请求值可能不对）。
            a2_glfw_emit_size(window, wp, hp, wpx, hpx);
            a2_glfw_emit_scale(window, (float) scale, (float) scale);
            a2_glfw_emit_focus(window, a2_glfw_window_is_focused(window));

            // ★渲染器解耦交接面★：从「中立表面描述」读回真实值 —— 也是本单的真机判据日志锚点。
            A2GlfwSurface surf;
            if (a2_glfw_window_surface(window, &surf)) {
                a2_log_f(@"[A2-GLFW] 窗口就绪 window=%ld pts=%dx%d px=%dx%d scale=%.2f view=%p host=%p（中立表面就绪；渲染器接哪个后端与本层无关）",
                         window, surf.widthPoints, surf.heightPoints,
                         surf.widthPixels, surf.heightPixels,
                         (double) surf.contentScaleX, surf.nativeView, surf.nativeWindow);
            }
        }
    });

    return 1;
}

void a2_glfw_window_destroy(long window) {
    // ★摘记录 + 释放 UIKit 对象都在主队列★（同 terminate 的线程理由）。
    dispatch_async(dispatch_get_main_queue(), ^{
        A2GlfwHost *host = nil;
        pthread_mutex_lock(&gWindowLock);
        host = a2_glfw_host_locked(window);
        if (host != nil) {
            [gHosts removeObject:host];
        }
        pthread_mutex_unlock(&gWindowLock);

        if (host == nil) {
            return;
        }
        host.hostWindow.hidden = YES;
        host.hostWindow.rootViewController = nil;
        host.hostWindow = nil;
        host.hostView = nil;
        a2_log_f(@"[A2-GLFW] 窗口已销毁 window=%ld", window);
    });
}

// ============================================================================
//  中立查询面（内部「窗口就绪」日志 + 未来渲染器交接）
// ============================================================================
int a2_glfw_window_is_focused(long window) {
    int focused = 0;
    a2_glfw_host_snapshot(window, NULL, NULL, NULL, NULL, NULL, NULL, &focused, NULL);
    return focused;
}

int a2_glfw_window_surface(long window, A2GlfwSurface *out) {
    if (out == NULL) {
        return 0;
    }
    memset(out, 0, sizeof(*out));
    pthread_mutex_lock(&gWindowLock);
    A2GlfwHost *h = a2_glfw_host_locked(window);
    if (h == nil) {
        pthread_mutex_unlock(&gWindowLock);
        return 0;
    }
    out->nativeView    = (__bridge void *) h.hostView;
    out->nativeWindow  = (__bridge void *) h.hostWindow;
    out->widthPoints   = h.widthPoints;
    out->heightPoints  = h.heightPoints;
    out->widthPixels   = h.widthPixels;
    out->heightPixels  = h.heightPixels;
    out->contentScaleX = h.scaleX;
    out->contentScaleY = h.scaleY;
    out->pixelFormat   = A2_GLFW_PIXEL_FORMAT_HOST_DEFAULT;
    pthread_mutex_unlock(&gWindowLock);
    return (out->nativeView != NULL) ? 1 : 0;
}

// ★游戏宿主视图的稳定访问（无句柄）★ —— 见 a2_glfw_window.h 的契约说明。
// 取法：gHosts 尾部（最近创建）里第一个已就绪的 hostView；与 a2_glfw_window_surface()
// 读的是**同一个** h.hostView（本层不另存一份副本，避免两处状态不一致）。
void *a2_glfw_window_game_view(void) {
    void *view = NULL;
    pthread_mutex_lock(&gWindowLock);
    for (NSInteger i = (NSInteger) gHosts.count - 1; i >= 0; i--) {
        A2GlfwHost *h = gHosts[(NSUInteger) i];
        if (h.hostView != nil) {
            view = (__bridge void *) h.hostView;
            break;
        }
    }
    pthread_mutex_unlock(&gWindowLock);
    return view;
}
