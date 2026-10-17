//
//  A2RendererRegistry.h
//  Air2
//
//  渲染器注册表 —— 内置 + 导入的插件，统一成一份列表。
//
//  对应 ZL2 的 game/renderer/Renderers.kt（getRenderers()）。
//
//  三源合并：
//    1. 内置渲染器（编译进 IPA，与 Air1 相同）
//    2. 导入的插件（Documents/Air2/Renderers/）
//    3. 未来：从 bundle 预置的插件
//
//  为什么需要这一层：
//    渲染器选择的 UI、启动时的加载逻辑，都只需要面对一种数据类型。
//    让它们分别处理「内置」和「插件」会把判断散落到各处。
//

#import <Foundation/Foundation.h>
#import "A2RendererPlugin.h"

NS_ASSUME_NONNULL_BEGIN

/// 统一的渲染器条目
@interface A2RendererEntry : NSObject
/// 全局唯一标识（内置用固定字符串，插件用 rendererId）
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *summary;
/// 来源：内置 / 插件
@property (nonatomic, assign, getter=isBuiltin) BOOL builtin;
/// 插件来源名（导入插件的包名或文件名）
@property (nonatomic, copy, nullable) NSString *sourceName;

/// 关联的插件对象（内置为 nil）
@property (nonatomic, strong, nullable) A2RendererPlugin *plugin;

/// 可用性
@property (nonatomic, assign, readonly) A2RendererAvailability availability;
@property (nonatomic, copy, nullable, readonly) NSString *unavailableReason;

/// 是否有可配置项（插件的 Toggleable/Selectable/Customizable）
@property (nonatomic, assign, readonly) BOOL hasConfigurableOptions;
/// 版本兼容范围
@property (nonatomic, copy, nullable) NSString *minMCVer;
@property (nonatomic, copy, nullable) NSString *maxMCVer;
@end

@interface A2RendererRegistry : NSObject

+ (instancetype)shared;

/// 全部渲染器（内置在前，插件按名称排序在后）
@property (nonatomic, copy, readonly) NSArray<A2RendererEntry *> *allRenderers;

/// 仅可用的
@property (nonatomic, copy, readonly) NSArray<A2RendererEntry *> *availableRenderers;

/// 当前选中的渲染器标识（持久化在 UserDefaults）
@property (nonatomic, copy, nullable) NSString *selectedIdentifier;

/// 重新扫描（内置 + 插件）
- (void)reload;

/// 按标识查找
- (nullable A2RendererEntry *)rendererWithIdentifier:(NSString *)identifier;

/// 该渲染器在指定 MC 版本下是否适用
- (BOOL)renderer:(A2RendererEntry *)renderer supportsMCVersion:(NSString *)version;

/// 解析出某个渲染器在当前用户配置下应设置的环境变量。
/// 返回 [{key, value}]，直接 setenv 即可。
- (NSDictionary<NSString *, NSString *> *)environmentForRenderer:(A2RendererEntry *)renderer;

@end

NS_ASSUME_NONNULL_END
