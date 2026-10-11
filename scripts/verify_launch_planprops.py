#!/usr/bin/env python3
"""
Air2 —— 「启动计划运行时事实」自证（Java 消费端 ↔ ObjC 产出端 的 ABI 对齐 + 接线）

本单要修死的硬卡点：复用线覆盖层 GLFW.java 的**静态块**直接读两个 JVM 系统属性
    GLFW.java:538  System.getProperty("glfw.windowSize").split("x")
    GLFW.java:557  Integer.parseInt(System.getProperty("UIScreen.maximumFramesPerSecond"))
全仓没人设置 ⇒ 真机在装载 GLFW 类时先 NPE（null.split("x")）⇒ 走不到任何 native 符号。

本脚本不测「能不能编译」（那是 xcodebuild 的事），只把这条链上**机器可复核**的
不变量固化成断言，防止日后有人改了其中一头而另一头没跟上：

  [1] 消费端（Java 覆盖层）真的这样读、且格式就是「十进制x十进制」/「十进制整数」
  [2] 产出端（Utils 契约常量）的字面量与之★逐字相同★
  [3] 计划（Core）把运行时事实落成 VM 级 -D，且★拿不到真值就不下发★
  [4] 值对象（Utils）的 "WxH" 格式：小写 x 分隔
  [5] 接线顺序：Player 在产出计划【之前】经 Bridge 采集（否则晚于类装载，赶不上）
  [6] 真来源（Bridge）：UIScreen.mainScreen.maximumFramesPerSecond + 宿主窗口像素尺寸
  [7] 阴性对照：启动链上不得出现「猜的默认值」（1280x720 / =60 之类兜底）

退出码：0 = 全部通过；1 = 有 FAIL。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

GLFW_JAVA = os.path.join(ROOT, "JavaApp", "src", "lwjgl", "org", "lwjgl", "glfw", "GLFW.java")
CONTRACT_H = os.path.join(ROOT, "Air2", "Utils", "A2LaunchContract.h")
CONTRACT_M = os.path.join(ROOT, "Air2", "Utils", "A2LaunchContract.m")
FACTS_M = os.path.join(ROOT, "Air2", "Utils", "A2LaunchRuntimeFacts.m")
PLAN_H = os.path.join(ROOT, "Air2", "Core", "Version", "A2LaunchPlan.h")
PLAN_M = os.path.join(ROOT, "Air2", "Core", "Version", "A2LaunchPlan.m")
SESSION_M = os.path.join(ROOT, "Air2", "Player", "A2LaunchSession.m")
RUNNER_H = os.path.join(ROOT, "Air2", "Bridge", "A2LaunchRunner.h")
RUNNER_M = os.path.join(ROOT, "Air2", "Bridge", "A2LaunchRunner.m")

WINDOW_SIZE_KEY = "glfw.windowSize"
FPS_KEY = "UIScreen.maximumFramesPerSecond"

g_pass = 0
g_fail = 0


def ok(cond, what):
    global g_pass, g_fail
    if cond:
        g_pass += 1
        print(u"      \u2713 %s" % what)
    else:
        g_fail += 1
        print(u"      \u2717 FAIL %s" % what)
    return bool(cond)


def read(path):
    if not os.path.isfile(path):
        return ""
    with open(path, "rb") as f:
        return f.read().decode("utf-8", "replace")


def strip_comments(src):
    """去掉 ObjC 注释 —— 判据只看真代码，注释里提到 UIKit 不算越界。"""
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src = re.sub(r'//[^\n]*', '', src)
    return src


def rel(path):
    return os.path.relpath(path, ROOT).replace("\\", "/")


def main():
    print("Air2 —— 启动计划运行时事实自证（Java 消费端 \u2194 ObjC 产出端）")
    print("=" * 74)

    java = read(GLFW_JAVA)
    contract_h = read(CONTRACT_H)
    contract_m = read(CONTRACT_M)
    facts_m = read(FACTS_M)
    plan_h = read(PLAN_H)
    plan_m = read(PLAN_M)
    session_m = read(SESSION_M)
    runner_h = read(RUNNER_H)
    runner_m = read(RUNNER_M)

    for p, name in ((GLFW_JAVA, "GLFW.java"), (CONTRACT_M, "A2LaunchContract.m"),
                    (FACTS_M, "A2LaunchRuntimeFacts.m"), (PLAN_M, "A2LaunchPlan.m"),
                    (SESSION_M, "A2LaunchSession.m"), (RUNNER_M, "A2LaunchRunner.m")):
        if not read(p):
            print("  [致命] 读不到 %s（%s）" % (name, rel(p)))
            return 1

    # ---------------------------------------------------------------- [1] 消费端
    print("[1] 消费端 = 复用线覆盖层 GLFW.java（静态块）")
    props = set(re.findall(r'System\.getProperty\("([^"]+)"\)', java))
    ok(WINDOW_SIZE_KEY in props, 'Java 侧读 "%s"' % WINDOW_SIZE_KEY)
    ok(FPS_KEY in props, 'Java 侧读 "%s"' % FPS_KEY)
    # 格式契约：windowSize 必须是 split("x")；fps 必须是 Integer.parseInt
    ok(re.search(r'getProperty\("%s"\)\s*\.split\("x"\)' % re.escape(WINDOW_SIZE_KEY), java) is not None,
       'windowSize 的解析方式是 split("x") \u21d2 取值必须是 "<\u5bbdx<\u9ad8>"')
    ok(re.search(r'Integer\.parseInt\(System\.getProperty\("%s"\)\)' % re.escape(FPS_KEY), java) is not None,
       "maximumFramesPerSecond 的解析方式是 Integer.parseInt \u21d2 取值必须是十进制整数")
    # 它是【静态块】里读的：这一条解释了为什么只能走 -D
    m_static = re.search(r'static\s*\{(.*?)\n    \}', java, re.S)
    ok(m_static is not None and WINDOW_SIZE_KEY in m_static.group(1),
       "\u2605 两处读取都在 GLFW 类的【静态块】里（\u21d2 必须早于任何类初始化 \u21d2 只能 -D）")

    # ---------------------------------------------------------------- [2] 产出端字面量
    print("[2] 产出端 = Utils 契约常量（\u2605字面量必须与 Java 逐字相同\u2605）")
    ok(re.search(r'A2LaunchSysPropGLFWWindowSize\s*=\s*@"%s"' % re.escape(WINDOW_SIZE_KEY), contract_m) is not None,
       'A2LaunchContract.m 定义 A2LaunchSysPropGLFWWindowSize = "%s"' % WINDOW_SIZE_KEY)
    ok(re.search(r'A2LaunchSysPropMaximumFramesPerSecond\s*=\s*@"%s"' % re.escape(FPS_KEY), contract_m) is not None,
       'A2LaunchContract.m 定义 A2LaunchSysPropMaximumFramesPerSecond = "%s"' % FPS_KEY)
    ok(contract_h.count("A2LaunchSysPropGLFWWindowSize") >= 1 and
       contract_h.count("A2LaunchSysPropMaximumFramesPerSecond") >= 1,
       "头文件里两个常量都声明了（FOUNDATION_EXPORT）")

    # ---------------------------------------------------------------- [3] 计划落 -D
    print("[3] 计划（Core）把运行时事实落成 VM 级 -D，拿不到就不下发")
    ok(re.search(r'jvmOptionsWithMemoryMB', plan_h) is not None, "计划仍产出 VM 级选项")
    ok("runtimeFacts" in plan_h and "runtimeFacts" in plan_m, "计划有 runtimeFacts 字段（头/实现都声明）")
    ok(re.search(r'plan\.runtimeFacts\s*=\s*runtimeFacts\s*;', plan_m) is not None,
       "产出时把 runtimeFacts 原样收进计划")
    ok(re.search(r'-D%@=%@', plan_m) is not None and "A2LaunchSysPropGLFWWindowSize" in plan_m,
       '窗口尺寸经 "-D%@=%@" 用契约常量拼出')
    ok("A2LaunchSysPropMaximumFramesPerSecond" in plan_m, "帧率同理（用契约常量）")
    # ★不写猜的值★：两处都必须在「有值」的 if 里
    ok(re.search(r'if\s*\(windowSizeValue\.length\s*>\s*0\)\s*\{[^}]*A2LaunchSysPropGLFWWindowSize',
                 plan_m, re.S) is not None,
       '\u2605窗口尺寸没有真值（nil）时【不下发】-D（在 if 长度>0 里）')
    ok(re.search(r'if\s*\(facts\.hasMaximumFramesPerSecond\)\s*\{[^}]*A2LaunchSysPropMaximumFramesPerSecond',
                 plan_m, re.S) is not None,
       '\u2605帧率没有真值（\u22640）时【不下发】-D（在 if hasMaximumFramesPerSecond 里）')

    # ---------------------------------------------------------------- [4] 值对象格式
    print("[4] 值对象（Utils）的格式实现")
    ok(re.search(r'hasSurfaceSize', facts_m) is not None and
       re.search(r'hasMaximumFramesPerSecond', facts_m) is not None, "两个\u300c有没有取到\u300d的判据都在")
    ok(re.search(r'@?"%ldx%ld"', facts_m) is not None,
       'glfwWindowSizeValue 用 "%ldx%ld"（\u2605小写 x，对齐 split("x")\u2605）')
    ok(re.search(r'if\s*\(!self\.hasSurfaceSize\)\s*\{\s*return nil;', facts_m, re.S) is not None,
       "没取到表面尺寸 \u21d2 返回 nil（不是空串、不是 0x0）")

    # ---------------------------------------------------------------- [5] 接线顺序
    print("[5] 接线：Player 在产出计划【之前】经 Bridge 采集")
    i_facts = session_m.find("currentRuntimeFacts")
    i_plan = session_m.find("planForVersionDirectory:")
    ok(i_facts >= 0, "A2LaunchSession.m 调用了 [A2LaunchRunner currentRuntimeFacts]")
    ok(i_plan >= 0, "A2LaunchSession.m 调用了计划产出 API")
    ok(0 <= i_facts < i_plan, "\u2605采集在计划产出【之前】（否则赶不上 GLFW 的静态块）")
    ok(re.search(r'planForVersionDirectory:.*?runtimeFacts:runtimeFacts', session_m, re.S) is not None,
       "采集结果作为 runtimeFacts: 传进计划")
    ok("#import" in session_m and "A2LaunchRunner.h" in session_m,
       "Player 经 Bridge（A2LaunchRunner）取值 \u2014\u2014 不自己读 UIKit")
    session_code = strip_comments(session_m)
    ok("UIKit" not in session_code and "UIScreen" not in session_code,
       "\u2605 Player 代码里不出现 UIKit/UIScreen（分层：Player 不感知 UIKit）\u2605")

    # ---------------------------------------------------------------- [6] 真来源
    print("[6] 真来源（Bridge 的 +currentRuntimeFacts）")
    ok("+ (A2LaunchRuntimeFacts *)currentRuntimeFacts" in runner_h and
       "+ (A2LaunchRuntimeFacts *)currentRuntimeFacts" in runner_m, "接口与实现都在")
    ok("UIScreen.mainScreen.maximumFramesPerSecond" in runner_m,
       "\u2605帧率取 UIScreen.mainScreen.maximumFramesPerSecond（系统真实值）\u2605")
    ok(re.search(r'screen\.scale', runner_m) is not None and
       re.search(r'lround\(b\.size\.width\s*\*\s*scale\)', runner_m) is not None,
       "表面像素尺寸 = 宿主窗口 bounds \u00d7 屏幕 scale（与老树同口径）")
    ok("bounds" in runner_m, "窗口尺寸取自窗口 bounds（不是写死的常量）")

    # ---------------------------------------------------------------- [7] 阴性对照
    print("[7] 阴性对照：启动链上不得出现\u300c猜的默认值\u300d")
    hard_1280 = re.findall(r'1280\s*x\s*720|"1280x720"', plan_m + session_m + runner_m + facts_m)
    ok(len(hard_1280) == 0, "启动链（计划/会话/采集/值对象）里没有写死的 1280x720")
    # 帧率不得有「取不到就给 60」这种兜底
    fallback60 = re.findall(r'\?\s*:\s*60|=\s*60\s*;', runner_m)
    ok(len(fallback60) == 0, "\u2605采集里没有\u300c取不到就给 60\u300d的兜底\u2605")
    # 计划里不得对帧率写死数字
    ok(re.search(r'hasMaximumFramesPerSecond', plan_m) is not None,
       "计划对帧率的判据是 hasMaximumFramesPerSecond（不是写死 60）")

    print("=" * 74)
    print("pass=%d fail=%d" % (g_pass, g_fail))
    if g_fail:
        print("\u7ed3\u679c\uff1a\u6709 FAIL")
        return 1
    print("\u7ed3\u679c\uff1a\u5168\u90e8\u901a\u8fc7 \u2713")
    return 0


if __name__ == "__main__":
    sys.exit(main())
