//
//  A2ControlLayoutIO.h
//  Air2
//
//  控件布局的「一套内部模型 + 多格式导入」。
//
//  内部模型（每个控件一项）：
//    id     NSString   控件 id（内置 id 或外部布局的 uuid）
//    x/y    double     控件中心点，归一化 0..1
//    w/h    double     名义尺寸，归一化 0..1（兜底值，见下）
//    a      double     透明度
//    key    NSNumber   GLFW 键码；-1 鼠标左键 / -2 右键 / -3 中键
//    keys   NSArray    组合键（含 key 在内的全部键；A2 旧存档可能没有此项，
//                      视图侧应以 key 兜底）
//    label  NSString   显示文本
//    role   NSString   迁移方向键时才有：up / down / left / right / sneak
//
//  精确尺寸（只有从 FCL / ZL2 导入时才带；视图应优先使用它们）：
//    wPct/hPct  NSNumber  0..10000，相对 wRef/hRef 指定的那条边
//    wRef/hRef  NSString  "w" = 屏幕宽，"h" = 屏幕高
//    wPt/hPt    NSNumber  点（dp 按 1:1 视为 pt）
//    wrap       NSNumber  @YES 表示 wrap_content（尺寸随内容）
//    xPct/yPct  NSNumber  0..10000，控件左上角占「屏幕尺寸减去控件尺寸」的百分比
//
//  为什么 w/h 只是兜底：
//    FCL/ZL2 的尺寸可以「参考屏幕高」，按屏幕宽归一化必须知道设备宽高比；
//    位置也是「剩余空间的百分比」而不是中心点。这里按 iPhone 横屏
//    （844×390 pt）折算出一个名义值供老调用方使用，精确值在 wPct/wPt 与
//    xPct/yPct 里，视图用实际 bounds 还原即可。
//
//  支持格式（字段依据参考实现的公开类型定义，仅参考结构、不抄实现）：
//    · A2 : 上面的内部模型（本启动器原生）
//    · FCL: viewGroups[].viewData.{buttonList,directionList}；
//           坐标为千分比，尺寸 PERCENTAGE（/1000）或 ABSOLUTE（dp）；
//           键码是 Linux evdev（KEY_W = 17），必须换算成 GLFW。
//    · ZL2: layers[].normalButtons[]；坐标为万分比；
//           尺寸 type = dp / percentage / wrap_content；
//           键码是字符串名（"GLFW_KEY_W"），必须查表。
//
//  导出：只有 A2 是完整可用的。FCL / ZL2 的顶层还要求 styles、special、
//        info 等字段，缺了会让对方启动器解析失败，所以暂不产出半合法文件
//        （返回 nil 并在日志里说明）。
//
//  调用点：A2GameControlsView 的编辑面板（导入=读剪贴板 / 导出=写剪贴板）
//          与设置里的控件布局编辑器。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2ControlLayoutFormat) {
    A2ControlLayoutFormatA2 = 0,
    A2ControlLayoutFormatFCL,
    A2ControlLayoutFormatZL2,
};

@interface A2ControlLayoutIO : NSObject

/// 解析任意受支持格式。失败返回 nil（调用方提示"格式不认识"）。
/// json 允许传 nil（直接返回 nil），方便调用方把「剪贴板为空」交给同一入口。
+ (nullable NSArray<NSDictionary *> *)parseJSON:(nullable id)json
                                         format:(A2ControlLayoutFormat)format;

/// 导出成指定格式的可序列化对象。目前只有 A2 可用，FCL/ZL2 返回 nil。
+ (nullable id)exportControls:(NSArray<NSDictionary *> *)controls
                       format:(A2ControlLayoutFormat)format
                         name:(NSString *)name;

/// 按内容猜格式（先看 layers / viewGroups / controls）。
+ (A2ControlLayoutFormat)detectFormat:(id)json;

@end

NS_ASSUME_NONNULL_END
