//
//  SurfaceViewController+ExternalDisplay.m
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
#import "SurfaceViewController.h"
#import "utils.h"

@implementation SurfaceViewController(ExternalDisplay)

- (void)switchToExternalDisplay {
    [self.surfaceView removeFromSuperview];
    [self.mousePointerView removeFromSuperview];

    UILabel *noteLabel = [[UILabel alloc] initWithFrame:self.view.frame];
    noteLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    noteLabel.numberOfLines = 0;
    noteLabel.textAlignment = NSTextAlignmentCenter;
    noteLabel.textColor = UIColor.whiteColor;
    noteLabel.text = localize(@"game.note.airplay", nil);
    [self.touchView addSubview:noteLabel]; 

    UIWindow *secondWindow = UIWindow.externalWindow;
    secondWindow.rootViewController = [[UIViewController alloc] init];
    [secondWindow.rootViewController.view addSubview:self.surfaceView]; 
    [secondWindow.rootViewController.view addSubview:self.mousePointerView];

    secondWindow.hidden = NO;
    [self updateSavedResolution];
}

- (void)switchToInternalDisplay {
    [self.surfaceView removeFromSuperview];
    [self.mousePointerView removeFromSuperview];

    UIWindow *secondWindow = UIWindow.externalWindow;
    secondWindow.hidden = YES;

    [self.touchView.subviews[0] removeFromSuperview];
    [self.touchView addSubview:self.surfaceView]; 
    [self.touchView addSubview:self.mousePointerView];
    [self updateSavedResolution];
}

@end
