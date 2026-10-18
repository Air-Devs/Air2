#import "utils.h"
#import "CustomIconManager.h"

@interface CustomIconManager()
@property (nonatomic, strong) NSFileManager *fileManager;
@property (nonatomic, strong) NSString *documentsDirectory;
@property (nonatomic, strong) NSString *customIconPath;
@end

@implementation CustomIconManager

+ (instancetype)sharedManager {
    static CustomIconManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[CustomIconManager alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.fileManager = [NSFileManager defaultManager];
        NSArray *paths = [self.fileManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
        self.documentsDirectory = [paths.firstObject path];
        self.customIconPath = [self.documentsDirectory stringByAppendingPathComponent:@"custom_icon.png"];
    }
    return self;
}

- (void)saveCustomIcon:(UIImage *)image withCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    // 将图片保存到文档目录
    NSData *imageData = UIImagePNGRepresentation(image);
    if (!imageData) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"CustomIconError" code:1001 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_47", nil)}]);
        }
        return;
    }
    
    NSError *error;
    BOOL success = [imageData writeToURL:[NSURL fileURLWithPath:self.customIconPath] options:NSDataWritingAtomic error:&error];
    
    if (completion) {
        completion(success, error);
    }
}

- (void)setCustomIconWithCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    // 检查是否支持替换图标
    if (!UIApplication.sharedApplication.supportsAlternateIcons) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"CustomIconError" code:1002 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_102", nil)}]);
        }
        return;
    }
    
    // 检查自定义图标是否存在
    if (![self.fileManager fileExistsAtPath:self.customIconPath]) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"CustomIconError" code:1003 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_103", nil)}]);
        }
        return;
    }
    
    // 读取自定义图标
    NSData *imageData = [NSData dataWithContentsOfFile:self.customIconPath];
    if (!imageData) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"CustomIconError" code:1004 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_104", nil)}]);
        }
        return;
    }
    
    // 创建临时目录
    NSString *tempDirectory = [self.documentsDirectory stringByAppendingPathComponent:@"temp_icons"];
    if (![self.fileManager fileExistsAtPath:tempDirectory]) {
        [self.fileManager createDirectoryAtPath:tempDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    // 保存图标到临时目录，使用正确的文件名格式
    NSString *tempIconPath = [tempDirectory stringByAppendingPathComponent:@"CustomIcon@2x.png"];
    [imageData writeToURL:[NSURL fileURLWithPath:tempIconPath] options:NSDataWritingAtomic error:nil];
    
    // 复制不同尺寸的图标文件（如果需要）
    NSString *tempIconPath3x = [tempDirectory stringByAppendingPathComponent:@"CustomIcon@3x.png"];
    [imageData writeToURL:[NSURL fileURLWithPath:tempIconPath3x] options:NSDataWritingAtomic error:nil];
    
    // 设置自定义图标
    [UIApplication.sharedApplication setAlternateIconName:@"CustomIcon" completionHandler:^(NSError * _Nullable error) {
        // 延迟清理临时文件，确保系统有足够时间读取
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.fileManager removeItemAtPath:tempDirectory error:nil];
        });
        
        if (completion) {
            completion(error == nil, error);
        }
    }];
}

- (BOOL)hasCustomIcon {
    return [self.fileManager fileExistsAtPath:self.customIconPath];
}

- (void)removeCustomIcon {
    if ([self.fileManager fileExistsAtPath:self.customIconPath]) {
        [self.fileManager removeItemAtPath:self.customIconPath error:nil];
    }
    
    // 如果当前使用的是自定义图标，则恢复默认图标
    if ([UIApplication.sharedApplication.alternateIconName isEqualToString:@"CustomIcon"]) {
        [UIApplication.sharedApplication setAlternateIconName:nil completionHandler:nil];
    }
}

@end