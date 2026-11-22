//
//  SurfaceViewController+LogView.m
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

@implementation SurfaceViewController(LogView)

- (void)initCategory_LogView {
    self.logOutputView = [[PLLogOutputView alloc] initWithFrame:self.view.frame];
    [self.rootView addSubview:self.logOutputView];
}

- (void)viewWillTransitionToSize_LogView:(CGRect)frame {
    self.logOutputView.frame = frame;
}

@end
