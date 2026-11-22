//
//  A2LogUploader.h
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
//  A2LogUploader.h
//  Air2
//
//  崩溃日志上传：把日志正文贴到日志托管服务，换回一个可分享的短链接。
//
//  ## 对照的 ZL2 实现
//
//    zl2/ZalithLauncher/.../crashlogs/AbstractAPI.kt
//        POST form  body: content=<日志正文>
//    zl2/ZalithLauncher/.../crashlogs/platform/MCLogsAPI.kt
//        api  = https://api.mclo.gs/1/log
//        root = https://mclo.gs
//    zl2/ZalithLauncher/.../crashlogs/platform/MirroredAPI.kt
//        api  = https://api.logshare.cn/1/log      （国内镜像，同样的协议）
//        root = https://logshare.cn
//    zl2/ZalithLauncher/.../crashlogs/MCLogsResponse.kt
//        响应 JSON：{ success: Bool, url: String?, id: String?, error: String? }
//
//  ## 为什么需要
//
//  崩溃页现在只能「分享日志文件」——对方还得下载文件、找得到解析器。
//  贴成链接后，直接在聊天里发 URL 就能看，这是 ZL2 崩溃页的核心体验。
//
//  ## 隐私提醒
//
//  上传的是完整日志，里面可能含：游戏目录绝对路径、Java 参数、
//  显卡/设备型号、Mod 列表、（若有）账号名。默认**不自动上传**，
//  只在用户点按钮时上传，并在按钮上写明"上传日志并复制链接"。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 日志托管服务。两个服务协议完全相同（form 字段 content），只是域名不同。
typedef NS_ENUM(NSInteger, A2LogShareProvider) {
    /// 优先用 mclo.gs（ZL2 默认）
    A2LogShareProviderMCLogs = 0,
    /// 国内镜像 logshare.cn —— mclo.gs 不可达时用
    A2LogShareProviderMirrored = 1,
    /// 先 mclo.gs，失败自动回退镜像
    A2LogShareProviderAutomatic = 2,
};

/// 上传结果
@interface A2LogShareResult : NSObject
/// 可分享的短链接，例如 https://mclo.gs/AbCdEfG
@property (nonatomic, copy, readonly, nullable) NSString *url;
/// 服务端分配的日志 id（url 的最后一段）
@property (nonatomic, copy, readonly, nullable) NSString *logID;
/// 实际生效的服务
@property (nonatomic, assign, readonly) A2LogShareProvider provider;
/// 失败原因（url 为 nil 时非 nil）
@property (nonatomic, strong, readonly, nullable) NSError *error;
@end

FOUNDATION_EXPORT NSString *const A2LogUploaderErrorDomain;

typedef NS_ERROR_ENUM(A2LogUploaderErrorDomain, A2LogUploaderErrorCode) {
    /// 日志内容为空
    A2LogUploaderErrorEmptyContent = 1,
    /// 网络/HTTP 失败
    A2LogUploaderErrorTransport = 2,
    /// 服务端返回 success=false，或返回体无法解析
    A2LogUploaderErrorRejected = 3,
};

@interface A2LogUploader : NSObject

/// 单次上传允许的最大字节数。日志动辄几十 MB，托管服务会拒收，
/// 所以默认只上传尾部（崩溃现场在末尾）。ZL2 也是截断后再传。
@property (nonatomic, assign) NSUInteger maxBytes;   // 默认 512 KB

/// 上传一段日志正文。completion 一定在主线程回调，且只回调一次。
+ (void)uploadLogContent:(NSString *)content
                provider:(A2LogShareProvider)provider
              completion:(void (^)(A2LogShareResult *result))completion;

/// 从日志文件读取尾部若干字节再上传（不会把整个文件读进内存）。
/// 文件不存在或读失败时，result.url 为 nil、result.error 说明原因。
+ (void)uploadLogFileAtPath:(NSString *)path
                   provider:(A2LogShareProvider)provider
                 completion:(void (^)(A2LogShareResult *result))completion;

/// 当前生效的服务根地址（用于拼「在浏览器打开」之类的文案）
+ (NSString *)rootURLStringForProvider:(A2LogShareProvider)provider;

@end

NS_ASSUME_NONNULL_END
