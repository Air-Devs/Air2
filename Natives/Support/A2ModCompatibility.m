#import "A2ModCompatibility.h"
#import "a2_log.h"

/// 一条「iOS 上根本跑不了」的 mod。
/// filePrefix 与 jar 文件名开头做大小写不敏感匹配（只匹配开头，避免名字里恰好含某词的无关 mod 被误伤）。
typedef struct {
    __unsafe_unretained NSString *filePrefix;
    __unsafe_unretained NSString *reason;
} A2UnsupportedMod;

/// 两个做同一件事、不能共存的 mod：superseded 被剔除，keeps 保留；两者都在才触发。
typedef struct {
    __unsafe_unretained NSString *supersededPrefix;
    __unsafe_unretained NSString *keepsPrefix;
    __unsafe_unretained NSString *reason;
} A2ConflictingMods;

static BOOL A2DirHasMod(NSArray<NSString *> *entries, NSString *prefix) {
    for (NSString *name in entries) {
        if ([name hasPrefix:@"."]) continue;
        if (![name.pathExtension.lowercaseString isEqualToString:@"jar"]) continue;
        if ([name rangeOfString:prefix options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *A2ScanUnsupportedMods(NSString *directory) {
    // 名单故意保持很短：只有「在 iOS 上完全不可能工作、并且会把游戏一起带崩」才进来，
    // 跑得慢或显示不对的不算。
    static const A2UnsupportedMod kUnsupported[] = {
        {@"controllable-forge",
         @"加载桌面版 SDL2，链接 Apple ForceFeedback 框架（iOS 没有）。手柄不需要它：启动器自己读手柄，"
          "按键盘鼠标的同一套输入喂给游戏。"},
        {@"controllable-fabric",
         @"加载桌面版 SDL2，链接 Apple ForceFeedback 框架（iOS 没有）。手柄不需要它。"},
        {@"controllable-neoforge",
         @"加载桌面版 SDL2，链接 Apple ForceFeedback 框架（iOS 没有）。手柄不需要它。"},
        {@"controllable-sdl",
         @"是 Controllable 用来加载的桌面 SDL2 库，按 Mac 构建，不是 iOS 的。"},
    };
    static const size_t kUnsupportedCount = sizeof(kUnsupported) / sizeof(kUnsupported[0]);

    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:directory error:nil];
    if (entries.count == 0) return @[];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *found = [NSMutableArray new];
    for (NSString *name in entries) {
        if ([name hasPrefix:@"."]) continue;
        if (![name.pathExtension.lowercaseString isEqualToString:@"jar"]) continue;
        for (size_t i = 0; i < kUnsupportedCount; i++) {
            if ([name rangeOfString:kUnsupported[i].filePrefix
                            options:NSCaseInsensitiveSearch | NSAnchoredSearch].location == NSNotFound) continue;
            [found addObject:@{@"name": name, @"reason": kUnsupported[i].reason}];
            break;
        }
    }

    // 互斥组合：两个渲染器同时改写同一批 MC 类 ⇒ 两套缓冲、两套 GL 状态 ⇒ 进世界时
    // 在 Metal 驱动里 SIGSEGV，看起来像硬件故障。
    static const A2ConflictingMods kConflicts[] = {
        {@"rubidium", @"embeddium",
         @"是 Embeddium 的旧版本，同一个渲染器；两个一起装会在进世界时把图形驱动带崩。Embeddium 是维护中的那个，保留它。"},
        {@"reeses_sodium_options", @"textrues_embeddium_options",
         @"是 Rubidium 的设置界面，而 Rubidium 已被剔除；Embeddium 自带同类设置界面。"},
        {@"magnesium", @"embeddium",
         @"是 Embeddium 的旧名字，同一个渲染器；两个一起装会崩图形驱动。"},
    };
    static const size_t kConflictCount = sizeof(kConflicts) / sizeof(kConflicts[0]);

    for (size_t i = 0; i < kConflictCount; i++) {
        if (!A2DirHasMod(entries, kConflicts[i].keepsPrefix)) continue;
        for (NSString *name in entries) {
            if ([name hasPrefix:@"."]) continue;
            if (![name.pathExtension.lowercaseString isEqualToString:@"jar"]) continue;
            if ([name rangeOfString:kConflicts[i].supersededPrefix
                            options:NSCaseInsensitiveSearch | NSAnchoredSearch].location == NSNotFound) continue;

            BOOL already = NO;
            for (NSDictionary *e in found) {
                if ([e[@"name"] isEqualToString:name]) { already = YES; break; }
            }
            if (!already) {
                [found addObject:@{@"name": name, @"reason": kConflicts[i].reason}];
            }
        }
    }

    return found;
}

@implementation A2ModCompatibility

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)unsupportedModsInDirectory:(NSString *)directory {
    if (directory.length == 0) return @[];
    return A2ScanUnsupportedMods(directory);
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)setAsideUnsupportedModsInDirectory:(NSString *)directory {
    NSArray<NSDictionary<NSString *, NSString *> *> *unsupported = [self unsupportedModsInDirectory:directory];
    if (unsupported.count == 0) return unsupported;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *asideDir = [directory stringByAppendingPathComponent:@".a2_unsupported"];
    [fm createDirectoryAtPath:asideDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *moved = [NSMutableArray new];
    for (NSDictionary<NSString *, NSString *> *entry in unsupported) {
        NSString *name = entry[@"name"];
        NSString *source = [directory stringByAppendingPathComponent:name];
        NSString *destination = [asideDir stringByAppendingPathComponent:name];
        [fm removeItemAtPath:destination error:nil];

        NSError *moveError = nil;
        if ([fm moveItemAtPath:source toPath:destination error:&moveError]) {
            a2_log_criterion(@"[A2-MODCOMPAT] 已剔除 %s：%s", name.UTF8String, entry[@"reason"].UTF8String);
            [moved addObject:entry];
        } else {
            // 用户自己装的文件，永远不删；留在原地意味着游戏仍会崩，所以如实记一行。
            a2_log_f(@"[A2-MODCOMPAT] 剔除失败 %s：%s", name.UTF8String,
                     moveError.localizedDescription.UTF8String ?: "unknown");
        }
    }
    return moved;
}

@end
