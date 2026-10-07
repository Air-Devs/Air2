//
//  A2ModpackModels.m
//  Air2
//

#import "A2ModpackModels.h"

@implementation A2ModpackFile

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _relativePath = @"";
    _downloadURLs = @[];
    return self;
}

@end

@implementation A2ModpackInfo

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _name = @"";
    _files = @[];
    _overrideDirectories = @[];
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<A2ModpackInfo %@ name=%@ mc=%@ files=%lu>",
            A2ModpackFormatDisplayName(self.format), self.name,
            self.gameVersion ?: @"?", (unsigned long)self.files.count];
}

@end
