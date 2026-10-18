//
//  ServerItem.m
//  Amethyst
//

#import "ServerItem.h"

@implementation ServerItem

- (instancetype)initWithSearchData:(NSDictionary *)data {
    if (self = [super init]) {
        if (![data isKindOfClass:[NSDictionary class]]) {
            return self;
        }

        // 来源 API：1=Modrinth，2=CurseForge（默认值根据字段命名风格推断）
        id apiSrc = data[@"apiSource"];
        if ([apiSrc respondsToSelector:@selector(integerValue)]) {
            _apiSource = [apiSrc integerValue];
        } else if (data[@"project_id"] || data[@"slug"]) {
            _apiSource = ServerAPISourceModrinth;
        } else if (data[@"id"] && data[@"logo"]) {
            _apiSource = ServerAPISourceCurseForge;
        }

        // 服务器项目 ID
        id sid = data[@"serverID"] ?: data[@"project_id"] ?: data[@"id"] ?: data[@"slug"];
        _serverID = [sid isKindOfClass:[NSString class]] ? sid : [sid description];

        // 标题：Modrinth 用 title，CurseForge 用 name
        id title = data[@"title"] ?: data[@"name"];
        _title = [title isKindOfClass:[NSString class]] ? title : [title description];

        // 描述：Modrinth 用 description，CurseForge 用 summary
        id desc = data[@"description"] ?: data[@"summary"];
        _serverDescription = [desc isKindOfClass:[NSString class]] ? desc : @"";

        // 图标 URL：Modrinth 用 icon_url / imageUrl，CurseForge 用 logo.thumbnailUrl / logo.url
        NSString *icon = data[@"iconURL"] ?: data[@"icon_url"] ?: data[@"imageUrl"];
        if (![icon isKindOfClass:[NSString class]] || icon.length == 0) {
            NSDictionary *logo = [data[@"logo"] isKindOfClass:[NSDictionary class]] ? data[@"logo"] : nil;
            icon = logo[@"thumbnailUrl"] ?: logo[@"url"];
        }
        _iconURL = [icon isKindOfClass:[NSString class]] ? icon : @"";

        // 作者
        id author = data[@"author"];
        _author = [author isKindOfClass:[NSString class]] ? author : @"";

        // 下载数
        id dl = data[@"downloads"];
        if ([dl isKindOfClass:[NSNumber class]]) {
            _downloads = dl;
        } else if ([dl respondsToSelector:@selector(longLongValue)]) {
            _downloads = @([dl longLongValue]);
        }

        // 点赞数：Modrinth 用 follows，CurseForge 用 thumbsUpCount
        id likes = data[@"likes"] ?: data[@"follows"] ?: data[@"thumbsUpCount"];
        if ([likes isKindOfClass:[NSNumber class]]) {
            _likes = likes;
        } else if ([likes respondsToSelector:@selector(longLongValue)]) {
            _likes = @([likes longLongValue]);
        }

        // 最后更新时间
        id updated = data[@"lastUpdated"] ?: data[@"date_modified"] ?: data[@"dateReleased"];
        _lastUpdated = [updated isKindOfClass:[NSString class]] ? updated : @"";

        // 项目类型：Modrinth 返回 project_type，CurseForge 通过 classId 推断
        NSString *ptype = data[@"projectType"] ?: data[@"project_type"];
        if ([ptype isKindOfClass:[NSString class]] && ptype.length > 0) {
            _projectType = ptype;
        } else {
            // 默认：Modrinth 的 server/modpack，CurseForge 的 modpack
            _projectType = (_apiSource == ServerAPISourceCurseForge) ? @"modpack" : @"server";
        }

        // 分类
        id cats = data[@"categories"];
        _categories = [cats isKindOfClass:[NSArray class]] ? cats : @[];

        // 主页：Modrinth 用 page_url，CurseForge 用 websiteUrl
        NSString *home = data[@"homepage"] ?: data[@"page_url"];
        if (![home isKindOfClass:[NSString class]] || home.length == 0) {
            NSDictionary *links = [data[@"links"] isKindOfClass:[NSDictionary class]] ? data[@"links"] : nil;
            home = links[@"websiteUrl"];
        }
        _homepage = [home isKindOfClass:[NSString class]] ? home : @"";
    }
    return self;
}

- (void)applyDetailData:(NSDictionary *)data {
    if (![data isKindOfClass:[NSDictionary class]]) return;

    // 服务器地址：优先取 server_address / serverAddress / ip / address 字段
    NSString *addr = data[@"server_address"] ?: data[@"serverAddress"] ?: data[@"ip"] ?: data[@"address"];
    if ([addr isKindOfClass:[NSString class]] && addr.length > 0) {
        self.serverAddress = addr;
    } else if (self.serverDescription.length > 0) {
        // 回退：从描述中解析可能的地址（IP:端口 或 域名:端口）
        NSString *parsed = [self extractAddressFromText:self.serverDescription];
        if (parsed) self.serverAddress = parsed;
    }

    // 关联整合包 ID：Modrinth 用 modpack_project_id，CurseForge 用 modpackId
    NSString *mpID = data[@"modpack_project_id"] ?: data[@"modpackId"] ?: data[@"associatedModpackId"];
    if ([mpID isKindOfClass:[NSString class]] && mpID.length > 0) {
        self.associatedModpackID = mpID;
    } else if ([mpID respondsToSelector:@selector(integerValue)]) {
        self.associatedModpackID = [mpID description];
    }

    // 服务端整合包文件信息（如果有）
    NSString *spURL = data[@"serverPackDownloadURL"] ?: data[@"downloadUrl"];
    if ([spURL isKindOfClass:[NSString class]] && spURL.length > 0) {
        self.serverPackDownloadURL = spURL;
    }
    NSString *spName = data[@"serverPackFileName"] ?: data[@"fileName"];
    if ([spName isKindOfClass:[NSString class]] && spName.length > 0) {
        self.serverPackFileName = spName;
    }
    id spSize = data[@"serverPackFileSize"] ?: data[@"fileLength"];
    if ([spSize isKindOfClass:[NSNumber class]]) {
        self.serverPackFileSize = spSize;
    } else if ([spSize respondsToSelector:@selector(unsignedLongLongValue)]) {
        self.serverPackFileSize = @([spSize unsignedLongLongValue]);
    }
}

/// 从文本中提取可能的服务器地址（IP:端口 或 域名:端口 形式）
- (nullable NSString *)extractAddressFromText:(NSString *)text {
    if (!text.length) return nil;
    NSError *error = nil;
    // 匹配：xxx.xxx.xxx.xxx:port 或 domain.example.com:port
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"\\b((?:[a-zA-Z0-9-]+\\.)+[a-zA-Z]{2,}|(?:\\d{1,3}\\.){3}\\d{1,3}):\\d{1,5}\\b"
                             options:0
                               error:&error];
    if (error || !regex) return nil;
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (match) {
        return [text substringWithRange:match.range];
    }
    return nil;
}

- (NSString *)formattedDownloads {
    return [self formatCount:self.downloads];
}

- (NSString *)formattedLikes {
    return [self formatCount:self.likes];
}

- (NSString *)formatCount:(NSNumber *)count {
    if (!count) return @"0";
    long long value = [count longLongValue];
    if (value < 1000) return [NSString stringWithFormat:@"%lld", value];
    if (value < 1000000) return [NSString stringWithFormat:@"%.1fk", value / 1000.0];
    return [NSString stringWithFormat:@"%.1fM", value / 1000000.0];
}

@end
