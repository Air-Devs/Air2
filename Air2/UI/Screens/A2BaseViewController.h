//
//  A2BaseViewController.h
//  Air2
//
//  页面基类 —— 统一顶栏、背景、返回手势。
//  所有二级页面继承它，避免每个页面重复写顶栏。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2BaseViewController : UIViewController

/// 页面标题，显示在顶栏中央
@property (nonatomic, copy, nullable) NSString *pageTitle;

/// 顶栏右侧按钮（可多个）。设置后自动排布。
@property (nonatomic, strong, readonly) NSMutableArray<UIButton *> *trailingButtons;

/// 顶栏左侧自定义视图（默认是返回按钮）
@property (nonatomic, strong, nullable) UIView *leadingCustomView;

/// 内容容器。子类把视图加到这里，不要直接加到 self.view。
@property (nonatomic, strong, readonly) UIScrollView *scrollView;
@property (nonatomic, strong, readonly) UIStackView *contentStack;

/// 是否隐藏顶栏（如主页、游戏内界面）
@property (nonatomic, assign) BOOL hidesTopBar;

/// 是否使用滚动容器（默认 YES）。设为 NO 则用 plainContentView。
@property (nonatomic, assign) BOOL usesScrollContent;

/// 非滚动模式的内容容器
@property (nonatomic, strong, readonly) UIView *plainContentView;

/// 返回按钮回调（默认 pop）
@property (nonatomic, copy, nullable) void (^onBack)(void);

/// 添加一个顶栏右侧图标按钮，返回该按钮
- (UIButton *)addTrailingButtonWithSymbol:(NSString *)symbolName action:(void (^)(void))action;

/// 添加一个设置分组到内容区
- (void)addSection:(UIView *)section;

/// 重新套用主题
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
