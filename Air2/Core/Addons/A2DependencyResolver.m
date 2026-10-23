//
//  A2DependencyResolver.m
//  Air2
//

#import "A2DependencyResolver.h"
#import "A2Log.h"

@implementation A2DependencyResolver

+ (void)resolveForProjectID:(NSString *)projectID
                gameVersion:(NSString *)gameVersion
                     loader:(NSString *)loader
                 completion:(void (^)(NSArray<A2ModrinthProject *> *, NSArray<NSString *> *, NSError *))completion {
    if (completion == nil) return;
    if (projectID.length == 0) {
        completion(@[], @[], [NSError errorWithDomain:@"A2Dep" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少工程 id"}]);
        return;
    }

    A2ModrinthAPI *api = [A2ModrinthAPI shared];
    [api versionsForProject:projectID
                  gameVersion:gameVersion
                       loader:loader
                   completion:^(NSArray<A2ModrinthVersion *> *versions, NSError *error) {
        if (error != nil || versions.count == 0) {
            [A2Log log:@"[DEP] 解析前置失败：project=%@ 无可用版本（%@）", projectID, error.localizedDescription ?: @"空"];
            completion(@[], @[], error ?: [NSError errorWithDomain:@"A2Dep" code:2
                userInfo:@{NSLocalizedDescriptionKey: @"该工程没有匹配当前版本/加载器的文件"}]);
            return;
        }

        A2ModrinthVersion *v = versions.firstObject;
        NSArray<NSDictionary *> *deps = v.dependencies ?: @[];

        NSMutableArray<NSString *> *requiredIDs = [NSMutableArray array];
        NSMutableArray<NSString *> *optionalIDs = [NSMutableArray array];
        for (NSDictionary *d in deps) {
            if (![d isKindOfClass:NSDictionary.class]) continue;
            NSString *depPID = d[@"project_id"];
            NSString *type = d[@"dependency_type"] ?: @"required";
            if (![depPID isKindOfClass:NSString.class] || depPID.length == 0) continue;
            if ([type isEqualToString:@"required"]) {
                if (![requiredIDs containsObject:depPID]) [requiredIDs addObject:depPID];
            } else if ([type isEqualToString:@"optional"]) {
                if (![optionalIDs containsObject:depPID]) [optionalIDs addObject:depPID];
            }
            // embedded（已内嵌）/ incompatible（不兼容）都不需要自动安装
        }

        if (requiredIDs.count == 0 && optionalIDs.count == 0) {
            [A2Log log:@"[DEP] project=%@ 版本 %@ 没有声明依赖", projectID, v.versionNumber ?: v.versionID];
            completion(@[], @[], nil);
            return;
        }

        dispatch_group_t group = dispatch_group_create();
        NSMutableArray<A2ModrinthProject *> *required = [NSMutableArray array];
        NSMutableArray<NSString *> *optionalTitles = [NSMutableArray array];
        NSLock *lock = [NSLock new];

        for (NSString *depPID in requiredIDs) {
            dispatch_group_enter(group);
            [api projectWithID:depPID completion:^(A2ModrinthProject *project, NSError *err) {
                if (project != nil) {
                    [lock lock]; [required addObject:project]; [lock unlock];
                } else {
                    // 拿不到详情也要让玩家知道有这么个前置
                    A2ModrinthProject *stub = [A2ModrinthProject new];
                    stub.projectID = depPID;
                    stub.title = [NSString stringWithFormat:@"(未取到详情) %@", depPID];
                    [lock lock]; [required addObject:stub]; [lock unlock];
                }
                dispatch_group_leave(group);
            }];
        }
        for (NSString *depPID in optionalIDs) {
            dispatch_group_enter(group);
            [api projectWithID:depPID completion:^(A2ModrinthProject *project, NSError *err) {
                NSString *title = project.title.length ? project.title : depPID;
                [lock lock]; [optionalTitles addObject:title]; [lock unlock];
                dispatch_group_leave(group);
            }];
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            NSArray *sortedRequired = [required sortedArrayUsingComparator:^NSComparisonResult(A2ModrinthProject *a, A2ModrinthProject *b) {
                return [a.title compare:b.title];
            }];
            [A2Log log:@"[DEP] project=%@ 前置解析完成：必需 %lu 个（%@），可选 %lu 个（%@）",
             projectID, (unsigned long)sortedRequired.count,
             [[sortedRequired valueForKey:@"title"] componentsJoinedByString:@"、"] ?: @"",
             (unsigned long)optionalTitles.count,
             [optionalTitles componentsJoinedByString:@"、"] ?: @""];
            completion(sortedRequired, optionalTitles, nil);
        });
    }];
}

@end
