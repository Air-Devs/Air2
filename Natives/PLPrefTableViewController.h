#import <UIKit/UIKit.h>

typedef void(^CreateView)(UITableViewCell *, NSString *,NSString *, NSDictionary *);
typedef id (^GetPreferenceBlock)(NSString *, NSString *);
typedef void (^SetPreferenceBlock)(NSString *, NSString *, id);

@interface PLPrefTableViewController : UITableViewController<UITextFieldDelegate, UISearchResultsUpdating>

@property(nonatomic) CreateView typeButton, typeChildPane, typePickField, typeTextField, typeSlider, typeSwitch;

@property(nonatomic) GetPreferenceBlock getPreference;
@property(nonatomic) SetPreferenceBlock setPreference;
@property(nonatomic) BOOL prefSectionsVisible, hasDetail;

@property(nonatomic) NSArray<NSString*>* prefSections;
@property(nonatomic) NSMutableArray<NSNumber*>* prefSectionsVisibility;
@property(nonatomic) NSArray<NSArray<NSDictionary*>*>* prefContents;
@property(nonatomic) BOOL prefDetailVisible;

/// 搜索功能：是否启用搜索栏（子类在 viewDidLoad 设置 YES 启用）
@property(nonatomic) BOOL searchEnabled;
/// 当前搜索关键词（仅读，由 searchController 内部更新）
@property(nonatomic, readonly) NSString *currentSearchText;
/// 搜索结果列表（仅读，搜索激活时非 nil，否则为 nil）。
/// 子类可据此判断当前是否处于搜索模式，并访问过滤后的项数据
/// （每项含 __origSection / __origRow / __localizedTitle 等内部字段）
@property(nonatomic, readonly, nullable) NSArray *filteredItems;

- (UIBarButtonItem *)drawHelpButton;
- (void)initViewCreation;

/// 打开子页面（typeChildPane 类型的设置项触发）
/// 子类可重写此方法以自定义特定 key 的跳转逻辑，然后调用 super 处理其他项
- (void)tableView:(UITableView *)tableView openChildPaneAtIndexPath:(NSIndexPath *)indexPath;

@end