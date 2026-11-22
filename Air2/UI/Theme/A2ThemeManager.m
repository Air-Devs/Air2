//
//  A2ThemeManager.m
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

#import "A2ThemeManager.h"
#import <AVFoundation/AVFoundation.h>

NSNotificationName const A2ThemeDidChangeNotification = @"A2ThemeDidChangeNotification";
NSNotificationName const A2BackgroundDidChangeNotification = @"A2BackgroundDidChangeNotification";

static NSString *const kKeyThemeKind   = @"A2ThemeKind";
static NSString *const kKeyAppearance  = @"A2AppearanceMode";
static NSString *const kKeyBgBlur      = @"A2BackgroundBlur";
/// 用户是否真的动过模糊滑杆。
/// 旧版本默认 24 且 persist 会把这个默认值写盘，历史用户分不清
/// 「没设过」和「主动选了 24」；用这个标记做一次迁移。
static NSString *const kKeyBgBlurTouched = @"A2BackgroundBlurTouched";
static NSString *const kKeyBgOverlay   = @"A2BackgroundDarkOverlay";
static NSString *const kKeyBgFade      = @"A2BackgroundFadeRatio";
static NSString *const kKeyPaletteStyle = @"A2PaletteStyle";
static NSString *const kKeyCustomSeed  = @"A2CustomSeedColor";
/// 视频背景只持久化【文件名】，不存沙盒绝对路径。
/// 沙盒容器 UUID 会在重装 / 迁移后变化，绝对路径会直接失效。
static NSString *const kKeyBgVideoName = @"A2BackgroundVideoFileName";
static NSString *const kBackgroundFileName = @"air2_background.jpg";
static NSString *const kBackgroundPosterName = @"air2_background_video_poster.jpg";

@implementation A2ThemeManager {
    A2ColorTheme *_theme;
    UIImage *_backgroundImage;
    /// 视频文件名（Documents 内的相对名，可持久化）
    NSString *_backgroundVideoFileName;
    /// 视频首帧，播放前与解码失败时用
    UIImage *_backgroundPosterImage;
    // 按模式解析后的色板缓存
    A2ColorScheme *_resolvedScheme;
    BOOL _resolvedIsDark;
}

+ (instancetype)shared {
    static A2ThemeManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2ThemeManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;

    // 默认 0：用户没主动调过模糊，就把原图/视频原样清晰地显示出来。
    // （旧版本默认 24，一设背景就糊，是用户反馈「会模糊」的直接原因）
    // 迁移：旧版本没动过滑杆的用户，盘里也会留下 24 —— 视为未设置，归 0。
    if ([d objectForKey:kKeyBgBlur]) {
        NSInteger saved = [d integerForKey:kKeyBgBlur];
        BOOL touched = [d boolForKey:kKeyBgBlurTouched];
        _backgroundBlur = (touched || saved != 24) ? MAX(0, MIN(100, saved)) : 0;
    } else {
        _backgroundBlur = 0;
    }
    _backgroundDarkOverlay = [d objectForKey:kKeyBgOverlay] ? [d doubleForKey:kKeyBgOverlay] : 0.28;
    _backgroundFadeRatio = [d objectForKey:kKeyBgFade] ? [d doubleForKey:kKeyBgFade] : 0.35;
    _appearanceMode = (A2AppearanceMode)[d integerForKey:kKeyAppearance];

    // 新用户默认冰川蓝（清爽取向；已存选择不受影响，只改缺省）。
    NSInteger kind = [d objectForKey:kKeyThemeKind] ? [d integerForKey:kKeyThemeKind] : A2ThemeKindGlacier;
    if (kind < 0 || kind >= A2ThemeKindCount) kind = A2ThemeKindGlacier;
    _selectedKind = (A2ThemeKind)kind;

    _paletteStyle = [d objectForKey:kKeyPaletteStyle] ? [d integerForKey:kKeyPaletteStyle] : 0;
    NSInteger seedRGB = [d objectForKey:kKeyCustomSeed] ? [d integerForKey:kKeyCustomSeed] : -1;
    if (seedRGB >= 0) {
        _customSeedColor = A2Hex((uint32_t)seedRGB);
    }

    _backgroundImage = [self loadPersistedBackground];
    [self loadPersistedVideoState];
    [self rebuildTheme];

    return self;
}

#pragma mark - 主题

- (A2ColorTheme *)theme {
    return _theme;
}

- (A2ColorScheme *)scheme {
    // 缓存：同一模式下反复取色不应重复创建对象。
    // isDark / theme 变化时清掉缓存。
    if (!_resolvedScheme || _resolvedIsDark != self.isDark) {
        _resolvedScheme = [_theme.scheme resolvedForDark:self.isDark];
        _resolvedIsDark = self.isDark;
    }
    return _resolvedScheme;
}

- (void)setSelectedKind:(A2ThemeKind)selectedKind {
    if (selectedKind < 0 || selectedKind >= A2ThemeKindCount) return;
    if (_selectedKind == selectedKind) return;

    _selectedKind = selectedKind;
    [self rebuildTheme];
    _resolvedScheme = nil;      // 主题变了，解析缓存失效
    [self persist];
    [self notifyThemeChanged];
}

/// 依据当前种类重建主题对象
- (void)rebuildTheme {
    // 自定义种子色优先：用户在大色盘里选的颜色会覆盖主题预设
    if (_customSeedColor) {
        _theme = [A2ColorTheme themeWithSeedColor:_customSeedColor
                                          paletteStyle:_paletteStyle
                                                 name:@"自定义"
                                                 desc:@"从色盘选取的种子色"];
        return;
    }

    if (_selectedKind == A2ThemeKindDynamic && _backgroundImage) {
        _theme = [A2ColorTheme themeFromImage:_backgroundImage];
    } else if (_selectedKind == A2ThemeKindDynamic) {
        // 选了动态取色但还没设背景图，回退到默认主题，避免界面出现随机配色
        _theme = [A2ColorTheme themeForKind:A2ThemeKindGlacier];
    } else {
        _theme = [A2ColorTheme themeForKind:_selectedKind];
    }
}

#pragma mark - 外观

/// 当前是否暗色。
///
/// 注意不能用 UITraitCollection.currentTraitCollection ——
/// 它返回的是「当前线程的 trait 环境」，在布局、后台回调等上下文里
/// 会退化成默认值（表现为亮色主题下卡片却取了暗色 surface）。
/// 正确做法是从窗口的 traitCollection 取，它反映真实的界面外观。
- (BOOL)isDark {
    switch (_appearanceMode) {
        case A2AppearanceModeLight: return NO;
        case A2AppearanceModeDark:  return YES;
        case A2AppearanceModeSystem:
        default:
            return [self resolveSystemDark];
    }
}

- (BOOL)resolveSystemDark {
    // 优先用窗口（最可靠）
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) {
                return w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
            }
        }
    }
    // 退化：取任意窗口
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindow *w = ((UIWindowScene *)scene).windows.firstObject;
        if (w) return w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

- (void)setPaletteStyle:(NSInteger)paletteStyle {
    if (_paletteStyle == paletteStyle) return;
    _paletteStyle = paletteStyle;
    if (_customSeedColor) [self rebuildTheme];
    _resolvedScheme = nil;
    [self persist];
    [self notifyThemeChanged];
}

- (void)setCustomSeedColor:(UIColor *)customSeedColor {
    _customSeedColor = customSeedColor;
    [self rebuildTheme];
    _resolvedScheme = nil;
    [self persist];
    [self notifyThemeChanged];
}

- (void)setAppearanceMode:(A2AppearanceMode)appearanceMode {
    if (_appearanceMode == appearanceMode) return;
    _appearanceMode = appearanceMode;
    [self persist];
    [self notifyThemeChanged];
}

- (void)applyAppearanceToWindow:(UIWindow *)window {
    if (!window) return;
    switch (_appearanceMode) {
        case A2AppearanceModeLight:
            window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
            break;
        case A2AppearanceModeDark:
            window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            break;
        case A2AppearanceModeSystem:
            window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
            break;
    }
    window.tintColor = _theme.lightPrimary;
}

#pragma mark - 自定义背景

- (void)setBackgroundImage:(UIImage *)image {
    _backgroundImage = image;
    // 图片与视频互斥：选了图就清掉视频，避免两套来源同时存在说不清显示哪个
    if (image) [self removeVideoFiles];
    // 动态取色主题依赖背景图，换了图要重算
    if (_selectedKind == A2ThemeKindDynamic) {
        [self rebuildTheme];
        [self notifyThemeChanged];
    }
    [self notifyBackgroundChanged];
}

- (UIImage *)backgroundImage {
    return _backgroundImage;
}

- (void)setBackgroundBlur:(NSInteger)backgroundBlur {
    NSInteger clamped = MAX(0, MIN(100, backgroundBlur));
    if (_backgroundBlur == clamped) return;
    _backgroundBlur = clamped;
    // 标记「用户确实动过」，下次启动不再按旧默认值迁移
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kKeyBgBlurTouched];
    [self persist];
    [self notifyBackgroundChanged];
}

- (void)setBackgroundDarkOverlay:(CGFloat)v {
    CGFloat clamped = MAX(0.0, MIN(1.0, v));
    if (fabs(_backgroundDarkOverlay - clamped) < 0.001) return;
    _backgroundDarkOverlay = clamped;
    [self persist];
    [self notifyBackgroundChanged];
}

- (void)setBackgroundFadeRatio:(CGFloat)v {
    CGFloat clamped = MAX(0.0, MIN(1.0, v));
    if (fabs(_backgroundFadeRatio - clamped) < 0.001) return;
    _backgroundFadeRatio = clamped;
    [self persist];
    [self notifyBackgroundChanged];
}

#pragma mark - 背景来源：图片 / 视频共用状态

- (NSString *)documentsPath {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

/// 背景图存沙盒而非 UserDefaults —— UserDefaults 存大图会拖慢启动
- (NSString *)backgroundFilePath {
    NSString *docs = [self documentsPath];
    if (!docs) return nil;
    return [docs stringByAppendingPathComponent:kBackgroundFileName];
}

- (NSString *)backgroundPosterFilePath {
    NSString *docs = [self documentsPath];
    if (!docs) return nil;
    return [docs stringByAppendingPathComponent:kBackgroundPosterName];
}

/// 运行时由「当前沙盒 Documents + 持久化的文件名」拼出 URL。
/// 这样重装 / 迁移导致容器 UUID 变化后依然能找到文件。
- (NSURL *)backgroundVideoURL {
    if (_backgroundVideoFileName.length == 0) return nil;
    NSString *docs = [self documentsPath];
    if (!docs) return nil;
    NSString *path = [docs stringByAppendingPathComponent:_backgroundVideoFileName];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    return [NSURL fileURLWithPath:path];
}

- (A2BackgroundMediaKind)backgroundMediaKind {
    if (self.backgroundVideoURL) return A2BackgroundMediaKindVideo;
    if (_backgroundImage) return A2BackgroundMediaKindImage;
    return A2BackgroundMediaKindNone;
}

- (BOOL)hasCustomBackground {
    return self.backgroundMediaKind != A2BackgroundMediaKindNone;
}

- (UIImage *)backgroundPosterImage {
    return _backgroundPosterImage;
}

/// 启动时恢复视频文件名、校验文件是否真的还在、加载海报。
- (void)loadPersistedVideoState {
    _backgroundVideoFileName = [NSUserDefaults.standardUserDefaults stringForKey:kKeyBgVideoName];
    if (_backgroundVideoFileName.length == 0) {
        _backgroundVideoFileName = nil;
        return;
    }
    if (!self.backgroundVideoURL) {
        // 文件被删 / 迁移丢失：清掉脏状态，别让界面以为还有视频
        _backgroundVideoFileName = nil;
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kKeyBgVideoName];
        return;
    }
    NSString *posterPath = [self backgroundPosterFilePath];
    if (posterPath) _backgroundPosterImage = [UIImage imageWithContentsOfFile:posterPath];
}

- (BOOL)persistBackgroundImage:(UIImage *)image {
    if (!image) return NO;
    NSString *path = [self backgroundFilePath];
    if (!path) return NO;

    // 缩到合理尺寸再存：原图可能好几 MB，界面用不到那么大
    CGFloat maxSide = 2400;
    CGSize size = image.size;
    if (MAX(size.width, size.height) > maxSide) {
        CGFloat scale = maxSide / MAX(size.width, size.height);
        size = CGSizeMake(size.width * scale, size.height * scale);
    }

    UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    NSData *data = UIImageJPEGRepresentation(scaled, 0.88);
    if (!data) return NO;

    NSError *error = nil;
    BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&error];
    return ok;
}

- (UIImage *)loadPersistedBackground {
    NSString *path = [self backgroundFilePath];
    if (!path) return nil;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    return [UIImage imageWithContentsOfFile:path];
}

#pragma mark 视频导入

/// 删除除 keepName 以外的所有视频文件（换视频时清掉旧扩展名的残留）
- (void)pruneVideoFilesExcept:(NSString *)keepName {
    NSString *docs = [self documentsPath];
    if (!docs) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:docs error:nil] ?: @[];
    for (NSString *name in names) {
        if (![name hasPrefix:@"air2_background_video."]) continue;
        if (keepName && [name isEqualToString:keepName]) continue;
        [fm removeItemAtPath:[docs stringByAppendingPathComponent:name] error:nil];
    }
}

/// 彻底清掉视频状态（文件 + 海报 + 持久化名）
- (void)removeVideoFiles {
    [self pruneVideoFilesExcept:nil];
    NSString *posterPath = [self backgroundPosterFilePath];
    if (posterPath) [NSFileManager.defaultManager removeItemAtPath:posterPath error:nil];
    _backgroundVideoFileName = nil;
    _backgroundPosterImage = nil;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kKeyBgVideoName];
}

/// 视频首帧海报 —— AVPlayerLayer 出画前、以及解码失败时都靠它兜底
- (nullable UIImage *)generatePosterForVideoAtPath:(NSString *)path {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.maximumSize = CGSizeMake(1920, 1920);
    gen.requestedTimeToleranceBefore = kCMTimeZero;
    gen.requestedTimeToleranceAfter = kCMTimeZero;
    NSError *error = nil;
    CGImageRef cg = [gen copyCGImageAtTime:CMTimeMakeWithSeconds(0.1, 600)
                                actualTime:NULL
                                     error:&error];
    if (!cg) return nil;
    UIImage *image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return image;
}

- (NSError *)backgroundErrorWithMessage:(NSString *)message {
    return [NSError errorWithDomain:@"A2Background"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (void)importBackgroundVideoFromURL:(NSURL *)url
                          completion:(void (^)(BOOL, NSError *))completion {
    if (!url) {
        if (completion) completion(NO, [self backgroundErrorWithMessage:@"无效的视频地址"]);
        return;
    }
    NSString *docs = [self documentsPath];
    if (!docs) {
        if (completion) completion(NO, [self backgroundErrorWithMessage:@"找不到文档目录"]);
        return;
    }

    NSString *ext = url.pathExtension.length ? url.pathExtension.lowercaseString : @"mov";
    NSString *fileName = [NSString stringWithFormat:@"air2_background_video.%@", ext];

    // 复制大视频是同步 IO，放到后台队列；完成回主线程更新状态与通知。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        BOOL scoped = [url startAccessingSecurityScopedResource];

        // 先写临时名再原子替换：中途失败不会把正在用的旧视频弄坏
        NSString *destPath = [docs stringByAppendingPathComponent:fileName];
        NSString *tmpPath = [destPath stringByAppendingString:@".importing"];
        [fm removeItemAtPath:tmpPath error:nil];

        NSError *error = nil;
        BOOL ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmpPath] error:&error];
        if (scoped) [url stopAccessingSecurityScopedResource];

        UIImage *poster = nil;
        if (ok) {
            [fm removeItemAtPath:destPath error:nil];
            ok = [fm moveItemAtPath:tmpPath toPath:destPath error:&error];
            if (ok) poster = [self generatePosterForVideoAtPath:destPath];
        }
        if (!ok && !error) error = [self backgroundErrorWithMessage:@"复制视频失败"];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                [fm removeItemAtPath:tmpPath error:nil];
                if (completion) completion(NO, error);
                return;
            }

            // 图片与视频互斥
            NSString *imagePath = [self backgroundFilePath];
            if (imagePath) [fm removeItemAtPath:imagePath error:nil];
            _backgroundImage = nil;

            [self pruneVideoFilesExcept:fileName];
            _backgroundVideoFileName = fileName;
            [NSUserDefaults.standardUserDefaults setObject:fileName forKey:kKeyBgVideoName];

            _backgroundPosterImage = poster;
            NSString *posterPath = [self backgroundPosterFilePath];
            if (poster && posterPath) {
                NSData *data = UIImageJPEGRepresentation(poster, 0.86);
                if (data) [data writeToFile:posterPath atomically:YES];
            } else if (posterPath) {
                [fm removeItemAtPath:posterPath error:nil];
            }

            if (_selectedKind == A2ThemeKindDynamic) {
                [self rebuildTheme];
                [self notifyThemeChanged];
            }
            [self notifyBackgroundChanged];
            if (completion) completion(YES, nil);
        });
    });
}

- (void)clearBackgroundMedia {
    NSString *imagePath = [self backgroundFilePath];
    if (imagePath) [NSFileManager.defaultManager removeItemAtPath:imagePath error:nil];
    [self removeVideoFiles];
    _backgroundImage = nil;

    // 动态取色依赖背景图；背景没了就要回退，否则配色会停在上一张图上
    if (_selectedKind == A2ThemeKindDynamic) {
        [self rebuildTheme];
        [self notifyThemeChanged];
    }
    [self notifyBackgroundChanged];
}

- (void)clearBackgroundImage {
    [self clearBackgroundMedia];
}

#pragma mark - 持久化与广播

- (void)persist {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:_selectedKind forKey:kKeyThemeKind];
    [d setInteger:_appearanceMode forKey:kKeyAppearance];
    [d setInteger:_backgroundBlur forKey:kKeyBgBlur];
    [d setDouble:_backgroundDarkOverlay forKey:kKeyBgOverlay];
    [d setDouble:_backgroundFadeRatio forKey:kKeyBgFade];
    [d setInteger:_paletteStyle forKey:kKeyPaletteStyle];
    if (_customSeedColor) {
        [d setInteger:(NSInteger)A2RGBValue(_customSeedColor) forKey:kKeyCustomSeed];
    } else {
        [d removeObjectForKey:kKeyCustomSeed];
    }
}

- (void)notifyThemeChanged {
    [NSNotificationCenter.defaultCenter postNotificationName:A2ThemeDidChangeNotification
                                                      object:self
                                                    userInfo:@{ @"theme": _theme }];
}

- (void)notifyBackgroundChanged {
    [NSNotificationCenter.defaultCenter postNotificationName:A2BackgroundDidChangeNotification
                                                      object:self
                                                    userInfo:nil];
}

@end
