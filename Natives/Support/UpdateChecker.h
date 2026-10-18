#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 更新信息数据模型
@interface UpdateInfo : NSObject
@property(nonatomic, copy, nullable) NSString *latestVersion;    /* 最新版本号（去掉 v 前缀） */
@property(nonatomic, copy, nullable) NSString *currentVersion;   /* 当前 App 版本号 */
@property(nonatomic, assign) BOOL hasUpdate;                     /* 是否有新版本 */
@property(nonatomic, copy, nullable) NSString *tagName;          /* 原始 tag_name（未去 v 前缀） */
@property(nonatomic, copy, nullable) NSString *releaseName;      /* release 标题 */
@property(nonatomic, copy, nullable) NSString *releaseNotes;     /* 更新日志（markdown） */
@property(nonatomic, copy, nullable) NSString *htmlURL;          /* 本次查到的 release 页面链接 */
@property(nonatomic, copy, nullable) NSString *publishedAt;      /* 发布时间（ISO8601） */
@property(nonatomic, assign) BOOL isPrerelease;                  /* 是否为预发布版（仅 latest 接口 404 回退时可能出现） */
@property(nonatomic, copy, nullable) NSArray<NSDictionary *> *assets; /* 下载资源列表 */
@end

/// 更新检查器（参考 FCL / ZL2，使用 GitHub Releases API）
///
/// 正式版检查：访问 /releases/latest 接口，GitHub 自动返回最新的非 pre-release。
/// 该接口在仓库「只有 pre-release」时会返回 404，此时自动回退到 /releases 列表
/// 取最新一条（isPrerelease = YES），避免直接判定为"检查失败"。
/// 项目地址：https://github.com/herbrine8403/Amethyst-iOS-MyRemastered
@interface UpdateChecker : NSObject

/// 仓库所有者
@property(nonatomic, class, readonly) NSString *repoOwner;
/// 仓库名称
@property(nonatomic, class, readonly) NSString *repoName;
/// 正式版 releases API URL
@property(nonatomic, class, readonly) NSString *latestReleaseURL;
/// 回退用的 releases 列表 API URL
@property(nonatomic, class, readonly) NSString *releaseListURL;

#pragma mark - 检查更新

/// 检查更新（正式版）。网络请求在后台线程，回调在主线程。
/// @param completion 回调，info 为 nil 表示请求失败（error 不为 nil）或解析失败
+ (void)checkForUpdateWithCompletion:(void(^)(UpdateInfo *_Nullable info, NSError *_Nullable error))completion;

/// 检查更新，可指定是否忽略已被用户忽略的版本。
/// 启动时自动检查传 YES（不再打扰），设置页手动检查传 NO（用户主动要看到）。
+ (void)checkForUpdateIgnoringSkipped:(BOOL)ignoreSkipped
                           completion:(void(^)(UpdateInfo *_Nullable info, NSError *_Nullable error))completion;

#pragma mark - 启动时自动检查

/// 启动时自动检查（参照 ZL2 LauncherUpgradeViewModel.checkOnAppStart）。
/// 三道闸门，任一不满足就静默返回：
///   1. general.auto_check_update 开关（默认开启）
///   2. 距上次检查不足 minimumCheckInterval（默认 1 小时）不再请求
///   3. 该版本已被用户点过"忽略此版本"
/// 仅当确认有新版本时才弹窗，失败/已是最新一律静默。
+ (void)performStartupCheckFromPresenter:(UIViewController *)presenter;

/// 手动检查（设置页入口）。忽略"已忽略版本"，但仍受 5 秒防连点限制。
+ (void)performManualCheckFromPresenter:(UIViewController *)presenter
                       showUpToDate:(BOOL)showUpToDate;

/// 用 ZL2 风格弹窗展示更新信息
+ (void)presentUpdateDialogForInfo:(UpdateInfo *)info fromPresenter:(UIViewController *)presenter;

/// 启动时自动检查的限频间隔（秒）。默认 1 小时，与 ZL2 一致。
+ (NSTimeInterval)minimumCheckInterval;

/// 是否在启动时自动检查更新（偏好 general.auto_check_update，默认 YES）
+ (BOOL)autoCheckEnabled;

#pragma mark - 忽略此版本

/// 记录用户忽略的版本号（偏好 general.skipped_update_version）
+ (void)skipVersion:(nullable NSString *)version;
+ (NSString * _Nullable)skippedVersion;

#pragma mark - 跳转

/// 打开本次查到的 release 页面；无 htmlURL 时回退到 /releases/latest
+ (void)openReleasePageForInfo:(nullable UpdateInfo *)info;

/// 打开 release 页面（跳转 Safari）。保留旧接口，始终跳 /releases/latest
+ (void)openReleasePage;

#pragma mark - 版本工具

/// 版本比较：v1 < v2 返回 NSOrderedAscending
+ (NSComparisonResult)compareVersion:(NSString *)v1 withVersion:(NSString *)v2;

/// 获取当前 App 版本号（CFBundleShortVersionString）
+ (NSString *)currentVersion;

/// 去掉版本号前面的 "v" 或 "V" 前缀
+ (NSString *)normalizeVersion:(NSString *)tag;

/// 从版本字符串中提取数字部分（如 "5.0.0 Preview" → "5.0.0"），提取不到返回 nil
+ (NSString * _Nullable)extractVersionNumbers:(NSString *)version;

@end

NS_ASSUME_NONNULL_END
