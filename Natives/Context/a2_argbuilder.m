// ============================================================================
// Natives/runtime/a2_argbuilder.m
// ★ [RT-P1] R3 —— ArgBuilder（实现）
// 方案：D:\CTF\_RUNTIME_REWRITE_PLAN.md §3.3
//
// ingestArgv 解析规则（旧 margv → 结构化）：
//   argv[0]                      → 丢弃（旧链是 "<javaHome>/bin/java"，VM 侧不需要）
//   "-cp" / "-classpath" <path>  → 折叠进 classpath（吞两个 token）
//   "-Djava.class.path=<cp>"     → 折叠进 classpath（吞一个 token）
//   "-jar"                       → 记 jarMode=YES 并丢弃
//   其它 "-" 开头                 → 原始选项（保序；-D 按 key 去重）
//   首个非 "-" 开头 token         → 主类
//   主类之后的全部 token          → 程序参数（顺序保持）
// ============================================================================
#import "a2_argbuilder.h"

#include <stdlib.h>
#include <string.h>

A2ClasspathForm a2_classpath_form_from_name(NSString *name) {
    if ([name isEqualToString:@"option"] || [name isEqualToString:@"b"] ||
        [name isEqualToString:@"B"] || [name isEqualToString:@"1"]) {
        return A2ClasspathFormOption;
    }
    return A2ClasspathFormProperty;
}

// ============================================================================
// A2VMArgsBundle —— JavaVMInitArgs 的稳定存储
// ============================================================================
@implementation A2VMArgsBundle {
    JavaVMInitArgs _args;
    JavaVMOption  *_opts;
    char         **_strs;
    int            _n;
}

- (instancetype)initWithOptionStrings:(NSArray<NSString *> *)opts
                               version:(jint)version
                    ignoreUnrecognized:(BOOL)ignoreUnrecognized {
    self = [super init];
    if (!self) return nil;

    _n = (int)opts.count;
    if (_n > 0) {
        _opts = (JavaVMOption *)calloc((size_t)_n, sizeof(JavaVMOption));
        _strs = (char **)calloc((size_t)_n, sizeof(char *));
    }
    for (int i = 0; i < _n; i++) {
        const char *s = opts[i].UTF8String;
        _strs[i] = strdup(s ? s : "");
        _opts[i].optionString = _strs[i];
        _opts[i].extraInfo    = NULL;
    }
    memset(&_args, 0, sizeof(_args));
    _args.version            = version;
    _args.nOptions           = _n;
    _args.options            = _opts;
    _args.ignoreUnrecognized = ignoreUnrecognized ? JNI_TRUE : JNI_FALSE;
    return self;
}

- (JavaVMInitArgs)initArgs {
    return _args;
}

- (const char *const *)optionStrings {
    return (const char *const *)_strs;
}

- (int)optionCount {
    return _n;
}

- (void)dealloc {
    if (_strs) {
        for (int i = 0; i < _n; i++) free(_strs[i]);
        free(_strs);
    }
    if (_opts) free(_opts);
}

@end

// ============================================================================
// A2ArgBuilder
// ============================================================================
@implementation A2ArgBuilder {
    NSMutableArray<NSString *> *_options;                  // 原始选项（保序）
    NSMutableDictionary<NSString *, NSNumber *> *_propIdx; // -D<key> → _options 下标（去重）
    NSMutableArray<NSString *> *_programArgs;
    NSString *_classpath;
    NSString *_mainClass;
    BOOL      _jarMode;
}

+ (instancetype)builder {
    return [[self alloc] init];
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _options       = [NSMutableArray array];
    _propIdx       = [NSMutableDictionary dictionary];
    _programArgs   = [NSMutableArray array];
    _classpathForm = A2ClasspathFormProperty;   // 默认 A；B 由调用方显式设置
    return self;
}

- (void)addRawOption:(NSString *)option {
    if (option.length == 0) return;

    // -D<key>=<value>：按 key 去重（后到者覆盖值、位置不变）——保证 R4 注入与旧 margv 同名 -D
    // 重复注入时结果稳定（单一真相源不被破坏）。
    if ([option hasPrefix:@"-D"]) {
        NSString *kv = [option substringFromIndex:2];
        NSRange eq = [kv rangeOfString:@"="];
        NSString *key = (eq.location == NSNotFound) ? kv : [kv substringToIndex:eq.location];
        if (key.length > 0) {
            NSNumber *idx = _propIdx[key];
            if (idx) {
                _options[idx.unsignedIntegerValue] = [option copy];
                return;
            }
            _propIdx[key] = @(_options.count);
        }
    }
    [_options addObject:[option copy]];
}

- (void)setClasspath:(NSString *)classpath { _classpath = [classpath copy]; }
- (NSString *)classpath { return _classpath; }

- (NSString *)mainClass { return _mainClass; }

- (NSArray<NSString *> *)programArgs { return [_programArgs copy]; }

- (BOOL)jarMode { return _jarMode; }

// ----------------------------------------------------------------------------
// 旧 margv 摄取
// ----------------------------------------------------------------------------
- (BOOL)ingestArgv:(const char *const *)argv count:(int)count {
    if (!argv || count <= 1) return NO;

    int  i = 1;                 // 跳过 argv[0]（"<javaHome>/bin/java"）
    BOOL sawMain = NO;
    BOOL jar = NO;

    for (; i < count; i++) {
        const char *c = argv[i];
        if (!c) continue;
        NSString *t = @(c);

        if ([t isEqualToString:@"-jar"]) {
            jar = YES;          // JLI 语义，runtime 层不支持 ⇒ 标记回退
            continue;
        }
        if ([t isEqualToString:@"-cp"] || [t isEqualToString:@"-classpath"]) {
            if (i + 1 < count && argv[i + 1]) {
                _classpath = @(argv[i + 1]);
                i += 1;
            }
            continue;
        }
        if ([t hasPrefix:@"-Djava.class.path="]) {
            _classpath = [t substringFromIndex:(NSUInteger)[@"-Djava.class.path=" length]];
            continue;
        }
        if ([t hasPrefix:@"-"]) {
            [self addRawOption:t];
            continue;
        }
        // 首个非选项 token = 主类；其后为程序参数
        if (!sawMain) {
            _mainClass = [t copy];
            sawMain = YES;
        } else {
            [_programArgs addObject:[t copy]];
        }
    }

    _jarMode = jar;
    return (sawMain && !jar);
}

// ----------------------------------------------------------------------------
// 构建 JavaVMInitArgs
// ----------------------------------------------------------------------------
- (A2VMArgsBundle *)buildInitArgsWithVersion:(jint)jniVersion
                          ignoreUnrecognized:(BOOL)ignoreUnrecognized {
    NSMutableArray<NSString *> *final = [NSMutableArray arrayWithArray:_options];

    if (_classpath.length > 0) {
        if (_classpathForm == A2ClasspathFormOption) {
            // 形态 B：launcher 风格 "-cp" + 路径 两个独立条目（真机 A/B 用）
            [final addObject:@"-cp"];
            [final addObject:_classpath];
        } else {
            // 形态 A：合并为单个 -Djava.class.path=（默认）
            [final addObject:[NSString stringWithFormat:@"-Djava.class.path=%@", _classpath]];
        }
    }

    return [[A2VMArgsBundle alloc] initWithOptionStrings:final
                                                 version:jniVersion
                                      ignoreUnrecognized:ignoreUnrecognized];
}

- (NSString *)summary {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"options=%lu classpathForm=%s",
        (unsigned long)_options.count,
        (_classpathForm == A2ClasspathFormOption) ? "B(-cp)" : "A(-Djava.class.path)"];
    [s appendFormat:@" classpathLen=%lu main=%@ jarMode=%d programArgs=%lu",
        (unsigned long)_classpath.length, _mainClass ?: @"(nil)", _jarMode ? 1 : 0,
        (unsigned long)_programArgs.count];
    for (NSString *o in _options) [s appendFormat:@"\n  %@", o];
    return s;
}

@end
