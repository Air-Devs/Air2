#pragma once

#import <UIKit/UIKit.h>

#include <stdbool.h>
#include <string.h>
#include "environ.h"
#include "jni.h"

// Remove date + time from NSLog, unneeded
#define NSLog(args...) customNSLog(__FILE__,__LINE__,__PRETTY_FUNCTION__,args);

// Control button actions
#define ACTION_DOWN 0
#define ACTION_UP 1
#define ACTION_MOVE 2
#define ACTION_MOVE_MOTION 3

#define BUTTON1_DOWN_MASK 1 << 10 // left btn
#define BUTTON2_DOWN_MASK 1 << 11 // mid btn
#define BUTTON3_DOWN_MASK 1 << 12 // right btn

// GLFW event types
#define EVENT_TYPE_CHAR 1000
#define EVENT_TYPE_CHAR_MODS 1001
#define EVENT_TYPE_CURSOR_ENTER 1002
#define EVENT_TYPE_CURSOR_POS 1003
#define EVENT_TYPE_FRAMEBUFFER_SIZE 1004
#define EVENT_TYPE_KEY 1005
#define EVENT_TYPE_MOUSE_BUTTON 1006
#define EVENT_TYPE_SCROLL 1007
#define EVENT_TYPE_WINDOW_POS 1008
#define EVENT_TYPE_WINDOW_SIZE 1009
#define EVENT_TYPE_MODIFIERS 1010

#define GLFW_FOCUSED 0x00020001
#define GLFW_VISIBLE 0x00020004

#define RENDERER_NAME_GL4ES "libgl4es_114.dylib"
#define RENDERER_NAME_MTL_ANGLE "libtinygl4angle.dylib"
#define RENDERER_NAME_MOBILEGLUES "libmobileglues.dylib"
#define RENDERER_NAME_VK_ZINK "libOSMesa.8.dylib"
#define RENDERER_NAME_VULKAN "libMoltenVK.dylib"
// LTW (Large Thin Wrapper) - OpenGL Core 3.3 → OpenGL ES 3 转译层
// 复刻自官方 MojoLauncher/LTW 仓库，完美支持 Sodium + Iris 光影：
//   - 伪装成 OpenGL 3.3 Core Profile 让 MC 1.17+ 正常运行
//   - 主动声明 GL_ARB_buffer_storage 等 ARB 扩展，让 Sodium 的
//     persistent mapped buffers / texture buffers 正常工作
//   - Fragment shader 编译失败时忽略错误，让 BSL/Mellow 等光影包能运行
#define RENDERER_NAME_LTW "libltw.dylib"

// ★ [RENDERER-GAP] 以下渲染器常量来自队友仓库
//   Gsjsjzhznsz/Air-Minecraft-iOS-Launcher（同一项目家族的更晚 fork，Task173/206/211/215）。
//   本树原先没有这些常量/候选，故按"他们有我们没有"整批抄入。全部为【纯追加】：
//   对应 dylib 由 Makefile dep_* / CMake 目标从 vendored 源码构建。
//   dylib 与 lwjgl 装载名配对见报告 D:\CTF\_RENDERER_GAP_REPORT.md。

// VGPU（PojavLauncherTeam/VGPU，gl4es 分支 + 强化着色器语法转换；旧版 MC <1.13 生态）。
// 源码 vendored 于 Natives/external/vgpu（Task173 iOS 移植补丁），由 CMake 目标 vgpu 构建。
#define RENDERER_NAME_VGPU "libvgpu.dylib"

// VirGLRenderer（≤26.2）：Mesa virgl guest + 进程内 vtest server（ZL2 移植）。
// 三件套由 Makefile dep_virgl 产出：libepoxy.dylib / libvtestserver.dylib / libOSMesaVirgl.dylib；
// 桥接源码 Natives/ctxbridges/virgl_server.m（引导 vtest 服务端）。
#define RENDERER_NAME_VIRGL "libOSMesaVirgl.dylib"

// NG-GL4ES（"Krypton Wrapper"，BZLZHH/NG-GL4ES）—— ZalithLauncher 2 用的 gl4es 分支：
// 能处理更高级的着色器、几乎全 MC 版本可跑（glslang + SPIRV-Cross 着色器管线）。
// 与 holy gl4es 不同，它自带 ARB 着色器转译管线；EGL 仍由宿主 ANGLE 提供
// （dylib 只做 GL 转译，零 EGL 动作）。源码 vendored 于 ThirdParty/NG-GL4ES，
// Makefile dep_nggl4es 构建；别名表脚本 scripts/task206_gen_nggl4es_aliases.py。
#define RENDERER_NAME_NGGL4ES "libnggl4es.dylib"

// GL4ESZL2（PojavLauncherTeam/gl4es_extra_extra）—— ZL2 经典版 "gl4es"：
// 纯 C 字符串改写式 GLSL→ESSL 转换（shaderconv.c），无 glslang/SPIRV-Cross 依赖。
// 源码 vendored 于 ThirdParty/gl4es_extra_extra，Makefile dep_gl4eszl2 构建。
#define RENDERER_NAME_GL4ESZL2 "libgl4eszl2.dylib"

// Metal 渲染器（metallum / MetalUniversal）：图形后端由 metallum agent 走原生 Metal
// （直接 MTLDevice），不经过 EGL 渲染器 —— 选中它时 JavaLauncher 只置
// AMETHYST_METAL=1（agent 据此打开渲染 patch），并把 AMETHYST_RENDERER 回落
// auto（Surface 的 GL 上下文仍由 ANGLE 提供），与 metallum 官方集成一致
// （渲染器只管 GL / Vulkan 回退）。
// 渲染器 dylib 由 agent jar 自带（natives/ios/libmetallum.dylib，运行期解出）。
#define RENDERER_NAME_METAL "libmetallum.dylib"

// Mithril 渲染器 - OpenGL 3.3 Core → Vulkan/Metal 转译层（libmithril.dylib）。
// 自带完整的 EGL 1.5 + GL 实现（Vulkan backend，经 MoltenVK 到 Metal），
// 必须从自身 dylib 解析 EGL 符号：若复用 ANGLE 的 EGL，会创建 ANGLE 的 Metal
// 上下文而非 Mithril 的 swapchain，且 eglChooseConfig 在 Mithril 的属性组合下
// 可能返回 0 个配置，触发 gl_init_context 的 assert(bundle->config)。
// 参考：Uniaball/Mithril-Wrapper 仓库 launcher-patch/ 下对 Air 的接入方式。
#define RENDERER_NAME_MITHRIL "libmithril.dylib"

// MobileGL - MobileGL-Dev 的桌面 OpenGL 实现（LGPL-3.0）。
// 两个变体共用同一个 libMobileGL.dylib 二进制，由环境变量
// MOBILEGL_BACKEND_TYPE 在运行时选择后端：
//   libMobileGL.dylib       -> DirectVulkan（GL -> Vulkan -> MoltenVK -> Metal）
//   libMobileGL-gles.dylib  -> DirectGLES（GL -> OpenGL ES）
// 与 Mithril 一样自带 EGL 实现，必须从自身 dylib 解析 EGL 符号。
// 参考：Swung0x48/Amethyst-iOS 提交 dc57bfd3d2 "feat: add MobileGL renderer support"。
#define RENDERER_NAME_MOBILEGL "libMobileGL.dylib"
#define RENDERER_NAME_MOBILEGL_GLES "libMobileGL-gles.dylib"

// SimpleFPEWrapper（MobileGL-Dev，LGPL-3.0）—— 固定管线 (GL 1.x) 仿真层。
// 接入方式对齐安卓 AngelAuraMC/Amethyst-Android @ feat/sfpew_angle：SFPEW 顶替
// 渲染器被 LWJGL dlopen，真正的后端 EGL 由环境变量 SFPEW_EGL 指定，SFPEW 内部
// dlopen 它并转发调用。安卓是 Tools.useSFPEW + SFPEW_EGL + 把 renderLibrary
// 换成 libSimpleFPEWrapper.so；iOS 侧 AMETHYST_RENDERER 本身就是最终库名，
// 故只需补 SFPEW_EGL（见 JavaLauncher.m）。
#define RENDERER_NAME_SFPEW "libSimpleFPEWrapper.dylib"

static inline bool isSFPEWRenderer(const char *renderer) {
    return renderer && !strcmp(renderer, RENDERER_NAME_SFPEW);
}

// SFPEW 只能叠加在「OpenGL ES 后端」之上（对齐安卓 JREUtils：gl4es / system-gles /
// zink 一律 Tools.useSFPEW=false，只有 MobileGlues 这类 GLES 后端才叠加）。
// 桌面 GL→GLES 的 MobileGL-gles 同样属于 GLES 后端，故一并允许。
static inline bool isSFPEWOverlayEligibleRenderer(const char *renderer) {
    if (!renderer) return false;
    return !strcmp(renderer, RENDERER_NAME_MOBILEGLUES) ||
           !strcmp(renderer, RENDERER_NAME_MOBILEGL_GLES);
}

static inline bool isMobileGLRenderer(const char *renderer) {
    return renderer && (!strcmp(renderer, RENDERER_NAME_MOBILEGL) ||
                        !strcmp(renderer, RENDERER_NAME_MOBILEGL_GLES));
}

static inline bool isMithrilRenderer(const char *renderer) {
    return renderer && !strcmp(renderer, RENDERER_NAME_MITHRIL);
}

// 自带 EGL 实现的渲染器：EGL 符号要从渲染器自己的 dylib 解析，不能用 ANGLE。
static inline bool isSelfEglRenderer(const char *renderer) {
    return isMithrilRenderer(renderer) || isMobileGLRenderer(renderer);
}

// 导出 desktop OpenGL（而非 OpenGL ES）的渲染器：
// 需要 EGL_OPENGL_BIT 配置 + eglBindAPI(EGL_OPENGL_API)。
static inline bool isDesktopGLRenderer(const char *renderer) {
    return isMobileGLRenderer(renderer) || isMithrilRenderer(renderer) ||
           (renderer && !strcmp(renderer, RENDERER_NAME_MTL_ANGLE));
}

// ★ [RENDERER-GAP] 新增渲染器的判定谓词（来自队友仓库，纯追加）。
// gl4es 家族：导出全套桌面 GL API，运行时经 ANGLE/libGLESv2 解析后端。
// 三者（VGPU / GL4ESZL2 / NG-GL4ES）与既有 GL4ES 同链路，共用同一套
// proc_address 解析与 init 时机（见 Natives/ctxbridges/gl4es_family_boot.m）。
static inline bool isVGPURenderer(const char *renderer) {
    return renderer && !strcmp(renderer, RENDERER_NAME_VGPU);
}
// NG-GL4ES（"Krypton Wrapper"）—— gl4es 家族第三支，唯二需要宿主显式
// initialize_gl4es() 的成员（另一支是 GL4ESZL2）。
static inline bool isNGGL4ESRenderer(const char *renderer) {
    return renderer && !strcmp(renderer, RENDERER_NAME_NGGL4ES);
}
static inline bool isGL4ESZL2Renderer(const char *renderer) {
    return renderer && !strcmp(renderer, RENDERER_NAME_GL4ESZL2);
}
static inline bool isGL4ESFamilyRenderer(const char *renderer) {
    return isVGPURenderer(renderer) || isGL4ESZL2Renderer(renderer) ||
           isNGGL4ESRenderer(renderer);
}
static inline bool isVirglRenderer(const char *renderer) {
    return renderer && !strcmp(renderer, RENDERER_NAME_VIRGL);
}
// 是否任一"新增（gap）渲染器"。egl_bridge 的兜底/预载分支用它做排除，
// 避免 libOSMesaVirgl.dylib 被既有 "libOSMesa" 前缀误判成 zink。
static inline bool isRendererGapExtra(const char *renderer) {
    return isGL4ESFamilyRenderer(renderer) || isVirglRenderer(renderer);
}

#define SPECIALBTN_KEYBOARD -1
#define SPECIALBTN_TOGGLECTRL -2
#define SPECIALBTN_MOUSEPRI -3
#define SPECIALBTN_MOUSESEC -4
#define SPECIALBTN_VIRTUALMOUSE -5
#define SPECIALBTN_MOUSEMID -6
#define SPECIALBTN_SCROLLUP -7
#define SPECIALBTN_SCROLLDOWN -8
#define SPECIALBTN_MENU -9

#define NSDebugLog(...) if (debugLogEnabled) { NSLog(__VA_ARGS__); }
BOOL debugLogEnabled, isJailbroken;

//__weak UIViewController *viewController;

#define CS_DEBUGGED 0x10000000
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
BOOL isJITEnabled(BOOL checkCSOps);
// ★ [JIT-FLOW] TrollStore 装机判定（entitlement 标记 AND ../_TrollStore 磁盘标记）。
//   取代对 getEntitlementValue(@"jb.pmap_cs.custom_trust") 的单点信任——侧载模板
//   给每个包都预写了该 entitlement，单点信任会让每个侧载包都走 apple-magnifier://。
BOOL isTrollStoreInstall(void);
// legacy method used to check if we're using universal script
void* JIT26CreateRegionLegacy(size_t len);
// JIT26 调试器存活探针（议题 #133）：CS_DEBUGGED 只是"曾经启用过"的持久标志，
// 外部工具瞬时附加后退出会残留置位；TXM 机型上 launchJVM 的 brk #0x69 必须由
// 活的调试器现场服务，否则 EXC_BREAKPOINT 秒闪退。状态显示继续用 isJITEnabled，
// 启动决策用这组探针（三探针任一命中即在岗：ppid!=1 / P_TRACED / 任务异常端口）。
BOOL JIT26IsLikelyDebuggerKeepAttached(void);
BOOL JIT26DebuggerAttachedViaPtrace(void);
BOOL JIT26DebuggerViaExceptionPorts(void);
// ★ [JIT-FLOW] 「JIT 是否真的可用」的**可验证能力**判据：主动发一次 brk #0x69
//   向调试器要一块 JIT 区并（尽力）写入验证。拿到 = 真能执行 JIT；拿不到 = 未开。
//   不依赖外部工具（StikDebug 等）自己的「完成」提示，也不依赖粘滞的 CS_DEBUGGED。
//   日志：成功打 [JIT-FLOW] verified；失败打 [JIT-FLOW] false-positive guard triggered。
BOOL AMEJITVerifyWritableJITRegion(void);
// 等待就绪谓词：非 Universal 路径沿用 isJITEnabled(false)；Universal 路径要求
// 上述真能力验证通过。替代 UI 闸门/headless 里的裸 isJITEnabled(false) 等待条件。
BOOL AMEJITWaitReadyVerified(void);
// 已通过验证的 JIT 区（未验证过返回 NULL）。
void *AMEJITVerifiedRegionPtr(void);
// brk #0x69 的 SIGTRAP 安全网包装：无人应答时返回 NULL 而不是致死崩溃，
// 由调用方走优雅报错路径；调试器正常应答时行为与裸函数完全一致。
void* JIT26CreateRegionLegacySafe(size_t len);
// JIT 等待轮询的有界版本（最长 timeout 秒，每 10s 心跳日志，挂起间隙不计入
// 超时预算，超时返回 NO）。替代裸 while(!isJITEnabled) 死循环。
BOOL ame169_waitForJITCondition(BOOL (^condition)(void), NSTimeInterval timeout, NSString *label);
// JIT 等待成功后的自愈式主队列派发（三道防线：常规派发 / 前台激活重派 /
// 后台看门狗重派并钉死未送达锚点），防主队列续接块丢失导致启动卡死。
void ame185_dispatchToMainSelfHealing(dispatch_block_t block, NSString *label);
// used for large memory regions
void* JIT26PrepareRegion(void *addr, size_t len);
// ★ [POCKETJ-JIT] Universal JIT 协议第 0 号调用:请求调试器脱离
//   (mov x16,#0; brk #0xf00d)。与 JIT26PrepareRegion 同族,是 PocketJ/StikJIT
//   universal.js 的 commands[0]。⚠ 只能在【所有】初始 RX 区都已 PrepareRegion
//   之后调用(见 utils.m 内注释与 Natives/pocketj_jit/PORTING_NOTES.md)。
void JIT26Detach(void);
// JIT26Detach 的 SIGTRAP 安全网版:调试器已脱离时 brk #0xf00d 无人应答,
// 捕获后返回 NO(降级),不使进程致死(与 JIT26CreateRegionLegacySafe 同款)。
BOOL JIT26DetachSafe(void);
// ★ [POCKETJ-JIT] PocketJ 内置 StikJIT 的前置门禁(INTEGRATION.md「Gate every
//   entry point」):iOS ≥17.4 + 宿主 get-task-allow + 可读配对文件。
//   本仓库暂未接入 Helper 扩展,以下仅用于检测/日志/UI 提示,不做自附加调试器。
BOOL AMEJITDeviceSupportsBuiltInStikJIT(void);
BOOL AMEJITHasGetTaskAllow(void);
NSString *AMEJITPairingFilePath(void);
// ★ [JIT-PAIRING] 多候选路径 + 工具是否已装(与配对文件解耦)
NSArray<NSString *> *AMEJITPairingFileCandidates(void);
BOOL AMEJITEnablerAppInstalled(void);   // Documents/StikJIT/pairingFile.plist
BOOL AMEJITHasPairingFile(void);
void AMEJITLogPocketJReadiness(NSString *context);
// same as JIT26PrepareRegion, but used for smaller memory regions
// and retain content instead of filling 0x69
void JIT26PrepareRegionForPatching(void *addr, size_t len);
void JIT26SetDetachAfterFirstBr(BOOL value);
void JIT26SendJITScript(NSString* script);

// ★ [JIT-ADAPT] ============================================================
// 「市面上能开 JIT 的工具」统一适配层。
//
// 背景：主游戏启动路径（LauncherRightPanelViewController / LauncherNavigationController
//  / DownloadViewController 的 invokeAfterJITEnabled:）原先把「获取 JIT」硬编码成
//  stikjit://（≥17.4）/ sidestore://（<17.4）/ apple-magnifier://（TrollStore），
//  **完全忽略** debug.jit_enabler 偏好。于是只装了 StosDebug / JitStreamer / SideJITServer
//  等工具的用户，即便在设置里选了对应工具也仍旧走 stikjit://（点了没反应 /
//  只弹“未装 StikDebug”）。headless(JavaLauncher.ame139_requestJIT) 早已按偏好分发，
//  这里让 UI 路径复用同一套语义：
//    · stikdebug / stosdebug / jitstreamer / sidestore / trollstore → 打开对应 URL；
//    · sidejitserver / altstore / sideloadly / jailbreak / manual  → 本机无 URL 可调
//      （AltStore/Sideloadly 靠电脑端、SideJITServer 靠 Shortcut、越狱靠系统开关），
//      只给「可辨识引导」，由用户在自己的 App/电脑上为本 App 开 JIT；
//    · auto / stikjit → 不在本层处理，交回调用方既有分支（**默认行为保持不变**）。
// 无论走哪条，判定「已开」都只用 AMEJITWaitReadyVerified()（真拿到可写 JIT 区），
// 绝不相信外部工具的“完成”提示；工具没装时立刻回 MissingTool 让调用方给提示。
typedef NS_ENUM(NSInteger, AMEJITEnablerActionResult) {
    AMEJITEnablerActionResultNotHandled = 0, // auto/stikjit：调用方走既有分支
    AMEJITEnablerActionResultOpened,         // 已调起外部工具（进入可验证等待）
    AMEJITEnablerActionResultManual,         // 需用户手动开（进入可验证等待）
    AMEJITEnablerActionResultMissingTool,    // 工具未装/URL 无人处理（给提示，不白等）
};
// 当前 debug.jit_enabler 是否属于本适配层负责的“外部工具”取值。
BOOL AMEJITConfiguredExternalEnablerIsActive(void);
// 按 debug.jit_enabler 调起/引导对应工具（有副作用，调用一次）。
AMEJITEnablerActionResult AMEJITOpenConfiguredExternalEnabler(void);
// 当前 debug.jit_enabler 的原始 key（日志用，缺省 auto）。
NSString *AMEJITConfiguredEnablerKey(void);
// 当前 enabler 的工具显示名（“未安装”提示用；无需安装物的返回 nil）。
NSString *AMEJITConfiguredEnablerDisplayName(void);
// 需要用户手动开的外部工具对应的「引导文案」i18n key（仅 Manual 类返回，否则 nil）。
NSString *AMEJITConfiguredEnablerGuidanceKey(void);

// ★ [JB-ADAPT] ============================================================
// 越狱环境适配层（unc0ver / checkra1n / Taurine / Odyssey / Dopamine(rootless) /
// palera1n(rootless·checkm8) / RootHide / XinaA15 / Electra …，以及 ElleKit /
// libhooker / Substitute / CydiaSubstrate 四类注入框架）。
//
// 背景：越狱机上 JIT 是**原生可用**的（对本 App 而言不必有调试器 attach，也不需要
// 外部 JIT 工具）。但"越狱"本身【不等于】"本 App 被授予 JIT"：越狱只提供机制，
// 是否给某个 App 开 JIT 由用户/越狱配置决定（Dopamine「Allow JIT in Apps」、
// palera1n/checkra1n/unc0ver 的 get-task-allow / platform-application 等）。
//
// ⚠ 硬约束（沿用 [ROOTHIDE] 线）：环境识别**只用于【选路径/选策略】**，绝不参与
//   isJITEnabled 判定。若把"检测到越狱"当 JIT 能力代理，在"越狱已装但本 App 未开
//   JIT"时会误报可用 ⇒ 启动闸门跳过 JIT 获取 ⇒ 游戏 SIGILL 闪退。故本层：
//     ① 正确识别越狱环境（日志/诊断/策略选择，含 RootHide 假阴性修复）；
//     ② 越狱下用**真能力自检**（本进程能否直接把匿名页置 RX）替代"等外部工具"。
//
// 证据来源（IOSSecuritySuite JailbreakChecker · Apple Wiki「Roothide/ElleKit」·
// opa334/dopamine · palera1n/jbinit · CoolStar libhooker · MidnightTeam/substitute）：
//   · 注入库（dyld 镜像，沙盒下最可靠）：libellekit.dylib / libhooker.dylib /
//     libsubstitute.dylib / substrate-inserter|loader / MobileSubstrate.dylib /
//     systemhook.dylib(Dopamine) / roothideinit.dylib(RootHide) / libblackjack.dylib；
//   · 越狱根：固定 /var/jb（rootless）· 随机 /var/containers/Bundle/Application/
//     .jbroot-<hex>（RootHide）· /Library/MobileSubstrate（rootful）· /var/binpack(checkra1n)；
//   · 磁盘标记：/.installed_unc0ver · /Applications/{Dopamine,palera1nLoader,Cydia,Sileo}.app ·
//     /var/mobile/Library/Preferences/com.roothide.pref.plist。
typedef NS_ENUM(NSInteger, AMEJBEnvironment) {
    AMEJBEnvironmentUnknown = 0,  // 尚未探测
    AMEJBEnvironmentNone,         // 未越狱
    AMEJBEnvironmentRootful,      // checkra1n / unc0ver（rootful，Cydia Substrate）
    AMEJBEnvironmentRootless,     // Dopamine / palera1n(rootless) / Taurine / Odyssey（/var/jb）
    AMEJBEnvironmentRootHide,     // Dopamine-roothide / palera1n-roothide（随机 jbroot）
};
// 越狱环境分类（只读、缓存；仅用于选路径/选策略/日志，绝不参与 isJITEnabled）。
AMEJBEnvironment AMEJailbreakEnvironment(void);
// 越狱环境摘要（日志/诊断）：如 "RootHide(random jbroot) + ElleKit (Dopamine)"；未越狱 "None"。
NSString *AMEJailbreakEnvSummary(void);
// 越狱下「原生 JIT」策略是否适用（= 环境分类可辨识出越狱）。**不表示 JIT 已开**。
BOOL AMEJailbreakNativeJITPathApplies(void);
// 越狱下原生 JIT 的**真能力**判据：本进程能否直接把匿名页设为可执行（无需调试器
// 服务 brk #0x69）。成功即证明 JIT 原生可用；失败绝不放行。
BOOL AMEJailbreakNativeJITReady(void);

// ★ [JIT-NOCRASH] 其余 JIT26 brk(#0xf00d)协议调用的 SIGTRAP 安全网包装。
//   与 JIT26CreateRegionLegacySafe / JIT26DetachSafe 共用同一套 handler /
//   sigjmp / armed 机制(分层、支持嵌套)。调试器在岗时行为与裸函数一致；无人
//   应答时降级:返回 NO(或 NULL) 并仅在失败分支打日志,由调用方跳过该步,
//   不再 SIGTRAP 致死。安全网只在"无人应答"时兜底,不干扰正常 JIT。
//   JIT26PrepareRegionSafe 丢弃裸函数的 void* 返回值(无任何调用方使用),
//   只回报"是否被调试器服务"。
BOOL JIT26PrepareRegionSafe(void *addr, size_t len);
BOOL JIT26PrepareRegionForPatchingSafe(void *addr, size_t len);
BOOL JIT26SendJITScriptSafe(NSString *script);
BOOL JIT26SetDetachAfterFirstBrSafe(BOOL value);

// ★ [SHADER-SIGBUS] ==========================================================
// 已 PrepareRegion 的 JIT 区登记表（只记录、不改变任何行为）。
//
// 用途：崩溃取证时把「PC/帧地址落在匿名 JIT 区」与「落在真实 dylib 镜像」
// 区分开。上一轮 SIGBUS 的悬案正是这两种解释分不开（pc − region_base 恰好
// == dylib 偏移 ⇒ 无法判断是"dylib 被映射进 JIT 区"还是"JIT 区恰好同址"）。
// 有了这张表，`ame_write_fatal_trace` 可以直接标注每一帧的归属类别。
// 表本身只是只读旁路：写入点在各 Safe 包装成功返回处，读取点只在崩溃路径。
// ============================================================================
void JIT26RecordPreparedRegion(void *addr, size_t len);
BOOL JIT26AddressInPreparedRegion(const void *p);

// Device JIT flags（同步自上游 AngelAuraMC/Amethyst-iOS）
// 支持 iOS 26.6+ / 27 的现代 Preboot 路径 + ChipID 硬件 fallback + capability 查询
typedef enum {
    JIT_FLAG_IS_IOS_26 = 1 << 0,
    JIT_FLAG_FORCE_MIRRORED = 1 << 1,
    JIT_FLAG_HAS_TXM = 1 << 2,
} JITFlags;
JITFlags DeviceGetJITFlags(BOOL refresh);
BOOL DeviceHasJITFlags(JITFlags flags);
BOOL DeviceNeedsDebugJITMapping(void);

// Init functions
void init_bypassDyldLibValidation();
// ★ [DYLD-SWITCH] dyld 库校验旁路总开关求值（偏好 java.dyld_bypass，默认关；
// AMETHYST_DYLD_BYPASS=0 强制关）。见 dyld_bypass_validation.m。
BOOL ame_dyldBypassRequested(void);
void init_hookFunctions();

// Zink (Mesa 25.0.7) + MoltenVK vertex stride 4 字节对齐 fix
// 仅在 zink 渲染器被选中时激活（需在 AMETHYST_RENDERER 环境变量设置后调用）
// 详见 main_hook.m 中的实现注释
void installZinkStrideFix();
// 在新 image（libOSMesa / libMoltenVK）加载后调用，重新执行 fishhook
// 捕获新 image 对 Vulkan loader 函数的符号引用
void rebindZinkStrideFixForNewImage();
void init_hookUIKitConstructor();
void init_setupMultiDir();

BOOL PLPatchMachOPlatformForFile(const char *path);

UIViewController* currentVC();
void openLink(UIViewController* sender, NSURL* link);
void handle_fatal_exit(int code);

NSString* localize(NSString* key, NSString* comment);

// ★ [I18N] 启动器界面语言覆盖（独立于系统 AppleLanguages）：
// 用户在「设置 > 语言」里选择后写入 NSUserDefaults（键名 ame_launcher_language），
// localize() 以「生效语言」为准统一取词（用户选择 → 系统最佳匹配 → en）。
extern NSString * const AmeLauncherLanguageDefaultsKey;
/// ★ [I18N] 真正支持的界面语言白名单（curated：只有翻译覆盖率高、能用的那些）。
/// 依据 Natives/resources/*.lproj 键集合盘点，见 D:\CTF\_I18N_FIX.md。
NSArray<NSString *> *AmeLauncherSupportedLanguageCodes(void);
/// ★ [I18N] 系统语言代码 → 我们实际使用的 .lproj 代码（含变体映射：
/// zh-Hans-CN→zh-Hans、zh-CN→zh-Hans、zh-Hant-TW→zh-Hant、en-GB→en、ja-JP→ja…）。
/// 匹配不到返回 nil。
NSString *AmeLauncherMatchLanguageCode(NSString *systemCode);
/// ★ [I18N] 当前"实际生效"的界面语言代码：用户选择 ?? 系统语言最佳匹配 ?? @"en"。
/// 设置页显示与实际渲染都用它，保证"所见即所得"。
NSString *AmeLauncherEffectiveLanguageCode(void);
/// ★ [I18N-ORDER] 启动最早期(任何 UI 构建之前)调用一次:解析并缓存"生效语言"、预热语言包,
/// 并打印自证日志(生效语言 / 使用的 .lproj / 真实覆盖率 / Bundle.main 首选本地化)。
/// 单一入口 + 早期解析 ⇒ 杜绝"设置显示中文、界面却渲染英文"这类显示/渲染分叉。
void AmeLauncherPrimeLanguage(void);
/// 用户选择的语言代码（如 @"zh-Hans"）；返回 nil 表示「跟随系统」。
/// ★ [I18N] 旧版存下的、现已不支持的语言会被视为未选择并清理（幂等迁移）。
NSString *AmeLauncherPreferredLanguageOverride(void);
/// 写入/清除语言覆盖。code 为 nil 或空串时清除（回到跟随系统）。
void AmeLauncherSetPreferredLanguageOverride(NSString *code);
/// 语言代码 → 人读显示名（用系统当前语言本地化）；取不到时回退返回 code 本身。
NSString *AmeLauncherDisplayNameForLanguageCode(NSString *code);
/// ★ [I18N] 语言选单要列出的语言（= AmeLauncherSupportedLanguageCodes，按显示名排序）。
NSArray<NSString *> *AmeLauncherAvailableLanguageCodes(void);
/// ★ [I18N] 某语言的"人工翻译率"（0.0~1.0，基准语言返回 1.0）；选单标"部分翻译"用。
double AmeLauncherLanguageTranslatedRatio(NSString *code);

// ★ [I18N-PARTIAL] ============================================================
// 「部分翻译」语言（单一事实源）。
// 用户拍板：ja.lproj 有 1608/1955 个键与 zh-Hans 逐字相同（大量界面其实是中文），
// 但也确实有真实日语翻译 ⇒ 【保留该语言】、只在用户能看到语言的地方如实标注
// 「部分翻译」。要追加/移除被标注的语言，**只改** utils.m 里
// AmeLauncherPartiallyTranslatedLanguageCodes() 这一个集合，展示层全部经下面两个函数。
/// ★ [I18N-PARTIAL] 被标为"部分翻译"的语言代码集合（单一事实源；先只有 ja）。
NSSet<NSString *> *AmeLauncherPartiallyTranslatedLanguageCodes(void);
/// ★ [I18N-PARTIAL] 该语言是否被标为"部分翻译"。
BOOL AmeLauncherIsPartiallyTranslatedLanguage(NSString *code);
/// ★ [I18N-PARTIAL] 语言选单/设置页展示名：部分翻译的语言追加本地化的「（部分翻译）」后缀。
/// 非部分翻译语言 = AmeLauncherDisplayNameForLanguageCode(code)，行为完全不变。
NSString *AmeLauncherDisplayNameAnnotatedForLanguageCode(NSString *code);
/// ★ [I18N-PARTIAL] 部分翻译语言的补充说明（如「部分界面仍为中文」）；非部分翻译返回 nil。
NSString *AmeLauncherPartiallyTranslatedNoteForLanguageCode(NSString *code);
// YES 表示 NSError 是"当前没有可用网络"，而非服务器返回了不喜欢的内容。
// 账户刷新只认 NSURLErrorDataNotAllowed 会漏掉飞行模式/无 Wi-Fi 等常见离线形态。
BOOL isConnectivityError(NSError *error);
NSMutableDictionary* parseJSONFromFile(NSString *path);
NSError* saveJSONToFile(NSDictionary *dict, NSString *path);
void customNSLog(const char *file, int lineNumber, const char *functionName, NSString *format, ...);

static inline CGFloat clamp(CGFloat x, CGFloat lower, CGFloat upper) {
    return fmin(upper, fmax(x, lower));
}
CGFloat MathUtils_dist(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2);
CGFloat MathUtils_map(CGFloat x, CGFloat in_min, CGFloat in_max, CGFloat out_min, CGFloat out_max);
CGFloat dpToPx(CGFloat dp);
CGFloat pxToDp(CGFloat px);
void setButtonPointerInteraction(UIButton *button);
void _CGDataProviderReleaseBytePointerCallback(void *info,const void *pointer);
void dismissModalViewController(UIViewController *viewController);

jboolean attachThread(bool isAndroid, JNIEnv** secondJNIEnvPtr);

void sendData(short type, int i1, int i2, short i3, short i4);
void sendDataFloat(short type, float i1, float i2, short i3, short i4);

void closeGLFWWindow();
void callback_LauncherViewController_installMinecraft();
void callback_SurfaceViewController_launchMinecraft(int width, int height);
int callback_SurfaceViewController_touchHotbar(CGFloat x, CGFloat y);

// FPS 计数器：在 pojavSwapBuffers() 中累加，调用此函数读取并重置（参照 FCL/ZL2）
unsigned int pojavGetAndResetFps();
// 显式递增 FPS 计数器（供 Vulkan 模式 CADisplayLink fallback 使用）
void pojavIncrementFpsCounter();
// 运行时判定 MC 真实渲染路径是否为 Vulkan（clientAPI == GLFW_NO_API）。
// 比 SurfaceViewController 在 viewDidLoad 时的静态字符串推断更准确：
// - 真正 Vulkan 路径（graphicsApi=prefer_vulkan 或 default 走 Vulkan）→ 返回 true
// - Vulkan 渲染器但 MC 实际选 OpenGL 路径（prefer_opengl）→ 返回 false，避免双重计数
// 此函数读取 egl_bridge.m 中的 clientAPI 全局变量，由 pojavSetWindowHint(GLFW_CLIENT_API, ...) 写入。
bool pojavIsActualVulkanPath();

void CallbackBridge_nativeSetInputReady(BOOL inputReady);
BOOL CallbackBridge_nativeSendChar(jchar codepoint /* jint codepoint */);
BOOL CallbackBridge_nativeSendCharMods(jchar codepoint, int mods);
void CallbackBridge_nativeSendCursorPos(char event, CGFloat x, CGFloat y);
void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods);
// Task83：控件按钮键盘打字——按下时按 US ANSI 布局补发一个字符事件
// （MC 1.13+ 聊天框只认 charTyped/text-input，纯 key 事件不进文本）。
// 仅由按钮路径调用（SurfaceViewController executebtn），硬件键盘不走这里。
BOOL CallbackBridge_buttonKeySynthesizeText(int key);
void CallbackBridge_nativeSendMouseButton(int button, int action, int mods);
void CallbackBridge_nativeSendScreenSize(int width, int height);
void CallbackBridge_nativeSendScroll(CGFloat xoffset, CGFloat yoffset);
void CallbackBridge_sendKeycode(int keycode, jchar keychar, int scancode, int modifiers, BOOL isDown);
void CallbackBridge_pauseGameIfNeed();
// issue #27 修复（参照 FCL commit 08c0716）：物理键盘 modifier 同步
// 显式同步 MC 1.21.9+ 内部的 InputConstants modifier 缓存。
// 由 KeyboardInput.m 在物理键盘按下/释放事件中调用。
void CallbackBridge_syncModifiersToMC(int mods);
void CallbackBridge_queueModifierSync(int mods);

// ---- Air 对齐：gl_bridge.m 实现的取证/呈现层接口（见 gl_bridge.m 内定义）----
void ame_egl_swap_stats(unsigned long *ok, unsigned long *fail);
void ame_egl_swap_framegap(unsigned int *maxGapMs, unsigned int *avgGapMs);
void ame_egl_swap_phase_stats(unsigned int *presentAvgMs, unsigned int *presentMaxMs,
                              unsigned int *buildAvgMs, unsigned int *buildMaxMs);
// ★ [SDL-FIRSTFRAME] 首帧/钩子活性取证（判读「零 [SDLHook] 行」到底是钩子没装上
//   还是本场根本没走 SDL3 链路）。三件套：启动期自证行、活性探针、SDL 链计数。
//   ame_sdlhook_probe      —— main_hook.m：hooked_dlsym 调用次数 / 其中 SDL* 名字次数
//   amethyst_sdl3_hook_stats —— sdl3_hook.m：SDL 名字被咨询次数 / 真接管次数
void ame_sdlhook_probe(unsigned long *dlsymCalls, unsigned long *sdlNames);
void amethyst_sdl3_hook_stats(unsigned long *consulted, unsigned long *takenOver);
bool ame_gl_surface_owns_layer(void);
bool ame_gl_surface_transposed(void);

// ★ [VER-ISOLATE] ============================================================
// 完全版本隔离：实例隔离根目录解析（单一事实源）。
//
// 背景：1.21.11 / 26.2 / 26.3 与多实例共用同一份 POJAV_HOME，历史上日志/临时/
// 渲染器配置等产物落在 POJAV_HOME 根下，被后启动的会话覆盖 ⇒「另一个版本崩、
// 另一个能跑」时无法取证、渲染器偏好互相串扰。本组函数把「可安全隔离」的产物
// 统一落到 <POJAV_HOME>/instances/<实例>/ 内。
//
// 隔离键 = 实例目录（general.game_directory）。刻意直接读全局 plist，不依赖
// loadPreferences() —— main.m 的 STDIO 重定向早于 loadPreferences()，必须在启动
// 最早期就能拿到实例名。任何一步不可得都返回 nil / 回退旧共享路径，绝不阻断启动。
NSString *ameVIInstanceRoot(void);              // <POJAV_HOME>/instances/<实例>（不保证已存在）
NSString *ameVIInstanceSubdir(NSString *leaf);  // 创建并返回 <root>/<leaf>；root 不可得返回 nil
NSString *ameVILatestLogPath(void);             // 每实例 latestlog.txt
NSString *ameVILatestLogRotatedPath(void);      // 每实例 latestlog.old.txt

// ★ [LOG-FIX] ===============================================================
// 日志隔离的「兼容层」：POJAV_HOME 下那两个名字必须仍是【普通文件】，不能是符号链接。
// 证据：iOS 文件 API 把 symlink 当独立条目 —— attributesOfItemAtPath: 报
// NSFileTypeSymbolicLink、NSFileSize=目标串长度（不是内容长度）；copyItemAtPath: /
// UIActivityViewController 分享 / 文件 App / AFC / 第三方工具会【原样拷贝链接本身】，
// 目标一旦不在接收方沙盒就拿到空/断裂文件。改用【硬链接】：与真身同一 inode，对一切
// 读方表现为普通文件、内容实时就是当前实例那次运行；零额外写入，隔离收益完全保留。
//
// 成对处理约定（调用点必须遵守）：
//   · 建链：先 removeItemAtPath:dest（dest 可能是旧版残留 symlink），再 linkItemAtPath:。
//   · 轮转：真身按 move+create 轮转（得到新 inode），随后对 latestlog(./old) 两个名字重建。
//   · 删除：dest 被删只是少一个名字，真身 inode 仍由实例内名字保活；下次启动重建。
BOOL ameVIPathIsSymlink(NSString *path);                     // 不跟随 symlink 的判定
BOOL ameVIHardLinkLog(NSString *srcPath, NSString *dstPath); // 建硬链接；成功=dest 为普通文件

// ★ [VER-ISOLATE-PCL] ========================================================
// 版本隔离（对齐 PCL2 社区版 PCL-CE 的「实例隔离」语义，源码键
// VersionArgumentIndieV2 / LaunchArgumentIndieV2）。
//
// 语义（与 PCL 一致，纯目录指针切换，**不搬运文件**）：
//   开启 → 该版本的 gameDir = <实例根>/versions/<版本 id>/   （mods/config/saves/
//          resourcepacks/shaderpacks/logs/options.txt 全部落在此，与其它版本互不干涉）
//   关闭 → 该版本的 gameDir = <实例根>/                      （与实例内其它版本共享，现状）
// versions/ 目录本身、libraries/、assets/ 始终按实例共享 —— 与 PCL 相同：
//   只有"游戏数据目录"被隔离，不是把整棵树复制一份。
//
// 判定顺序（对应 PCL McInstance.PathIndie / ShouldBeIndie）：
//   1) profile 显式值 versionIsolation（"1"/"0"）——对应 PCL 的 VersionArgumentIndieV2
//   2) 自动判定：<实例根>/versions/<id>/ 下已有 mods(含文件) 或 saves(含目录) ⇒ 开启
//   3) 全局默认 general.version_isolation ——对应 PCL 的「默认实例隔离」LaunchArgumentIndieV2
//
// 解析给定 profile 的版本隔离是否开启。concreteVersionId 可为 nil（启动期可传
// launchTarget[@“id”] 以拿到比 lastVersionId 更准确的版本 id）。
BOOL amePCLVersionIsolationForProfile(NSDictionary *prof, NSString *concreteVersionId);

// 生效的 gameDir 子路径（相对当前实例根）：@“.”（共享）或 @“versions/<id>”（隔离）。
// profile 里显式写了非 @“.” 的 gameDir 时以显式值为准（保持既有语义不变）。
NSString *amePCLVersionGameDirSubpath(NSDictionary *prof, NSString *concreteVersionId);

// 生效的 gameDir 绝对路径（POJAV_GAME_DIR + 上面的子路径）。
NSString *amePCLVersionGameDirAbsolute(NSDictionary *prof, NSString *concreteVersionId);

// 一次性幂等迁移（哨兵键 internal.version_isolation_migrated）：
// 把"升级前已手工隔离过"的 profile（gameDir 指向 versions/*，或对应版本目录下
// 已有 mods/saves）显式写成 versionIsolation=@"1"，使其在设置页可见、可回退。
void amePCLMigrateVersionIsolationOnce(void);

// ★ [VER-ISOLATE-MIGRATE] ====================================================
// 实例【共享游戏根】绝对路径（= POJAV_GAME_DIR；不可得时回退 ameVIInstanceRoot()）。
// 仅作 fallback；带 profile 的迁移请用下面的 amePCLSharedGameDirForProfile。
// 注意：本函数【只解析路径，绝不移动/复制任何文件】。
NSString *amePCLSharedGameDirAbsolute(void);

// ★ [VER-ISOLATE-MIGRATE] 某 profile 在【关闭隔离】时实际使用的 gameDir 绝对路径
// （= 迁移的"源根" = 用户当前真正在用的那个目录）。**唯一真相源 = 同一 resolver**：
// 本函数不另拼路径，而是把 profile 的 versionIsolation 显式置 "0" 后交给
// amePCLVersionGameDirAbsolute 解析（显式 versionIsolation 会让 resolver 立即返回，
// 不再走自动启发式）。profile 若写了显式自定义 gameDir，则会解析成该目录 ⇒ 与
// amePCLVersionGameDirAbsolute(profile,...)（开隔离）同值 ⇒ 迁移自动判定为"无目标"。
// 迁移动作用户在实例编辑页显式触发；本函数自身不动任何文件。
NSString *amePCLSharedGameDirForProfile(NSDictionary *prof, NSString *concreteVersionId);

// ★ [VI-POLISH] ==============================================================
// 采纳《_LAUNCHER_ISOLATION_SURVEY.md》§③ 建议 A/B/C/D 的共用底座：
//   A 三态可见化 —— 隔离显式三态读写 + 目录形状嗅探明细（供 UI 说明「为什么是这个判定」）
//   B 首启向导   —— ★ [VI-FLOW] 用户修正：每次进启动器都再弹，直到用户主动选「以后不再提示」
// （C 共享边界文案 / D 关闭恢复提示 是纯文案，落在 .strings 与各页 UI，不在这里。）
// 硬约束：本段所有函数只【读磁盘 + 读/写设置】，绝不移动、复制或删除任何文件；
//         「自动」= 不落键，保持 resolver 既有默认语义（默认仍关，未改任何默认值）。

// A. 隔离显式三态 —— 对应 profile 的 versionIsolation 键，与 resolver 第 1 步完全同源：
//    Auto     = 未落键（resolver 走 自动判定 → 全局默认 general.version_isolation）
//    Shared   = 显式 "0"（PCL 的 VersionArgumentIndieV2=0）
//    Isolated = 显式 "1"（PCL 的 VersionArgumentIndieV2=1）
typedef NS_ENUM(NSInteger, AmeVIExplicitState) {
    AmeVIExplicitStateAuto     = -1,
    AmeVIExplicitStateShared   =  0,
    AmeVIExplicitStateIsolated =  1,
};

// 读 profile 的显式三态（未落键 ⇒ Auto）。
AmeVIExplicitState ameVIExplicitStateForProfile(NSDictionary *prof);

// 写 profile 的显式三态：Auto ⇒ 移除该键（回到自动判定），Isolated/Shared ⇒ 写 "1"/"0"。
// 只改这一个键，不动任何文件、不动 profile 的其它字段。
void ameVISetExplicitStateForProfile(NSMutableDictionary *prof, AmeVIExplicitState state);

// A. 版本目录形状嗅探明细（纯只读）。判定规则与 resolver 的自动判定**逐字同源**
//    （mods：含非隐藏文件；saves：含非隐藏条目 ⇒ 视为已隔离）。
// 返回 @{ @"hasMods": @BOOL, @"hasSaves": @BOOL, @"hasAny": @BOOL,
//          @"exists": @BOOL, @"path": NSString }（任何一步不可得都返回全 NO，绝不抛错）。
NSDictionary *ameVISniffVersionFolder(NSString *versionId);

// A. 向导用「建议隔离态」：嗅探到内容 ⇒ 建议显式隔离；否则建议保持自动（默认）。只读，不落键。
BOOL ameVISniffShouldSuggestIsolation(NSString *versionId);

// ★ [VI-FLOW] B（用户修正 1 + 补充）：向导「弹到用户主动说『以后都不弹』为止」。
//    * 哨兵 internal.version_isolation_wizard_off：幂等，【只】在用户于点「以后不再提示」时写一次；
//      弹出时绝不写。未落哨兵 ⇒ 每次进启动器都会再次出现（可跳过、不阻碍启动）。
//    * 已落哨兵 ⇒ 不再【自动】弹；但实例设置页的「版本隔离向导」手动入口直接 present（不受哨兵约束）。
//    静态证明：哨兵读点唯一（ShouldPresent，只读不写）、写点唯一（MarkDontShowAgain，仅向导按钮调用）。
BOOL ameVIWizardShouldPresent(void);
void ameVIWizardMarkDontShowAgain(void);
