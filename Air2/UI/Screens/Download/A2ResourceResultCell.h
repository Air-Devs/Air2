//
//  A2ResourceResultCell.h
//  Air2
//
//  搜索结果行 —— 从 A2ResourceSearchViewController 抽出来。
//
//  抽出的理由：搜索结果页原本有 1037 行，承担了
//  「结果行 / 筛选栏 / 分栏布局 / 数据加载 / 分页」五个职责。
//  结果行是最独立的一块（只依赖 A2ResourceCard 与两个数据源），
//  且收藏页也用它，放在独立文件里便于复用。
//

#import <UIKit/UIKit.h>
#import "A2ContentSource.h"
@class A2ResourceCard;

NS_ASSUME_NONNULL_BEGIN

@interface A2ResourceResultCell : UITableViewCell

@property (nonatomic, strong) A2ResourceCard *card;

/// 配置内容（含已安装与收藏状态）
- (void)configureWithItem:(A2ContentItem *)item;

@end

NS_ASSUME_NONNULL_END
