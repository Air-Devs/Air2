//
//  A2VersionRowView.h
//  Air2
//
//  版本列表的一行。
//
//  布局对齐 ZL2 的 VersionItemLayout：
//    ○  [图标] 版本名          📌  ⚙️  ⋯
//              加载器信息
//
//  左侧单选按钮表示「当前正在使用的版本」，
//  右侧三个图标按钮：置顶、版本设置、更多操作。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2VersionRowView : UIControl

- (instancetype)initWithVersionName:(NSString *)name meta:(nullable NSString *)meta;

@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, copy, nullable) NSString *meta;

/// 是否为当前选中的版本（左侧单选按钮的选中态）
@property (nonatomic, assign, getter=isCurrent) BOOL current;

/// 是否置顶
@property (nonatomic, assign, getter=isPinned) BOOL pinned;

/// 版本是否有效（无效时右侧按钮置灰）
@property (nonatomic, assign, getter=isValid) BOOL valid;

@property (nonatomic, copy, nullable) void (^onSelect)(void);
@property (nonatomic, copy, nullable) void (^onPin)(void);
@property (nonatomic, copy, nullable) void (^onSettings)(void);
@property (nonatomic, copy, nullable) void (^onMore)(void);

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
