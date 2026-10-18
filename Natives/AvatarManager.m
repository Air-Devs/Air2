#import "utils.h"
#import "AvatarManager.h"

@interface AvatarManager()
@property (nonatomic, strong) NSFileManager *fileManager;
@property (nonatomic, strong) NSString *documentsDirectory;
@property (nonatomic, strong) NSString *avatarsDirectory;
@end

@implementation AvatarManager

+ (instancetype)sharedManager {
    static AvatarManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[AvatarManager alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.fileManager = [NSFileManager defaultManager];
        NSArray *paths = [self.fileManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
        self.documentsDirectory = [paths.firstObject path];
        self.avatarsDirectory = [self.documentsDirectory stringByAppendingPathComponent:@"avatars"];
        if (![self.fileManager fileExistsAtPath:self.avatarsDirectory]) {
            [self.fileManager createDirectoryAtPath:self.avatarsDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                   error:nil];
        }
    }
    return self;
}

/// 将 accountName 转换为安全的文件名（移除路径分隔符等非法字符）。
/// Minecraft 用户名通常为字母数字下划线，但仍做一层防护避免路径穿越。
- (NSString *)safeFileNameForAccount:(NSString *)accountName {
    if (accountName.length == 0) return @"anonymous";
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSArray *parts = [accountName componentsSeparatedByCharactersInSet:invalid];
    NSString *cleaned = [parts componentsJoinedByString:@"_"];
    if (cleaned.length == 0) cleaned = @"anonymous";
    return cleaned;
}

- (NSString *)avatarPathForAccount:(NSString *)accountName {
    NSString *fileName = [self safeFileNameForAccount:accountName];
    return [self.avatarsDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", fileName]];
}

- (void)saveAvatarForAccount:(NSString *)accountName
                     image:(UIImage *)image
          withCompletion:(void (^)(BOOL, NSError * _Nullable))completion {
    if (accountName.length == 0) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"AvatarError" code:1001 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_46", nil)}]);
        }
        return;
    }
    NSData *imageData = UIImagePNGRepresentation(image);
    if (!imageData) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"AvatarError" code:1002 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_47", nil)}]);
        }
        return;
    }
    NSString *path = [self avatarPathForAccount:accountName];
    NSError *error;
    BOOL success = [imageData writeToURL:[NSURL fileURLWithPath:path] options:NSDataWritingAtomic error:&error];
    if (completion) {
        completion(success, error);
    }
}

- (UIImage *)avatarForAccount:(NSString *)accountName {
    if (accountName.length == 0) return nil;
    NSString *path = [self avatarPathForAccount:accountName];
    if (![self.fileManager fileExistsAtPath:path]) return nil;
    return [UIImage imageWithContentsOfFile:path];
}

- (BOOL)hasCustomAvatarForAccount:(NSString *)accountName {
    if (accountName.length == 0) return NO;
    return [self.fileManager fileExistsAtPath:[self avatarPathForAccount:accountName]];
}

- (void)removeAvatarForAccount:(NSString *)accountName {
    if (accountName.length == 0) return;
    NSString *path = [self avatarPathForAccount:accountName];
    if ([self.fileManager fileExistsAtPath:path]) {
        [self.fileManager removeItemAtPath:path error:nil];
    }
}

@end
