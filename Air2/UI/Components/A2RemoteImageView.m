//
//  A2RemoteImageView.m
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
//  见头文件。缓存与解码细节全部收在本文件。
//
//  路径取舍：磁盘缓存落在 NSCachesDirectory 下的子目录，而不是走 Core/Path。
//  原因：Core/Path 是「业务沙盒」的路径出口，管的是版本目录、游戏文件这类
//  有语义、要迁移、要校验的资源；图片缓存是 UI 侧的纯临时数据，系统可随时
//  回收（Caches 本身就可能被清理），把它塞进业务沙盒会造成职责污染。
//  两者职责不同，故这里自行拼 Caches 子目录。
//
//  哈希取舍：磁盘文件名用 URL 的 SHA1（CommonCrypto），不用 NSString.hash ——
//  后者跨进程不稳定且碰撞概率高，会导致不同图标互相覆盖。
//

#import "A2RemoteImageView.h"
#import "A2ThemeManager.h"
#import "A2Log.h"

#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>

#pragma mark - 全局缓存与工具

/// 内存缓存：所有实例共享，按像素数估算成本，软上限 64MB。
/// 用 NSCache 而不是字典，是为了在系统内存吃紧时能被自动回收。
static NSCache<NSString *, UIImage *> *A2RemoteImageMemoryCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.totalCostLimit = 64 * 1024 * 1024;
    });
    return cache;
}

/// 磁盘缓存目录（Caches/A2RemoteImages），首次访问时创建。
static NSString *A2RemoteImageCacheDirectory(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *caches =
            NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *base = caches.firstObject ?: NSTemporaryDirectory();
        dir = [base stringByAppendingPathComponent:@"A2RemoteImages"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
    });
    return dir;
}

/// 解码/联网统一放这条并发队列，主线程只做赋值，避免滚动掉帧。
static dispatch_queue_t A2RemoteImageWorkQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("dev.airdevs.air2.remoteimage", DISPATCH_QUEUE_CONCURRENT);
    });
    return queue;
}

/// URL → SHA1 十六进制，做磁盘文件名。
static NSString *A2RemoteImageSHA1(NSString *input) {
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

/// 下采样：先按目标像素生成缩略图再解码，避免把整张原图读进内存。
/// kCGImageSourceShouldCacheImmediately 让解码在后台完成，主线程直接拿到成品。
static UIImage *A2RemoteImageDownsample(NSData *data, CGFloat maxPixel) {
    if (data.length == 0) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;

    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform:   @YES,
        (id)kCGImageSourceShouldCacheImmediately:         @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize:          @(MAX(maxPixel, 1)),
    };
    CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                           (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!thumb) return nil;

    UIImage *image = [UIImage imageWithCGImage:thumb];
    CGImageRelease(thumb);
    return image;
}

/// 写入内存缓存，成本按解码后的像素数（含 4 字节/像素）估算。
static void A2RemoteImageCacheMemory(UIImage *image, NSString *key) {
    CGImageRef cg = image.CGImage;
    NSUInteger pixels = cg ? (NSUInteger)CGImageGetWidth(cg) * CGImageGetHeight(cg) : 0;
    [A2RemoteImageMemoryCache() setObject:image forKey:key cost:pixels * 4];
}

/// 失败日志：按 URL 去重，避免列表里同一批坏链疯狂刷屏。
/// 集合只做去重用途，超过上限就清空重来，不追求精确统计。
static void A2RemoteImageLogFailure(NSString *urlString) {
    static NSMutableSet<NSString *> *logged;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logged = [NSMutableSet set];
    });
    @synchronized (logged) {
        if ([logged containsObject:urlString]) return;
        if (logged.count > 256) [logged removeAllObjects];
        [logged addObject:urlString];
    }
    [A2Log log:@"远程图片加载失败: %@", urlString];
}

#pragma mark -

@interface A2RemoteImageView ()
/// 当前占位图，加载/失败时回退展示用；nil 表示回到语义底色。
@property (nonatomic, strong, nullable) UIImage *placeholderImage;
/// 当前的 URL，配合令牌判断回调是否过期。
@property (nonatomic, copy, nullable) NSString *currentURLString;
/// 请求令牌：每次 setImageURL/cancelLoading 自增，回调令牌不匹配即丢弃。
@property (nonatomic, assign) NSUInteger requestToken;
/// 进行中的下载任务，便于取消。
@property (nonatomic, strong, nullable) NSURLSessionDataTask *task;
@end

@implementation A2RemoteImageView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (!self) return nil;
    [self commonInit];
    return self;
}

- (void)commonInit {
    // 图标多为方形封面，AspectFill + 裁剪最稳；不裁剪会溢出圆角。
    self.contentMode = UIViewContentModeScaleAspectFill;
    self.clipsToBounds = YES;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    [self applyTheme];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleThemeChanged:)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - 属性

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    self.layer.cornerRadius = cornerRadius;
}

#pragma mark - 加载

- (void)setImageURL:(nullable NSString *)urlString placeholder:(nullable UIImage *)placeholder {
    // 令牌自增即作废所有在途回调 —— cell 复用的关键。
    self.requestToken += 1;
    NSUInteger token = self.requestToken;

    [self.task cancel];
    self.task = nil;
    self.currentURLString = urlString;
    self.placeholderImage = placeholder;

    if (urlString.length == 0) {
        [self showPlaceholder];
        return;
    }

    // 内存命中直接显示，避免先占位再替换造成的闪烁。
    UIImage *cached = [A2RemoteImageMemoryCache() objectForKey:urlString];
    if (cached) {
        [self displayImage:cached];
        return;
    }

    [self showPlaceholder];

    CGFloat maxPixel = [self targetMaxPixel];
    NSString *path = [A2RemoteImageCacheDirectory()
        stringByAppendingPathComponent:A2RemoteImageSHA1(urlString)];

    __weak typeof(self) weakSelf = self;
    dispatch_async(A2RemoteImageWorkQueue(), ^{
        __strong typeof(weakSelf) self1 = weakSelf;
        if (!self1 || self1.requestToken != token) return;

        // 一级：磁盘缓存
        NSData *data = [NSData dataWithContentsOfFile:path];
        UIImage *image = A2RemoteImageDownsample(data, maxPixel);
        if (image) {
            A2RemoteImageCacheMemory(image, urlString);
            [self1 deliverImage:image token:token];
            return;
        }

        // 二级：联网下载
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            A2RemoteImageLogFailure(urlString);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2 || self2.requestToken != token) return;

            NSURLSessionDataTask *task =
                [NSURLSession.sharedSession dataTaskWithURL:url
                    completionHandler:^(NSData *downloaded, NSURLResponse *response, NSError *error) {
                        if (downloaded.length == 0) {
                            A2RemoteImageLogFailure(urlString);
                            return;
                        }
                        dispatch_async(A2RemoteImageWorkQueue(), ^{
                            UIImage *decoded = A2RemoteImageDownsample(downloaded, maxPixel);
                            if (!decoded) {
                                A2RemoteImageLogFailure(urlString);
                                return;
                            }
                            // 磁盘写入留在后台队列，不占主线程。
                            [downloaded writeToFile:path atomically:YES];
                            A2RemoteImageCacheMemory(decoded, urlString);

                            __strong typeof(weakSelf) self3 = weakSelf;
                            if (!self3 || self3.requestToken != token) return;
                            [self3 deliverImage:decoded token:token];
                        });
                    }];
            self2.task = task;
            [task resume];
        });
    });
}

- (void)cancelLoading {
    self.requestToken += 1;
    [self.task cancel];
    self.task = nil;
}

#pragma mark - 显示

/// 主线程回填。令牌已在上游校验，这里再确认一次以防竞态。
- (void)deliverImage:(UIImage *)image token:(NSUInteger)token {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.requestToken != token) return;
        [self displayImage:image];
    });
}

- (void)displayImage:(UIImage *)image {
    self.image = image;
    self.backgroundColor = UIColor.clearColor;
}

- (void)showPlaceholder {
    if (self.placeholderImage) {
        self.image = self.placeholderImage;
        self.backgroundColor = UIColor.clearColor;
    } else {
        self.image = nil;
        [self applyTheme];
    }
}

/// 目标像素：按当前边长换算成物理像素；bounds 尚未布局时退回 128。
- (CGFloat)targetMaxPixel {
    CGFloat side = MAX(self.bounds.size.width, self.bounds.size.height);
    if (side <= 0) return 128;
    return side * UIScreen.mainScreen.scale;
}

#pragma mark - 主题

- (void)handleThemeChanged:(NSNotification *)note {
    [self applyTheme];
}

- (void)applyTheme {
    // 只有在「没有占位图、也没有真实图」时，底色才作为占位块露出来；
    // 其余情况都交给图片本身，底色置空避免描边。
    BOOL themedPlaceholder = (self.placeholderImage == nil && self.image == nil);
    self.backgroundColor = themedPlaceholder ? A2ThemeManager.shared.scheme.cSurfaceContainerHigh
                                            : UIColor.clearColor;
}

@end
