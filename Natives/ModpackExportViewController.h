#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 整合包导出控制器（参照 FCL ExportModpackViewModel / HMCL ExportModpackPanel / ZL2 ModpackExportScreen）
///
/// 独立的导出界面，提供：
///   - Profile 选择（含 gameDir 预览、loader 信息）
///   - 5 种格式选择（Modrinth / CurseForge / MMC / Plain Zip / 链接列表）
///   - 名称 / 版本号 / 作者 输入
///   - 文件过滤选项（mods / configs / resourcepacks / shaderpacks / saves / options / servers / scripts）
///   - 进度卡片（百分比 + 阶段文案 + 取消按钮）
///   - 完成后分享按钮
@interface ModpackExportViewController : UIViewController

/// 初始化时预选的 profile 名称（可空，空时取 currentProfile）
@property (nonatomic, copy, nullable) NSString *preselectedProfileName;

@end

NS_ASSUME_NONNULL_END
