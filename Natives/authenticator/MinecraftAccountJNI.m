#import "BaseAuthenticator.h"
#include "jni.h"

JNIEXPORT jstring JNICALL Java_net_kdt_pojavlaunch_value_MinecraftAccount_getAccessTokenFromKeychain(JNIEnv *env, jclass clazz, jstring xuid) {
    // This function should only be called once
    static BOOL called = NO;
    if (called) {
        // ★ [DEMINE] 原为 abort()：一旦该 JNI 被第二次调用(重复登录 / 多账号 token
        //   刷新)，整个进程立即死。下面只是再次查 keychain，幂等 ⇒ 降级为记日志并继续。
        NSLog(@"[DEMINE] getAccessTokenFromKeychain called more than once; continuing (previously aborted)");
    }
    called = YES;

    const char *xuidC = (*env)->GetStringUTFChars(env, xuid, 0);
    NSString *accessToken = [NSClassFromString(@"MicrosoftAuthenticator") tokenDataOfProfile:@(xuidC)][@"accessToken"];
    (*env)->ReleaseStringUTFChars(env, xuid, xuidC);
    // ★ [DEMINE] 原直接把 accessToken.UTF8String 交给 NewStringUTF；MicrosoftAuthenticator
    //   类缺失 / 无 token 时为 NULL ⇒ NewStringUTF(NULL) 属未定义行为(可能崩)。空串兜底。
    if (accessToken.length == 0) {
        NSLog(@"[DEMINE] getAccessTokenFromKeychain: no access token available; returning empty string");
        return (*env)->NewStringUTF(env, "");
    }
    return (*env)->NewStringUTF(env, accessToken.UTF8String);
}
