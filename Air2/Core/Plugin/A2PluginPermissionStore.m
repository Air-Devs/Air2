//
//  A2PluginPermissionStore.m
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

#import "A2PluginPermissionStore.h"

#import "A2Log.h"
#import "A2PluginRegistry.h"

NSString *const A2PluginPermissionStoreErrorDomain = @"A2PluginPermissionStoreErrorDomain";

NSError *A2PluginPermissionErrorMake(A2PluginPermissionStoreError code,
                                     NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return [NSError errorWithDomain:A2PluginPermissionStoreErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"权限操作失败"}];
}

#pragma mark - 小工具

/// ISO-8601（UTC，秒精度）—— 与注册表 / 安装器里的时间字段同一格式。
/// 这里不抽公共函数：注册表那两份各自是 10 行的 formatter 缓存，
/// 抽出来会让 Core 多一个只服务三处的工具件，收益不如重复。
static NSString *A2PermissionISO8601Now(void) {
    static NSISO8601DateFormatter *formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    });
    return [formatter stringFromDate:NSDate.date] ?: @"1970-01-01T00:00:00Z";
}

/// 语义化版本的主版本号（`1.4.2` → 1）。判定「跨 major 要重确认」只用它。
static NSInteger A2PermissionMajorVersion(NSString *version) {
    NSArray<NSString *> *parts = [version componentsSeparatedByString:@"."];
    if (parts.count == 0) return 0;
    return [parts.firstObject integerValue];
}

/// 授权记录里的宿主版本。拿不到时写 `0` 而不是空串 ——
/// 管理页会把它显示成「授权于 1.2.0」，空串会变成一条没有来源的记录。
static NSString *A2PermissionHostVersion(void) {
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    return version.length ? version : @"0";
}

/// 64 位 hex（可带 `sha256:` 前缀）。与注册表的判定口径一致。
static BOOL A2PermissionIsValidHash(NSString *hash) {
    if (![hash isKindOfClass:NSString.class]) return NO;
    NSString *value = [hash hasPrefix:@"sha256:"] ? [hash substringFromIndex:7] : hash;
    if (value.length != 64) return NO;
    NSCharacterSet *notHex = [[NSCharacterSet characterSetWithCharactersInString:
                               @"0123456789abcdef"] invertedSet];
    return [value rangeOfCharacterFromSet:notHex].location == NSNotFound;
}

static NSString *A2PermissionNormalizedHash(NSString *hash) {
    return [hash hasPrefix:@"sha256:"] ? [hash substringFromIndex:7] : hash;
}

#pragma mark - 目录条目

@interface A2PluginPermissionInfo ()
@property (nonatomic, copy) NSString *permissionId;
@property (nonatomic, assign) A2PluginRisk risk;
@property (nonatomic, assign) A2PluginPermissionGroup group;
@property (nonatomic, assign) A2PluginMilestone milestone;
@property (nonatomic, copy) NSString *shortName;
@property (nonatomic, copy) NSString *consequence;
@property (nonatomic, copy) NSString *definition;
@property (nonatomic, copy) NSArray<NSString *> *allowedOperations;
@property (nonatomic, copy) NSString *boundary;
@property (nonatomic, copy) NSArray<NSString *> *harmScenarios;
@end

@implementation A2PluginPermissionInfo
@end

NSString *A2PluginRiskDisplayName(A2PluginRisk risk) {
    switch (risk) {
        case A2PluginRiskLow: return @"低";
        case A2PluginRiskMedium: return @"中";
        case A2PluginRiskCritical: return @"高危";
        case A2PluginRiskUnknown: break;
    }
    return @"未知";
}

NSString *A2PluginPermissionGroupTitle(A2PluginPermissionGroup group) {
    switch (group) {
        case A2PluginPermissionGroupGameFiles: return @"改游戏文件";
        case A2PluginPermissionGroupNetwork: return @"联网";
        case A2PluginPermissionGroupReadData: return @"读你的数据";
        case A2PluginPermissionGroupLaunch: return @"启动参数";
        case A2PluginPermissionGroupInterface: return @"改界面";
        case A2PluginPermissionGroupCount: break;
    }
    return @"";
}

NSString *A2PluginPermissionGroupConsequence(A2PluginPermissionGroup group) {
    switch (group) {
        case A2PluginPermissionGroupGameFiles:
            return @"能修改游戏内容（等同直接装 mod，可执行代码）";
        case A2PluginPermissionGroupNetwork:
            return @"能把数据发到网上 / 从网上下载东西";
        case A2PluginPermissionGroupReadData:
            return @"能查看你的游戏文件与配置";
        case A2PluginPermissionGroupLaunch:
            return @"能改游戏如何启动（可注入代码）";
        case A2PluginPermissionGroupInterface:
            return @"能改启动器看起来的样子";
        case A2PluginPermissionGroupCount:
            break;
    }
    return @"";
}

NSString *A2PluginMilestoneName(A2PluginMilestone milestone) {
    switch (milestone) {
        case A2PluginMilestoneP1: return @"P1";
        case A2PluginMilestoneP2: return @"P2";
        case A2PluginMilestoneP3a: return @"P3a";
        case A2PluginMilestoneP3b: return @"P3b";
        case A2PluginMilestoneP4: return @"P4";
        case A2PluginMilestoneP5: return @"P5";
    }
    return @"";
}

#pragma mark - 目录内容（PLUGIN-SECURITY §2 / §3.2.1 / §9）

/// 建一条目录条目。风险级不在这里写：它是 `A2PluginRiskForPermission` 的返回值，
/// 权限集规范串也用它 —— 两处各写一份的话，「中 → critical 升级」就判定不出来。
static A2PluginPermissionInfo *A2PermissionEntry(NSString *permissionId,
                                                 A2PluginPermissionGroup group,
                                                 A2PluginMilestone milestone,
                                                 NSString *shortName,
                                                 NSString *consequence,
                                                 NSString *definition,
                                                 NSArray<NSString *> *operations,
                                                 NSString *boundary,
                                                 NSArray<NSString *> *scenarios) {
    A2PluginPermissionInfo *info = [[A2PluginPermissionInfo alloc] init];
    info.permissionId = permissionId;
    info.risk = A2PluginRiskForPermission(permissionId);
    info.group = group;
    info.milestone = milestone;
    info.shortName = shortName;
    info.consequence = consequence;
    info.definition = definition;
    info.allowedOperations = operations;
    info.boundary = boundary;
    info.harmScenarios = scenarios ?: @[];
    return info;
}

NSArray<A2PluginPermissionInfo *> *A2PluginPermissionCatalog(void) {
    static NSArray<A2PluginPermissionInfo *> *catalog = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<A2PluginPermissionInfo *> *items = [NSMutableArray array];

        // ---- 改游戏文件（3 项，2 项高危）----
        [items addObject:A2PermissionEntry(
            @"files.game.write.content", A2PluginPermissionGroupGameFiles,
            A2PluginMilestoneP3a, @"修改游戏内容",
            @"能修改游戏内容（等同直接安装 mod，可执行代码）",
            @"能替换游戏目录里的 mod、资源包、光影包和存档文件。",
            @[@"写入或覆盖 mods 下的 jar", @"替换 resourcepacks / shaderpacks",
              @"改写 saves 下的存档", @"删除这些位置的文件"],
            @"不能改游戏目录以外的文件，不能改 libraries/ 下的库，也碰不到你的账号数据。",
            @[@"插件可以把任意 mod 的 jar 换成自己的代码；下次启动游戏时这些代码会运行。",
              @"插件可以覆盖你的存档目录，把原来的世界换成它写好的内容。"])];

        [items addObject:A2PermissionEntry(
            @"files.game.write.config", A2PluginPermissionGroupGameFiles,
            A2PluginMilestoneP3a, @"改游戏设置",
            @"能改游戏设置（options.txt、config）",
            @"能改配置类文件：options.txt、config、mod 的 toml 配置、servers.dat。",
            @[@"写 options.txt", @"写 config 下的文件", @"写 mods 里的 toml 配置",
              @"写 servers.dat"],
            @"不能写 mod 的 jar，不能写存档、资源包、光影包，也不能碰游戏目录以外。",
            @[])];

        [items addObject:A2PermissionEntry(
            @"version.patch", A2PluginPermissionGroupGameFiles,
            A2PluginMilestoneP3a, @"改版本内容",
            @"能改版本目录里的内容（启动的版本可能不是你以为的那个）",
            @"能往版本目录写补丁文件，并改本地的 version.json。",
            @[@"写入版本目录下的补丁文件", @"替换本地的 version.json"],
            @"不能改 jar 本体与 libraries/；每次改动都记进 patches.log，版本详情页会常驻「已被插件修改」。",
            @[@"插件可以改版本元数据，让启动器显示的和实际运行的不是同一个版本。",
              @"插件可以塞进额外的库文件，让游戏加载到不是你安装的东西。"])];

        // ---- 联网（4 项，1 项高危）----
        [items addObject:A2PermissionEntry(
            @"network.http", A2PluginPermissionGroupNetwork,
            A2PluginMilestoneP4, @"联网",
            @"能联网（仅限声明过的域名）",
            @"只能访问它在安装时声明过的域名。",
            @[@"发送 GET / POST 请求", @"读取响应内容（单次 ≤ 8 MB）"],
            @"不能访问声明外的域名，不能用 file://，不能访问内网地址。",
            @[])];

        [items addObject:A2PermissionEntry(
            @"download.source", A2PluginPermissionGroupNetwork,
            A2PluginMilestoneP4, @"加下载源",
            @"能往下载器里加镜像源（下载的文件可能不是你选的那个来源）",
            @"能往下载器的候选源里追加镜像地址。",
            @[@"追加镜像 URL 模板"],
            @"只能追加，不能改下载引擎的选择顺序，也不参与官方文件的完整性校验。",
            @[])];

        [items addObject:A2PermissionEntry(
            @"download.fetch", A2PluginPermissionGroupNetwork,
            A2PluginMilestoneP4, @"自己下载文件",
            @"能自己下载文件到插件目录",
            @"能发起一次下载，存进插件自己的缓存目录。",
            @[@"发起一次下载（单文件 ≤ 512 MB）", @"读取下载结果"],
            @"域名仍受「联网」权限的预声明约束；下载内容不进备份。",
            @[])];

        [items addObject:A2PermissionEntry(
            @"ui.web", A2PluginPermissionGroupNetwork,
            A2PluginMilestoneP5, @"打开网页",
            @"能在插件页面里打开一个网页（内容来自网络）",
            @"能在插件页面里嵌一个网页。",
            @[@"在插件页面内加载远端页面"],
            @"不能用 file://；只能出现在插件页面里，不能覆盖宿主的关键界面。",
            @[@"插件页面里的内容由作者随时替换，页面之外看不到任何提示。",
              @"页面里输入的内容会直接发给远端服务器，Air2 不经过也不记录。"])];

        // ---- 读你的数据（2 项）----
        [items addObject:A2PermissionEntry(
            @"files.game.read", A2PluginPermissionGroupReadData,
            A2PluginMilestoneP4, @"读游戏文件",
            @"能读你的游戏文件（配置、日志、存档、mod、资源包）",
            @"能读游戏目录里的数据类文件。",
            @[@"读 options.txt 与 config", @"读 logs", @"读 mods 里的 jar 内容",
              @"读存档、资源包、光影包"],
            @"不能读 libraries/ 里的库，也不能读账号数据；单次 ≤ 8 MB；插件拿不到绝对路径。",
            @[])];

        [items addObject:A2PermissionEntry(
            @"files.export", A2PluginPermissionGroupReadData,
            A2PluginMilestoneP4, @"导出文件",
            @"能把你的文件交给系统分享面板（等于你自己发出去）",
            @"能把它已经能读的文件交给你选择的 App 或云盘。",
            @[@"唤起系统分享面板", @"导出它已能读的文件（单次 ≤ 512 MB）"],
            @"必须经过系统分享面板，插件不能自己指定落盘位置。",
            @[])];

        // ---- 启动参数（10 项，6 项高危）----
        [items addObject:A2PermissionEntry(
            @"launch.args", A2PluginPermissionGroupLaunch,
            A2PluginMilestoneP3a, @"追加 JVM 参数",
            @"能改启动参数（可注入 javaagent）",
            @"能在游戏主类之前追加裸 JVM 参数。",
            @[@"追加 -X 类参数", @"追加 -D 属性", @"追加 -javaagent（另需注入 agent 权限）",
              @"追加 -cp（另需 classpath 权限）"],
            @"不能写受保护参数（账号 token、--username 等），也不能写 -Dminecraft.api.*.host；"
             "同时申请注入 agent、classpath、环境变量代码任一项时，本权限会被直接拒装。",
            @[@"插件可以往 JVM 追加调试端口，让同一网络内的调试器接管游戏进程。",
              @"插件可以改内存参数，让游戏在你的设备上频繁闪退。"])];

        [items addObject:A2PermissionEntry(
            @"launch.gameArgs", A2PluginPermissionGroupLaunch,
            A2PluginMilestoneP3a, @"追加游戏参数",
            @"能给游戏本身追加启动参数（如连到指定服务器、改窗口大小）",
            @"能在游戏主类之后追加游戏自己的参数。",
            @[@"追加 --server 指向", @"追加窗口尺寸", @"追加游戏自身支持的开关"],
            @"不能写 --accessToken / --uuid / --username；单条 ≤ 2 KB，最多 64 条。",
            @[@"插件可以让你每次启动都自动连到它选的服务器，而不是你上次玩的那个。",
              @"插件可以把窗口改小、把渲染关掉，让游戏表现异常而你说不清原因。"])];

        [items addObject:A2PermissionEntry(
            @"launch.classpath", A2PluginPermissionGroupLaunch,
            A2PluginMilestoneP3a, @"改 classpath",
            @"能替换游戏的 classpath（可注入代码）",
            @"能往 classpath 追加插件自己的 jar。",
            @[@"追加插件目录里的 jar", @"追加游戏目录里已存在的 jar"],
            @"条目必须落在插件目录或游戏目录内，不能用沙箱外的绝对路径。",
            @[@"插件可以把自己的 jar 放进 classpath，于是游戏启动时加载的是它的代码。",
              @"插件可以替换游戏依赖的类，让原本的流程走到它写好的地方。"])];

        [items addObject:A2PermissionEntry(
            @"launch.libraryPath", A2PluginPermissionGroupLaunch,
            A2PluginMilestoneP3a, @"改原生库路径",
            @"能改原生库搜索路径（可加载被替换的动态库）",
            @"能往原生库搜索路径里追加目录。",
            @[@"追加原生库目录"],
            @"只能追加，不能替换宿主原有的库路径。",
            @[@"插件可以让游戏加载它自带的动态库，而不是系统里那一份。",
              @"被替换的库能直接读写游戏进程的内存。"])];

        [items addObject:A2PermissionEntry(
            @"launch.env.code", A2PluginPermissionGroupLaunch,
            A2PluginMilestoneP3a, @"用代码算环境变量",
            @"能在每次启动时用代码算环境变量（每次启动都会跑它的逻辑）",
            @"每次启动时由插件代码计算进程环境变量。",
            @[@"计算并设置环境变量（单个值 ≤ 4 KB）"],
            @"不能写宿主保留变量（HOME / TMPDIR / JAVA_HOME / DYLD_* / JAVA_TOOL_OPTIONS 等）；"
             "每次启动都会写一条脱敏诊断日志。",
            @[@"插件每次启动都会执行自己的逻辑，即使你什么都没点。",
              @"它可以改变游戏看到的环境，让某些 mod 的行为和你想的不一样。"])];

        [items addObject:A2PermissionEntry(
            @"launch.env", A2PluginPermissionGroupLaunch,
            A2PluginMilestoneP3a, @"设置固定环境变量",
            @"能在启动时设置固定环境变量",
            @"按 manifest 里写死的值设置环境变量。",
            @[@"设置 manifest 声明的环境变量（值 ≤ 4 KB）"],
            @"不能写宿主保留变量，值有长度上限。",
            @[])];

        [items addObject:A2PermissionEntry(
            @"launch.properties", A2PluginPermissionGroupLaunch,
            A2PluginMilestoneP3a, @"设置启动属性",
            @"能设置 -D 启动属性（只限 mod 加载器相关前缀）",
            @"能设置 fml. / forge. / fabric. / mixin. / iris. 这些前缀的启动属性。",
            @[@"设置 mod 加载器相关属性"],
            @"前缀必须在白名单内，其余参数只能走「追加 JVM 参数」。",
            @[])];

        [items addObject:A2PermissionEntry(
            @"launch.tuning", A2PluginPermissionGroupLaunch,
            A2PluginMilestoneP3a, @"调内存 / GC",
            @"能调内存 / GC / 渲染开关（只在宿主允许的范围内）",
            @"能调整内存上下限、GC 选择和渲染开关。",
            @[@"调内存上限", @"选择 GC", @"开关部分渲染选项"],
            @"只接受宿主枚举内的键值，内存上限还受设备物理内存限制。",
            @[])];

        [items addObject:A2PermissionEntry(
            @"java.agent", A2PluginPermissionGroupLaunch,
            A2PluginMilestoneP3a, @"注入 Java agent",
            @"能向游戏进程注入 Java agent（等同任意代码执行）",
            @"能通过 -javaagent / -agentlib / -Xrunjdwp 挂载代码或调试器。",
            @[@"挂载插件自带的 agent jar", @"打开调试器端口"],
            @"jar 必须在插件文件清单里并被哈希校验，路径必须在插件或游戏目录内。",
            @[@"插件可以向游戏进程注入任意 Java 代码，等同于把游戏进程交给它。",
              @"插件可以打开调试端口，让同一网络里的任何人都能接管你的游戏。"])];

        [items addObject:A2PermissionEntry(
            @"native.module", A2PluginPermissionGroupLaunch,
            A2PluginMilestoneP5, @"加载原生库",
            @"能加载原生动态库（等同任意代码执行）",
            @"能装载插件自带的 dylib。",
            @[@"装载插件自带的 dylib"],
            @"只在支持原生插件的设备上可用；ABI 版本必须匹配；只能调用宿主对外导出的接口。",
            @[@"原生库可以读写宿主进程的内存，Air2 的权限检查对它不起作用。",
              @"这段代码没有经过任何审核，它做什么你无法从授权页看出来。"])];

        // ---- 改界面（5 项）----
        [items addObject:A2PermissionEntry(
            @"ui.contribute", A2PluginPermissionGroupInterface,
            A2PluginMilestoneP2, @"往界面里加东西",
            @"能往启动器界面里加东西（图标、按钮、主题色、插件页面）",
            @"能往宿主预留的位置放图标、按钮、主题色和插件页面。",
            @[@"在宿主预留位置加组件", @"覆盖主题色", @"注册插件页面"],
            @"只能用宿主词表里的组件与图标，页面外框由宿主绘制。",
            @[])];

        [items addObject:A2PermissionEntry(
            @"ui.override", A2PluginPermissionGroupInterface,
            A2PluginMilestoneP3b, @"隐藏或替换界面",
            @"能隐藏或替换启动器界面的一部分",
            @"能隐藏或替换宿主界面的某些部分。",
            @[@"隐藏指定界面元素", @"整页替换", @"替换启动遮罩的内容"],
            @"不能隐藏「插件管理」「安全模式横幅」「取消启动」「启动失败页」这些入口；同一位置只允许一个插件占用。",
            @[])];

        [items addObject:A2PermissionEntry(
            @"version.decorate", A2PluginPermissionGroupInterface,
            A2PluginMilestoneP2, @"改版本显示名",
            @"能改版本列表上显示的名字和图标（只影响显示）",
            @"能改版本列表的标题、副标题、徽标和图标。",
            @[@"改标题", @"改副标题", @"换徽标与图标"],
            @"只影响显示，不改磁盘；宿主保留真实名，详情页可以切换查看。",
            @[])];

        [items addObject:A2PermissionEntry(
            @"version.filter", A2PluginPermissionGroupInterface,
            A2PluginMilestoneP4, @"筛选版本",
            @"能隐藏或置灰版本条目（只影响显示，不删文件）",
            @"能按规则隐藏或置灰版本条目。",
            @[@"隐藏版本条目", @"置灰版本条目"],
            @"不删任何文件，被隐藏的条目可以在设置里一键显示。",
            @[])];

        [items addObject:A2PermissionEntry(
            @"instance.guard", A2PluginPermissionGroupInterface,
            A2PluginMilestoneP4, @"实例前拦一下",
            @"能在你打开游戏实例前拦一下（只能否决，不能改数据）",
            @"能在打开或编辑实例前做检查，返回允许或拒绝。",
            @[@"允许打开", @"拒绝并给出原因", @"向你提一个问题"],
            @"只能否决，不能改实例数据；交互最长 60 秒，超时按允许处理。",
            @[])];

        catalog = [items copy];
    });
    return catalog;
}

A2PluginPermissionInfo *_Nullable A2PluginPermissionInfoForId(NSString *permissionId) {
    if (![permissionId isKindOfClass:NSString.class] || !permissionId.length) return nil;
    for (A2PluginPermissionInfo *info in A2PluginPermissionCatalog()) {
        if ([info.permissionId isEqualToString:permissionId]) return info;
    }
    return nil;
}

#pragma mark - 存储

@interface A2PluginPermissionStore ()
@property (nonatomic, strong) A2PluginRegistry *registry;
@end

@implementation A2PluginPermissionStore

- (instancetype)init {
    // 与头文件 NS_UNAVAILABLE 对应：没有注册表的权限存储是非法状态。
    // 声明/实现一致性检查要求每个声明都有实现；正常代码走不到这里。
    return nil;
}

- (instancetype)initWithRegistry:(A2PluginRegistry *)registry {
    self = [super init];
    if (self) {
        _registry = registry;
    }
    return self;
}

#pragma mark 日志

- (void)logLine:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [@"[A2-PLUGIN-PERM] " stringByAppendingString:message ?: @""];
    [A2Log log:@"%@", line];
}

#pragma mark 内部

/// 取一条**可安全修改**的条目副本。
/// 不原地改注册表里的对象：`upsertEntry:` 写盘失败时会把旧对象放回去，
/// 旧对象已经被改过的话，「回滚」之后内存与磁盘就不一致了。
- (nullable A2PluginRegistryEntry *)editableEntryForPluginId:(NSString *)pluginId {
    A2PluginRegistryEntry *existing = [self.registry entryForPluginId:pluginId];
    if (!existing) return nil;
    NSError *error = nil;
    A2PluginRegistryEntry *copy =
        [A2PluginRegistryEntry entryWithDictionary:[existing dictionaryRepresentation]
                                             error:&error];
    if (!copy) {
        // 走到这里说明注册表里有一条已经读不回来的记录 —— 这是数据损坏，
        // 不是本次授权失败；如实报出来，不要静默继续写。
        [self logLine:@"entry-copy-failed plugin=%@ reason=%@",
               pluginId, error.localizedDescription ?: @"unknown"];
        return nil;
    }
    return copy;
}

/// 校验「这个权限对这份 manifest 而言能不能操作」，并返回目录条目。
- (BOOL)resolvePermission:(NSString *)permissionId
               inManifest:(A2PluginManifest *)manifest
                     info:(A2PluginPermissionInfo **)outInfo
                    error:(NSError **)error {
    if (![manifest isKindOfClass:A2PluginManifest.class] || !manifest.pluginId.length) {
        if (error) {
            *error = A2PluginPermissionErrorMake(A2PluginPermissionStoreErrorInvalidManifest,
                                                 @"缺少插件信息，无法处理权限");
        }
        return NO;
    }
    if (![permissionId isKindOfClass:NSString.class] || !permissionId.length) {
        if (error) {
            *error = A2PluginPermissionErrorMake(A2PluginPermissionStoreErrorUnknownPermission,
                                                 @"权限 id 为空");
        }
        return NO;
    }
    A2PluginPermissionInfo *info = A2PluginPermissionInfoForId(permissionId);
    if (!info) {
        if (error) {
            *error = A2PluginPermissionErrorMake(A2PluginPermissionStoreErrorUnknownPermission,
                                                 @"权限目录里没有「%@」", permissionId);
        }
        return NO;
    }
    if (![manifest hasPermission:permissionId]) {
        if (error) {
            *error = A2PluginPermissionErrorMake(A2PluginPermissionStoreErrorNotRequested,
                                                 @"插件「%@」没有申请「%@」",
                                                 manifest.pluginId, permissionId);
        }
        return NO;
    }
    if (![self.registry entryForPluginId:manifest.pluginId]) {
        if (error) {
            *error = A2PluginPermissionErrorMake(A2PluginPermissionStoreErrorNotInstalled,
                                                 @"插件「%@」不在注册表里，先安装再授权",
                                                 manifest.pluginId);
        }
        return NO;
    }
    if (outInfo) *outInfo = info;
    return YES;
}

/// 写入一条改动过的条目（`grantRevision` 已由调用方 +1）。
- (BOOL)commitEntry:(A2PluginRegistryEntry *)entry
            changed:(NSString *)changed
       permissionId:(NSString *)permissionId
              error:(NSError **)error {
    entry.updatedAt = A2PermissionISO8601Now();
    NSError *writeError = nil;
    if (![self.registry upsertEntry:entry error:&writeError]) {
        // 注册表失败原因照搬：可能是磁盘，也可能是条目校验不通过。
        // 后者必须是可修的（不该被压成一句「写盘失败」）。
        if (error) {
            *error = A2PluginPermissionErrorMake(A2PluginPermissionStoreErrorWrite,
                                                 @"写入注册表失败：%@",
                                                 writeError.localizedDescription ?: @"未知原因");
        }
        [self logLine:@"write-failed plugin=%@ perm=%@ action=%@",
               entry.pluginId, permissionId, changed];
        return NO;
    }
    [self logLine:@"%@ plugin=%@ perm=%@ rev=%ld",
           changed, entry.pluginId, permissionId, (long)entry.grantRevision];
    return YES;
}

/// 按 manifest 的申请顺序重排数组：注册表里同一个授权状态，
/// 不管用户是先开 A 再开 B 还是反过来，落盘结果都一样（便于取证与 diff）。
static NSArray<NSString *> *A2PermissionOrderedArray(NSSet<NSString *> *values,
                                                     NSArray<NSString *> *order) {
    NSMutableArray<NSString *> *ordered = [NSMutableArray arrayWithCapacity:values.count];
    for (NSString *item in order) {
        if ([values containsObject:item]) [ordered addObject:item];
    }
    // manifest 之外的历史残留（理论上不存在）追加在尾部，不丢数据
    for (NSString *item in values) {
        if (![ordered containsObject:item]) [ordered addObject:item];
    }
    return ordered;
}

- (nullable A2PluginCriticalGrant *)grantForPermission:(NSString *)permissionId
                                                 entry:(A2PluginRegistryEntry *)entry {
    for (A2PluginCriticalGrant *grant in entry.criticalGrants) {
        if ([grant.permissionId isEqualToString:permissionId]) return grant;
    }
    return nil;
}

/// 统一的「插件不在注册表里」失败出口：三处授予/撤销都要给出同一句话，
/// 否则用户在不同入口看到的同一个原因是三种说法。
- (BOOL)failNotInstalled:(NSString *)pluginId error:(NSError **)error {
    if (error) {
        *error = A2PluginPermissionErrorMake(A2PluginPermissionStoreErrorNotInstalled,
                                             @"插件「%@」不在注册表里，先安装再授权", pluginId);
    }
    [self logLine:@"refused plugin=%@ reason=not-installed", pluginId];
    return NO;
}

#pragma mark 授予

- (BOOL)grantPermission:(NSString *)permissionId
              forPlugin:(A2PluginManifest *)manifest
                  error:(NSError **)error {
    A2PluginPermissionInfo *info = nil;
    if (![self resolvePermission:permissionId inManifest:manifest info:&info error:error]) {
        return NO;
    }
    if (info.risk == A2PluginRiskCritical) {
        // 硬规则：critical 不能被一次性调用授予（§3.3）。这一步在存储层拦住，
        // 而不是靠「UI 记得走三次确认」—— 那是唯一挡得住误接线的位置。
        if (error) {
            *error = A2PluginPermissionErrorMake(
                A2PluginPermissionStoreErrorCriticalNeedsConfirmation,
                @"「%@」是高危权限，必须走三次确认才能授予", permissionId);
        }
        [self logLine:@"grant-refused plugin=%@ perm=%@ reason=critical-needs-confirmation",
               manifest.pluginId, permissionId];
        return NO;
    }

    A2PluginRegistryEntry *entry = [self editableEntryForPluginId:manifest.pluginId];
    if (!entry) return [self failNotInstalled:manifest.pluginId error:error];

    if ([entry.permissionsGranted containsObject:permissionId]) return YES;   // 幂等

    NSMutableSet<NSString *> *granted =
        [NSMutableSet setWithArray:entry.permissionsGranted ?: @[]];
    [granted addObject:permissionId];
    entry.permissionsGranted = A2PermissionOrderedArray(granted, manifest.permissions);
    entry.grantRevision = entry.grantRevision + 1;
    return [self commitEntry:entry changed:@"grant" permissionId:permissionId error:error];
}

- (BOOL)grantCriticalPermission:(NSString *)permissionId
                      forPlugin:(A2PluginManifest *)manifest
                          error:(NSError **)error {
    A2PluginPermissionInfo *info = nil;
    if (![self resolvePermission:permissionId inManifest:manifest info:&info error:error]) {
        return NO;
    }
    if (info.risk != A2PluginRiskCritical) {
        // 非高危项走普通授予：调用方（三次确认流程）只会传高危 id，
        // 但这里不制造一个「传错了就静默失败」的分支。
        return [self grantPermission:permissionId forPlugin:manifest error:error];
    }

    A2PluginRegistryEntry *entry = [self editableEntryForPluginId:manifest.pluginId];
    if (!entry) return [self failNotInstalled:manifest.pluginId error:error];

    NSInteger major = A2PermissionMajorVersion(manifest.version);
    A2PluginCriticalGrant *existing = [self grantForPermission:permissionId entry:entry];
    BOOL changed = !(existing && existing.majorVersion == major);

    if (changed) {
        NSDictionary<NSString *, id> *record = @{
            @"permissionId": permissionId,
            @"grantedAt": A2PermissionISO8601Now(),
            @"method": @"three-step",
            @"hostVersion": A2PermissionHostVersion(),
            @"majorVersion": @(major),
        };
        A2PluginCriticalGrant *grant = [A2PluginCriticalGrant grantWithDictionary:record];
        if (!grant) {
            if (error) {
                *error = A2PluginPermissionErrorMake(A2PluginPermissionStoreErrorWrite,
                                                     @"构造授权记录失败：%@", permissionId);
            }
            return NO;
        }
        NSMutableArray<A2PluginCriticalGrant *> *grants = [NSMutableArray array];
        for (A2PluginCriticalGrant *item in entry.criticalGrants) {
            if ([item.permissionId isEqualToString:permissionId]) continue;
            [grants addObject:item];
        }
        [grants addObject:grant];
        entry.criticalGrants = grants;
        entry.grantRevision = entry.grantRevision + 1;
    }

    // 包哈希只进白名单（取证），不参与授权判定（§3.4）。
    // 这里记的是**已安装内容**的那一份（entry.packageHash）——
    // 「用户在这个内容上点过同意」，正是 §3.3 记录规则要的事实。
    if (A2PermissionIsValidHash(entry.packageHash)) {
        [entry noteApprovedHash:entry.packageHash];
    }

    return [self commitEntry:entry changed:@"grant-critical" permissionId:permissionId
                       error:error];
}

- (BOOL)revokePermission:(NSString *)permissionId
               forPlugin:(A2PluginManifest *)manifest
                   error:(NSError **)error {
    A2PluginPermissionInfo *info = nil;
    if (![self resolvePermission:permissionId inManifest:manifest info:&info error:error]) {
        return NO;
    }

    A2PluginRegistryEntry *entry = [self editableEntryForPluginId:manifest.pluginId];
    if (!entry) return [self failNotInstalled:manifest.pluginId error:error];

    BOOL changed = NO;
    if ([entry.permissionsGranted containsObject:permissionId]) {
        NSMutableSet<NSString *> *granted =
            [NSMutableSet setWithArray:entry.permissionsGranted ?: @[]];
        [granted removeObject:permissionId];
        entry.permissionsGranted = A2PermissionOrderedArray(granted, manifest.permissions);
        changed = YES;
    }
    if ([self grantForPermission:permissionId entry:entry]) {
        NSMutableArray<A2PluginCriticalGrant *> *grants = [NSMutableArray array];
        for (A2PluginCriticalGrant *item in entry.criticalGrants) {
            if ([item.permissionId isEqualToString:permissionId]) continue;
            [grants addObject:item];
        }
        entry.criticalGrants = grants;
        changed = YES;
    }
    if (!changed) return YES;   // 幂等：本来就没授予

    entry.grantRevision = entry.grantRevision + 1;
    return [self commitEntry:entry changed:@"revoke" permissionId:permissionId error:error];
}

#pragma mark 查询

- (BOOL)isGranted:(NSString *)permissionId forPlugin:(NSString *)pluginId {
    if (!permissionId.length || !pluginId.length) return NO;
    A2PluginRegistryEntry *entry = [self.registry entryForPluginId:pluginId];
    if (!entry) return NO;

    A2PluginPermissionInfo *info = A2PluginPermissionInfoForId(permissionId);
    if (info.risk == A2PluginRiskCritical) {
        return [self grantForPermission:permissionId entry:entry] != nil;
    }
    return [entry.permissionsGranted containsObject:permissionId];
}

- (NSArray<NSString *> *)criticalPermissionsAwaitingConfirmationForManifest:
                                (A2PluginManifest *)manifest
                                                                     error:(NSError **)error {
    if (![manifest isKindOfClass:A2PluginManifest.class] || !manifest.pluginId.length) {
        if (error) {
            *error = A2PluginPermissionErrorMake(A2PluginPermissionStoreErrorInvalidManifest,
                                                 @"缺少插件信息，无法判定是否需要重确认");
        }
        return @[];
    }
    A2PluginRegistryEntry *entry = [self.registry entryForPluginId:manifest.pluginId];
    NSInteger major = A2PermissionMajorVersion(manifest.version);

    NSMutableArray<NSString *> *pending = [NSMutableArray array];
    for (NSString *permissionId in manifest.permissions) {
        if (A2PluginRiskForPermission(permissionId) != A2PluginRiskCritical) continue;
        // 未安装（entry 为 nil）时全部高危项都在等待确认 —— 首装就是这么走的。
        A2PluginCriticalGrant *grant = entry
            ? [self grantForPermission:permissionId entry:entry] : nil;
        if (!grant) {
            [pending addObject:permissionId];
            continue;
        }
        // 授权时的主版本与当前不等 ⇒ 跨 major，逐项重确认（§3.4 补充规则 8）
        if (grant.majorVersion != major) [pending addObject:permissionId];
    }
    return pending;
}

- (BOOL)needsReconfirmForManifest:(A2PluginManifest *)manifest
                      packageHash:(nullable NSString *)packageHash
                            error:(NSError **)error {
    NSArray<NSString *> *pending =
        [self criticalPermissionsAwaitingConfirmationForManifest:manifest error:error];
    if (!manifest.pluginId.length) return NO;   // 已在上面给了 InvalidManifest

    NSString *hash = packageHash.length ? A2PermissionNormalizedHash(packageHash) : @"-";
    if (pending.count == 0) {
        // §3.4 上表：包哈希变化但权限集相同 / 同包重装 → 不弹。
        // 这一行是「为什么不弹」的唯一线索，别删。
        [self logLine:@"reconfirm=0 plugin=%@ hash=%@ reason=permission-set-unchanged",
               manifest.pluginId, hash];
        return NO;
    }
    [self logLine:@"reconfirm=1 plugin=%@ hash=%@ pending=%@",
           manifest.pluginId, hash, [pending componentsJoinedByString:@","]];
    return YES;
}

#pragma mark 取证

- (BOOL)noteApprovedHash:(NSString *)packageHash
               forPlugin:(NSString *)pluginId
                   error:(NSError **)error {
    if (!A2PermissionIsValidHash(packageHash)) {
        if (error) {
            *error = A2PluginPermissionErrorMake(A2PluginPermissionStoreErrorInvalidHash,
                                                 @"包哈希「%@」不是 64 位 hex", packageHash ?: @"(空)");
        }
        return NO;
    }
    A2PluginRegistryEntry *entry = [self editableEntryForPluginId:pluginId];
    if (!entry) return [self failNotInstalled:pluginId error:error];

    // 已经是最新一条时不写盘：每次打开授权页都写一次会让 seq 无意义地涨。
    NSString *newest = entry.approvedHashes.firstObject;
    BOOL alreadyRecorded = newest &&
        [A2PermissionNormalizedHash(newest) isEqualToString:A2PermissionNormalizedHash(packageHash)];
    if (alreadyRecorded) return YES;

    if (![entry noteApprovedHash:packageHash]) {
        if (error) {
            *error = A2PluginPermissionErrorMake(A2PluginPermissionStoreErrorInvalidHash,
                                                 @"包哈希「%@」不合法", packageHash);
        }
        return NO;
    }
    // 白名单不授予任何东西，所以不动 grantRevision —— 能力面没变。
    return [self commitEntry:entry changed:@"note-hash" permissionId:@"-" error:error];
}

@end
