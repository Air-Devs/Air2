# 启动链排障记录 2026-10-31

> 今天（10-31）在真机上定位并修掉的三个**根因级**问题。每条都带真机证据与修复提交，避免下次重复摸索。

---

## 1. MobileGlues 从未被引导：缺 `mg_init_gles`

**现象**（lastlog-108，1.20.1 + MG，包 96e8e14）

```
GL 桥附着 rc=0，帧回调 #1 glGetError=0（我们的清屏在跑）
但游戏日志停在：Backend library: LWJGL version 3.4.1-snapshot 之后再无输出
⇒ LWJGL 的 GL.createCapabilities 卡死，屏幕黑、无声音
```

**根因**：MG 是一个「GL on host GLES」的实现，它需要先被**引导**（`mg_init_gles()`），
引导时才会去解析宿主 GL 函数表并做 caps 探测。我们只 `dlopen` 了它，从没调用引导入口。

**老 Air 的做法**（`tree510/Natives/ctxbridges/gl_bridge.m`）

```
L1215-1216  typedef void (*ame_mg_init_gles_t)(void);
L1381       dlsym(mg, "mg_init_gles")
L1534/1559  在 gl_make_current 里、真实上下文生效之后调用
L1203-1206  注释：mg_init_gles 内要做 caps 检测 ⇒ 必须真实上下文在场
            另：MG 的 LOAD_EGL 是 static 指针，初始化时机错了会永久 NULL
```

**修复**（`7f91f1d`）

```
三个调用点：
  A attach ④ 加载 MG 后 dlsym 取符号
  B attach ⑥ eglMakeCurrent 成功之后调用（老 Air 同款时机）
  C 首次 glfwMakeContextCurrent 成功之后（兜底）
幂等、计时、归属前后对比；失败只记日志不阻断
```

**真机结果**（lastlog-109）

```
mg_init_gles: loading GL ES function pointers (Apple platform)
[MG] GL ES table pinned to real ANGLE libGLESv2 via @executable_path/.../libGLESv2.framework
mg_init_gles: done (2936 GL ES functions resolved)
mg_init_gles 耗时 7.37 ms
OpenGL ES Version: OpenGL ES 3.0.0 (300)
GL Caps: Using framebuffer using OpenGL 3.2
```

⇒ **GL caps init 首次通过**，卡点前移。

---

## 2. oshi / JNA 在 iOS 上 dlopen 了 macOS 二进制

**现象**：GL caps 过了之后，MC 在 `Initializing game` 阶段 Java 崩溃（lastlog-109 尾部有 `#@!@# Game crashed!`）。

**crash report 原文**（`Documents/minecraft/crash-reports/crash-2026-10-31_10.16.40-client.txt`）

```
Description: Initializing game
java.lang.NoClassDefFoundError: Could not initialize class com.sun.jna.Native
  at ca.weblite.objc.Runtime.<clinit>
  ...
Caused by: java.lang.ExceptionInInitializerError: java.lang.UnsatisfiedLinkError:
  .../Documents/Library/Caches/JNA/temp/jna8365118736943536432.tmp:
  dlopen(...): mach-o file ..., but incompatible platform (have 'macOS', need 'iOS')
  at com.sun.jna.Native.loadNativeDispatchLibraryFromClasspath
  at oshi.hardware.platform.mac.MacCentralProcessor.initProcessorCounts
  at oshi.hardware.platform.mac.MacCentralProcessor.<init>
```

**根因**：MC 初始化时用 **oshi** 探硬件，oshi 在 macOS 分支走 **JNA**；
JNA 从 jar 里解出一份 **macOS** 的 dylib，iOS 上 dlopen 直接拒绝（平台不符）。

**修复**（`778c27f`）：`patchjna_agent.jar` **对所有渲染器无条件注入**（之前只在 metallum 分支加）。

```
[A2-AGENT] 注入 patchjna_agent.jar（所有渲染器；修 oshi/JNA 在 iOS 上 dlopen macOS 库）
```

---

## 3. iOS 上 GL 宿主的「混搭」不成立

**背景**：为 MG 配宿主时反复试过几种组合，真机把它们分成了两类。

**不成立的组合（试过，必崩/必黑）**

```
EGL = ANGLE libEGL，GL = 系统 OpenGLES
  ⇒ 上下文是 ANGLE 的，GL 调用却落在系统 GLES
  ⇒ MG 宿主函数表为空 ⇒ glGetError+0x14 pc=0x0
  （而且「系统 OpenGLES 没有 EGL」这件事会被误读成"符号被抢"）
```

**两种自洽组合**

```
 A 全 ANGLE：EGL = ANGLE libEGL，GL = ANGLE libGLESv2，MG 仅作门面     ← 当前采用（96e8e14）
 B 假 EGL：EGL = a2_eagl_egl（EAGL），GL = 系统 OpenGLES，MG 作门面    ← 保留为可选后端
```

**推论**：MG 的 `mg_init_gles` 在方案 A 下会把函数表 **pin 到 ANGLE 的 libGLESv2**（真机日志已证），
所以 A 是可行的；B 需要把假 EGL 接进 MG 的 EGL 查找路径，工作量更大，先留作备选。

---

## 4. 顺带修掉的工程问题

| 提交 | 内容 |
|---|---|
| `799b369` | 系统框架绝对路径（`/System/…`、`/usr/lib/…`）不再走「包内内置」校验 |
| `2793ad6` | 撤销渲染器侧的 10 次免责确认（按用户口径，改为插件安装时弹） |
| `af9ead8` / `3c9eb9d` / `119972e` | JIT 脚本：`vCont;S`（单步）→ `C<sig>`；未知 brk/信号不再无限 continue；抽出三个纯函数让 100 例单测全绿 |

---

## 5. 复现与取证方法（下次直接用）

**崩溃报告不用让用户找**——设备配对后（USB 或无线均可）：

```bash
# 列出 Documents 下 minecraft
printf "ls minecraft\nexit\n" | python3 -m pymobiledevice3 apps afc --documents <bundle-id>

# 拉最新 crash report（注意：路径要带 Documents/ 前缀，--documents 模式下相对容器根）
python3 -m pymobiledevice3 apps pull <bundle-id> \
  "Documents/minecraft/crash-reports/crash-YYYY-MM-DD_HH.MM.SS-client.txt" ./c.txt
```

判据行速查：

```
 [MG] mg_init_gles: done (N GL ES functions resolved)   ← MG 被引导
 GL Caps: Using framebuffer using OpenGL X.Y            ← GL 能力初始化通过
 #@!@# Game crashed! Crash report saved to: …           ← MC 自己的 Java 崩溃（看 crash report）
 SIGBUS/SIGSEGV + libmobileglues…glGetError+0x14        ← MG 宿主表为空（见 §3）
```
