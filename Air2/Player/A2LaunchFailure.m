//
//  A2LaunchFailure.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  ★只有 switch + 查表，无任何平台调用★（因此可被 tests/JIT 直接编译运行）。
//

#import "A2LaunchFailure.h"
#import "A2JITVerdictGuidance.h"
#import "A2JITStrings.h"

@implementation A2LaunchFailure

+ (A2LaunchFailureClass)classForChainStage:(A2LaunchChainStage)stage {
    switch (stage) {
        case A2LaunchChainStageScript:
        case A2LaunchChainStageVerify:
            // ① 不拦路 ⇒ 只可能停在 ②（探测不合格）。
            return A2LaunchFailureClassJITBlocked;
        case A2LaunchChainStageCreateVM:
            return A2LaunchFailureClassVMFailed;
        case A2LaunchChainStageIdle:
        case A2LaunchChainStageDone:
        default:
            return A2LaunchFailureClassNone;
    }
}

+ (NSString *)diagnosticTagForClass:(A2LaunchFailureClass)cls {
    switch (cls) {
        case A2LaunchFailureClassNone:        return @"none";
        case A2LaunchFailureClassSwitchOff:   return @"switch-off";
        case A2LaunchFailureClassMissingInput:return @"missing-input";
        case A2LaunchFailureClassJITBlocked:  return @"jit-blocked";
        case A2LaunchFailureClassVMFailed:    return @"vm-failed";
    }
    return @"unknown";
}

+ (NSString *)diagnosticForJITVerdict:(A2JITReadinessVerdict)verdict
                             evidence:(nullable NSString *)evidence {
    return [NSString stringWithFormat:
            @"[A2-CHAIN] ② JIT 不可用 ⇒ 已阻止创建 VM（class=%@ verdict=%@(%ld) 判据=%@ 取证=%@）",
            [self diagnosticTagForClass:A2LaunchFailureClassJITBlocked],
            [A2JITVerdictGuidance displayNameForVerdict:verdict],
            (long)verdict,
            [A2JITVerdictGuidance diagnosticForVerdict:verdict],
            evidence.length ? evidence : @"(无取证)"];
}

+ (NSString *)jitvmLineWithStep:(NSString *)step
                        verdict:(A2JITReadinessVerdict)verdict
                      enableJIT:(BOOL)enable
                     reasonText:(nullable NSString *)reasonText
                       evidence:(nullable NSString *)evidence {
    // reason 缺省 = 本档的稳定短语（7 档互不相同 ⇒ ★未就绪 / 失败 两路文案天然分开★）。
    NSString *reason = reasonText.length ? reasonText : [A2JITVerdictGuidance diagnosticForVerdict:verdict];
    // ★格式串保持纯 ASCII★：这样它在主二进制里是 UTF-8（`strings` 能直接抓到），
    //   不像含中文的 `[A2-CHAIN] …` 那样被 clang 存成 UTF-16（那时须按三编码扫）。
    return [NSString stringWithFormat:
            @"[A2-JITVM] step=%@ verdict=%@(%ld) enable=%d reason=%@ evidence=%@",
            step,
            [A2JITVerdictGuidance displayNameForVerdict:verdict],
            (long)verdict,
            enable ? 1 : 0,
            reason.length ? reason : @"(无)",
            evidence.length ? evidence : @"(无取证)"];
}

+ (NSString *)userMessageForJITVerdict:(A2JITReadinessVerdict)verdict {
    NSString *reason = [A2JITStrings stringForKey:[A2JITVerdictGuidance reasonKeyForVerdict:verdict]];
    NSString *action = [A2JITStrings stringForKey:[A2JITVerdictGuidance actionKeyForVerdict:verdict]];
    return [NSString stringWithFormat:@"② JIT 不可用，已阻止启动（%ld）：%@。下一步：%@",
            (long)verdict, reason ?: @"未知判据", action ?: @"请先启用 JIT"];
}

+ (NSString *)userMessageForVMFailureCode:(NSInteger)rc {
    NSString *why;
    switch (rc) {
        case -1:  why = @"R3 判定 jarMode（须回退旧链）"; break;
        case -2:  why = @"主类为空"; break;
        case -3:  why = @"未找到 libjvm.dylib（无可用 JRE）"; break;
        case -4:  why = @"R2 建 VM 失败（JNI_CreateJavaVM）"; break;
        case -5:
        case -6:
        case -7:  why = @"主类 main 派发失败（FindClass / GetStaticMethodID / 执行抛异常）"; break;
        case -8:  why = @"R3 摄取失败（未解析出主类 / 参数不足）"; break;
        case -9:  why = @"classpath 与 R3 摄取不一致（漂移）⇒ 阻断启动"; break;
        // ★[RENDER-SEL]/[JRE-SEL]：所选渲染后端 / Java 运行时的可用性问题 ⇒ 未进 VM，
        //   由各自调用点在更早一步阻断（这里只负责把码翻译成人话）。
        case -10: why = @"所选渲染器未内置/加载失败 ⇒ 阻断启动（改选已内置的渲染器）"; break;
        case -11: why = @"所选 Java 运行时未内置/不完整 ⇒ 阻断启动（改选已内置的档位）"; break;
        // ★[GL-BRIDGE]：所选后端是 EGL/GL 系但没建出 GL 上下文（缺库/无表面/EGL 失败）。
        //   具体缺什么由 Natives/Renderer/a2_gl_bridge 的 `[A2-GLBRIDGE]` 判据行点名。
        case -12: why = @"所选渲染器是 EGL/GL 系，但未能建出 GL 上下文（缺库/无表面/EGL 失败）⇒ 阻断启动（详见 [A2-GLBRIDGE] 日志）"; break;
        default:  why = [NSString stringWithFormat:@"未知返回码 %ld", (long)rc]; break;
    }
    return [NSString stringWithFormat:@"③ 建 VM 失败 rc=%ld：%@（见 a2_launch.h 契约）",
            (long)rc, why];
}

@end
