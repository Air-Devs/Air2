#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ImageCropperViewController : UIViewController

@property (nonatomic, strong) UIImage *sourceImage;
@property (nonatomic, copy) void (^completionHandler)(UIImage * _Nullable croppedImage);

- (instancetype)initWithImage:(UIImage *)image;

@end

NS_ASSUME_NONNULL_END