//
//  A2JITLocalFactsSource.m
//  Air2
//
//  [JIT-IMPL] Foundation-only 的薄探测实现。取不到的字段一律保守返回 NO。
//

#import "A2JITLocalFactsSource.h"

@implementation A2JITLocalFactsSource

- (NSInteger)osMajorVersion {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
}

- (NSInteger)osMinorVersion {
    return NSProcessInfo.processInfo.operatingSystemVersion.minorVersion;
}

- (A2JITEnvironmentKind)environment {
    NSFileManager *fm = NSFileManager.defaultManager;
    // 越狱文件特征（rootless 与 classic 各一；只作选路径依据）。
    if ([fm fileExistsAtPath:@"/var/jb"] || [fm fileExistsAtPath:@"/var/lib/dpkg"]) {
        return A2JITEnvironmentKindJailbroken;
    }
    // TrollStore 识别需要 URL scheme 探测（UIKit），归第二阶段；此处保守返回纯签名。
    return A2JITEnvironmentKindPlain;
}

- (BOOL)hasImportedPairingFile {
    for (NSString *path in [A2JITLocalFactsSource candidatePairingFilePaths]) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)hasExternalEnablerInstalled {
    // canOpenURL 探测（stikdebug:// …）需要 UIKit 且需 Info.plist 白名单 ⇒ 第二阶段（App 装配处）。
    return NO;
}

- (BOOL)hasGetTaskAllow {
    // entitlement 取证（SecTaskCopyValueForEntitlement 等）⇒ 第二阶段（Natives/Support）。
    // 保守返回 NO：本字段不参与分级表判定，误判风险低。
    return NO;
}

- (BOOL)hasDynamicCodesigning {
    // 同上，归第二阶段。保守返回 NO。
    return NO;
}

+ (NSArray<NSString *> *)candidatePairingFilePaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    for (NSString *docs in dirs) {
        [paths addObject:[docs stringByAppendingPathComponent:@"pairingFile.plist"]];
        [paths addObject:[docs stringByAppendingPathComponent:@"pairingFile.mobiledevicepairing"]];
        [paths addObject:[docs stringByAppendingPathComponent:@"StikJIT/pairingFile.plist"]];
    }
    NSArray<NSString *> *libs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    for (NSString *lib in libs) {
        [paths addObject:[lib stringByAppendingPathComponent:@"Application Support/Pairing/pairingFile.plist"]];
        [paths addObject:[lib stringByAppendingPathComponent:@"Application Support/Pairing/pairingFile.mobiledevicepairing"]];
    }
    return paths;
}

@end
