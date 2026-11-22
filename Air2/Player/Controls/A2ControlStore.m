//
//  A2ControlStore.m
//  Air2
//
//  实现见 .h。
//

#import "A2ControlStore.h"
#import "A2ControlFormat.h"
#import "A2Logger.h"
#import <stdlib.h>
#import <string.h>

@implementation A2ControlStore

#pragma mark - 路径

+ (NSString *)controlDirectory {
    NSString *base = nil;
    const char *home = getenv("POJAV_HOME");
    if (home && strlen(home) > 0) {
        base = [NSString stringWithUTF8String:home];
        base = [base stringByAppendingPathComponent:@"controlmap"];
    } else {
        NSArray<NSString *> *paths =
            NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                NSUserDomainMask, YES);
        NSString *support = paths.firstObject ?: NSTemporaryDirectory();
        base = [[support stringByAppendingPathComponent:@"Air2"]
                stringByAppendingPathComponent:@"controlmap"];
    }

    NSError *err = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:base
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&err]) {
        [A2Logger warning:@"A2ControlStore"
                  message:[NSString stringWithFormat:@"创建控件目录失败：%@（%@）",
                           base, err.localizedDescription ?: @""]];
    }
    return base;
}

+ (NSString *)defaultLayoutPath {
    return [[self controlDirectory] stringByAppendingPathComponent:@"air2_default.json"];
}

+ (NSString *)backupLayoutPath {
    return [[self controlDirectory] stringByAppendingPathComponent:@"air2_default.bak.json"];
}

#pragma mark - 版本

+ (NSInteger)versionOfJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return 0;
    id v = json[@"air2Version"];
    if ([v isKindOfClass:NSNumber.class]) return [v integerValue];
    // 老 Air2 文件没有 air2Version；ZL2/FCL 源文件同样没有。
    // 统一当 0，交给 normalize 补字段。
    return 0;
}

#pragma mark - 读写

+ (A2ControlLayout *)loadLayoutAtPath:(NSString *)path error:(NSError **)error {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;

    NSError *err = nil;
    A2ControlLayout *layout = [A2ControlFormat layoutFromFile:path error:&err];
    if (!layout) {
        if (error) *error = err;
        return nil;
    }
    [layout normalize];

    // 读的时候就迁移，避免「文件一直是老版本，每次读都要 normalize」
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:NULL];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSInteger version = [self versionOfJSON:json];
    if (version < [A2ControlLayout currentFormatVersion]) {
        NSError *saveErr = nil;
        if (![self saveLayout:layout toPath:path error:&saveErr]) {
            [A2Logger warning:@"A2ControlStore"
                      message:[NSString stringWithFormat:@"布局迁移回写失败：%@",
                               saveErr.localizedDescription ?: @""]];
        } else {
            [A2Logger info:@"A2ControlStore"
                   message:[NSString stringWithFormat:@"布局已迁移：v%ld → v%ld（%@）",
                            (long)version,
                            (long)[A2ControlLayout currentFormatVersion],
                            path.lastPathComponent]];
        }
    }
    return layout;
}

+ (BOOL)saveLayout:(A2ControlLayout *)layout
            toPath:(NSString *)path
             error:(NSError **)error {
    if (!layout || path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2ControlStore" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"参数为空"}];
        }
        return NO;
    }

    // 先备份旧文件（存在才备份）
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
        NSString *backup = [self backupLayoutPath];
        [NSFileManager.defaultManager removeItemAtPath:backup error:NULL];
        [NSFileManager.defaultManager copyItemAtPath:path toPath:backup error:NULL];
    }

    [layout normalize];
    return [A2ControlFormat writeLayout:layout
                                 toFile:path
                                 format:A2ControlFormatKindAir2
                                  error:error];
}

+ (A2ControlLayout *)loadUserLayoutWithError:(NSError **)error {
    return [self loadLayoutAtPath:[self defaultLayoutPath] error:error];
}

+ (BOOL)saveUserLayout:(A2ControlLayout *)layout error:(NSError **)error {
    return [self saveLayout:layout toPath:[self defaultLayoutPath] error:error];
}

#pragma mark - 迁移

+ (BOOL)migrateLayoutFileAtPath:(NSString *)path error:(NSError **)error {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return YES;

    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return NO;

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = [NSError errorWithDomain:@"A2ControlStore" code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"不是 JSON 对象"}];
        }
        return NO;
    }

    NSInteger version = [self versionOfJSON:json];
    if (version >= [A2ControlLayout currentFormatVersion]) return YES;

    A2ControlLayout *layout = [A2ControlFormat layoutFromJSON:json error:error];
    if (!layout) return NO;
    [layout normalize];

    // 迁移时改个名，方便玩家在日志/文件里看出这是升级过的版本
    if (!layout.name.length || [layout.name isEqualToString:@"未命名布局"]) {
        layout.name = @"默认布局";
    }
    return [self saveLayout:layout toPath:path error:error];
}

@end
