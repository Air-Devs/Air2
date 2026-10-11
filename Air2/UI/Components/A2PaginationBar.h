//
//  A2PaginationBar.h
//  Air2
//
//  分页控件 —— 对照 ZL2 的 _PlatformPages.kt 与其 UI。
//
//  为什么不用无限滚动：
//    ZL2 用的是经典分页 —— 上一页 / 页码 / 下一页。
//    搜索类界面的无限滚动有个问题：用户滑到第 10 页就找不回
//    第 3 页看到的东西了；分页让位置明确、可回退。
//
//  页面缓存：已看过的页不重新请求（ZL2 的 pages 列表就是这个用途）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface A2PaginationBar : UIView

/// 当前页码（从 1 开始）
@property (nonatomic, assign, readonly) NSInteger currentPage;
/// 总页数。0 表示未知（还能继续翻）。
/// 只读 —— 改它要走 setCurrentPage:totalPages:，那样才会同步更新按钮状态。
@property (nonatomic, assign, readonly) NSInteger totalPages;
/// 是否已到最后一页（服务端返回的结果数不足一页时判定）
@property (nonatomic, assign) BOOL isLastPage;

/// 请求某页。
/// 返回 nil 表示缓存命中（调用方不必发请求），非 nil 表示需要请求的 offset。
/// 简化设计：由调用方自己维护缓存，这里只负责交互。
@property (nonatomic, copy, nullable) void (^onNavigate)(NSInteger page);

/// 更新显示状态
- (void)setCurrentPage:(NSInteger)page totalPages:(NSInteger)totalPages;

@end

NS_ASSUME_NONNULL_END
