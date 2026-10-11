//
//  A2JITFacts.m
//  Air2
//
//  ★纯判定★：全部是版本号与环境形态的比较，无任何平台调用。
//  [JIT-IMPL] factsWithSource: 从注入的来源（协议 A2JITFactsSource）读出一份事实，
//  自身不发平台调用 ⇒ 单测可注入假数据。
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

// [JIT-IMPL] 探测接缝：只读来源，不做任何平台调用。
+ (instancetype)factsWithSource:(id<A2JITFactsSource>)source {
    NSParameterAssert(source);
    return [self factsWithOSMajorVersion:[source osMajorVersion]
                            minorVersion:[source osMinorVersion]
                             environment:[source environment]
                hasImportedPairingFile:[source hasImportedPairingFile]
           hasExternalEnablerInstalled:[source hasExternalEnablerInstalled]
                        hasGetTaskAllow:[source hasGetTaskAllow]
                  hasDynamicCodesigning:[source hasDynamicCodesigning]];
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
