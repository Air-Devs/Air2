//
//  GyroInput.m
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
#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>
#import "GyroInput.h"
#import "SurfaceViewController.h"
#import "utils.h"

@implementation GyroInput

static CGFloat lastXValue, lastYValue, lastFrameTime;
static CGFloat gyroSensitivity;
static int gyroInvertX;
static BOOL gyroInvertAxis, gyroSwapAxis;
static CMMotionManager* cmInstance;

+ (void)updateOrientation {
    UIInterfaceOrientation orientation = UIApplication.sharedApplication.windows[0].windowScene.interfaceOrientation;
    gyroInvertAxis =
        orientation==UIInterfaceOrientationPortraitUpsideDown ||
        orientation==UIInterfaceOrientationLandscapeLeft;
    gyroSwapAxis = UIInterfaceOrientationIsPortrait(orientation);
    // FIXME: camera jumps upon rotating screen
}

+ (void)updateSensitivity:(int)sensitivity invertXAxis:(BOOL)invertX {
    if (cmInstance == nil) {
        cmInstance = [[CMMotionManager alloc] init];
    }
    gyroSensitivity = sensitivity / 100.0;
    if (sensitivity > 0) {
        gyroInvertX = invertX ? 1 : -1;
        [self updateOrientation];
        [cmInstance startDeviceMotionUpdates];
    } else {
        lastXValue = lastYValue = lastFrameTime = 0;
        [cmInstance stopDeviceMotionUpdates];
    }
}

+ (void)tick {
    if (!isGrabbing || gyroSensitivity == 0) {
        lastFrameTime = 0;
        return;
    }

    // Compute delta since last tick time
    CGFloat frameTime = CACurrentMediaTime();
    CGFloat factor = gyroSensitivity;
    if (lastFrameTime != 0) {
        CGFloat deltaTimeScale = (frameTime - lastFrameTime) / (1.0/60.0); // Scale of 1 = 60Hz
        factor *= deltaTimeScale;
    }

    // 100% sensitivity -> 1:1 ratio between real world and ingame camera
    if (gyroInvertAxis) {
        factor *= -1;
    }
    if (gyroSwapAxis) {
        lastXValue = cmInstance.deviceMotion.rotationRate.y / (M_PI*90) * windowWidth * factor * gyroInvertX;
        lastYValue = -cmInstance.deviceMotion.rotationRate.x / (M_PI*180) * windowHeight * factor;
    } else {
        lastXValue = cmInstance.deviceMotion.rotationRate.x / (M_PI*180) * windowWidth * factor * gyroInvertX;
        lastYValue = cmInstance.deviceMotion.rotationRate.y / (M_PI*90) * windowHeight * factor;
    }

    SurfaceViewController *vc = [SurfaceViewController currentInstance];
    if (vc) {
        [vc sendTouchPoint:CGPointMake(lastXValue, lastYValue) withEvent:ACTION_MOVE_MOTION];
    }

    lastFrameTime = frameTime;
}

@end
