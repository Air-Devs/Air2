//
//  A2LaunchRuntimeFacts.m
//  Air2
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  运行时事实值对象实现（规格与理由见头文件）。
//

#import "A2LaunchRuntimeFacts.h"

@interface A2LaunchRuntimeFacts ()

// 头文件标 readonly，本扩展重声明为可写（仓内既有写法，见 A2LaunchPlan.m）。
@property (nonatomic, assign, readwrite) NSInteger surfaceWidthPixels;
@property (nonatomic, assign, readwrite) NSInteger surfaceHeightPixels;
@property (nonatomic, assign, readwrite) NSInteger maximumFramesPerSecond;

@end

@implementation A2LaunchRuntimeFacts

+ (instancetype)factsWithSurfaceWidthPixels:(NSInteger)surfaceWidthPixels
                              heightPixels:(NSInteger)surfaceHeightPixels
                     maximumFramesPerSecond:(NSInteger)maximumFramesPerSecond {
    A2LaunchRuntimeFacts *facts = [[A2LaunchRuntimeFacts alloc] init];
    facts.surfaceWidthPixels      = surfaceWidthPixels;
    facts.surfaceHeightPixels     = surfaceHeightPixels;
    facts.maximumFramesPerSecond  = maximumFramesPerSecond;
    return facts;
}

- (BOOL)hasSurfaceSize {
    return (self.surfaceWidthPixels > 0) && (self.surfaceHeightPixels > 0);
}

- (BOOL)hasMaximumFramesPerSecond {
    return self.maximumFramesPerSecond > 0;
}

- (nullable NSString *)glfwWindowSizeValue {
    if (!self.hasSurfaceSize) {
        return nil;   // ★没取到就不给值★ —— 调用方据此不下发 -Dglfw.windowSize
    }
    // ★格式唯一实现处★：小写 x 分隔，两端十进制（对齐 GLFW.java:538 的 split("x")）。
    return [NSString stringWithFormat:@"%ldx%ld",
            (long)self.surfaceWidthPixels, (long)self.surfaceHeightPixels];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<A2LaunchRuntimeFacts surface=%ldx%ld(px) fps=%ld>",
            (long)self.surfaceWidthPixels, (long)self.surfaceHeightPixels,
            (long)self.maximumFramesPerSecond];
}

@end
