//
//  A2JITFacts.m
//  Air2
//
//  ★纯判定★：全部是版本号与环境形态的比较，无任何平台调用。
//

#import "A2JITFacts.h"

@implementation A2JITFacts

+ (instancetype)factsWithOSMajorVersion:(NSInteger)majorVersion
                             minorVersion:(NSInteger)minorVersion
                              environment:(A2JITEnvironmentKind)environment
                 hasImportedPairingFile:(BOOL)hasImportedPairingFile
            hasExternalEnablerInstalled:(BOOL)hasExternalEnablerInstalled
                         hasGetTaskAllow:(BOOL)hasGetTaskAllow
                   hasDynamicCodesigning:(BOOL)hasDynamicCodesigning {
    A2JITFacts *facts = [A2JITFacts new];
    facts->_osMajorVersion = majorVersion;
    facts->_osMinorVersion = minorVersion;
    facts->_environment = environment;
    facts->_hasImportedPairingFile = hasImportedPairingFile;
    facts->_hasExternalEnablerInstalled = hasExternalEnablerInstalled;
    facts->_hasGetTaskAllow = hasGetTaskAllow;
    facts->_hasDynamicCodesigning = hasDynamicCodesigning;
    return facts;
}

- (BOOL)supportsRemoteDebugJIT {
    if (self.osMajorVersion > 17) {
        return YES;
    }
    if (self.osMajorVersion == 17) {
        return self.osMinorVersion >= 4;
    }
    return NO;
}

- (BOOL)supportsBuiltInHelper {
    return self.osMajorVersion >= 26;
}

- (BOOL)supportsAutomaticPairing {
    return self.osMajorVersion >= 27;
}

- (BOOL)hasKernelJITEnvironment {
    return self.environment != A2JITEnvironmentKindPlain || self.hasDynamicCodesigning;
}

- (NSString *)description {
    return [NSString stringWithFormat:
            @"<A2JITFacts iOS %ld.%ld env=%ld pairing=%d enabler=%d gta=%d dcs=%d>",
            (long)self.osMajorVersion, (long)self.osMinorVersion, (long)self.environment,
            self.hasImportedPairingFile, self.hasExternalEnablerInstalled,
            self.hasGetTaskAllow, self.hasDynamicCodesigning];
}

@end
