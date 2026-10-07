//
//  A2VersionCard.h
//  Air2
//
//  版本卡片 —— 用于「最近游玩」横滑列表和版本管理网格。
//  参考 ZL2 的 VersionCardContent，视觉上是：
//    [版本图标] 版本名
//               附加信息（加载器 / 上次游玩）
//               可选：置顶角标、状态点
//

#import <UIKit/UIKit.h>
#import "A2GlassCard.h"

NS_ASSUME_NONNULL_BEGIN

/// 版本卡片状态，对应 ZL2 的 VersionCardStatus
typedef NS_ENUM(NSInteger, A2VersionCardStatus) {
    A2VersionCardStatusLoading = 0,   ///< 尚未完成首次检查
    A2VersionCardStatusAvailable,     ///< 可用
    A2VersionCardStatusDeleted,       ///< 目录可访问但版本已不存在
    A2VersionCardStatusInaccessible,  ///< 路径不可访问
};

@interface A2VersionCard : A2GlassCard

- (instancetype)initWithVersionName:(NSString *)name meta:(nullable NSString *)meta;

@property (nonatomic, copy) NSString *versionName;
@property (nonatomic, copy, nullable) NSString *meta;

@property (nonatomic, assign) A2VersionCardStatus status;

/// 置顶
@property (nonatomic, assign, getter=isPinned) BOOL pinned;

/// 版本图标。为空时用首字母占位。
@property (nonatomic, strong, nullable) UIImage *versionIcon;

/// 选中态（当前默认版本）
@property (nonatomic, assign, getter=isSelected) BOOL selected;

/// 点击回调
@property (nonatomic, copy, nullable) void (^onSelect)(void);

/// 长按回调
@property (nonatomic, copy, nullable) void (^onLongPress)(void);

@end

NS_ASSUME_NONNULL_END
