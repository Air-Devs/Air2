# 鸿蒙（HarmonyOS NEXT）移植可行性评估

> 2026-10-31。基于公开文档与社区资料整理，**不是官方承诺**；带「待验」标记的条目需要在真机上确认。

---

## 一、结论先说

**这不是「移植」，是「重写 UI + 重写平台层」，只有 JVM 与 GL 两段能复用。**

| 我们的组成 | 鸿蒙上能否复用 | 说明 |
|---|---|---|
| ObjC / UIKit 界面（约 24 个二级页 + 一级页） | ❌ 重写 | 鸿蒙只有 ArkTS/ArkUI（声明式），没有 UIKit |
| 启动链（ObjC：A2LaunchSession/A2LaunchRunner） | ❌ 重写 | 平台层是 OHOS 的 Ability/NativeWindow |
| JNI + Java 启动器（A2Entry、classpath、plan） | ✅ 基本可用 | 前提是能带上一个 JVM（见 §三） |
| JRE（java-8/17/21/25 的 libjvm.dylib） | ⚠️ 要换产物 | 必须是 HarmonyOS 的 arm64 `.so`，不能用 iOS 的 `.dylib` |
| GL 渲染（EGL/GLES 桥、MG、gl4es、ANGLE） | ✅ 大部分可复用 | 鸿蒙原生支持 EGL + OpenGL ES + NativeWindow |
| metallum（Metal 直连） | ❌ 不可用 | 鸿蒙没有 Metal；要改走 Vulkan（MoltenVK 也无意义） |
| JIT（我们的 JIT26/mirror 那套） | ⚠️ 换机制 | 鸿蒙默认关 JIT，要申请权限（见 §三） |

---

## 二、平台事实（已核）

```
 HarmonyOS NEXT 去掉 AOSP，没有 JVM、不能装 APK
   应用形态：.hap（打包后 .app 上架），主力语言 ArkTS（TypeScript 扩展）
 UI：ArkUI 声明式 + XComponent（用于把原生渲染层嵌进 ArkUI）
 图形：原生 OpenGL ES（EGL + NativeWindow + XComponent），也支持 Vulkan
   已有开源示例 ndk-opengl（C++ 原生 GLES 游戏）与 Cocos/团结引擎的鸿蒙移植
 分发：DevEco Studio 打包 + AGC 签名/上架；用户侧没有「拖 ipa 就装」这种路径
 侧载：只能靠开发者签名 + 设备调试，普通用户装不了
```

这意味着我们现在的分发方式（TrollStore / SideStore / 直接发 ipa）在鸿蒙上**完全没有对应物**。

---

## 三、JVM 这条路（最关键）

```
 社区事实：鸿蒙里跑 Java 不是官方能力，有人用 bisheng JDK17 做过（论坛帖）
 官方立场：系统不带 JVM，ArkTS 是唯一官方应用语言
 JIT 限制：默认关闭；要用需向 AGC 申请 ohos.permission.kernel.ALLOW_EXECUTABLE（JSVM 同类权限），
           审核时说明用途；否则只能解释执行（性能不可接受）
```

对我们的影响：

```
 1 我们要自己带一个 arm64 的 libjvm.so（OpenJDK for OHOS），
   相当于把「iOS 上自编 libjvm」那套再做一遍，目标换成 ohos-clang + OHOS NDK
 2 我们的 mirror code cache（为 iOS TXM 写的）在鸿蒙上没有意义，
   要按鸿蒙的内存/执行页规则重新做（或直接申请 JIT 权限后走常规路径）
 3 32 位/64 位、页大小、加载器差异都要重验
```

**结论**：JVM 技术可行，但工作量约等于「再做一次 iOS 的 JRE 移植」，且有上架审核风险（JIT 权限要给理由）。

---

## 四、图形这条路（相对乐观）

```
 鸿蒙原生支持 EGL 1.4/1.5 + OpenGL ES 3.x（XComponent 提供 Surface，NativeWindow 做生产者）
 ⇒ 我们的 a2_gl_bridge（EGL/GLES 桥）逻辑可以照搬，只要把「宿主表面」从 CAEAGLLayer 换成 OHNativeWindow
 MobileGlues（GL on host GLES）理论上可直接编成 OHOS 的 .so
 ANGLE 也能编（它本来就跨平台），但 ANGLE 的 Metal 后端在鸿蒙无意义，只能用 Vulkan 后端
 metallum（Metal 直连）作废；26.x 若要在鸿蒙跑，需要一条 Vulkan 路径
 我们的「假 EGL → EAGL」在鸿蒙没有 EAGL，但有系统 EGL，用不上
```

---

## 五、UI 这条路（工作量最大）

```
 现有：ObjC + UIKit，自绘 MD3，24 个二级页 + 一级页 + 控件编辑器 + 下载/版本/实例管理
 鸿蒙：ArkTS + ArkUI（声明式），组件模型完全不同
 只能：按功能重写界面，复用后端逻辑（如果有的话）
```

按页面数量粗估：**一级页 + 24 个二级页 + 控件层**，即使 1:1 照着搬，也是**月级**工作量。

---

## 六、如果真要做，建议的顺序

```
 1 先做「能不能跑起来」的最小验证（1~2 周）
    · 建一个 HAP，XComponent + EGL + GLES3 画三角形（验证图形栈）
    · 同一个 HAP 里带一个 arm64 libjvm.so，用 JNI 起 VM 跑 "Hello"（验证 JVM 可行性）
    这两步任一失败 ⇒ 整个方向不成立，早停
 2 图形：把 a2_gl_bridge 改成「OHNativeWindow 版」，先跑通 MG（GL→宿主GLES）
 3 JVM：把 Java 启动器（A2Entry/plan/classpath）搬过去，去掉所有 iOS 专有依赖
 4 UI：最后做，按页面优先级重写
 5 分发：AGC 签名 + 上架；放弃侧载思维
```

---

## 七、我的建议（给群里那句「要跨平台」）

```
 跨平台 ≠ 移植。鸿蒙这条线的真实成本是「重写一个客户端」，
 能复用的只有 Java 启动器和 GL 桥；UI 与平台层必须重写。
 如果目标是「让鸿蒙用户玩上 MC」，更划算的路径是：
   · 先看有没有现成的鸿蒙 MC 启动器/整合包（社区已有）
   · 我们提供 Java 运行时 + 渲染器方案（.so 形式），让别人去做 UI
 如果目标是「我们自己做鸿蒙版」，那要按新产品立项，不是当前这条线顺手能带的。
```

---

## 八、待验清单

```
 1 鸿蒙 NDK 是否允许应用自带 libjvm.so 并 dlopen（有无白名单/签名限制）
 2 ALLOW_EXECUTABLE 权限的申请门槛（是否只给 JSVM，还是任意原生代码都能要）
 3 XComponent + EGL 的多线程渲染是否有额外限制（论坛提到要独立渲染线程）
 4 MobileGlues 在 OHOS 上编译需要哪些适配（它依赖 dlopen 宿主 libEGL，鸿蒙的 libEGL 名字/路径不同）
 5 鸿蒙对 .so 的符号可见性与 iOS 的 flat namespace 差异（我们踩过的符号互抢问题会重演）
```
