//
//  A2ControlStore.h
//  Air2
//
//  控件布局的持久化与版本迁移。
//
//  ## 存哪里
//
//    POJAV_HOME 存在时：<POJAV_HOME>/controlmap/air2_default.json
//    POJAV_HOME 不存在：<Library/Application Support>/Air2/controlmap/air2_default.json
//
//  为什么放 controlmap：这个目录是 Air1 沿用下来的控件目录（宿主里
//  mouse_pointer.png 也在这里），卸载重装不会丢；zip 备份/导入导出时
//  也只会碰到这一个目录。文件名沿用 `default`，与旧版本的
//  `defaultTouchCtrl` 偏好项指向的文件名一致，方便从旧设置迁移。
//
//  ## 版本与迁移
//
//    内部格式：{ "format": "air2", "air2Version": 1, "layers": [...] }
//    · 没有 format/air2Version 的老文件 → A2ControlFormat 按内容识别：
//        viewGroups            → FCL
//        layers + editorVersion→ ZL2
//        normalButtons         → Air1
//      解析后统一 normalize()，再以 Air2 格式回写（升级文件本身）。
//    · 版本 < 当前：补字段（opacity / viewAreas / scrollButtons /
//      hideWhenMouse 等），不删旧字段 —— 旧版 Air2 仍能读。
//    · 解析失败：保留原文件，回退内置默认布局，不覆盖用户的坏文件。
//
//  ## 为什么每次保存都留备份
//
//  编辑器是「进游戏后改布局」的场景。玩家在游戏里改坏一版、保存、
//  发现动不了，原文件已经没了。留一份 default.bak.json，至少能手工救。
//

#import <Foundation/Foundation.h>
#import "A2ControlLayout.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2ControlStore : NSObject

#pragma mark - 路径

/// 控件目录（会自动创建）
+ (NSString *)controlDirectory;
/// 用户布局路径：<controlDirectory>/air2_default.json
+ (NSString *)defaultLayoutPath;
/// 上一个版本的备份（air2_default.bak.json）
+ (NSString *)backupLayoutPath;

#pragma mark - 读写

/// 读布局并执行迁移。文件不存在返回 nil（error 为 nil）。
+ (nullable A2ControlLayout *)loadLayoutAtPath:(NSString *)path error:(NSError **)error;

/// 以 Air2 原生格式写布局（先备份旧文件）。
+ (BOOL)saveLayout:(A2ControlLayout *)layout
            toPath:(NSString *)path
             error:(NSError **)error;

/// 用户布局（不存在返回 nil）
+ (nullable A2ControlLayout *)loadUserLayoutWithError:(NSError **)error;
/// 保存用户布局
+ (BOOL)saveUserLayout:(A2ControlLayout *)layout error:(NSError **)error;

#pragma mark - 迁移

/// 把文件升级到当前内部版本；不需要升级时直接返回 YES。
/// 解析失败返回 NO 且不修改原文件。
+ (BOOL)migrateLayoutFileAtPath:(NSString *)path error:(NSError **)error;

/// 判断一个 JSON 的内部版本（缺省/老格式一律当 0）
+ (NSInteger)versionOfJSON:(nullable NSDictionary *)json;

@end

NS_ASSUME_NONNULL_END
