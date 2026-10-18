#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherProfileEditorViewController.h"
#import "MinecraftResourceUtils.h"
#import "PickTextField.h"
#import "PLProfiles.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "VersionDataMigration.h"   // ★ [VER-ISOLATE-MIGRATE] 版本隔离数据迁移引擎
#import "BackgroundManager.h"

@interface LauncherProfileEditorViewController()<UIPickerViewDataSource, UIPickerViewDelegate>
@property(nonatomic) NSString* oldName;

@property(nonatomic) NSArray<NSDictionary *> *versionList;
@property(nonatomic) UITextField* versionTextField;
@property(nonatomic) UISegmentedControl* versionTypeControl;
@property(nonatomic) UIPickerView* versionPickerView;
@property(nonatomic) UIToolbar* versionPickerToolbar;
@property(nonatomic) int versionSelectedAt;
// ★ [VER-ISOLATE-MIGRATE] 版本隔离数据迁移（逐实例、复制式、默认不自动搬）
- (void)actionMigrateVersionData;
- (void)runMigrateItems:(NSArray<NSString *> *)names removeSource:(BOOL)removeSource;
- (NSString *)ameHumanBytes:(unsigned long long)bytes;
@end

@implementation LauncherProfileEditorViewController

- (void)viewDidLoad {
    // Setup navigation bar & appearance
    // ★ [AUDIT-DECIDE] A-11：English 字面量当 key（.strings 无此键）→ 复用已有键 i18n_str_1091。
    self.title = localize(@"i18n_str_1091", nil);
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionDone)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationController.modalInPresentation = YES;
    self.prefSectionsVisible = YES;
    
    // 设置半透明背景
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    
    // 设置导航栏半透明样式
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    self.navigationController.navigationBar.tintColor = [UIColor systemBlueColor];

    // Setup preference getter and setter
    __weak LauncherProfileEditorViewController *weakSelf = self;
    self.getPreference = ^id(NSString *section, NSString *key){
        // ★ [VER-ISOLATE-PCL] 版本隔离：未显式设置时展示"解析后的实际生效值"
        // （与 PCL 设置页一致——显示跟随全局/自动判定的结果），用户切换时才写入显式值。
        if ([key isEqualToString:@"versionIsolation"]) {
            id raw = weakSelf.profile[key];
            if (raw) return [raw boolValue] ? @"1" : @"0";
            id vid = weakSelf.profile[@"lastVersionId"];
            return amePCLVersionIsolationForProfile(weakSelf.profile,
                       [vid isKindOfClass:NSString.class] ? (NSString *)vid : nil) ? @"1" : @"0";
        }
        id rawValue = weakSelf.profile[key];
        // 兼容 NSDictionary 类型的 javaVersion（旧版直装器写入）
        if ([rawValue isKindOfClass:[NSDictionary class]]) {
            id major = rawValue[@"majorVersion"];
            return major ? [major description] : @"(default)";
        }
        NSString *value = rawValue;
        if (value.length > 0 || ![weakSelf isPickFieldAtSection:section key:key]) {
            return value;
        } else {
            return @"(default)";
        }
    };
    self.setPreference = ^(NSString *section, NSString *key, NSString *value){
        if ([value isEqualToString:@"(default)"] && [weakSelf isPickFieldAtSection:section key:key]) {
            [weakSelf.profile removeObjectForKey:key];
        } else if (value) {
            weakSelf.profile[key] = value;
        }
    };

    // Obtain all the lists
    self.oldName = self.getPreference(nil, @"name");
    if ([self.oldName length] == 0) {
        self.setPreference(nil, @"name", @"New Profile");
    }
    NSArray *rendererKeys = getRendererKeys(YES);
    NSArray *rendererList = getRendererNames(YES);
    NSArray *touchControlList = [self listFilesAtPath:[NSString stringWithFormat:@"%s/controlmap", getenv("POJAV_HOME")]];
    NSArray *gamepadControlList = [self listFilesAtPath:[NSString stringWithFormat:@"%s/controlmap/gamepads", getenv("POJAV_HOME")]];
    NSMutableArray *javaList = [getPrefObject(@"java.java_homes") allKeys].mutableCopy;
    [javaList sortUsingSelector:@selector(compare:)];
    javaList[0] = @"(default)";

    // Setup version picker
    [self setupVersionPicker];
    id typeVersionPicker = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item){
        self.typeTextField(cell, section, key, item);
        UITextField *textField = (id)cell.accessoryView;
        weakSelf.versionTextField = textField;
        textField.inputAccessoryView = weakSelf.versionPickerToolbar;
        textField.inputView = weakSelf.versionPickerView;
        // Auto pick version type
        if (self.versionList) return;
        if ([MinecraftResourceUtils findVersion:textField.text inList:localVersionList]) {
            self.versionTypeControl.selectedSegmentIndex = 0;
        } else {
            NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:textField.text inList:remoteVersionList];
            if (selected) {
                NSArray *types = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"];
                NSString *type = selected[@"type"];
                self.versionTypeControl.selectedSegmentIndex = [types indexOfObject:type];
            } else {
                // Version not found
                self.versionTypeControl.selectedSegmentIndex = 0;
            }
        }
        self.versionSelectedAt = -1;
        [self changeVersionType:nil];
    };

    self.prefContents = @[
        @[
            // General settings
            @{@"key": @"name",
              @"icon": @"tag",
              @"title": @"preference.profile.title.name",
              @"type": self.typeTextField,
              @"placeholder": self.oldName
            },
            @{@"key": @"lastVersionId",
              @"icon": @"archivebox",
              @"title": @"preference.profile.title.version",
              @"type": typeVersionPicker,
              @"placeholder": self.getPreference(nil, @"lastVersionId"),
              @"customClass": PickTextField.class
            },
            @{@"key": @"gameDir",
              @"icon": @"folder",
              @"title": @"preference.title.game_directory",
              @"type": self.typeTextField,
              @"placeholder": [NSString stringWithFormat:@". -> /Documents/instances/%@", getPrefObject(@"general.game_directory")]
            },
            // ★ [VER-ISOLATE-PCL] 版本隔离开关（对齐 PCL-CE 实例设置页的「实例隔离」）：
            // 开 = 该版本的 mods/config/saves/... 独立落 <实例根>/versions/<版本 id>/；
            // 关 = 与实例内其它版本共享（现状）。值以字符串存 profile（"1"/"0"），
            // 与 profile 内其它键（NSDictionary<NSString*,NSString*>）类型一致。
            @{@"key": @"versionIsolation",
              @"icon": @"square.on.square.dashed",
              @"title": @"preference.profile.title.version_isolation",
              @"type": self.typeSwitch,
              @"customSwitchValue": @[@"0", @"1"],
              @"hasDetail": @YES,
              // ★ [VER-ISOLATE-MIGRATE] 切换隔离会改变下方「迁移版本数据」行是否可用，
              // 故请求整表刷新以重算 enableCondition（复用既有机制，未改视觉）。
              @"requestReload": @YES
            },
            // ★ [VER-ISOLATE-MIGRATE] 版本隔离「数据迁移」入口（逐实例、复制式、默认不自动搬）：
            // 仅在「版本隔离」已开启时可用（enableCondition）。点击后列出将搬运的目录/文件
            // 与体量，用户确认才复制；只复制不删除源；同名文件默认跳过并保留两边。
            // 复用既有 typeButton 行样式，未改视觉。
            @{@"key": @"migrate_version_data",
              @"icon": @"arrow.right.square.on.square",
              @"title": @"preference.profile.title.migrate_version_data",
              @"type": self.typeButton,
              @"hasDetail": @YES,
              @"enableCondition": ^BOOL{
                  id vid = weakSelf.profile[@"lastVersionId"];
                  return amePCLVersionIsolationForProfile(weakSelf.profile,
                             [vid isKindOfClass:NSString.class] ? (NSString *)vid : nil);
              },
              @"action": ^void(){ [weakSelf actionMigrateVersionData]; }
            },
            // Video and renderer settings
            @{@"key": @"renderer",
              @"icon": @"cpu",
              @"type": self.typePickField,
              @"pickKeys": rendererKeys,
              @"pickList": rendererList
            },
            // Control settings
            @{@"key": @"defaultTouchCtrl",
              @"icon": @"hand.tap",
              @"title": @"preference.profile.title.default_touch_control",
              @"type": self.typePickField,
              @"pickKeys": touchControlList,
              @"pickList": touchControlList
            },
            @{@"key": @"defaultGamepadCtrl",
              @"icon": @"gamecontroller",
              @"title": @"preference.profile.title.default_gamepad_control",
              @"type": self.typePickField,
              @"pickKeys": gamepadControlList,
              @"pickList": gamepadControlList
            },
            // Java tweaks
            @{@"key": @"javaVersion",
              @"icon": @"cube",
              @"title": @"preference.manage_runtime.header.default",
              @"type": self.typePickField,
              @"pickKeys": javaList,
              @"pickList": javaList
            },
            @{@"key": @"lwjglVersion",
              @"icon": @"shippingbox",
              @"title": @"preference.profile.title.lwjgl_version",
              @"type": self.typePickField,
              @"pickKeys": @[@"(default)", @"333", @"341"],
              @"pickList": @[@"(default)", @"3.3.3", @"3.4.1"]
            },
            @{@"key": @"javaArgs",
              @"icon": @"slider.vertical.3",
              @"title": @"preference.title.java_args",
              @"type": self.typeTextField,
              @"placeholder": @"(default)"
            }
        ]
    ];

    [super viewDidLoad];
    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    // 此处在上方已通过 applyEffectToView 为视图添加了毛玻璃/半透明效果，
    // 这里再调用 makeViewControllerTransparent 以确保 tableView 背景也被置为透明。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 监听版本列表刷新通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadVersionList)
                                                 name:@"ReloadProfileList"
                                               object:nil];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 确保 tableView 背景透明、全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)reloadVersionList {
    // 清除当前版本列表缓存，下次打开选择器时会重新加载
    self.versionList = nil;
    self.versionSelectedAt = -1;
    
    // 如果版本选择器正在显示，立即刷新
    if (self.versionPickerView && self.versionPickerView.window) {
        [self changeVersionType:nil];
    }
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)actionDone {
    // We might be saving without ending editing, so make sure textFieldDidEndEditing is always called
    UITextField *currentTextField = [self performSelector:@selector(_firstResponder)];
    if ([currentTextField isKindOfClass:UITextField.class] && [currentTextField isDescendantOfView:self.tableView]) {
        [self textFieldDidEndEditing:currentTextField];
    }

    if ([self.profile[@"name"] length] == 0 && self.oldName.length > 0) {
        // Return to its old name
        self.profile[@"name"] = self.oldName;
    }

    if ([self.oldName isEqualToString:self.profile[@"name"]]) {
        // Not a rename, directly create/replace
        PLProfiles.current.profiles[self.oldName] = self.profile;
    } else if (!PLProfiles.current.profiles[self.profile[@"name"]]) {
        // A rename, remove then re-add to update its key name
        if (self.oldName.length > 0) {
            [PLProfiles.current.profiles removeObjectForKey:self.oldName];
        }
        PLProfiles.current.profiles[self.profile[@"name"]] = self.profile;
        // Update selected name
        if ([PLProfiles.current.selectedProfileName isEqualToString:self.oldName]) {
            PLProfiles.current.selectedProfileName = self.profile[@"name"];
        }
    } else {
        // Cancel rename since a profile with the same name already exists
        showDialog(localize(@"Error", nil), localize(@"profile.error.name_exists", nil));
        // Skip dismissing this view controller
        return;
    }

    [PLProfiles.current save];
    
    // 发送通知刷新配置文件列表
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:self.profile[@"name"]];
    
    [self actionClose];
}

#pragma mark ★ [VER-ISOLATE-MIGRATE] 版本隔离数据迁移

- (NSString *)ameHumanBytes:(unsigned long long)bytes {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                           countStyle:NSByteCountFormatterCountStyleFile];
}

- (NSString *)ameMigrationVersionId {
    id vid = self.profile[@"lastVersionId"];
    return [vid isKindOfClass:NSString.class] ? (NSString *)vid : nil;
}

/// 迁移入口（实例编辑页「迁移版本数据」行）。仅列出将搬运的目录/文件与体量，
/// 逐项可选、用户确认才复制；默认只复制、不删源。不动渲染产物 / 不改 UI 视觉。
- (void)actionMigrateVersionData {
    NSString *title = localize(@"preference.profile.title.migrate_version_data", nil);
    NSString *vid = [self ameMigrationVersionId];

    // 未开启隔离 ⇒ 无隔离目标，先提示去开开关（不偷偷替用户开）。
    if (!amePCLVersionIsolationForProfile(self.profile, vid)) {
        showDialog(title, localize(@"preference.migrate.need_isolation", nil));
        return;
    }
    // 源 = resolver 在「关隔离」时给出的 gameDir（用户当前实际在用的那个目录）；
    // 目标 = resolver 在「开隔离」时给出的目录。两端共用同一 resolver，不自拼路径。
    NSString *src = amePCLSharedGameDirForProfile(self.profile, vid);
    NSString *dst = amePCLVersionGameDirAbsolute(self.profile, vid);
    if (src.length == 0 || dst.length == 0 || [src isEqualToString:dst]) {
        showDialog(title, localize(@"preference.migrate.no_target", nil));
        return;
    }

    ameVDMCleanupStaleTemps(dst, ameVDMDefaultItemNames());   // 清上次中断残留
    NSArray<NSDictionary *> *plan = ameVDMPlan(src, dst, ameVDMDefaultItemNames());
    if (plan.count == 0) {
        showDialog(title, localize(@"preference.migrate.nothing", nil));
        return;
    }

    NSUInteger totalFiles = 0;
    unsigned long long totalBytes = 0;
    for (NSDictionary *it in plan) {
        totalFiles += [it[@"files"] unsignedIntegerValue];
        totalBytes += [it[@"bytes"] unsignedLongLongValue];
    }
    NSString *msg = [NSString stringWithFormat:localize(@"preference.migrate.confirm.message", nil),
                     (unsigned long)plan.count, (unsigned long)totalFiles,
                     [self ameHumanBytes:totalBytes], dst];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:msg
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak LauncherProfileEditorViewController *weakSelf = self;
    // 逐项动作：每项都显示体量（文件数 / 字节），可单独迁移。
    for (NSDictionary *it in plan) {
        NSString *rowTitle = [NSString stringWithFormat:localize(@"preference.migrate.item.title", nil),
                              it[@"name"], (unsigned long)[it[@"files"] unsignedIntegerValue],
                              [self ameHumanBytes:[it[@"bytes"] unsignedLongLongValue]]];
        [sheet addAction:[UIAlertAction actionWithTitle:rowTitle style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a){
            [weakSelf runMigrateItems:@[it[@"name"]] removeSource:NO];
        }]];
    }
    NSMutableArray<NSString *> *allNames = [NSMutableArray array];
    for (NSDictionary *it in plan) [allNames addObject:it[@"name"]];
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"preference.migrate.all", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a){
        [weakSelf runMigrateItems:allNames removeSource:NO];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
                                              style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.tableView;
    sheet.popoverPresentationController.sourceRect = self.tableView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

/// 执行迁移并逐项报告；仅在「已复制且无冲突」时提供 destructive 的"删除源"后续动作。
- (void)runMigrateItems:(NSArray<NSString *> *)names removeSource:(BOOL)removeSource {
    NSString *vid = [self ameMigrationVersionId];
    NSString *src = amePCLSharedGameDirForProfile(self.profile, vid);   // resolver 的「关隔离」值
    NSString *dst = amePCLVersionGameDirAbsolute(self.profile, vid);    // resolver 的「开隔离」值
    NSDictionary *opts = @{@"conflictPolicy": @(ameVDMConflictSkip), @"removeSource": @(removeSource)};
    NSDictionary *rep = ameVDMExecute(src, dst, names, opts);

    NSUInteger copied = 0, identical = 0, conflicts = 0, renamed = 0;
    NSMutableString *body = [NSMutableString string];
    NSMutableArray<NSString *> *issues = [NSMutableArray array];
    for (NSDictionary *r in rep[@"items"]) {
        copied    += [r[@"copied"] unsignedIntegerValue];
        identical += [r[@"identical"] unsignedIntegerValue];
        conflicts += [r[@"conflict"] unsignedIntegerValue];
        renamed   += [r[@"renamed"] unsignedIntegerValue];
        [body appendFormat:@"%@\n", [NSString stringWithFormat:localize(@"preference.migrate.line", nil),
            r[@"name"], (unsigned long)[r[@"copied"] unsignedIntegerValue],
            (unsigned long)[r[@"identical"] unsignedIntegerValue],
            (unsigned long)[r[@"conflict"] unsignedIntegerValue],
            (unsigned long)[r[@"renamed"] unsignedIntegerValue]]];
        for (NSString *e in r[@"errors"]) [issues addObject:e];
    }
    [body appendFormat:@"%@", [NSString stringWithFormat:localize(@"preference.migrate.summary", nil),
        (unsigned long)copied, (unsigned long)identical, (unsigned long)conflicts, (unsigned long)renamed]];
    if (removeSource && [rep[@"removed"] boolValue]) {
        [body appendFormat:@"\n%@", localize(@"preference.migrate.removed", nil)];
    }
    if (issues.count > 0) {
        [body appendFormat:@"\n\n%@\n· %@", localize(@"preference.migrate.issues", nil),
            [issues componentsJoinedByString:@"\n· "]];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"preference.migrate.result.title", nil)
                                                                  message:body
                                                           preferredStyle:UIAlertControllerStyleAlert];
    if (!removeSource && copied > 0 && conflicts == 0) {
        __weak LauncherProfileEditorViewController *weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"preference.migrate.cleanup_source", nil)
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *a){
            [weakSelf runMigrateItems:names removeSource:YES];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil)
                                              style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)isPickFieldAtSection:(NSString *)section key:(NSString *)key {
    NSDictionary *pref = [self.prefContents[0] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(key == %@)", key]].firstObject;
    return pref[@"type"] == self.typePickField;
}

- (NSArray *)listFilesAtPath:(NSString *)path {
    NSMutableArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil].mutableCopy;
    for (int i = 0; i < files.count;) {
        if ([files[i] hasSuffix:@".json"]) {
            i++;
        } else {
            [files removeObjectAtIndex:i];
        }
    }
    [files insertObject:@"(default)" atIndex:0];
    return files;
}

#pragma mark Version picker

- (void)setupVersionPicker {
    self.versionPickerView = [[UIPickerView alloc] init];
    self.versionPickerView.delegate = self;
    self.versionPickerView.dataSource = self;
    self.versionPickerToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0.0, 0.0, self.view.frame.size.width, 44.0)];
    self.versionTypeControl = [[UISegmentedControl alloc] initWithItems:@[
        localize(@"Installed", nil),
        localize(@"Releases", nil),
        localize(@"Snapshot", nil),
        localize(@"Old-beta", nil),
        localize(@"Old-alpha", nil)
    ]];
    [self.versionTypeControl addTarget:self action:@selector(changeVersionType:) forControlEvents:UIControlEventValueChanged];
    self.versionPickerToolbar.items = @[
        [[UIBarButtonItem alloc] initWithCustomView:self.versionTypeControl],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(versionClosePicker)]
    ];
}

- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    if (self.versionList.count == 0) {
        self.versionTextField.text = @"";
        return;
    }
    self.versionSelectedAt = row;
    self.versionTextField.text = [self pickerView:pickerView titleForRow:row forComponent:component];
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)thePickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return self.versionList.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    if (self.versionList.count <= row) return nil;
    NSObject *object = self.versionList[row];
    if ([object isKindOfClass:[NSString class]]) {
        return (NSString*) object;
    } else {
        return [object valueForKey:@"id"];
    }
}

- (void)versionClosePicker {
    [self.versionTextField endEditing:YES];
    [self pickerView:self.versionPickerView didSelectRow:[self.versionPickerView selectedRowInComponent:0] inComponent:0];
}

- (void)changeVersionType:(UISegmentedControl *)sender {
    NSArray *newVersionList = self.versionList;
    if (sender || !self.versionList) {
        if (self.versionTypeControl.selectedSegmentIndex == 0) {
            // installed
            newVersionList = localVersionList;
        } else {
            NSString *type = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"][self.versionTypeControl.selectedSegmentIndex];
            newVersionList = [remoteVersionList filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(type == %@)", type]];
        }
    }

    if (self.versionSelectedAt == -1) {
        NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:self.versionTextField.text inList:newVersionList];
        self.versionSelectedAt = [newVersionList indexOfObject:selected];
    } else {
        // Find the most matching version for this type
        NSObject *lastSelected = nil; 
        if (self.versionList.count > self.versionSelectedAt) {
            lastSelected = self.versionList[self.versionSelectedAt];
        }
        if (lastSelected != nil) {
            NSObject *nearest = [MinecraftResourceUtils findNearestVersion:lastSelected expectedType:self.versionTypeControl.selectedSegmentIndex];
            if (nearest != nil) {
                self.versionSelectedAt = [newVersionList indexOfObject:(id)nearest];
            }
        }
        lastSelected = nil;
        // Get back the currently selected in case none matching version found
        self.versionSelectedAt = MIN(abs(self.versionSelectedAt), newVersionList.count - 1);
    }

    self.versionList = newVersionList;
    [self.versionPickerView reloadAllComponents];
    if (self.versionSelectedAt != -1) {
        [self.versionPickerView selectRow:self.versionSelectedAt inComponent:0 animated:NO];
        [self pickerView:self.versionPickerView didSelectRow:self.versionSelectedAt inComponent:0];
    }
}

@end
