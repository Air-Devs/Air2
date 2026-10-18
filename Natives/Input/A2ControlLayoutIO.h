//
//  A2ControlLayoutIO.h
//  Air2
//
//  控件布局的「一套内部模型 + 多格式导入导出」。
//
//  内部模型（每个控件一项，坐标与尺寸都归一化到 0..1，键位统一用 GLFW 键码）：
//    { "id": "attack", "x": 0.92, "y": 0.85, "w": 0.08, "h": 0.17,
//      "a": 1.0, "key": -1 }        // key: GLFW 键码；-1/-2 = 鼠标左右键
//
//  支持格式（字段依据公开类型定义，仅参考结构、不抄实现）：
//   · A2 : 上面的内部模型（本启动器原生）
//   · FCL: controllerVersion 数字键码 + 千分比坐标（xPosition/yPosition 0..1000）
//   · ZL2: GLFW 键码 + 万分比坐标（position.x/y 0..10000）
//
//  调用点：A2GameControlsView 的编辑面板（导入=读剪贴板 / 导出=写剪贴板）。
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
+ (nullable NSArray<NSDictionary *> *)parseJSON:(id)json
                                         format:(A2ControlLayoutFormat)format;

/// 导出成指定格式的可序列化对象。
+ (nullable id)exportControls:(NSArray<NSDictionary *> *)controls
                       format:(A2ControlLayoutFormat)format
                         name:(NSString *)name;

/// 按内容猜格式（先看 controllerVersion / layers / controls）。
+ (A2ControlLayoutFormat)detectFormat:(id)json;

@end

NS_ASSUME_NONNULL_END
