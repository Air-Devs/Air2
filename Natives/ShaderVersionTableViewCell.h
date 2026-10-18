//
//  ShaderVersionTableViewCell.h
//  Amethyst
//
//  Table view cell for displaying shader version information
//

#import <UIKit/UIKit.h>
#import "ShaderVersion.h"

NS_ASSUME_NONNULL_BEGIN

@interface ShaderVersionTableViewCell : UITableViewCell

- (void)configureWithVersion:(ShaderVersion *)version;

@end

NS_ASSUME_NONNULL_END
