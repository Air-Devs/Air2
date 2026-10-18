//
//  AiCrashAnalyzer.m
//  Amethyst
//

#import "AiCrashAnalyzer.h"

@implementation AiCrashAnalyzer

- (NSString *)name {
    return @"match_known_errors";
}

- (AiToolPermission)permission {
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    return @"分析日志或崩溃报告，识别已知错误类型并给出通俗的解释与修复建议。"
           "\n参数（二选一）："
           "\n  - log（string，可选）：启动日志全文（通常来自 read_latest_log）。"
           "\n  - crashReport（string，可选）：崩溃报告全文（通常来自 read_crash_report）。"
           "\n至少提供一个入参。返回 JSON：{matched, category, explanation, suggestions}。"
           "\ncategory 取值：内存不足 / JNI 初始化失败 / 图形初始化失败 / Java 版本不符 / 数值越界 / "
           "iOS-妙控键盘崩溃 / iOS-MC 26.2 OpenGL 语法错误 / iOS-MC 26.3-Snapshot4 启动失败（SDL3） / "
           "iOS-启动器自身闪退 / iOS-LWJGL 魔改兼容问题 / iOS-启动黑屏/直接闪退（JIT） / 未知。"
           "\n边界：仅内置规则匹配，不承诺 100% 命中；未命中时给出通用排查建议。";
}

/// 单个匹配规则：catgeory + alternatives（每组 alt 的关键词需全部命中才算该 alt 匹配）
- (NSArray<NSDictionary *> *)ruleTable {
    return @[
        @{
            @"category": @"内存不足",
            @"alternatives": @[
                @[@"OutOfMemoryError"],
            ],
            @"explanation": @"这就像你每个月的工资就那么多，却要同时付房租、水电和零食钱，最后余额见底了。"
                            "游戏的内存（可用空间）不够用，Java 想再申请内存时被系统拒绝，于是崩溃。",
            @"suggestions": @[
                @"在启动器设置中调大游戏分配内存（Java 参数里的 -Xmx，让「工资」多起来）。",
                @"关闭或减少已安装的模组、光影包，减轻「房租压力」。",
                @"若修改内存也不行，尝试降低渲染距离、关闭光影。",
            ],
        },
        @{
            @"category": @"JNI 初始化失败",
            @"alternatives": @[
                @[@"Failed to initialize JNI", @"META-INF"],
                @[@"java.lang.UnsatisfiedLinkError"],
            ],
            @"explanation": @"JNI 就像你的「签证」，负责让游戏（Java）和本机核心库之间通行。"
                            "如果签证过期或证件不齐（原生库缺失/版本不对），Java 就放行不了，启动直接失败。",
            @"suggestions": @[
                @"重新安装/重下游戏本体，让核心库完整落盘。",
                @"确认使用的是完整版 Java 运行时（不要用精简版）。",
                @"若字库损坏，删除该版本后重新安装对应版本。",
            ],
        },
        @{
            @"category": @"图形初始化失败",
            @"alternatives": @[
                @[@"OpenGL", @"GLFW error"],
                @[@"GLX"],
            ],
            @"explanation": @"就像司机拿着 B 照却要开大货车，发现驾照不对口。"
                            "游戏想用图形接口（OpenGL/GLFW/GLX）初始化显示，但当前渲染器支持不完整或驱动不兼容。",
            @"suggestions": @[
                @"在启动器设置中切换到其它渲染器（如 MobileGlues / GL4ES / Auto）。",
                @"更新启动器或游戏到较新版本，或降低 OpenGL 版本要求。",
                @"在设置里重置/恢复默认渲染配置后再试。",
            ],
        },
        @{
            @"category": @"Java 版本不符",
            @"alternatives": @[
                @[@"Unsupported Java version"],
                @[@"Java 8"],
            ],
            @"explanation": @"就像用普通话跟只会说方言的人聊天，鸡同鸭讲。"
                            "这个游戏版本要求的 Java 与启动器当前给它的 Java 不匹配，导致无法启动。",
            @"suggestions": @[
                @"在启动器版本管理里确认该游戏版本要求的 Java 版本，安装对应的 Java（8/17/21 等）。",
                @"使用启动器推荐的自动选择 Java 版本的选项。",
            ],
        },
        @{
            @"category": @"数值越界",
            @"alternatives": @[
                @[@"Zombie"],
                @[@"invalid range"],
            ],
            @"explanation": @"就像往只有 3 个抽屉的柜子塞 5 个盒子，数字对不上号。"
                            "某个数值（版本/索引/范围）超出了合法区间，通常是配置文件被损坏或版本号不匹配导致。",
            @"suggestions": @[
                @"删除/重置该实例的相关配置文件后重新创建。",
                @"重新安装该游戏版本，避免混用损坏的旧配置。",
            ],
        },
        // ===== iOS 环境已知错误（enhance-ai-agent Task 17）=====
        @{
            @"category": @"iOS-妙控键盘崩溃",
            @"alternatives": @[
                @[@"Magic Keyboard", @"crash"],
                @[@"妙控键盘"],
            ],
            @"explanation": @"这是 iOS 平台点击妙控键盘（Magic Keyboard）触发的已知崩溃，开发者已知晓该问题。",
            @"suggestions": @[
                @"开发者已知该问题，请耐心等待开发者修复。",
                @"修复前尽量避免连接/点击妙控键盘，或改用触屏与虚拟键盘操作。",
            ],
        },
        @{
            @"category": @"iOS-MC 26.2 OpenGL 语法错误",
            @"alternatives": @[
                @[@"26.2", @"OpenGL", @"syntax"],
                @[@"GL_INVALID_OPERATION", @"syntax error"],
            ],
            @"explanation": @"Minecraft 26.2 在 iOS 渲染层触发了 OpenGL 语法错误，是当前渲染器与该版本的兼容性问题。",
            @"suggestions": @[
                @"把该实例的渲染器切换为 MoltenVK（set_setting：key=video.renderer, value=MoltenVK）。",
                @"切换渲染器后重新启动游戏验证。",
            ],
        },
        @{
            @"category": @"iOS-MC 26.3-Snapshot4 启动失败（SDL3）",
            @"alternatives": @[
                @[@"26.3-Snapshot4"],
                @[@"SDL3"],
            ],
            @"explanation": @"Mojang 在 26.3-Snapshot4 把渲染库从 LWJGL 改为 SDL3，iOS 端暂未实现对应支持，因此无法启动。",
            @"suggestions": @[
                @"目前无解，建议换用其它 Minecraft 版本（如 26.2 或更早的正式版）。",
            ],
        },
        @{
            @"category": @"iOS-启动器自身闪退",
            @"alternatives": @[
                @[@"启动器", @"闪退"],
                @[@"launcher", @"SIGKILL"],
            ],
            @"explanation": @"启动器自身发生了闪退（而非游戏崩溃），需要开发者介入排查。",
            @"suggestions": @[
                @"通过 GitHub Issues 或官方 QQ 群（966475918）上报该问题，附上 latestlog.txt。",
                @"开发者一般在法定节假日集中修复此类问题。",
            ],
        },
        @{
            @"category": @"iOS-LWJGL 魔改兼容问题",
            @"alternatives": @[
                @[@"LWJGL", @"UnsatisfiedLinkError"],
                @[@"LWJGL", @"no such function"],
                @[@"LWJGL", @"NoSuchMethodError"],
            ],
            @"explanation": @"5.0.0 公测起开发者魔改了 LWJGL 3.3.3 以适配 Minecraft 26.2（含部分 3.4.1 特性），"
                            "这可能导致部分旧版本游戏无法启动。",
            @"suggestions": @[
                @"确认游戏版本与 LWJGL 版本的兼容性（旧版本游戏建议用对应旧版实例配置）。",
                @"通过 GitHub Issues 或官方 QQ 群（966475918）反馈具体版本组合。",
            ],
        },
        @{
            @"category": @"iOS-启动黑屏/直接闪退（JIT）",
            @"alternatives": @[
                @[@"JIT", @"SIGSEGV"],
                @[@"JIT", @"SIGTRAP"],
                @[@"ptrace", @"debugged"],
            ],
            @"explanation": @"属于 JIT（即时编译）未正确开启导致的问题：启动后黑屏或直接闪退。",
            @"suggestions": @[
                @"建议换用 StikDebug 或 LiveContainer 开启 JIT 后再启动游戏。",
                @"开发者已知晓该问题，等待后续修复。",
            ],
        },
    ];
}

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    NSString *log = params[@"log"];
    NSString *crash = params[@"crashReport"];
    if (![log isKindOfClass:[NSString class]]) log = nil;
    if (![crash isKindOfClass:[NSString class]]) crash = nil;

    if (log.length == 0 && crash.length == 0) {
        NSError *err = [NSError errorWithDomain:@"AiTool" code:400
                                       userInfo:@{NSLocalizedDescriptionKey: @"参数 log 与 crashReport 至少提供一个"}];
        completion(nil, err);
        return;
    }

    NSString *combined = [NSString stringWithFormat:@"%@\n%@", (log ?: @""), (crash ?: @"")];

    // 内置规则匹配
    NSDictionary *matchedResult = nil;
    for (NSDictionary *rule in [self ruleTable]) {
        BOOL ruleMatched = NO;
        for (NSArray *alternative in rule[@"alternatives"]) {
            BOOL allHit = YES;
            for (NSString *keyword in alternative) {
                if ([combined rangeOfString:keyword options:NSCaseInsensitiveSearch].location == NSNotFound) {
                    allHit = NO;
                    break;
                }
            }
            if (allHit) { ruleMatched = YES; break; }
        }
        if (ruleMatched) {
            matchedResult = @{
                @"matched": @YES,
                @"category": rule[@"category"],
                @"explanation": rule[@"explanation"],
                @"suggestions": rule[@"suggestions"],
            };
            break;
        }
    }

    if (!matchedResult) {
        matchedResult = @{
            @"matched": @NO,
            @"category": @"未知",
            @"explanation": @"没有匹配到已知错误类型，无法直接定位原因。",
            @"suggestions": @[
                @"再尝试启动一次，观察是否必现。",
                @"把完整日志或导出的崩溃报告发给社区/开发者在论坛反馈。",
                @"临时关闭模组和光影，逐个排查是否为某个资源导致。",
            ],
        };
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:matchedResult options:0 error:nil];
    NSString *resultJSON = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    completion(resultJSON, nil);
}

@end