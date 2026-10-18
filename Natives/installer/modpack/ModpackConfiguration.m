//
//  ModpackConfiguration.m
//  Amethyst
//
//  Created by iFlow on 2024/11/29.
//

#import "ModpackConfiguration.h"

@implementation ModpackFileInformation

- (instancetype)initWithPath:(NSString *)path fileHash:(NSString *)fileHash downloadURL:(NSString *)downloadURL fileSize:(NSUInteger)fileSize {
    self = [super init];
    if (self) {
        _path = path;
        _fileHash = fileHash;
        _downloadURL = downloadURL;
        _fileSize = fileSize;
    }
    return self;
}

- (BOOL)validate {
    if (!_path || _path.length == 0) {
        NSLog(@"[ModpackConfiguration] File path is empty");
        return NO;
    }
    if (!_fileHash || _fileHash.length == 0) {
        NSLog(@"[ModpackConfiguration] File hash is empty for path: %@", _path);
        return NO;
    }
    return YES;
}

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [super init];
    if (self) {
        _path = dict[@"path"];
        _fileHash = dict[@"hashes"][@"sha1"];
        _downloadURL = dict[@"downloads"][0];
        _fileSize = [dict[@"fileSize"] unsignedIntegerValue];
    }
    return self;
}

@end

@implementation ModpackConfiguration

- (instancetype)initWithName:(NSString *)name version:(NSString *)version gameVersion:(NSString *)gameVersion {
    self = [super init];
    if (self) {
        _name = name;
        _version = version;
        _gameVersion = gameVersion;
        _files = [NSArray array];
        _dependencies = [NSDictionary dictionary];
    }
    return self;
}

- (void)saveToFile:(NSString *)filePath error:(NSError **)error {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"name"] = self.name;
    dict[@"version"] = self.version;
    dict[@"gameVersion"] = self.gameVersion;
    
    if (self.author) {
        dict[@"author"] = self.author;
    }
    if (self.packDescription) {
        dict[@"description"] = self.packDescription;
    }
    
    NSMutableArray *filesArray = [NSMutableArray array];
    for (ModpackFileInformation *fileInfo in self.files) {
        NSDictionary *fileDict = @{
            @"path": fileInfo.path,
            @"hashes": @{@"sha1": fileInfo.fileHash},
            @"downloads": @[fileInfo.downloadURL],
            @"fileSize": @(fileInfo.fileSize)
        };
        [filesArray addObject:fileDict];
    }
    dict[@"files"] = filesArray;
    
    if (self.dependencies) {
        dict[@"dependencies"] = self.dependencies;
    }
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:error];
    if (jsonData) {
        [jsonData writeToFile:filePath atomically:YES];
    }
}

- (nullable instancetype)initWithContentsOfFile:(NSString *)filePath error:(NSError **)error {
    self = [super init];
    if (self) {
        NSData *jsonData = [NSData dataWithContentsOfFile:filePath options:0 error:error];
        if (!jsonData) {
            return nil;
        }
        
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:error];
        if (!dict || ![dict isKindOfClass:[NSDictionary class]]) {
            return nil;
        }
        
        _name = dict[@"name"];
        _version = dict[@"version"];
        _gameVersion = dict[@"gameVersion"];
        _author = dict[@"author"];
        _packDescription = dict[@"description"];
        _dependencies = dict[@"dependencies"];
        
        NSArray *filesArray = dict[@"files"];
        if ([filesArray isKindOfClass:[NSArray class]]) {
            NSMutableArray *files = [NSMutableArray array];
            for (NSDictionary *fileDict in filesArray) {
                if ([fileDict isKindOfClass:[NSDictionary class]]) {
                    ModpackFileInformation *fileInfo = [[ModpackFileInformation alloc] initWithDictionary:fileDict];
                    if (fileInfo) {
                        [files addObject:fileInfo];
                    }
                }
            }
            _files = [files copy];
        }
    }
    return self;
}

- (BOOL)validate {
    if (!_name || _name.length == 0) {
        NSLog(@"[ModpackConfiguration] Name is empty");
        return NO;
    }
    if (!_version || _version.length == 0) {
        NSLog(@"[ModpackConfiguration] Version is empty");
        return NO;
    }
    if (!_gameVersion || _gameVersion.length == 0) {
        NSLog(@"[ModpackConfiguration] Game version is empty");
        return NO;
    }
    
    for (ModpackFileInformation *fileInfo in self.files) {
        if (![fileInfo validate]) {
            return NO;
        }
    }
    
    return YES;
}

@end