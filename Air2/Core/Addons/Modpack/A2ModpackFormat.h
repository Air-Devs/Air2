//
//  A2ModpackFormat.h
//  Air2
//
//  整合包来源格式。
//
//  ZL2 的整合包导入按来源分成四类，各自用不同的清单文件描述
//  「游戏版本 / 加载器 / 要下载哪些文件」：
//
//    Modrinth    modrinth.index.json   文件带直链与 sha1
//    CurseForge  manifest.json         只给 projectID/fileID，要查 API
//    MultiMC     mmc-pack.json         组件式，文件都打在实例目录里
//    MCBBS       mcbbs.packmeta        国内论坛格式，旧包用 manifest.json
//
//  判别顺序固定为 CurseForge → Modrinth → MultiMC → MCBBS：
//  MCBBS 可能没有专属清单而退回 manifest.json，与 CurseForge 撞签名，
//  所以把判别力最强的放前面，前面解析不出来再往后。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2ModpackFormat) {
    A2ModpackFormatUnknown = 0,
    A2ModpackFormatModrinth,
    A2ModpackFormatCurseForge,
    A2ModpackFormatMultiMC,
    A2ModpackFormatMCBBS,
};

/// 显示名，用于日志与错误提示。
static inline NSString *A2ModpackFormatDisplayName(A2ModpackFormat format) {
    switch (format) {
        case A2ModpackFormatModrinth:   return @"Modrinth";
        case A2ModpackFormatCurseForge: return @"CurseForge";
        case A2ModpackFormatMultiMC:    return @"MultiMC";
        case A2ModpackFormatMCBBS:      return @"MCBBS";
        case A2ModpackFormatUnknown:
        default:                        return @"未知";
    }
}

/// 该格式的签名清单文件名，相对解压后的整合包根目录。
static inline NSString *A2ModpackFormatSignatureFile(A2ModpackFormat format) {
    switch (format) {
        case A2ModpackFormatModrinth:   return @"modrinth.index.json";
        case A2ModpackFormatCurseForge: return @"manifest.json";
        case A2ModpackFormatMultiMC:    return @"mmc-pack.json";
        case A2ModpackFormatMCBBS:      return @"mcbbs.packmeta";
        case A2ModpackFormatUnknown:
        default:                        return @"";
    }
}

NS_ASSUME_NONNULL_END
