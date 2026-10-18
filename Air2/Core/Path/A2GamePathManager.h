//
//  A2GamePathManager.h
//  Air2
//
//  游戏目录管理 —— 对照 ZL2 的 GamePathManager。
//
//  ## 为什么需要多目录
//
//  用户可能有多份游戏数据：
//    · 沙盒内默认目录（Documents/minecraft）
//    · 从「文件」App 挂载的外部目录
//    · iCloud Drive 上的目录
//
//  ZL2 让用户在「版本管理」的左侧菜单里切换这些目录，
//  每个目录有自己的 versions / mods / saves。
//
//  ## 与旧实现的差异
//
//  之前只有一个写死的 `A2GamePath.defaultGameHome`，无法切换。
//  现在引入目录列表 + 当前选中项，所有路径查询都走「当前目录」。
//
//  ## 数据模型（对照 ZL2 的 GamePathData）
//
//    id         唯一标识（默认目录用固定值 "default"）
//    name       显示名
//    path       绝对路径
//    isDefault  是否为沙盒内默认目录（不可删除）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一个游戏目录
@interface A2GamePathItem : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign, getter=isDefault) BOOL isDefault;
@end

/// 目录变化通知（增删改、切换）
extern NSNotificationName const A2GamePathsDidChangeNotification;

@interface A2GamePathManager : NSObject

+ (instancetype)shared;

/// 默认目录的固定 id
@property (class, nonatomic, copy, readonly) NSString *defaultIdentifier;

/// 全部目录（默认目录永远排第一）
@property (nonatomic, copy, readonly) NSArray<A2GamePathItem *> *allPaths;

/// 当前选中的目录
@property (nonatomic, strong, readonly) A2GamePathItem *currentPath;

/// 当前目录的绝对路径（所有业务代码用这个，不要再用 defaultGameHome）
@property (nonatomic, copy, readonly) NSString *currentGameHome;

/// 切换到某个目录
- (BOOL)selectPathWithIdentifier:(NSString *)identifier error:(NSError **)error;

/// 添加一个外部目录。
/// @param bookmark 用户通过文件选择器选中的 URL（会持久化安全书签）
- (BOOL)addPathFromURL:(NSURL *)url name:(nullable NSString *)name error:(NSError **)error;

/// 删除一个目录（默认目录不可删）
- (BOOL)removePathWithIdentifier:(NSString *)identifier error:(NSError **)error;

/// 重命名
- (BOOL)renamePathWithIdentifier:(NSString *)identifier
                            to:(NSString *)newName
                          error:(NSError **)error;

/// 该目录下是否有 Minecraft 数据（versions 目录存在）
- (BOOL)looksLikeGameDirectory:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
