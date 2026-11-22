//
//  A2ControlFormat.h
//  Air2
//
//  控件格式门面 —— 自动识别 / 导入 / 导出。
//
//  这是宿主（SurfaceViewController / 控件编辑器 / 导入导出面板）唯一需要
//  认识的类。具体的字段映射在：
//
//    A2ControlFormatZL     ZalithLauncher2  editorVersion 12
//    A2ControlFormatFCL    FoldCraftLauncher controllerVersion 21
//    A2ControlLayout       Air1 / Air2 通用格式（layers[]）
//
//  ## 为什么要有门面
//
//  导入一个文件时我们并不知道它是哪家的。判断依据（按优先级）：
//    1. 有 viewGroups / controllerVersion  → FCL
//    2. 有 layers  / editorVersion        → ZL2
//    3. 有 normalButtons / joystickButtons → Air1
//  这层判断只写一次，避免每个调用点各判一遍。
//
//  ## 用法
//
//    NSError *err = nil;
//    A2ControlLayout *layout = [A2ControlFormat layoutFromFile:path error:&err];
//    // layout.sourceFormat 会记录来源，writeToFile: 会自动按来源写回
//
//    // 需要指定导出格式时：
//    [A2ControlFormat writeLayout:layout toFile:out format:A2ControlFormatKindFCL error:&err];
//

#import <Foundation/Foundation.h>
#import "A2ControlLayout.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2ControlFormatKind) {
    A2ControlFormatKindUnknown = 0,
    A2ControlFormatKindZL2,
    A2ControlFormatKindFCL,
    A2ControlFormatKindAir1,
    A2ControlFormatKindAir2,   ///< Air2 自己写出来的（layers[] + 扩展键）
};

@interface A2ControlFormat : NSObject

#pragma mark - 识别

+ (A2ControlFormatKind)detectFormat:(nullable NSDictionary *)json;
+ (A2ControlFormatKind)kindForName:(nullable NSString *)name;
+ (NSString *)nameForKind:(A2ControlFormatKind)kind;
/// 文件扩展名 → 格式（.json 无法判断，返回 Unknown 让内容说了算）
+ (A2ControlFormatKind)kindForFileExtension:(nullable NSString *)ext;

#pragma mark - 导入

/// 自动识别并解析。Air1 走 A2ControlLayout 的兼容路径。
+ (nullable A2ControlLayout *)layoutFromJSON:(NSDictionary *)json error:(NSError **)error;
+ (nullable A2ControlLayout *)layoutFromFile:(NSString *)path error:(NSError **)error;

#pragma mark - 导出

/// 内部模型 → 指定格式的 JSON。Unknown 时按 layout.sourceFormat 推断。
+ (NSDictionary *)jsonFromLayout:(A2ControlLayout *)layout format:(A2ControlFormatKind)kind;

/// 写文件（原子写）
+ (BOOL)writeLayout:(A2ControlLayout *)layout
             toFile:(NSString *)path
             format:(A2ControlFormatKind)kind
              error:(NSError **)error;

#pragma mark - 扩展控件保真

/// Air2 专有的 gamepad / gyroscope / hotbar 在 ZL2 / FCL 里没有对应类型。
/// 导出时会把它们的描述塞进根节点的 air2Extensions，导入时再合并回来 ——
/// 对方启动器如果保留未知字段，就能无损往返；如果它自己的保存会丢未知字段，
/// 这部分就会退化成「一个装饰按钮」（见报告里的有损说明）。
@property (class, nonatomic, readonly) NSString *extensionsKey;

@end

NS_ASSUME_NONNULL_END
