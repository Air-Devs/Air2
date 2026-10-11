//
//  A2JITPairingPinSource.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Player —— 配对码来源的可选项 / 解析实现（声明与依据见头文件）。
//

#import "A2JITPairingPinSource.h"
#import "A2LaunchContract.h"   // ★跨层契约：偏好键（写入点在设置页，读取点=本文件）★

/// 信任弹窗档的固定配对码（协议事实：iOS 用 "000000"）。★不是「默认值」——只有选中该档才用★。
static NSString *const kA2TrustDialogPin = @"000000";

#pragma mark - 候选值对象

@implementation A2JITPairingPinSourceItem
+ (instancetype)itemWithIdentifier:(NSString *)identifier
                              mode:(A2JITPairingPinMode)mode
                       implemented:(BOOL)implemented
                           nameKey:(NSString *)nameKey {
    A2JITPairingPinSourceItem *it = [A2JITPairingPinSourceItem new];
    it->_identifier = [identifier copy];
    it->_mode = mode;
    it->_implemented = implemented;
    it->_nameKey = [nameKey copy];
    return it;
}
@end

#pragma mark - 候选表

@implementation A2JITPairingPinSourceCatalog

+ (NSArray<A2JITPairingPinSourceItem *> *)allItems {
    // ★顺序即展示顺序★；未实现的档照列不误（用户口径：「缺的也入表、标出来」）。
    return @[
        [A2JITPairingPinSourceItem itemWithIdentifier:@"trustDialog"
                                                 mode:A2JITPairingPinModeTrustDialog
                                          implemented:YES
                                              nameKey:@"jit.pairpin.mode.trust"],
        [A2JITPairingPinSourceItem itemWithIdentifier:@"deviceInitiated"
                                                 mode:A2JITPairingPinModeDeviceInitiated
                                          implemented:YES
                                              nameKey:@"jit.pairpin.mode.device"],
        [A2JITPairingPinSourceItem itemWithIdentifier:@"existingRecord"
                                                 mode:A2JITPairingPinModeExistingRecord
                                          implemented:YES
                                              nameKey:@"jit.pairpin.mode.existing"],
        [A2JITPairingPinSourceItem itemWithIdentifier:@"onScreenCode"
                                                 mode:A2JITPairingPinModeOnScreenCode
                                          implemented:NO
                                              nameKey:@"jit.pairpin.mode.onscreen"],
    ];
}

+ (NSString *)defaultIdentifier {
    // 主推 = 设备发起档（iOS 27 的「设备内自动配对」正是它）。
    return @"deviceInitiated";
}

+ (nullable A2JITPairingPinSourceItem *)itemForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return nil;
    }
    for (A2JITPairingPinSourceItem *it in [self allItems]) {
        if ([it.identifier isEqualToString:identifier]) {
            return it;
        }
    }
    return nil;
}

+ (A2JITPairingPinMode)modeForIdentifier:(NSString *)identifier {
    A2JITPairingPinSourceItem *it = [self itemForIdentifier:identifier];
    if (it != nil) {
        return it.mode;
    }
    return identifier.length == 0 ? A2JITPairingPinModeUnselected : A2JITPairingPinModeUnknown;
}

+ (NSString *)displayNameForMode:(A2JITPairingPinMode)mode {
    switch (mode) {
        case A2JITPairingPinModeUnselected:      return @"Unselected";
        case A2JITPairingPinModeTrustDialog:     return @"TrustDialog(fixed 000000)";
        case A2JITPairingPinModeDeviceInitiated: return @"DeviceInitiated(show 6-digit code)";
        case A2JITPairingPinModeExistingRecord:  return @"ExistingRecord(pair-verify only)";
        case A2JITPairingPinModeOnScreenCode:    return @"OnScreenCode(NOT implemented)";
        case A2JITPairingPinModeUnknown:         return @"Unknown";
    }
    return @"Unknown";
}

@end

#pragma mark - 解析

@implementation A2JITPairingPinResolver

+ (A2JITPairingPinMode)selectedMode {
    NSString *sel = [NSUserDefaults.standardUserDefaults stringForKey:A2SelectedPairingPinSourcePrefKey];
    return [A2JITPairingPinSourceCatalog modeForIdentifier:sel ?: @""];
}

+ (NSString *)criterionLine {
    A2JITPairingPinMode mode = [self selectedMode];
    NSString *sel = [NSUserDefaults.standardUserDefaults stringForKey:A2SelectedPairingPinSourcePrefKey] ?: @"";
    A2JITPairingPinSourceItem *it = [A2JITPairingPinSourceCatalog itemForIdentifier:sel];
    return [NSString stringWithFormat:@"[A2-PAIRPIN] source=%@ mode=%@ implemented=%@",
            sel.length ? sel : @"(none)",
            [A2JITPairingPinSourceCatalog displayNameForMode:mode],
            it ? (it.implemented ? @"YES" : @"NO") : @"(n/a)"];
}

+ (nullable NSString *)resolvedPinForDisplayedCode:(nullable NSString *)displayedCode
                                            reason:(NSString *_Nullable *_Nullable)reason {
    switch ([self selectedMode]) {
        case A2JITPairingPinModeTrustDialog:
            // iOS 常规：设备弹信任框，固定码，自动（不需要用户输入）。
            return kA2TrustDialogPin;
        case A2JITPairingPinModeDeviceInitiated: {
            NSString *code = displayedCode ?: @"";
            BOOL sixDigits = (code.length == 6);
            for (NSUInteger i = 0; sixDigits && i < code.length; i++) {
                unichar c = [code characterAtIndex:i];
                if (c < '0' || c > '9') { sixDigits = NO; }
            }
            if (!sixDigits) {
                if (reason) {
                    *reason = @"设备发起档：本机尚未显示 6 位码（先在设置页「设备发起」里生成并显示码，"
                              @"再到设备的 设置 › 通用 › VPN 与设备管理 里输入）";
                }
                return nil;
            }
            return code;
        }
        case A2JITPairingPinModeExistingRecord:
            if (reason) {
                *reason = @"已有配对记录档：设备已认识本机 ⇒ 走 pair-verify 快路径，不做 pair-setup";
            }
            return nil;
        case A2JITPairingPinModeOnScreenCode:
            if (reason) {
                *reason = @"设备屏显码档（Apple TV / Vision Pro）★未实现★ —— 本仓不面向该场景；"
                          @"该档照列仅为如实说明，选中即拒绝";
            }
            return nil;
        case A2JITPairingPinModeUnselected:
            if (reason) {
                *reason = @"未选择配对码来源 ⇒ 拒绝（★不静默回退到别的档★；"
                          @"请到 设置 › 运行环境 › JIT 供给 的「配对码来源」里选一档）";
            }
            return nil;
        case A2JITPairingPinModeUnknown:
        default:
            if (reason) {
                *reason = @"配对码来源的偏好值不认识 ⇒ 拒绝（不猜；请在设置里重新选择）";
            }
            return nil;
    }
}

@end
