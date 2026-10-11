//
//  A2JVMContext.h
//  Air2
//
//  Natives/Context —— JVM 创建 / 销毁（dlopen libjvm + JNI_CreateJavaVM）。
//
//  职责边界（见 docs/ARCHITECTURE.md「Natives/ » Context/ = JVM 创建/销毁、
//  类加载器、线程组」）：
//    · 只负责「加载 libjvm 动态库 → 调 JNI_CreateJavaVM → 持有 JavaVM*/JNIEnv*
//      → 关闭」。★同进程内★完成：不经 libjli / 不调 JLI_Launch / 不 posix_spawn。
//    · ★不嵌业务★：不选版本、不拼 classpath、不读账号；javaHome 与启动选项由上层
//      （Player → Core）解析后经 A2JVMConfig 传入。javaHome 内 libjvm 的相对布局
//      探测属「JVM 生命周期」范畴，留在本层。
//    · ★门禁不在此★：建 VM 之前的 JIT 可用性由 Natives/Support 的 A2JITEnvironment
//      负责；本层只暴露创建/销毁，是否调用由上层编排决定（见 Air2/Player/A2LaunchChain）。
//
//  来源（可追溯，逐条搬运自 feat/runtime-native）：
//    · Natives/runtime/jni_boot.m L154–L218（R1 libjvm 布局探测 rt_libjvmIn/rt_resolve_libjvm）
//    · Natives/runtime/jni_boot.m L147–L148（JNI_CreateJavaVM 函数指针类型）
//    · Natives/runtime/jni_boot.m L224–L375（R2 VMLoader：dlopen/dlsym/选项/版本自适应/GetVersion）
//    · Natives/runtime/rt_p0.h L24–L28（对外入口形态）
//    · 报告：D:\CTF\_RT_P0.md §1.2
//
//  ★不移植★：libjvm 的「候选顺序」（用户偏好 / App 内置 java_runtimes / POJAV_HOME /
//  JAVA_HOME）——那是路径与业务决策，属上层（Core/Path）；本层只接受已解析好的 javaHome。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 创建阶段码（对齐 jni_boot.m L382–L393 的 rt_stage_reason；供上层失败提示与日志分流）。
typedef NS_ENUM(NSInteger, A2JVMStage) {
    A2JVMStageOK             = 0,  ///< 成功
    A2JVMStageNoLibjvm       = 1,  ///< javaHome 内找不到 libjvm.dylib（无可用 JRE）
    A2JVMStageDlopenFailed   = 2,  ///< dlopen(libjvm) 失败
    A2JVMStageDlsymFailed    = 3,  ///< dlsym(JNI_CreateJavaVM) 失败
    A2JVMStageCreateVMFailed = 4,  ///< JNI_CreateJavaVM 失败（rc=JNI_ERR，多为 JIT/内存）
};

/**
 * JVM 创建参数 —— ★只放「已解析好的值」★，本层不再做版本/账号等业务判断。
 */
@interface A2JVMConfig : NSObject

/// JRE home（其内应为 lib/server/libjvm.dylib）。必填。
@property (nonatomic, copy) NSString *javaHome;

/// classpath。为空串表示依赖 DefineClass/引导加载（PoC 默认）。
@property (nonatomic, copy, nullable) NSString *classPath;

/// 是否启用 -XX:+MirrorMappedCodeCache（iOS26+ Universal：code cache 由调试器代映射）。
/// Java 8 的 VM 不识别该选项，须置 isJava8=YES 以跳过。
@property (nonatomic, assign) BOOL useMirrorMappedCodeCache;

/// 是否 Java 8 布局（<home>/lib/jli/libjli.dylib 存在）。Java 8 跳过 CodeCache 尺寸与 Mirror 选项。
@property (nonatomic, assign) BOOL isJava8;

/// CodeCache 尺寸（MB；对齐 JavaLauncher 的 64/16/4，避免 256m 镜像区越界 SIGBUS）。
@property (nonatomic, assign) unsigned long long reservedCodeCacheSizeMB;
@property (nonatomic, assign) unsigned long long initialCodeCacheSizeMB;
@property (nonatomic, assign) unsigned long long codeCacheExpansionSizeMB;

/// 额外 -D/-XX 选项（已解析；按需追加）。可为 nil。
@property (nonatomic, copy, nullable) NSArray<NSString *> *extraOptions;

/// 以 javaHome 构造；尺寸取工程默认（64/16/4），useMirrorMappedCodeCache=NO。
+ (instancetype)configWithJavaHome:(NSString *)javaHome;

@end

/**
 * 已创建的 JVM 上下文。持有 JavaVM* / JNIEnv*，负责生命周期。
 *
 * ★PoC 语义（不变）★：成功创建后【不】自动 DestroyJavaVM —— 保持 VM 存活，避免与
 * 后续阶段的重复创建（对齐 jni_boot.m L373）。销毁只由 -destroy 显式触发。
 */
@interface A2JVMContext : NSObject

/// JavaVM*（对上层以 void* 暴露，避免外部依赖 <jni.h>）。失败为 NULL。
@property (nonatomic, readonly, nullable) void *vm;

/// JNIEnv*（当前线程）。失败为 NULL。
@property (nonatomic, readonly, nullable) void *env;

/// GetVersion 返回的实际 JNI 版本（0x00010008 等）。失败为 0。
@property (nonatomic, readonly) int actualJNIVersion;

/// 实际加载的 libjvm.dylib 绝对路径。
@property (nonatomic, readonly, copy) NSString *libjvmPath;

/// 创建阶段码。
@property (nonatomic, readonly) A2JVMStage stage;

/**
 * 创建 JVM。同进程内 dlopen(libjvm) → dlsym(JNI_CreateJavaVM) → 拼最小 JavaVMInitArgs
 * → JNI_CreateJavaVM（版本自适应：1.8 → 9 → 10 → 21）。
 *
 * @param config    已解析的创建参数。
 * @param stageOut  可为 NULL；失败时回填阶段码。
 * @param reasonOut 可为 NULL；回填可读原因。
 * @return 成功返回实例；失败返回 nil。
 */
+ (nullable instancetype)createWithConfig:(A2JVMConfig *)config
                                    stage:(A2JVMStage *_Nullable)stageOut
                                   reason:(NSString *_Nullable *_Nullable)reasonOut;

/// 销毁 VM（DestroyJavaVM + dlclose）。幂等。
- (void)destroy;

@end

/// 在 javaHome 内定位 libjvm.dylib（兼容 11+/JDK8/hotspot 三种布局）。
/// 来源：jni_boot.m L157–L170。
FOUNDATION_EXPORT NSString *_Nullable a2_jvm_locate_libjvm(NSString *javaHome);

NS_ASSUME_NONNULL_END
