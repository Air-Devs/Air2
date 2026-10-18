//
//  AssetDetailHeaderView.h
//  Amethyst
//
//  资源详情页头部视图（参照 FCL/ZL2 的项目详情 header 设计）
//
//  用途：作为 ModVersionViewController / ShaderVersionViewController / AssetVersionViewController
//  的 tableView.tableHeaderView，在用户进入版本选择页时，于顶部展示项目的完整信息：
//    - 项目封面图（72x72 圆角，AFNetworking 加载 + 占位 SF Symbol）
//    - 项目标题（18pt bold，最多 2 行）
//    - 作者（带 person.crop.circle 图标）
//    - 元信息行：下载量 / 关注量 / 最后更新（带 SF Symbol 图标）
//    - 标签行：categories 彩色 pill 标签（参照 ZL2 LittleTextLabel）
//    - 描述区：默认 3 行，超过时显示"展开/收起"按钮
//
//  设计目标：
//    1. 补齐"信息显示 + 对应的图片显示"缺口（之前版本页无任何项目信息与封面图）
//    2. 视觉与 ModernAssetCell / ModVersionTableViewCell 统一（圆角卡片 + 浅阴影 + 毛玻璃）
//    3. 支持描述展开/收起，并通过 onSizeChanged 回调通知控制器更新 tableHeaderView 高度
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AssetDetailHeaderView : UIView

/// 尺寸变化回调（描述展开/收起时触发，控制器需在此回调中重新计算 tableHeaderView 高度）
@property (nonatomic, copy, nullable) void (^onSizeChanged)(void);

/// 配置 header 内容
/// @param iconURL 项目封面图 URL（可为 nil，显示占位 SF Symbol）
/// @param title 项目标题
/// @param author 作者（可为 nil）
/// @param downloads 下载量（可为 nil）
/// @param likes 关注/点赞量（可为 nil）
/// @param descriptionText 项目描述（可为 nil）
/// @param categories 分类/标签数组（彩色 pill，可为 nil）
/// @param lastUpdated 最后更新时间（ISO8601 字符串或任意可显示字符串，可为 nil）
/// @param placeholderSymbolName 无封面图时显示的占位 SF Symbol 名称（如 "puzzlepiece.extension.fill"）
/// @param placeholderColor 占位图标的强调色（与资源类型对应）
- (void)configureWithIconURL:(nullable NSString *)iconURL
                       title:(NSString *)title
                      author:(nullable NSString *)author
                   downloads:(nullable NSNumber *)downloads
                       likes:(nullable NSNumber *)likes
             descriptionText:(nullable NSString *)descriptionText
                 categories:(nullable NSArray<NSString *> *)categories
                lastUpdated:(nullable NSString *)lastUpdated
        placeholderSymbolName:(NSString *)placeholderSymbolName
            placeholderColor:(UIColor *)placeholderColor;

/// 计算并返回 header 在指定宽度下的适配高度（用于设置 tableHeaderView 的 frame）
/// @param width 目标宽度（通常为 tableView.bounds.size.width）
- (CGFloat)fittingHeightForWidth:(CGFloat)width;

@end

NS_ASSUME_NONNULL_END
