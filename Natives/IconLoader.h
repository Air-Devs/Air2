//
//  IconLoader.h
//  Amethyst
//
//  统一的项目图标加载器（参照 FCL Glide + ZL2 Coil 的最佳实践）
//
//  设计目标：
//    1. 解决 AFNetworking UIImageView+AFNetworking 仅内存缓存、应用重启后图标全部
//       需要重新下载的问题（启动器每次冷启动后浏览下载页时图标加载极慢的根因）。
//    2. 解决 AFNetworking 不对图标做降采样、按原始尺寸解码导致内存峰值过高、
//       解码耗时过长（典型 Modrinth/CurseForge 项目图标 200~800KB，原图可能 1024x1024，
//       但显示尺寸仅 56x56 / 72x72）的问题。
//    3. 统一占位与兜底：参照 ZL2 的 ShimmerBox + ic_unknown_icon，加载中显示占位
//       SF Symbol，加载失败显示兜底 SF Symbol，避免出现空白方块。
//    4. CDN 镜像替换：参照 ZL2 的 MCIMirror，把 cdn.modrinth.com /
//       edge.forgecdn.net 替换为国内可达的镜像域名（BMCLAPI），显著改善国内用户体验。
//    5. 并发上限 + 同 URL 去重：参照 Glide/Coil 的线程池与请求合并机制，避免列表滚动时
//       瞬间并发数十个请求导致网络拥塞与 CPU 尖峰。
//    6. 预取：参照 ZL2 的 imageLoader.enqueue，提供 prefetchIconWithURL: 接口，
//       在用户即将滚动到某 cell 前提前拉取并落盘。
//
//  对标实现要点（与 FCL/ZL2 横向对比）：
//    ┌──────────────────┬─────────────────────────┬──────────────────────────┐
//    │ 维度             │ FCL (Glide 4.16)        │ ZL2 (Coil 3.5)           │
//    ├──────────────────┼─────────────────────────┼──────────────────────────┤
//    │ 内存缓存         │ 默认 LRU + largeHeap    │ 20MB LRU + 弱引用        │
//    │ 磁盘缓存         │ 默认 250MB RESULT       │ 512MB 显式目录           │
//    │ 降采样           │ 隐式（依赖 ImageView）  │ 显式 .size(pxSize)       │
//    │ 异步解码         │ Glide 默认线程池        │ Dispatchers.IO           │
//    │ 预取             │ 无                      │ enqueue 轻量预取         │
//    │ 占位/兜底        │ 图标无占位              │ ShimmerBox + 兜底图      │
//    │ CDN 镜像         │ 无（直连官方 CDN）      │ MCIM 镜像替换            │
//    │ 并发上限         │ 默认（CPU 核心数）      │ 默认                     │
//    └──────────────────┴─────────────────────────┴──────────────────────────┘
//
//  本实现综合两者优点：显式降采样（ZL2）+ 双层缓存（ZL2 容量配置）+ enqueue 预取（ZL2）
//  + CDN 镜像替换（ZL2）+ 占位/兜底 SF Symbol（项目自有 SF Symbol 体系）+ 并发上限（自实现）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 加载完成的回调（始终在主线程触发）
/// image 为 nil 表示加载失败（调用方应显示兜底图标）
typedef void(^IconLoaderCompletion)(UIImage * _Nullable image);

/// 图标加载选项（按位标志，便于将来扩展）
typedef NS_OPTIONS(NSUInteger, IconLoaderOptions) {
    /// 默认行为：占位 + 兜底 + 降采样 + CDN 镜像替换 + 内存+磁盘缓存
    IconLoaderOptionsDefault = 0,
    /// 不做 CDN 镜像替换（强制使用原始 URL，例如服务器图标不应走 Modrinth 镜像）
    IconLoaderOptionsNoMirror = 1 << 0,
    /// 仅内存缓存（不写入磁盘，例如临时性头像）
    IconLoaderOptionsMemoryCacheOnly = 1 << 1,
    /// 跳过降采样（按原始尺寸解码，仅在需要原图时使用，例如截图详情）
    IconLoaderOptionsNoDownsample = 1 << 2,
};

@interface IconLoader : NSObject

/// 单例访问
+ (instancetype)sharedLoader;

#pragma mark - 核心加载接口

/// 加载图标到指定 UIImageView（参照 ZL2 AssetsIcon 的统一接口）
///
/// @param imageView   目标 ImageView（弱引用持有，避免循环引用；nil 时仅做预取）
/// @param url         图标 URL（nil 或空串则仅设置占位图）
/// @param placeholder 加载期间显示的占位图（nil 则保持 imageView 当前图像）
/// @param fallback    加载失败时显示的兜底图（nil 则保持占位图）
/// @param targetSize  目标显示尺寸（像素），用于降采样；传 CGSizeZero 表示按原始尺寸
/// @param options     加载选项
/// @param completion  加载完成回调（主线程，可为 nil）
///
/// 该方法会自动：
///   1. 取消该 imageView 上之前发起的请求（避免复用 cell 时旧请求覆盖新图像）
///   2. 设置占位图
///   3. 命中内存缓存则直接显示
///   4. 否则发起后台下载（同 URL 去重），下载完成后降采样解码并写入双层缓存
///   5. 失败时显示兜底图
+ (void)loadIconForImageView:(nullable UIImageView *)imageView
                         URL:(nullable NSString *)url
                 placeholder:(nullable UIImage *)placeholder
                    fallback:(nullable UIImage *)fallback
                   targetSize:(CGSize)targetSize
                      options:(IconLoaderOptions)options
                   completion:(nullable IconLoaderCompletion)completion;

/// 便捷接口：使用默认选项加载图标
+ (void)loadIconForImageView:(nullable UIImageView *)imageView
                         URL:(nullable NSString *)url
                 placeholder:(nullable UIImage *)placeholder
                    fallback:(nullable UIImage *)fallback
                   targetSize:(CGSize)targetSize;

#pragma mark - 预取（参照 ZL2 imageLoader.enqueue）

/// 预取图标到缓存（不绑定 imageView，仅触发下载+解码+缓存写入）
/// 用于列表滚动时提前拉取即将进入视口的图标，用户实际滚动到时即可从缓存命中秒开。
+ (void)prefetchIconWithURL:(NSString *)url targetSize:(CGSize)targetSize;

#pragma mark - 取消

/// 取消指定 imageView 上正在进行的图标加载请求
/// 在 cell prepareForReuse 或 viewController dealloc 时调用，避免无效请求占用网络
+ (void)cancelLoadingForImageView:(UIImageView *)imageView;

/// 取消所有进行中的请求（应用进入后台或收到内存警告时调用）
+ (void)cancelAllLoadings;

#pragma mark - 缓存管理

/// 清空内存缓存（收到内存警告时调用）
+ (void)clearMemoryCache;

/// 清空磁盘缓存（用户在设置中点击"清除图标缓存"时调用）
+ (void)clearDiskCacheWithCompletion:(nullable dispatch_block_t)completion;

/// 获取当前磁盘缓存大小（字节），用于设置页显示
+ (unsigned long long)diskCacheSize;

/// 当前缓存的图标数量（内存）
+ (NSUInteger)memoryCacheCount;

#pragma mark - CDN 镜像（参照 ZL2 MCIMirror）

/// 设置是否启用 CDN 镜像替换（默认根据 general.download_source 偏好自动判断）
/// 启用后会把 cdn.modrinth.com / edge.forgecdn.net 替换为国内镜像域名
+ (void)setMirrorEnabled:(BOOL)enabled;

/// 应用 URL 镜像替换（公开方法，便于其他网络层复用）
/// 传入原始 URL，返回替换后的 URL（未启用镜像或无匹配则原样返回）
+ (NSString *)applyMirrorToURL:(NSString *)url;

@end

NS_ASSUME_NONNULL_END
