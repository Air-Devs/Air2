//
//  A2JITDDI.m
//  Air2
//
//  Player —— DDI 的纯逻辑实现（★无平台调用、无网络、无文件系统★，全部可单测）。
//  ★不引入第三方、不搬运任何第三方代码★（见 docs/DEPENDENCIES.md）。
//

#import "A2JITDDI.h"

/// 默认新鲜度窗口：7 天（与 A2JITAutomaticPairingProvider 的配对文件窗口同口径）。
static const NSTimeInterval kA2JITDDIDefaultMaxAge = 7.0 * 24.0 * 60.0 * 60.0;

#pragma mark - 要求

@implementation A2JITDDIRequirement

+ (instancetype)requirementWithOSMajorVersion:(NSInteger)majorVersion
                                 minorVersion:(NSInteger)minorVersion
                                        build:(nullable NSString *)build
                                 uniqueChipID:(nullable NSString *)uniqueChipID {
    A2JITDDIRequirement *r = [A2JITDDIRequirement new];
    r->_osMajorVersion = majorVersion;
    r->_osMinorVersion = minorVersion;
    r->_build = [build copy];
    r->_uniqueChipID = [uniqueChipID copy];
    return r;
}

- (NSString *)versionString {
    return [NSString stringWithFormat:@"%ld.%ld", (long)self.osMajorVersion, (long)self.osMinorVersion];
}

- (NSString *)displayVersion {
    if (self.build.length) {
        return [NSString stringWithFormat:@"%@ (%@)", [self versionString], self.build];
    }
    return [self versionString];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<A2JITDDIRequirement %@ chip=%@>",
            [self displayVersion], self.uniqueChipID ?: @"(未取到)"];
}

@end

#pragma mark - 镜像

@implementation A2JITDDIImage

+ (instancetype)imageWithFilePath:(NSString *)filePath
                   trustcachePath:(nullable NSString *)trustcachePath
                             kind:(A2JITDDIKind)kind
                           source:(A2JITDDISource)source
                         byteSize:(unsigned long long)byteSize
                           sha256:(nullable NSString *)sha256
                       importedAt:(nullable NSDate *)importedAt
                    declaredBuild:(nullable NSString *)declaredBuild
                declaredOSVersion:(nullable NSString *)declaredOSVersion {
    NSParameterAssert(filePath.length > 0);
    A2JITDDIImage *img = [A2JITDDIImage new];
    img->_filePath = [filePath copy];
    img->_trustcachePath = [trustcachePath copy];
    img->_kind = kind;
    img->_source = source;
    img->_byteSize = byteSize;
    img->_sha256 = [sha256 copy];
    img->_importedAt = importedAt;
    img->_declaredBuild = [declaredBuild copy];
    img->_declaredOSVersion = [declaredOSVersion copy];
    return img;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<A2JITDDIImage %@ kind=%@ src=%@ bytes=%llu build=%@ ver=%@>",
            self.filePath.lastPathComponent,
            [A2JITDDI displayNameForKind:self.kind],
            [A2JITDDI displayNameForSource:self.source],
            self.byteSize,
            self.declaredBuild ?: @"(未声明)",
            self.declaredOSVersion ?: @"(未声明)"];
}

@end

#pragma mark - 判定结果

@implementation A2JITDDIStatus

+ (instancetype)statusWithVerdict:(A2JITDDIVerdict)verdict
                        imagePath:(nullable NSString *)imagePath
                           source:(A2JITDDISource)source
                         evidence:(NSString *)evidence {
    A2JITDDIStatus *s = [A2JITDDIStatus new];
    s->_verdict = verdict;
    s->_imagePath = [imagePath copy];
    s->_source = source;
    s->_evidence = [evidence copy] ?: @"";
    return s;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<A2JITDDIStatus %@ %@>",
            [A2JITDDI displayNameForVerdict:self.verdict], self.evidence];
}

@end

#pragma mark - 纯逻辑

@implementation A2JITDDI

+ (NSTimeInterval)defaultMaxAge {
    return kA2JITDDIDefaultMaxAge;
}

+ (A2JITDDIMatch)matchOfImage:(A2JITDDIImage *)image
              withRequirement:(A2JITDDIRequirement *)requirement
                          why:(NSString *_Nullable *_Nullable)whyOut {
    NSParameterAssert(image);
    NSParameterAssert(requirement);

    // ★顺序即优先级★：先按构建号（最精确），再按版本串；都没有 ⇒ Unknown（不猜）。
    if (image.declaredBuild.length > 0) {
        if (requirement.build.length == 0) {
            if (whyOut) {
                *whyOut = @"镜像声明了构建号，但本机系统构建号取不到 ⇒ 无法对齐";
            }
            return A2JITDDIMatchUnknown;
        }
        if ([image.declaredBuild isEqualToString:requirement.build]) {
            if (whyOut) {
                *whyOut = [NSString stringWithFormat:@"构建号一致（%@）", image.declaredBuild];
            }
            return A2JITDDIMatchMatched;
        }
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:@"构建号不一致：镜像 %@ ≠ 本机 %@",
                       image.declaredBuild, requirement.build];
        }
        return A2JITDDIMatchMismatched;
    }

    if (image.declaredOSVersion.length > 0) {
        NSString *want = [requirement versionString];
        if ([image.declaredOSVersion isEqualToString:want]) {
            if (whyOut) {
                *whyOut = [NSString stringWithFormat:@"系统版本一致（%@）", image.declaredOSVersion];
            }
            return A2JITDDIMatchMatched;
        }
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:@"系统版本不一致：镜像 %@ ≠ 本机 %@",
                       image.declaredOSVersion, want];
        }
        return A2JITDDIMatchMismatched;
    }

    // ★镜像没声明任何版本/构建号 ⇒ 无法对齐；绝不猜成「匹配」★。
    if (whyOut) {
        *whyOut = @"镜像未声明系统版本/构建号 ⇒ 无法与系统对齐（不猜）";
    }
    return A2JITDDIMatchUnknown;
}

+ (A2JITDDIVerdict)verdictForImage:(nullable A2JITDDIImage *)image
                   withRequirement:(A2JITDDIRequirement *)requirement
                            maxAge:(NSTimeInterval)maxAge
                               now:(NSDate *)now
                               why:(NSString *_Nullable *_Nullable)whyOut {
    NSParameterAssert(requirement);
    NSParameterAssert(now);

    if (image == nil) {
        if (whyOut) {
            *whyOut = @"本地未发现 DDI 镜像";
        }
        return A2JITDDIVerdictMissing;
    }
    if (image.byteSize == 0) {
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:@"镜像不可读或为空：%@", image.filePath];
        }
        return A2JITDDIVerdictUnknown;
    }

    NSString *matchWhy = nil;
    A2JITDDIMatch match = [self matchOfImage:image withRequirement:requirement why:&matchWhy];
    if (match == A2JITDDIMatchMismatched) {
        if (whyOut) {
            *whyOut = matchWhy;
        }
        return A2JITDDIVerdictVersionMismatch;
    }
    if (match == A2JITDDIMatchUnknown) {
        // ★无法对齐 ≠ 缺失，更 ≠ 就位★ —— 如实报「无法确认」。
        if (whyOut) {
            *whyOut = matchWhy;
        }
        return A2JITDDIVerdictUnknown;
    }

    // 版本已对齐 ⇒ 再看新鲜度（免费签名 7 天重签会让缓存失效）。
    if (image.importedAt == nil) {
        if (whyOut) {
            *whyOut = @"镜像无导入时间元数据 ⇒ 无法判新鲜度（不谎报为「刚生成」）";
        }
        return A2JITDDIVerdictUnknown;
    }
    NSTimeInterval age = [now timeIntervalSinceDate:image.importedAt];
    if (age < 0) {
        age = 0;   // 时钟回拨：按「刚导入」处理，不因此判过期
    }
    if (age > maxAge) {
        if (whyOut) {
            *whyOut = [NSString stringWithFormat:@"镜像已过期：age=%.0fs > 窗口 %.0fs", age, maxAge];
        }
        return A2JITDDIVerdictStale;
    }

    if (whyOut) {
        *whyOut = [NSString stringWithFormat:@"已就位（%@，age=%.0fs）", matchWhy ?: @"版本匹配", age];
    }
    return A2JITDDIVerdictPresent;
}

+ (NSInteger)preconditionStateValueForVerdict:(A2JITDDIVerdict)verdict {
    // ★取值必须与 A2JITAutoPairingPreconditionState 逐值一致★
    // （Unknown=0 / Satisfied=1 / Unsatisfied=2；单测与 A2JITDDIGuidance 双处断言）。
    switch (verdict) {
        case A2JITDDIVerdictPresent:
            return 1;   // Satisfied
        case A2JITDDIVerdictMissing:
        case A2JITDDIVerdictVersionMismatch:
        case A2JITDDIVerdictStale:
            return 2;   // Unsatisfied
        case A2JITDDIVerdictUnknown:
        default:
            return 0;   // Unknown（无法确认）
    }
}

+ (nullable NSString *)buildFromOperatingSystemVersionString:(NSString *)versionString {
    if (versionString.length == 0) {
        return nil;
    }
    // 形态一："Version 27.2 (Build 24B5084k)" / "Version 14.5 (Build 23F79)"
    NSRange open = [versionString rangeOfString:@"("];
    NSRange close = [versionString rangeOfString:@")" options:NSBackwardsSearch];
    if (open.location != NSNotFound && close.location != NSNotFound &&
        close.location > open.location + 1) {
        NSString *inner = [versionString substringWithRange:
                           NSMakeRange(open.location + 1, close.location - open.location - 1)];
        NSRange b = [inner rangeOfString:@"Build "];
        if (b.location != NSNotFound) {
            return [inner substringFromIndex:b.location + b.length];
        }
        return inner;
    }
    // 形态二：直接就是构建号（如 "24B5084k"；形如 数字+字母的构建号才认）。
    NSRegularExpression *bre =
        [NSRegularExpression regularExpressionWithPattern:@"^[0-9]{2}[A-Z][0-9A-Za-z]{2,}$"
                                                  options:0
                                                    error:NULL];
    if ([bre firstMatchInString:versionString options:0
                          range:NSMakeRange(0, versionString.length)] != nil) {
        return versionString;
    }
    return nil;
}

+ (NSString *)displayNameForVerdict:(A2JITDDIVerdict)verdict {
    switch (verdict) {
        case A2JITDDIVerdictUnknown:         return @"Unknown";
        case A2JITDDIVerdictPresent:         return @"Present";
        case A2JITDDIVerdictMissing:         return @"Missing";
        case A2JITDDIVerdictVersionMismatch: return @"VersionMismatch";
        case A2JITDDIVerdictStale:           return @"Stale";
        default:                             return @"?";
    }
}

+ (NSString *)displayNameForSource:(A2JITDDISource)source {
    switch (source) {
        case A2JITDDISourceUnknown:    return @"Unknown";
        case A2JITDDISourceContainer:  return @"Container";
        case A2JITDDISourceUserImport: return @"UserImport";
        case A2JITDDISourceDevice:     return @"Device";
        case A2JITDDISourceBundled:    return @"Bundled";
        default:                       return @"?";
    }
}

+ (NSString *)displayNameForKind:(A2JITDDIKind)kind {
    switch (kind) {
        case A2JITDDIKindUnknown:      return @"Unknown";
        case A2JITDDIKindLegacy:       return @"Legacy";
        case A2JITDDIKindPersonalized: return @"Personalized";
        default:                       return @"?";
    }
}

@end
