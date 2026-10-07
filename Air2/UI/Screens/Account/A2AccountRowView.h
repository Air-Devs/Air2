//
//  A2AccountRowView.h
//  Air2
//
//  账号列表的一行。
//
//  布局对齐 ZL2 的 AccountItem：
//    ○  [头像 46]  Steve        🔄   ⋮
//                  Microsoft 正版账号
//
//  左侧单选表示「当前使用的账号」，右侧是刷新与更多操作。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2AccountRowView : UIControl

- (instancetype)initWithName:(NSString *)name type:(NSString *)type;

@property (nonatomic, copy) NSString *accountName;
@property (nonatomic, copy) NSString *accountType;

/// 是否为当前账号
@property (nonatomic, assign, getter=isCurrent) BOOL current;

/// 是否可刷新（离线账号不可刷新）
@property (nonatomic, assign) BOOL refreshable;

@property (nonatomic, copy, nullable) void (^onSelect)(void);
@property (nonatomic, copy, nullable) void (^onRefresh)(void);
@property (nonatomic, copy, nullable) void (^onMore)(void);

- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
