//
//  A2ModpackParser.m
//  Air2
//

#import "A2ModpackParser.h"
#import "A2ModpackModels.h"
#import "A2ModrinthPackParser.h"
#import "A2CurseForgePackParser.h"
#import "A2MultiMCPackParser.h"
#import "A2MCBBSPackParser.h"

NSString *const A2ModpackParserErrorDomain = @"A2ModpackParser";

/// 把某个格式分派给对应解析器。
/// 抽成函数是为了让调度逻辑不掺入任何一个格式的细节。
static A2ModpackInfo *A2ParseWithFormat(A2ModpackFormat format, NSString *root, NSError **error) {
    switch (format) {
        case A2ModpackFormatModrinth:   return [A2ModrinthPackParser parseAtRoot:root error:error];
        case A2ModpackFormatCurseForge: return [A2CurseForgePackParser parseAtRoot:root error:error];
        case A2ModpackFormatMultiMC:    return [A2MultiMCPackParser parseAtRoot:root error:error];
        case A2ModpackFormatMCBBS:      return [A2MCBBSPackParser parseAtRoot:root error:error];
        case A2ModpackFormatUnknown:
        default:                        return nil;
    }
}

@implementation A2ModpackParser

+ (A2ModpackInfo *)parseExtractedPackAtRoot:(NSString *)root error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (root.length == 0 || ![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
        if (error) *error = A2ModpackError(A2ModpackParserErrorIO, @"整合包解压目录不存在");
        return nil;
    }

    // 顺序固定。签名文件存在只说明「值得一试」：
    // MCBBS 的旧包也带 manifest.json，而只有 CurseForge 的 manifest 才带
    // minecraft 字段，所以按判别力从强到弱排，前面解析不出来再往后。
    NSArray<NSNumber *> *order = @[
        @(A2ModpackFormatCurseForge),
        @(A2ModpackFormatModrinth),
        @(A2ModpackFormatMultiMC),
        @(A2ModpackFormatMCBBS),
    ];

    NSError *lastError = nil;
    for (NSNumber *number in order) {
        A2ModpackFormat format = (A2ModpackFormat)number.integerValue;
        NSString *signature = A2ModpackFormatSignatureFile(format);
        NSString *signaturePath = [root stringByAppendingPathComponent:signature];
        if (![fm fileExistsAtPath:signaturePath]) continue;

        NSError *parseError = nil;
        A2ModpackInfo *info = A2ParseWithFormat(format, root, &parseError);
        if (info) return info;
        if (parseError) lastError = parseError;
    }

    if (error) {
        *error = lastError ?: A2ModpackError(A2ModpackParserErrorNoPackFound,
                                             @"无法识别的整合包格式");
    }
    return nil;
}

@end