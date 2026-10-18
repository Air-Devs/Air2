// VersionCardCell.h
#ifndef VERSION_CARD_CELL_H
#define VERSION_CARD_CELL_H

#import <UIKit/UIKit.h>

@interface VersionCardCell : UICollectionViewCell

@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UILabel *typeLabel;
// FCL 风格：已安装标记（绿色 ✓ 徽章，表示该版本已在本地安装）
@property (nonatomic, strong) UIView *installedBadge;

- (void)configureWithVersionId:(NSString *)versionId
                          date:(NSString *)date
                          type:(NSString *)type;

/// 设置已安装标记的显示状态（YES=显示绿色 ✓ 徽章）
- (void)setInstalled:(BOOL)installed;

@end

#endif /* VERSION_CARD_CELL_H */
