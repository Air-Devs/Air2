#import "LauncherPreferences.h"
#import "PLPreferences.h"
#import "UIKit+hook.h"
#import "config.h"
#import "utils.h"

// ★ [UI-LAYOUT-MIGRATE] 物理机型判定（不受 UIKit+hook 对 idiom 的改写影响）。
//   与 SceneDelegate.AmeSceneIsPhysicalPad / LauncherRootIsPhysicalPhone 同口径：
//   UIKit+hook.m 的 init_hookUIKitConstructor 会把 active idiom 强制改成 Pad/Phone，
//   故这里必须用 UIDevice.model 判断真机；未识别机型（模拟器）用 idiom 兜底。
static BOOL AmePrefsIsPhysicalPhone(void) {
    NSString *model = [[UIDevice currentDevice].model lowercaseString];
    if ([model containsString:@"ipad"]) return NO;
    if ([model containsString:@"iphone"] || [model containsString:@"ipod"]) return YES;
    return (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone);
}

NSString *const PREF_DOWNLOAD_SOURCE_MOD = @"general.download_source_mod";
NSString *const PREF_DOWNLOAD_SOURCE_SHADER = @"general.download_source_shader";
NSString *const PREF_DOWNLOAD_SOURCE_RESOURCEPACK = @"general.download_source_resourcepack";
NSString *const PREF_DOWNLOAD_SOURCE_DATAPACK = @"general.download_source_datapack";
NSString *const PREF_DOWNLOAD_SOURCE_MODPACK = @"general.download_source_modpack";
NSString *const PREF_DOWNLOAD_SOURCE_WORLD = @"general.download_source_world";
NSString *const PREF_DOWNLOAD_SOURCE_SERVER = @"general.download_source_server";
NSString *const PREF_CURSEFORGE_API_KEY = @"general.curseforge_api_key";
NSString *const PREF_MOD_UPDATE_KEEP_OLD = @"general.mod_update_keep_old";
NSString *const PREF_MOD_MIRROR = @"general.mod_mirror";

@interface PLPreferences()
@end

@implementation PLPreferences

+ (id)defaultPrefForGlobal:(BOOL)global {
    // Preferences that can be isolated
    NSMutableDictionary<NSString *, NSMutableDictionary *> *defaults = @{
        @"general": @{
            @"check_sha": @YES,
            // 启动时自动检查更新。必须在此注册：键不存在时 PLPreferences 的
            // setter 会静默失败，用户关掉开关也存不住，下次启动又会被
            // +autoCheckEnabled 当作"缺省"写回 @YES（本仓已知的坑）。
            @"auto_check_update": @YES,
            @"cosmetica": @YES,
            @"debug_logging": @(!CONFIG_RELEASE),
            @"news_url": @"https://air-api.vercel.app/api/announcements.php",
            @"download_source": @"bmclapi",
            // 各资源类型独立下载源（未显式设置时回退到 modrinth）
            @"download_source_mod": @"modrinth",
            @"download_source_shader": @"modrinth",
            @"download_source_resourcepack": @"modrinth",
            @"download_source_datapack": @"modrinth",
            @"download_source_modpack": @"modrinth",
            @"download_source_world": @"modrinth",
            @"download_source_server": @"modrinth",
            // CurseForge API Key：空串代表使用编译时内置的默认 key
            @"curseforge_api_key": @"",
            // Mod 更新时是否保留旧文件（默认 YES）
            @"mod_update_keep_old": @YES,
            // 模组镜像源：official（官方源）/ mcim（MCIM 镜像源，国内加速）
            @"mod_mirror": @"official",
            // profile 写入的强制内存分配，0=使用 java.allocated_memory/auto_ram 逻辑
            @"ram_allocation": @(0),
            // 首页公告磁贴预览级别：full（标题+日期+摘要）/ summary（标题+摘要）/ title_only（仅标题）
            @"announcement_preview_level": @"summary",
        }.mutableCopy,
        // 分类镜像策略（值 auto / official_first / mirror_first，由 PLMirrorCenter 统一读取，
        // 未迁移时 PLMirrorCenter 会回退旧键 general.download_source）
        // 默认 auto（对齐 ZL2 MirrorSourceType.AUTO）：大陆环境镜像优先、其余官方优先
        @"download": @{
            @"fileSource": @"auto",
            @"assetSearchSource": @"auto",
            @"assetDownloadSource": @"auto",
            @"modLoaderSource": @"auto",
            // 一次性迁移哨兵：YES 表示旧键 download_source 已迁移到上述 4 键，
            // 防止用户手动改新键后被重复迁移覆盖（见 LauncherPreferences.m migrateDownloadSourcePreferences）
            @"sourceMigrated": @NO,
        }.mutableCopy,
        @"video": @{ // Video & Audio
            @"renderer": @"auto",
            @"resolution": @(100),
            // max_framerate 选项已移除：CADisplayLink 始终采用 30-120Hz 自适应范围，
            // 由屏幕硬件能力决定实际帧率。保留 disable_game_vsync 作为唯一帧率解锁开关。
            // 解锁帧率（关闭垂直同步）：默认开启。
            // MC 默认 enableVsync=true，会把帧率锁在屏幕刷新率（60Hz 锁 60、120Hz ProMotion 锁 120）。
            // 开启后启动器会在三层联动关闭 VSync：options.txt 强制 enableVsync=false、
            // pojavSwapInterval 强制 interval=0、CAMetalLayer 三缓冲。详见各修改点注释。
            @"disable_game_vsync": @YES,
            @"performance_hud": @NO,
            @"fullscreen_airplay": @YES,
            @"silence_other_audio": @NO,
            @"silence_with_switch": @NO,
            @"fix_simple_voice_chat_mod": @NO,
            @"allow_microphone": @NO,
            // MC 26.2+ 游戏内 OpenGL/Vulkan 切换，空串=默认（由 JavaLauncher 处理）
            @"graphics_api": @"",
            // SimpleFPEWrapper（GL 1.x 固定管线仿真层）叠加开关。
            // 默认关闭：iOS 侧叠加后 mobileglues / MobileGL-gles 两条路径在 1.7.10 上
            // 均会崩溃，故改为显式开启（opt-in）。
            // 键必须在此注册：否则 PLPreferences 的 getter/setter 因键不存在而静默
            // 失败（日志刷 "could not find preference video.sfpew_overlay"），
            // 设置页开关既读不出也存不下。
            @"sfpew_overlay": @NO,
            // iOS Kopper 直显（实验）：zink 渲染器下让 Mesa 直接 present 到
            // CAMetalLayer 的 Vulkan swapchain，跳过每帧 CPU 回读 + CGImage
            // 上传（OSMesa 离屏链路的主要开销）。默认关闭。
            // 键必须在此注册，否则设置页开关存不下（见 setObject 的说明）。
            @"kopper": @NO
        }.mutableCopy,
        @"control": @{
            @"default_ctrl": @"default.json",
            @"control_safe_area": UIApplication.sharedApplication ? NSStringFromUIEdgeInsets(getDefaultSafeArea()) : @"",
            @"default_gamepad_ctrl": @"default.json",
            @"controller_type": @"xbox",
            @"hardware_hide": @YES,
            @"recording_hide": @YES,
            @"gesture_mouse": @YES,
            // ★ [BT-MOUSE] 蓝牙鼠标/触控板（iOS 间接指针）支持总开关，默认开。
            //   iOS 上部分蓝牙鼠标/触控板（尤其 iPhone「辅助触控 → 指点设备」、
            //   以及 GameController 的 GCMouse 未报告鼠标的机型）不走 GCMouse，
            //   而以「间接指针」(UITouch.type == UITouchTypeIndirectPointer) 的
            //   hover/touch 形式送到 UIKit。开启后由 UIKit 层接住并复用既有合成
            //   路径送进游戏；仅当 GCMouse 未报告任何鼠标时接管，故与硬件鼠标、
            //   触控模拟鼠标零冲突。关掉即回到现状（触控/键盘不受影响）。
            //   键必须在此注册：否则 PLPreferences getter/setter 因键不存在而静默
            //   失败，设置页既读不出也存不下。
            @"bt_pointer_enable": @YES,
            // ★ [ISSUE-152] 游戏内悬浮球（小齿轮 = GameMenuOverlayView.menuButton）显示开关。
            //   默认 @YES = 【不改变现状】：升级后行为与改动前逐字一致（浮球照常显示），
            //   只有用户主动关掉才隐藏。issue #152 诉求「把小齿轮改成 Amethyst 那样，或加一个
            //   隐藏小齿轮的设置」——本仓无 Amethyst 参考实现/截图，故采用可验证的后半条：
            //   设置页加一行开关（沿用现有 UISwitch 样式）+ 偏好键。
            //   键必须在此注册：否则 PLPreferences getter/setter 因键不存在而静默失败，
            //   设置页开关既读不出也存不下。
            @"menu_button_visible": @YES,
            @"gesture_hotbar": @YES,
            @"disable_haptics": @NO,
            @"slideable_hotbar": @NO,
            @"press_duration": @(400),
            // ★ [TAP-CLICK] 轻触即左键（可调 + 开关）
            //   tap_click_enable       : 总开关，默认开；关掉即回到旧行为
            //                            （游戏内轻触=右键放置、菜单轻触=左键，长按=左键破坏）
            //   tap_click_duration     : 时长阈值(ms)，轻触时长须 < 该值
            //   tap_click_move         : 位移阈值(pt)，按下点与抬起点距离须 < 该值
            //   tap_click_button_right : 【兼容旧键】合成按键，YES=右键(旧"轻触=放置")。
            //                            见下方 tap_click_mode；本键为 YES 时强制 right。
            // ★ [TAP-UNIVERSAL] 轻触按键模式（单键通用）：
            //   tap_click_mode ∈ { "auto"(默认), "left", "right" }
            //     auto  : 启动器只发"轻触 marker"，由游戏侧(agent)按 Minecraft.hitResult 决定
            //             真键 —— 实体→左键攻击；方块可交互→右键打开；手持可放置→右键放置；
            //             普通方块/打空→左键挖掘。启动器看不到世界，判定只能在游戏侧。
            //     注意: auto 依赖游戏侧 agent(MouseHandler.onButton 补丁)。若 agent 缺失，
            //           marker 在游戏里是空操作 ⇒ 请把模式改为 left。
            //     left  : 恒左键(等价旧默认)。
            //     right : 恒右键(等价旧 tap_click_button_right=开)。
            // 键必须在此注册：否则 PLPreferences getter/setter 因键不存在而静默失败，
            // 设置页既读不出也存不下。
            @"tap_click_enable": @YES,
            @"tap_click_duration": @(300),
            @"tap_click_move": @(10),
            @"tap_click_button_right": @NO,
            @"tap_click_mode": @"auto",
            // ★ [TAP-BTN] 「非按键区域轻触默认动作」开关：ON = 非按键区域(游戏视野)的轻触恒发左键。
            //   优先级见 SurfaceViewController -tapClickEffectiveMode：旧键 tap_click_button_right(=right)
            //   > tap_click_mode 显式 left/right > 本开关(→left) > auto(智能/单键通用)。
            //   默认 @NO = 【不改变现状】：轻触仍按 tapClickEffectiveMode 智能判定(auto)。
            //   键必须在此注册：否则 getPrefBool/setter 因键不存在而静默失败，设置页既读不出也存不下。
            @"tap_default_left": @NO,
            @"button_scale": @(100),
            @"mouse_scale": @(100),
            @"mouse_speed": @(100),
            @"virtmouse_enable": @NO,
            @"gyroscope_enable": @NO,
            @"gyroscope_invert_x_axis": @NO,
            @"gyroscope_sensitivity": @(100),
            @"mod_touch_enable": @NO,
            @"mod_touch_mode": @0,
            @"mod_touch_vibrate_enable": @YES,
            @"mod_touch_vibrate_intensity": @2,
            @"mod_touch_moveview_enable": @NO,   // ★ [HOST-BUG-B] 强制关闭(「视角摇晃/移动视角」功能已移除,不再暴露开关)
            // UI 子面板占位 key（LauncherPreferencesViewController 的 getPreference 回调
            // 会对每个设置项按 "section.key" 查询，包括 button/childPane 类型）。
            // 提供空串默认值避免触发 "Getter could not find preference control.custom_controls" 日志。
            @"custom_controls": @""
        }.mutableCopy,
        @"java": @{
            @"java_homes": @{
                @"0": @{
                    @"1_16_5_older": @"8",
                    @"1_17_newer": @"17",
                    @"execute_jar": @"8"
                }.mutableCopy,
                @"8": @"internal",
                @"17": @"internal",
                @"21": @"internal",
                @"25": @"internal"
            }.mutableCopy,
            @"java_args": @"",
            @"env_variables": @"",
            // ★ [DYLD-SWITCH] dyld 库校验旁路总开关（设置页：Java 调整 → 绕过 dyld 库校验）。
            // 键必须在此注册，否则 getter/setter 静默失败，设置页开关存不下来
            // （日志 "could not find preference java.dyld_bypass"）。
            // 默认 @NO：真机 A/B 证实旁路会让启动器卡死在 dlopen(libjli)。
            // 来源 fork 分支 fix/dyld-bypass-default-off @ c26262a58b。
            @"dyld_bypass": @NO,
            @"auto_ram": @(!getEntitlementValue(@"com.apple.private.memorystatus")),
            @"allocated_memory": [NSNumber numberWithFloat:roundf((NSProcessInfo.processInfo.physicalMemory / 1048576) * 0.25)],
            // profile 写入的强制 Java 版本，auto=根据游戏版本自动选择
            @"java_version": @"auto"
        }.mutableCopy,
        // MobileGlues 渲染器偏好
        // 当渲染器选择为 MobileGlues 或 Vulkan 时，由 init_loadMobileGluesConfig() 写入
        // <POJAV_HOME>/MG/config.json，控制 GL 版本、ANGLE 后端、FSR 等。
        // Vulkan 渲染器的 OpenGL 回退使用 MobileGlues（对齐 Ynnyny 仓库），设置生效。
        // Auto 渲染器实际使用 ANGLE，不会加载 MobileGlues，这些设置不生效。
        @"mobileglues": @{
            @"enable_angle": @NO,
            @"enable_no_error": @(0),
            @"enable_ext_timer_query": @YES,
            @"enable_ext_compute_shader": @NO,
            @"enable_ext_direct_state_access": @NO,
            // Task129d（对齐参考仓库）：着色器缓存 128MB。旧默认 32MB 对重型
            // 整合包偏小——MG 的 Cache::put 是标准 LRU，容量耗尽即逐出，
            // 逐出意味着资源重载时整条 glslang→SPIRV→ESSL 链要重跑。
            // 26.3 的着色器规模远大于 26.2，整合包更是成倍，32MB 下
            // 重编译压力集中爆发。用户仍可在偏好分区改回。
            @"max_glsl_cache_size": @(128),
            @"multidraw_mode": @(0),
            @"angle_depth_clear_fix_mode": @(0),
            @"custom_gl_version": @(0),
            @"fsr1_setting": @(0)
        }.mutableCopy,
        // 游戏内覆盖层（GameMenuOverlayView）的位置持久化与开关
        // 位置以屏幕宽高百分比存储（0.0~1.0），哨兵值 -1 表示未设置，
        // GameMenuOverlayView 的 restorePositions 会回退到硬编码默认位置。
        @"game": @{
            @"menu_button_x": @(-1.0),
            @"menu_button_y": @(-1.0),
            @"stats_label_x": @(-1.0),
            @"stats_label_y": @(-1.0),
            @"stats_label_visible": @YES
        }.mutableCopy,
        @"internal": @{
            @"isolated": @NO,
            @"latest_version": [NSDictionary new],
            // ★ [VER-ISOLATE-PCL] 版本隔离一次性迁移哨兵（对应 [UI-LAYOUT-MIGRATE] 的写法）：
            // YES 表示"升级前已手工隔离过"的 profile 已被显式写回 versionIsolation。
            // 默认值只在键缺失时写入，故哨兵保证迁移只跑一次且不会被重复覆盖。
            @"version_isolation_migrated": @NO,
            // Task129d 迁移哨兵：YES 表示旧的 32MB 着色器缓存默认已治愈为 128MB。
            // 默认值只在键缺失时写入，而 @(32) 也会占住键——存量设备的 plist
            // 里那个 32 必须迁移一次才吃得到新默认；本哨兵保证只跑一次，
            // 不会覆盖用户手动改过的值（仅当值 <= 32 才迁移）。
            @"task129d_mg_cache_default_migrated": @NO
        }.mutableCopy
    }.mutableCopy;

    if (global) {
        // Preferences that cannot be isolated
        NSDictionary *general = @{
            @"game_directory": @"default",
            // ★ [VER-ISOLATE-PCL] 默认版本隔离（全局，对应 PCL-CE 的「默认实例隔离」
            // LaunchArgumentIndieV2）。关闭 = 实例内各版本共享 mods/config/saves（现状，
            // 默认值沿用本工程既有习惯，保证升级零行为变化）；开启 = 逐版本隔离到
            // <实例根>/versions/<版本 id>/。单版本可在「编辑配置」页用 versionIsolation 覆盖。
            // 放在 global 段（不可被实例偏好覆盖），与 game_directory 同层。
            @"version_isolation": @NO,
            @"hidden_sidebar": @(realUIIdiom == UIUserInterfaceIdiomPhone),
            @"appicon": @"AppIcon-Light",
            // ★ [UI-LAYOUT] 遗留键：布局已改为按设备自动判定（iPhone⇒标准 / iPad⇒卡片），SceneDelegate 不再读它。
            //   保留键避免旧读取方拿到 nil；值 "vs" 仅为历史默认。
            @"ui_layout": @"vs",
            @"ui_theme": @"dark",
            @"multi_threaded": @NO,
            // 自定义外观颜色（hex 字符串，空串=使用默认深色毛玻璃/白色文字）
            @"text_color": @"",
            @"card_color": @"",
            // 主题强调色（hex 字符串，空串=回退到默认蓝 #429CF5，见 LauncherPreferences.m accentColor()）
            // 提供默认值避免每次访问触发 "Getter could not find preference general.accent_color" 日志
            @"accent_color": @""
        };
        [defaults[@"general"] addEntriesFromDictionary:general];

        defaults[@"java"][@"manage_runtime"] = @""; // stub
        defaults[@"debug"] = @{
            // ★ [UI-LAYOUT] 内部布局回退开关（不暴露给设置 UI）：仅 iPad 生效，值 "vs"
            //   ⇒ 临时强制标准布局（Root）；"card"/空 ⇒ 按设备自动（iPad 卡片）。见 SceneDelegate。
            @"debug_ui_layout_force": @"",
            @"debug_universal_script_jit": @NO,
            @"debug_always_attached_jit": @NO,
            @"debug_skip_wait_jit": @NO,
            // Task 134（参照 Air）：JIT 开启工具选择（auto = 原自动判定）与
            // iOS 26 JS 脚本 JIT 开关（默认携带脚本）
            @"jit_enabler": @"auto",
            @"jit26_script_disable": @NO,
            @"debug_hide_home_indicator": @NO,
            @"debug_ipad_ui": @(realUIIdiom == UIUserInterfaceIdiomPad),
            @"debug_auto_correction": @YES,
            @"debug_show_layout_bounds": @NO,
            @"debug_show_layout_overlap": @NO
        }.mutableCopy;
        defaults[@"warnings"] = @{
            @"local_warn": @YES,
            @"mem_warn": @YES,
            @"auto_ram_warn": @YES,
            @"limited_ram_warn": @YES
        }.mutableCopy;
        // TODO: isolate this or add account picker into profile editor(?)
        defaults[@"internal"][@"selected_account"] = @"";
    }

    return defaults;
}

+ (id)getPreference:(NSString *)key from:(NSDictionary *)pref {
    for (NSDictionary *section in pref.allValues) {
        if ([section isKindOfClass:NSDictionary.class] && section[key]) {
            return section[key];
        }
    }
    return nil;
}

+ (id)getOldLayoutPreference:(NSString *)key from:(NSDictionary *)pref {
    // Find preference in the root dictionary first
    if (pref[key]) {
        return pref[key];
    }
    // Find preference in subdictionaries
    id value = [self getPreference:key from:pref];
    if (!value) {
        NSLog(@"[PLPreferences] Migrator could not find preference %@", key);
    }
    return value;
}

- (id)initWithGlobalPath:(NSString *)path {
    self = [super init];
    self.globalPath = path;
    self.globalPref = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    [self saveGlobalPref];
    return self;
}

- (id)initWithAutomaticMigrator {
    self = [super init];
    self.globalPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"launcher_preferences_v2.plist"];
    NSMutableDictionary *pref = [NSMutableDictionary dictionaryWithContentsOfFile:self.globalPath];

    NSString *oldPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"launcher_preferences.plist"];
    NSMutableDictionary *oldPref = [NSMutableDictionary dictionaryWithContentsOfFile:oldPath];

    if (pref || !oldPref[@"env_vars"]) {
        // Initialize or load existing v2 layout
        self.globalPref = pref;
    } else {
        NSDebugLog(@"[PLPreferences] Migrating to %@", self.globalPath.lastPathComponent);
        // Perform migration from v1 layout
        self.globalPref = [NSMutableDictionary new];
        for (NSString *section in self.globalPref.allKeys) {
            for (NSString *key in self.globalPref[section].allKeys) {
                id value = [PLPreferences getOldLayoutPreference:key from:oldPref];
                if (value) {
                    self.globalPref[section][key] = value;
                }
            }
        }
    }

    [self saveGlobalPref];
    return self;
}

- (id)setDefaultsForPref:(NSMutableDictionary *)pref global:(BOOL)global {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *defaults = [PLPreferences defaultPrefForGlobal:global];
    if (!pref) {
        NSLog(@"[PLPreferences] Initializing default values for %@ preferences", global ? @"global" : @"isolated");
        return defaults;
    }

    for (NSString *section in defaults.allKeys) {
        if (!pref[section]) {
            NSDebugLog(@"[PLPreferences] Set default values for section %@", section);
            pref[section] = defaults[section];
            continue;
        }
        // 关键修复：从 plist 加载的嵌套字典是不可变 NSDictionary（NSMutableDictionary
        // dictionaryWithContentsOfFile: 只保证顶层可变，嵌套字典仍为 NSDictionary）。
        // 如果不转为 NSMutableDictionary，后续 setValue:forKeyPath: 调用会抛出异常，
        // 导致用户修改的设置无法保存（mobileglues、video 等所有 section 均受影响）。
        if (![pref[section] isKindOfClass:[NSMutableDictionary class]]) {
            pref[section] = [pref[section] mutableCopy];
        }
        for (NSString *key in defaults[section].allKeys) {
            if (pref[section][key]) continue;
            id value = defaults[section][key];
            NSDebugLog(@"[PLPreferences] Set default vaule: %@", key, value);
            pref[section][key] = value;
        }
    }

    // Task129d 一次性治愈迁移：把历史持久化下来的 32MB 着色器缓存抬到 128MB。
    // 只在 global 偏好上跑一次；值已被用户改大过（> 32）则不动。
    if (global) {
        NSMutableDictionary *internal = pref[@"internal"];
        if (![internal isKindOfClass:[NSMutableDictionary class]]) {
            internal = [internal mutableCopy];
            pref[@"internal"] = internal;
        }
        if (![internal[@"task129d_mg_cache_default_migrated"] boolValue]) {
            NSMutableDictionary *mg = pref[@"mobileglues"];
            if ([mg isKindOfClass:[NSMutableDictionary class]] && mg[@"max_glsl_cache_size"]) {
                int cached = [mg[@"max_glsl_cache_size"] intValue];
                if (cached <= 32) {
                    mg[@"max_glsl_cache_size"] = @(128);
                    NSLog(@"[PLPreferences] Task129d: migrating mobileglues.max_glsl_cache_size %d -> 128 (heavy modpack shader recompilation pressure)", cached);
                }
            }
            internal[@"task129d_mg_cache_default_migrated"] = @YES;
        }
    }

    // ★ [UI-LAYOUT-MIGRATE] 启动最早期一次性迁移：旧版设置页允许把 iPhone 的
    //   general.ui_layout 设成 "card"（iPad 卡片布局）。升级后切换入口已删除，用户
    //   自己换不回来，主页长期错乱。这里【启动时主动写回】（不是仅被动忽略）：
    //     iPhone + ui_layout == "card"  ⇒  强制改写为 "vs"（并打迁移日志）；
    //     iPad 上保留 "card"（那是设计）；空 / "vs" / 未设置一律不动。
    //   写回发生在 global 偏好上；initWithAutomaticMigrator 末尾的 saveGlobalPref 会
    //   持久化 ⇒ 幂等：迁移后值即非 card，下次启动不再触发、不再刷日志。
    //   所有后续读取方（SceneDelegate 只按机型判定；若有旧/新读取方读该键，请走
    //   ameResolveUILayout 或直接读本迁移后的值）看到的都是纠正后的值。
    if (global) {
        NSMutableDictionary *general = pref[@"general"];
        if (![general isKindOfClass:[NSMutableDictionary class]]) {
            general = general ? [general mutableCopy] : [NSMutableDictionary dictionary];
            pref[@"general"] = general;
        }
        NSString *uiLayout = general[@"ui_layout"];
        if (AmePrefsIsPhysicalPhone() && [uiLayout isKindOfClass:[NSString class]] &&
            [uiLayout isEqualToString:@"card"]) {
            NSLog(@"[UI-LAYOUT] migrated legacy ui_layout=card -> vs (iPhone)");
            general[@"ui_layout"] = @"vs";
        }
    }

    // ★ [TC-MOVEVIEW-MIGRATE] 启动最早期一次性迁移：强制关闭「视角摇晃/移动视角」
    //   (control.mod_touch_moveview_enable)。该开关已从 TouchController 管理界面移除，
    //   存量用户若曾设为 @YES，这里【启动时主动写回 @NO】（不是仅忽略），
    //   保证所有读取方（SurfaceViewController 手势闸门 / 统一解析函数
    //   ameResolveTouchMoveViewEnabled）看到的都是迁移后的值。
    //   哨兵 internal.hostbugb_moveview_forced_off 保证只执行一次；不触碰用户其它设置。
    if (global) {
        NSMutableDictionary *internal2 = pref[@"internal"];
        if (![internal2 isKindOfClass:[NSMutableDictionary class]]) {
            internal2 = [NSMutableDictionary dictionary];
            pref[@"internal"] = internal2;
        }
        if (![internal2[@"hostbugb_moveview_forced_off"] boolValue]) {
            NSMutableDictionary *ctl = pref[@"control"];
            if ([ctl isKindOfClass:[NSMutableDictionary class]]) {
                if ([ctl[@"mod_touch_moveview_enable"] boolValue]) {
                    NSLog(@"[TC-MOVEVIEW] migrated legacy control.mod_touch_moveview_enable=enable -> disable (feature removed)");
                }
                ctl[@"mod_touch_moveview_enable"] = @NO;
            }
            internal2[@"hostbugb_moveview_forced_off"] = @YES;
        }
    }
    return pref;
}

- (void)setGlobalPref:(NSMutableDictionary *)pref {
    _globalPref = [self setDefaultsForPref:pref global:YES];
}

- (void)setInstancePref:(NSMutableDictionary *)pref {
    _instancePref = [self setDefaultsForPref:pref global:NO];
}

- (void)toggleIsolationForced:(BOOL)force {
    NSMutableDictionary *instancePref = [NSMutableDictionary dictionaryWithContentsOfFile:self.instancePath];
    if (force || [instancePref[@"internal"][@"isolated"] boolValue]) {
        NSLog(@"[PLPreferences] Using isolated preferences from %@", self.instancePath.stringByResolvingSymlinksInPath);
        self.instancePref = instancePref;
        if (!instancePref) {
            // Copy preferences from the global one
            for (NSString *section in self.instancePref) {
                for (NSString *key in self.instancePref[section].allKeys) {
                    self.instancePref[section][key] = self.globalPref[section][key];
                }
            }
        }

        // Declare that itself is isolated
        self.instancePref[@"internal"][@"isolated"] = @YES;

        [self saveInstancePref];
    } else if (self.instancePref) {
        NSLog(@"[PLPreferences] Using global preferences");
        _instancePref = nil;
    }
}

- (id)getObject:(NSString *)key {
    id value = [self.instancePref valueForKeyPath:key];
    if (!value) {
        value = [self.globalPref valueForKeyPath:key];
    }
    if (!value) {
        NSLog(@"[PLPreferences] Getter could not find preference %@", key);
    }
    return value;
}

- (BOOL)setObject:(NSString *)key value:(id)value {
    /* Presence must be tested with an explicit nil check, not truthiness:
     * a stored @NO is non-nil but falsy, so `if ([... valueForKeyPath:key])`
     * silently dropped every write that tried to store a boolean OFF -
     * which is why switches backed by boolean prefs could be turned on but
     * never off (see general.auto_check_update). */
    if ([self.instancePref valueForKeyPath:key] != nil) {
        [self.instancePref setValue:value forKeyPath:key];
        [self saveInstancePref];
        return YES;
    } else if ([self.globalPref valueForKeyPath:key] != nil) {
        [self.globalPref setValue:value forKeyPath:key];
        [self saveGlobalPref];
        return YES;
    }
    NSLog(@"[PLPreferences] Setter could not find preference %@", key);
    return NO;
}

- (void)reset {
    if (self.instancePref) {
        [NSFileManager.defaultManager removeItemAtPath:self.instancePath error:nil];
        [self toggleIsolationForced:YES];
        // Only reset isolated values
        return;
    }

    self.globalPref = nil;
    [self saveGlobalPref];
}

- (void)saveGlobalPref {
    [self.globalPref writeToFile:self.globalPath atomically:YES];
}

- (void)saveInstancePref {
    [self.instancePref writeToFile:self.instancePath atomically:YES];
}

// 下载源管理（按类型独立持久化）
+ (NSString *)currentDownloadSourceForType:(NSString *)type {
    NSString *key = [self downloadSourceKeyForType:type];
    NSString *source = getPrefObject(key);
    return source ?: @"modrinth";
}

+ (void)setDownloadSource:(NSString *)source forType:(NSString *)type {
    NSString *key = [self downloadSourceKeyForType:type];
    setPrefObject(key, source);
}

+ (NSString *)downloadSourceKeyForType:(NSString *)type {
    if ([type isEqualToString:@"mod"]) return PREF_DOWNLOAD_SOURCE_MOD;
    if ([type isEqualToString:@"shader"]) return PREF_DOWNLOAD_SOURCE_SHADER;
    if ([type isEqualToString:@"resourcepack"]) return PREF_DOWNLOAD_SOURCE_RESOURCEPACK;
    if ([type isEqualToString:@"datapack"]) return PREF_DOWNLOAD_SOURCE_DATAPACK;
    if ([type isEqualToString:@"modpack"]) return PREF_DOWNLOAD_SOURCE_MODPACK;
    if ([type isEqualToString:@"world"]) return PREF_DOWNLOAD_SOURCE_WORLD;
    if ([type isEqualToString:@"server"]) return PREF_DOWNLOAD_SOURCE_SERVER;
    return PREF_DOWNLOAD_SOURCE_MOD;
}

// CurseForge API Key（运行时配置，覆盖编译时默认值）
+ (NSString *)curseForgeAPIKey {
    return getPrefObject(PREF_CURSEFORGE_API_KEY);
}

+ (void)setCurseForgeAPIKey:(NSString *)key {
    if (key && key.length > 0) {
        setPrefObject(PREF_CURSEFORGE_API_KEY, key);
    } else {
        // 注意：传 nil 会被 setValue:forKeyPath: 当作 remove，导致下次再写时
        // setObject:value: 因键不存在而静默失败。这里改写为空串以保留键。
        setPrefObject(PREF_CURSEFORGE_API_KEY, @"");
    }
}

// Mod 更新旧文件保留（默认 YES）
+ (BOOL)modUpdateKeepOld {
    NSNumber *value = getPrefObject(PREF_MOD_UPDATE_KEEP_OLD);
    return value ? value.boolValue : YES;
}

+ (void)setModUpdateKeepOld:(BOOL)keepOld {
    setPrefObject(PREF_MOD_UPDATE_KEEP_OLD, @(keepOld));
}

@end
