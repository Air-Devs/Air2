#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <jni.h>
#import "A2MemoryPressure.h"
#import "a2_log.h"

// 两次回收之间的最小间隔：大整合包一次 full GC 会停顿约 1 秒，
// 太频繁本身就是另一种卡顿。
static const NSTimeInterval kA2MinInterval = 6.0;
// 连续几轮几乎没回收出东西 ⇒ 堆里基本都是活对象，退避，不再反复停顿。
static const NSTimeInterval kA2BackoffInterval = 45.0;
// 回收比例低于这个值就算"不值得再来一次"。
static const double kA2WorthwhileFraction = 0.03;

static void *sA2JavaVM = NULL;

static dispatch_queue_t a2_mem_queue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("dev.airdevs.air2.memory-relief", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

/// 让 Java 侧做一次 full GC，并回报回收量。
/// 跑在 relief 队列上，绝不在渲染线程；线程以 daemon 方式 attach，
/// 即使比游戏活得久也不会拖住 JVM 关闭。
static BOOL a2_mem_full_gc(long long *outReclaimed, long long *outMaxHeap) {
    JavaVM *vm = (JavaVM *)sA2JavaVM;
    if (vm == NULL) return NO;

    JNIEnv *env = NULL;
    BOOL attachedHere = NO;
    jint st = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_4);
    if (st == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThreadAsDaemon(vm, &env, NULL) != JNI_OK || env == NULL) return NO;
        attachedHere = YES;
    } else if (st != JNI_OK || env == NULL) {
        return NO;
    }

    BOOL ok = NO;
    if ((*env)->PushLocalFrame(env, 8) == JNI_OK) {
        jclass rt = (*env)->FindClass(env, "java/lang/Runtime");
        jmethodID getRuntime = rt ? (*env)->GetStaticMethodID(env, rt, "getRuntime", "()Ljava/lang/Runtime;") : NULL;
        jmethodID totalMemory = rt ? (*env)->GetMethodID(env, rt, "totalMemory", "()J") : NULL;
        jmethodID freeMemory  = rt ? (*env)->GetMethodID(env, rt, "freeMemory", "()J") : NULL;
        jmethodID maxMemory   = rt ? (*env)->GetMethodID(env, rt, "maxMemory", "()J") : NULL;
        jmethodID gc          = rt ? (*env)->GetMethodID(env, rt, "gc", "()V") : NULL;

        jobject runtime = getRuntime ? (*env)->CallStaticObjectMethod(env, rt, getRuntime) : NULL;
        if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); runtime = NULL; }

        if (runtime != NULL && totalMemory && freeMemory && maxMemory && gc) {
            long long usedBefore = (long long)((*env)->CallLongMethod(env, runtime, totalMemory) -
                                               (*env)->CallLongMethod(env, runtime, freeMemory));
            long long limit = (long long)(*env)->CallLongMethod(env, runtime, maxMemory);

            (*env)->CallVoidMethod(env, runtime, gc);
            if ((*env)->ExceptionCheck(env)) {
                (*env)->ExceptionClear(env);
            } else {
                long long usedAfter = (long long)((*env)->CallLongMethod(env, runtime, totalMemory) -
                                                  (*env)->CallLongMethod(env, runtime, freeMemory));
                long long reclaimed = usedBefore - usedAfter;
                if (reclaimed < 0) reclaimed = 0;

                a2_log_f(@"[A2-MEMREL] iOS 内存压力：Java 堆 %lldMB → %lldMB / %lldMB（归还 %lldMB）",
                         usedBefore >> 20, usedAfter >> 20, limit >> 20, reclaimed >> 20);

                if (outReclaimed) *outReclaimed = reclaimed;
                if (outMaxHeap) *outMaxHeap = limit;
                ok = YES;
            }
        }
        (*env)->PopLocalFrame(env, NULL);
    }

    if (attachedHere) (*vm)->DetachCurrentThread(vm);
    return ok;
}

void a2_mem_note_vm(void *vm) {
    sA2JavaVM = vm;
}

void a2_mem_start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *note) {
            if (sA2JavaVM == NULL) return;
            dispatch_async(a2_mem_queue(), ^{
                static NSTimeInterval lastRunAt = 0;
                static NSTimeInterval nextGap = kA2MinInterval;
                NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
                if (lastRunAt > 0 && (now - lastRunAt) < nextGap) return;
                lastRunAt = now;

                long long reclaimed = 0, maxHeap = 0;
                if (a2_mem_full_gc(&reclaimed, &maxHeap) && maxHeap > 0) {
                    double frac = (double)reclaimed / (double)maxHeap;
                    nextGap = (frac < kA2WorthwhileFraction) ? kA2BackoffInterval : kA2MinInterval;
                }
            });
        }];
        a2_log_criterion(@"[A2-MEMREL] 已开始监听 iOS 内存压力通知");
    });
}
