//
//  BackgroundSettingsViewController.h
//  Amethyst
//
//  Background wallpaper settings view controller
//

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import "BackgroundManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface BackgroundSettingsViewController : UITableViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>

@end

NS_ASSUME_NONNULL_END
