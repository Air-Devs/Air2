//
//  A2PairingFile.m
//  Air2
//
//  [JIT-IMPL] 配对文件的本地解析与校验实现。纯 Foundation、无副作用（只读文件）。
//

#import "A2PairingFile.h"

NSString *const A2PairingFileErrorDomain = @"A2PairingFileError";

static NSError *A2PairingError(A2PairingFileError code, NSString *message) {
    return [NSError errorWithDomain:A2PairingFileErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message ?: @"" }];
}

@interface A2PairingFile ()
@property (nonatomic, readwrite) A2PairingFileFormat format;
@property (nonatomic, readwrite, copy, nullable) NSString *deviceIdentifier;
@property (nonatomic, readwrite, copy) NSDictionary<NSString *, id> *fields;
@property (nonatomic, readwrite) BOOL isValid;
@end

@implementation A2PairingFile

#pragma mark - 必填字段

+ (NSArray<NSString *> *)requiredFieldsForFormat:(A2PairingFileFormat)format {
    switch (format) {
        case A2PairingFileFormatRemotePairing:
            return @[ @"identifier", @"public_key", @"private_key" ];
        case A2PairingFileFormatLockdownPairRecord:
            return @[ @"DeviceCertificate", @"HostCertificate", @"HostPrivateKey",
                      @"RootCertificate", @"HostID", @"SystemBUID" ];
        case A2PairingFileFormatUnknown:
        default:
            return @[];
    }
}

/// 每个字段的期望类型（用于「基本合法性」判定）。
static Class A2PairingExpectedClass(NSString *key) {
    static NSSet<NSString *> *stringKeys = nil;
    static NSSet<NSString *> *dataKeys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stringKeys = [NSSet setWithArray:@[ @"identifier", @"HostID", @"SystemBUID", @"UDID" ]];
        dataKeys = [NSSet setWithArray:@[ @"public_key", @"private_key", @"DeviceCertificate",
                                          @"HostCertificate", @"HostPrivateKey", @"RootCertificate" ]];
    });
    if ([stringKeys containsObject:key]) return [NSString class];
    if ([dataKeys containsObject:key]) return [NSData class];
    return nil;   // 其它字段不校验类型
}

/// 字段是否「存在且合法」：类型正确且非空（字符串去空白后非空）。
static BOOL A2PairingFieldValid(NSString *key, id value) {
    if (value == nil) return NO;
    Class expected = A2PairingExpectedClass(key);
    if (expected == [NSString class]) {
        if (![value isKindOfClass:[NSString class]]) return NO;
        return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0;
    }
    if (expected == [NSData class]) {
        if (![value isKindOfClass:[NSData class]]) return NO;
        return [(NSData *)value length] > 0;
    }
    return YES;
}

#pragma mark - 解析

+ (nullable NSDictionary<NSString *, id> *)propertyListFromData:(NSData *)data
                                                          error:(NSError *_Nullable *_Nullable)error {
    if (data.length == 0) {
        if (error) *error = A2PairingError(A2PairingFileErrorEmpty, @"配对文件为空");
        return nil;
    }

    // 空/纯空白也要先挡掉：OpenStep plist 解析器会把纯空白当成【空字典】，
    // 若不挡会把「空文件」误报成「缺字段」。
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *probe = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (probe != nil && [probe stringByTrimmingCharactersInSet:ws].length == 0) {
        if (error) *error = A2PairingError(A2PairingFileErrorEmpty, @"配对文件为空（仅空白）");
        return nil;
    }

    // ① 先按原始 plist（XML / binary）解析。
    NSError *plistErr = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:data
                                                       options:0
                                                        format:NULL
                                                         error:&plistErr];
    if (obj) {
        if ([obj isKindOfClass:[NSDictionary class]]) {
            return obj;
        }
        if (error) *error = A2PairingError(A2PairingFileErrorNotPropertyList,
                                           @"配对文件的 plist 顶层不是字典");
        return nil;
    }

    // ② 原始解析失败 ⇒ 兼容【base64 包裹的 plist 文本】。
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length == 0) {
        if (error) *error = A2PairingError(A2PairingFileErrorEmpty, @"配对文件为空（非 UTF-8 文本）");
        return nil;
    }
    NSString *b64 = [[text componentsSeparatedByCharactersInSet:ws] componentsJoinedByString:@""];
    if (b64.length == 0) {
        if (error) *error = A2PairingError(A2PairingFileErrorEmpty, @"配对文件为空（仅空白）");
        return nil;
    }
    // 明显是（损坏的）XML/plist 文本，而不是 base64。
    if ([b64 rangeOfString:@"<"].location != NSNotFound) {
        if (error) *error = A2PairingError(A2PairingFileErrorNotPropertyList,
                                           @"不是有效的 plist（文本结构损坏）");
        return nil;
    }
    // base64 解码（严格模式：非法字符 / 长度不合法一律返回 nil ⇒ 判定为损坏的 base64）。
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (decoded == nil) {
        if (error) *error = A2PairingError(A2PairingFileErrorMalformedBase64,
                                           @"base64 包裹解码失败（内容损坏）");
        return nil;
    }
    id inner = [NSPropertyListSerialization propertyListWithData:decoded
                                                        options:0
                                                         format:NULL
                                                          error:NULL];
    if ([inner isKindOfClass:[NSDictionary class]]) {
        return inner;
    }
    if (error) *error = A2PairingError(A2PairingFileErrorNotPropertyList,
                                       @"base64 解出的内容不是 plist 字典");
    return nil;
}

#pragma mark - 校验

+ (nullable instancetype)pairingFileWithData:(NSData *)data
                                       error:(NSError *_Nullable *_Nullable)error {
    NSDictionary<NSString *, id> *fields = [self propertyListFromData:data error:error];
    if (fields == nil) {
        return nil;
    }

    // 选格式：命中最多【合法】必填字段者胜出。
    A2PairingFileFormat best = A2PairingFileFormatUnknown;
    NSUInteger bestScore = 0;
    NSArray<NSString *> *bestMissing = @[];
    NSArray<NSString *> *bestInvalid = @[];

    for (NSNumber *fmtNum in @[ @(A2PairingFileFormatRemotePairing),
                                @(A2PairingFileFormatLockdownPairRecord) ]) {
        A2PairingFileFormat fmt = (A2PairingFileFormat)fmtNum.integerValue;
        NSArray<NSString *> *req = [self requiredFieldsForFormat:fmt];
        NSUInteger score = 0;
        NSMutableArray<NSString *> *missing = [NSMutableArray array];
        NSMutableArray<NSString *> *invalid = [NSMutableArray array];
        for (NSString *key in req) {
            id value = fields[key];
            if (value == nil) {
                [missing addObject:key];
            } else if (A2PairingFieldValid(key, value)) {
                score += 1;
            } else {
                [invalid addObject:key];
            }
        }
        if (score > bestScore) {
            bestScore = score;
            best = fmt;
            bestMissing = missing;
            bestInvalid = invalid;
        }
    }

    // 一点识别线索都没有 ⇒ 当作「缺字段」报出（以 RemotePairing 的必填集为准）。
    if (best == A2PairingFileFormatUnknown) {
        NSArray<NSString *> *req = [self requiredFieldsForFormat:A2PairingFileFormatRemotePairing];
        if (error) *error = A2PairingError(A2PairingFileErrorMissingFields,
            [NSString stringWithFormat:@"配对文件缺必填字段：%@", [req componentsJoinedByString:@", "]]);
        return nil;
    }

    // 存在字段但类型/取值非法 ⇒ InvalidField（优先于 MissingFields，便于给准确文案）。
    if (bestInvalid.count > 0) {
        if (error) *error = A2PairingError(A2PairingFileErrorInvalidField,
            [NSString stringWithFormat:@"配对文件字段非法：%@", [bestInvalid componentsJoinedByString:@", "]]);
        return nil;
    }
    if (bestMissing.count > 0) {
        if (error) *error = A2PairingError(A2PairingFileErrorMissingFields,
            [NSString stringWithFormat:@"配对文件缺必填字段：%@", [bestMissing componentsJoinedByString:@", "]]);
        return nil;
    }

    A2PairingFile *file = [A2PairingFile new];
    file.fields = fields;
    file.format = best;
    file.isValid = YES;
    if (best == A2PairingFileFormatRemotePairing) {
        file.deviceIdentifier = fields[@"identifier"];
    } else {
        id udid = fields[@"UDID"];
        file.deviceIdentifier = [udid isKindOfClass:[NSString class]] ? udid : fields[@"HostID"];
    }
    return file;
}

+ (nullable instancetype)pairingFileWithContentsOfFile:(NSString *)path
                                                 error:(NSError *_Nullable *_Nullable)error {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (data == nil) {
        return nil;
    }
    return [self pairingFileWithData:data error:error];
}

@end
