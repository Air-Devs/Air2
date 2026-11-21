//
//  UIKit+hook.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//
#import <UIKit/UIKit.h>

#define realUIIdiom UIDevice.currentDevice.userInterfaceIdiom
extern NSNotificationName UIPresentationControllerPresentationTransitionWillBeginNotification;

@interface UIDevice(hook)
- (NSString *)completeOSVersion;
@end

@interface UIImageView(hook)
@property(nonatomic) BOOL isSizeFixed;
@end

@interface UIImage(hook)
- (UIImage *)hook_imageWithSize:(CGSize)size;
@end

// private functions
@interface UIContextMenuInteraction(private)
- (void)_presentMenuAtLocation:(CGPoint)location;
@end
@interface _UIContextMenuStyle : NSObject <NSCopying>
@property(nonatomic) NSInteger preferredLayout;
+ (instancetype)defaultStyle;
@end

@interface UIDevice(private)
- (NSString *)buildVersion;
- (void)_setActiveUserInterfaceIdiom:(NSInteger)idiom;
@end

@interface UIImage(private)
- (UIImage *)_imageWithSize:(CGSize)size;
@end

@interface UIScreen(private)
- (void)_setUserInterfaceIdiom:(NSInteger)idiom;
@end

@interface UITextField(private)
@property(assign, nonatomic) NSInteger nonEditingLinebreakMode;
@end

@interface UIWindow(global)
+ (UIWindow *)mainWindow;
+ (UIWindow *)externalWindow;
@end

@protocol _UIPointerInteractionDriver<NSObject>
@property (assign, nonatomic) UIView *view;
@end

@interface UIPointerInteraction(private)
- (NSArray <id<_UIPointerInteractionDriver>> *)drivers;
- (id<_UIPointerInteractionDriver>)driver;
@end

/*
@interface WFTextTokenTextView : UITextField
@property(nonatomic) NSString* placeholder
@end
*/
