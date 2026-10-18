#import <Foundation/Foundation.h>
#import "ModpackUtils.h"
#import "UnzipKit.h"

@class MinecraftResourceDownloadTask;

@interface ModpackAPI : NSObject
@property(nonatomic) NSString *baseURL;
@property(nonatomic) NSError *lastError;
@property(nonatomic) BOOL reachedLastPage;

- (instancetype)initWithURL:(NSString *)url;
- (NSMutableArray *)searchModWithFilters:(NSDictionary *)filters previousPageResult:(NSMutableArray *)prevResult;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;
// Task 5.10：在线整合包下载已统一走 ModpackImportService 导入流程，
// submitDownloadTasksFromPackage:toPath: 已删除。

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params;

@end
