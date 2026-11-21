//
//  A2ControlEditorViewController.h
//  Air2
//
//  控件编辑器 —— 对照 ZL2 的 ControlEditor.kt + EditButtonDetails.kt。
//
//  ## 能力
//
//    · 拖拽移动控件（吸附到网格）
//    · 双指缩放控件
//    · 点击选中 → 属性面板（文字/大小/圆角/事件）
//    · 新增控件（从工具箱拖出来，或点「+」）
//    · 删除控件
//    · 撤销 / 重做
//    · 导入 / 导出（FCL / ZL2 / Air1 三种格式自动识别）
//
//  ## 与渲染层的关系
//
//  复用 A2ControlRenderer 的编辑模式：
//    editing = YES 时控件可拖动，点击选中
//  编辑器只负责「属性面板」和「增删」，拖动本身在渲染层。
//

#import <UIKit/UIKit.h>
#import "A2ControlLayout.h"

NS_ASSUME_NONNULL_BEGIN

@interface A2ControlEditorViewController : UIViewController

- (instancetype)initWithLayout:(A2ControlLayout *)layout;

/// 保存后回调（外部刷新渲染）
@property (nonatomic, copy, nullable) void (^onSave)(A2ControlLayout *layout);

/// 布局文件的路径（保存到此）
@property (nonatomic, copy, nullable) NSString *filePath;

@end

NS_ASSUME_NONNULL_END
