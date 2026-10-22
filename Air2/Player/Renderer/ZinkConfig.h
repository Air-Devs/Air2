//
//  ZinkConfig.h
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
#pragma once

#import <Foundation/Foundation.h>

extern NSString *const ZinkPrefSection;

typedef NS_ENUM(NSInteger, ZinkOptimizationLevel) {
    ZinkOptimizationLevelAuto = -1,
    ZinkOptimizationLevelOff = 0,
    ZinkOptimizationLevelSafe = 1,
    ZinkOptimizationLevelLow = 2,
    ZinkOptimizationLevelMedium = 3,
    ZinkOptimizationLevelHigh = 4,
    ZinkOptimizationLevelUltra = 5
};

typedef NS_OPTIONS(NSUInteger, ZinkAPIFeatures) {
    ZinkAPIFeatureNone               = 0,
    ZinkAPIFeatureTransformFeedback  = 1 << 0,
    ZinkAPIFeatureComputeShader      = 1 << 1,
    ZinkAPIFeatureTessellationShader = 1 << 2,
    ZinkAPIFeatureGeometryShader     = 1 << 3,
    ZinkAPIFeatureMultiDrawIndirect  = 1 << 4,
    ZinkAPIFeatureDirectStateAccess  = 1 << 5,
    ZinkAPIFeatureTextureAnisotropic = 1 << 6,
    ZinkAPIFeatureMax = 1 << 7
};

typedef NS_ENUM(NSInteger, AppleGPUGeneration) {
    AppleGPUGenerationUnknown = 0,
    AppleGPUGenerationA9  = 9,
    AppleGPUGenerationA10 = 10,
    AppleGPUGenerationA11 = 11,
    AppleGPUGenerationA12 = 12,
    AppleGPUGenerationA13 = 13,
    AppleGPUGenerationA14 = 14,
    AppleGPUGenerationA15 = 15,
    AppleGPUGenerationA16 = 16,
    AppleGPUGenerationA17 = 17,
    AppleGPUGenerationA18 = 18,
    AppleGPUGenerationM1  = 101,
    AppleGPUGenerationM2  = 102,
    AppleGPUGenerationM3  = 103,
    AppleGPUGenerationM4  = 104
};

@interface ZinkConfig : NSObject

+ (AppleGPUGeneration)deviceGPUGeneration;
+ (NSString *)deviceGPUGenerationName;
+ (ZinkOptimizationLevel)recommendedOptimizationLevel;
+ (ZinkAPIFeatures)supportedAPIFeaturesForGPUGeneration:(AppleGPUGeneration)gen;
+ (ZinkAPIFeatures)supportedAPIFeatures;
+ (BOOL)isZinkRenderSelected;

+ (void)applyZinkEnvironmentForOptimizationLevel:(ZinkOptimizationLevel)level;
+ (void)applyZinkEnvironmentFromPreferences;
+ (void)applyZinkAPIFeatureOverride:(ZinkAPIFeatures)enabledFeatures;

+ (NSString *)deviceRecommendationString;
+ (NSString *)apiSupportSummaryForGPUGeneration:(AppleGPUGeneration)gen;
+ (NSString *)activeConfigSummary;

@end
