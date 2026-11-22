//
//  A2ControlEditorViewController.m
//  Air2
//
//  控件编辑器。交互参考：
//    fcl/.../control/EditViewGroupDialog.java、EditButtonDetails.kt、
//    BindGroupDialog.java
//    zl2/.../ui/screens/main/control_editor/ControlEditor.kt、
//    EditorOperations.kt、edit_widget/BasicInfoEdit.kt、ClickEventEdit.kt
//
//  实现要点：
//    · 拖动 / 双指缩放由 A2ControlRenderer 的编辑手势完成，
//      本类只负责属性面板、增删、层级、复制粘贴、撤销重做、保存。
//    · 撤销/重做的快照用 A2ControlLayout 的内部快照（百分比坐标），
//      不用 ZL2/FCL 的 JSON —— 那会经过对方的坐标换算而漂移。
//    · 保存写 Air2 原生格式（A2ControlStore），宿主加载控件时的回退
//      路径 A2DefaultControls.makeLayout 会读同一份文件。
//

#import "A2ControlEditorViewController.h"
#import "A2ControlRenderer.h"
#import "A2ControlLayerPanel.h"
#import "A2ControlStore.h"
#import "A2ControlFormat.h"
#import "A2ControlInput.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Toast.h"
#import <math.h>

#pragma mark - 工具

/// 控件类型的中文名（编辑器展示用）
static NSString *A2WidgetTypeName(A2ControlWidgetType type) {
    switch (type) {
        case A2ControlWidgetTypeButton:    return @"按钮";
        case A2ControlWidgetTypeJoystick:  return @"摇杆 / 方向键";
        case A2ControlWidgetTypeTextBox:   return @"文本框";
        case A2ControlWidgetTypeGamepad:   return @"屏幕手柄";
        case A2ControlWidgetTypeGyroscope: return @"陀螺仪";
        case A2ControlWidgetTypeHotbar:    return @"快捷栏";
        case A2ControlWidgetTypeView:      return @"视角区";
        case A2ControlWidgetTypeScroll:    return @"滚轮";
    }
    return @"未知";
}

/// 新建控件时给的默认尺寸（屏幕百分比）。
/// 横屏 16:9 下大致是 72×56pt，手柄/摇杆再大一些。
static void A2DefaultSizeForType(A2ControlWidgetType type,
                                 CGFloat *width, CGFloat *height) {
    switch (type) {
        case A2ControlWidgetTypeJoystick:  *width = 24; *height = 38; break;
        case A2ControlWidgetTypeGamepad:   *width = 30; *height = 26; break;
        case A2ControlWidgetTypeGyroscope: *width = 9;  *height = 15; break;
        case A2ControlWidgetTypeHotbar:    *width = 48; *height = 10; break;
        case A2ControlWidgetTypeView:      *width = 42; *height = 70; break;
        case A2ControlWidgetTypeScroll:    *width = 6;  *height = 24; break;
        case A2ControlWidgetTypeTextBox:   *width = 20; *height = 6;  break;
        case A2ControlWidgetTypeButton:
        default:                           *width = 10; *height = 16; break;
    }
}

@interface A2ControlEditorViewController () <UITextFieldDelegate>

@property (nonatomic, strong) A2ControlLayout *layout;
@property (nonatomic, strong) A2ControlRenderer *renderer;

@property (nonatomic, strong) UIView *toolbar;
@property (nonatomic, strong) UIScrollView *toolbarScroll;
@property (nonatomic, strong, nullable) UIButton *gridButton;
@property (nonatomic, strong, nullable) UIButton *layerButton;

@property (nonatomic, strong) UIView *propertyPanel;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UITextField *keyField;
@property (nonatomic, strong) UITextField *xField;
@property (nonatomic, strong) UITextField *yField;
@property (nonatomic, strong) UITextField *widthField;
@property (nonatomic, strong) UITextField *heightField;
@property (nonatomic, strong) UISlider *opacitySlider;
@property (nonatomic, strong) UILabel *opacityLabel;
@property (nonatomic, strong) UISegmentedControl *visibilityControl;
@property (nonatomic, strong) UILabel *metaLabel;

@property (nonatomic, strong, nullable) A2ControlLayerPanel *layerPanel;
@property (nonatomic, strong, nullable) A2ControlLayer *selectedLayer;

/// 撤销/重做：内部快照
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *undoStack;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *redoStack;
/// 最近一次"已提交"的状态。所有修改完成后调用 recordChange。
@property (nonatomic, strong, nullable) NSDictionary *currentSnapshot;
/// 打开编辑器时的状态（取消时恢复）
@property (nonatomic, strong, nullable) NSDictionary *originalSnapshot;

/// 复制缓冲区：{type, json}
@property (nonatomic, strong, nullable) NSDictionary *clipboard;

@property (nonatomic, assign) BOOL applyingPannelUpdate;

@end

@implementation A2ControlEditorViewController

- (instancetype)initWithLayout:(A2ControlLayout *)layout {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _layout = layout;
    _undoStack = [NSMutableArray array];
    _redoStack = [NSMutableArray array];
    _selectedLayer = layout.layers.firstObject;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"编辑控件";
    self.view.backgroundColor = A2ThemeManager.shared.scheme.cSurface;

    self.originalSnapshot = [self.layout snapshotJSON];
    self.currentSnapshot = self.originalSnapshot;

    [self buildRenderer];
    [self buildToolbar];
    [self buildPropertyPanel];
    [self buildLayerPanel];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(save)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(cancel)];

    [self updatePropertyPanelForWidget:nil];
}

#pragma mark - 构件

- (void)buildRenderer {
    _renderer = [[A2ControlRenderer alloc] initWithLayout:self.layout];
    _renderer.translatesAutoresizingMaskIntoConstraints = NO;
    _renderer.editing = YES;
    _renderer.snapStep = 0.5;
    [self.view addSubview:_renderer];

    __weak typeof(self) weakSelf = self;
    _renderer.onSelectionChanged = ^(A2ControlWidget *w) {
        __strong typeof(weakSelf) self = weakSelf;
        [self updatePropertyPanelForWidget:w];
    };
    _renderer.onWidgetChanged = ^(A2ControlWidget *w) {
        __strong typeof(weakSelf) self = weakSelf;
        // 拖动/缩放过程中持续触发：只刷新数值，不进撤销栈
        [self refreshGeometryFieldsForWidget:w];
    };
    _renderer.onWidgetCommitted = ^(A2ControlWidget *w) {
        __strong typeof(weakSelf) self = weakSelf;
        // 一次手势结束才记一次撤销 —— 否则拖一次会塞几十条
        [self recordChange];
        [self updatePropertyPanelForWidget:w];
    };

    [NSLayoutConstraint activateConstraints:@[
        [_renderer.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_renderer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_renderer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_renderer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                               constant:-64],
    ]];
}

- (UIButton *)barButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:[@" " stringByAppendingString:title] forState:UIControlStateNormal];
    if (symbol.length) {
        [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    }
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    b.layer.cornerRadius = 16;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.backgroundColor = A2ThemeManager.shared.scheme.cSurfaceContainerHigh;
    b.tintColor = A2ThemeManager.shared.scheme.cOnSurface;
    [b.heightAnchor constraintEqualToConstant:34].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildToolbar {
    _toolbar = [[UIView alloc] initWithFrame:CGRectZero];
    _toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    _toolbar.backgroundColor = A2ThemeManager.shared.scheme.cSurfaceContainer;
    [self.view addSubview:_toolbar];

    _toolbarScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _toolbarScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _toolbarScroll.showsHorizontalScrollIndicator = NO;
    [_toolbar addSubview:_toolbarScroll];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = A2SpaceS;
    stack.alignment = UIStackViewAlignmentCenter;

    UIButton *add = [self barButton:@"新增" symbol:@"plus" action:@selector(addWidget)];
    UIButton *copy = [self barButton:@"复制" symbol:@"doc.on.doc" action:@selector(copyWidget)];
    UIButton *paste = [self barButton:@"粘贴" symbol:@"doc.on.clipboard" action:@selector(pasteWidget)];
    UIButton *del = [self barButton:@"删除" symbol:@"trash" action:@selector(deleteWidget)];
    UIButton *forward = [self barButton:@"上移" symbol:@"square.2.layers.3d.top.filled"
                                 action:@selector(bringForward)];
    UIButton *backward = [self barButton:@"下移" symbol:@"square.2.layers.3d.bottom.filled"
                                   action:@selector(sendBackward)];
    UIButton *undo = [self barButton:@"撤销" symbol:@"arrow.uturn.backward" action:@selector(undo)];
    UIButton *redo = [self barButton:@"重做" symbol:@"arrow.uturn.forward" action:@selector(redo)];
    _layerButton = [self barButton:@"图层" symbol:@"square.3.layers.3d" action:@selector(toggleLayerPanel)];
    _gridButton = [self barButton:@"网格" symbol:@"grid" action:@selector(toggleGrid)];

    for (UIButton *b in @[add, copy, paste, del, forward, backward, undo, redo, _layerButton, _gridButton]) {
        [stack addArrangedSubview:b];
    }
    // 删除按钮染成警示色
    del.tintColor = A2ThemeManager.shared.scheme.cError;

    [_toolbarScroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_toolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [_toolbar.heightAnchor constraintEqualToConstant:60],

        [_toolbarScroll.leadingAnchor constraintEqualToAnchor:_toolbar.leadingAnchor],
        [_toolbarScroll.trailingAnchor constraintEqualToAnchor:_toolbar.trailingAnchor],
        [_toolbarScroll.topAnchor constraintEqualToAnchor:_toolbar.topAnchor],
        [_toolbarScroll.bottomAnchor constraintEqualToAnchor:_toolbar.bottomAnchor],

        [stack.leadingAnchor constraintEqualToAnchor:_toolbarScroll.contentLayoutGuide.leadingAnchor
                                            constant:10],
        [stack.trailingAnchor constraintEqualToAnchor:_toolbarScroll.contentLayoutGuide.trailingAnchor
                                             constant:-10],
        [stack.topAnchor constraintEqualToAnchor:_toolbarScroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_toolbarScroll.contentLayoutGuide.bottomAnchor],
        [stack.heightAnchor constraintEqualToAnchor:_toolbarScroll.frameLayoutGuide.heightAnchor],
    ]];
}

- (UITextField *)fieldWithPlaceholder:(NSString *)placeholder {
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectZero];
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.placeholder = placeholder;
    f.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.delegate = self;
    f.returnKeyType = UIReturnKeyDone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    [f.heightAnchor constraintEqualToConstant:32].active = YES;
    [f addTarget:self action:@selector(textFieldDidBeginEditing:)
        forControlEvents:UIControlEventEditingDidBegin];
    return f;
}

- (UILabel *)smallLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text = text;
    l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    l.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;
    return l;
}

- (void)buildPropertyPanel {
    _propertyPanel = [[UIView alloc] initWithFrame:CGRectZero];
    _propertyPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _propertyPanel.hidden = YES;
    _propertyPanel.backgroundColor =
        [A2ThemeManager.shared.scheme.cSurfaceContainer colorWithAlphaComponent:0.96];
    _propertyPanel.layer.cornerRadius = A2RadiusL;
    _propertyPanel.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:_propertyPanel];

    _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metaLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _metaLabel.textColor = A2ThemeManager.shared.scheme.cOnSurfaceVariant;

    _textField = [self fieldWithPlaceholder:@"显示文字"];
    _keyField = [self fieldWithPlaceholder:@"按键 / 事件（如 87、GLFW_KEY_W、launcher.event.switch_ime）"];
    _keyField.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];

    _xField = [self fieldWithPlaceholder:@"X%"];
    _yField = [self fieldWithPlaceholder:@"Y%"];
    _widthField = [self fieldWithPlaceholder:@"宽%"];
    _heightField = [self fieldWithPlaceholder:@"高%"];

    _opacityLabel = [self smallLabel:@"100%"];
    _opacitySlider = [[UISlider alloc] initWithFrame:CGRectZero];
    _opacitySlider.translatesAutoresizingMaskIntoConstraints = NO;
    _opacitySlider.minimumValue = 0.05;
    _opacitySlider.maximumValue = 1.0;
    _opacitySlider.value = 1.0;
    [_opacitySlider addTarget:self action:@selector(opacityChanged)
            forControlEvents:UIControlEventValueChanged];
    [_opacitySlider addTarget:self action:@selector(opacityCommitted)
            forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

    _visibilityControl = [[UISegmentedControl alloc] initWithItems:@[@"始终", @"游戏内", @"菜单内"]];
    _visibilityControl.translatesAutoresizingMaskIntoConstraints = NO;
    [_visibilityControl addTarget:self action:@selector(visibilityChanged)
                 forControlEvents:UIControlEventValueChanged];
    [_visibilityControl.heightAnchor constraintEqualToConstant:30].active = YES;

    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[_textField, _keyField]];
    row1.axis = UILayoutConstraintAxisHorizontal;
    row1.spacing = 6;
    row1.distribution = UIStackViewDistributionFillEqually;

    UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:@[_xField, _yField,
                                                                     _widthField, _heightField]];
    row2.axis = UILayoutConstraintAxisHorizontal;
    row2.spacing = 6;
    row2.distribution = UIStackViewDistributionFillEqually;

    UIStackView *opacityRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self smallLabel:@"透明度"], _opacitySlider, _opacityLabel]];
    opacityRow.axis = UILayoutConstraintAxisHorizontal;
    opacityRow.spacing = 6;
    opacityRow.alignment = UIStackViewAlignmentCenter;
    [_opacityLabel.widthAnchor constraintEqualToConstant:40].active = YES;

    UIStackView *visibilityRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self smallLabel:@"可见性"], _visibilityControl]];
    visibilityRow.axis = UILayoutConstraintAxisHorizontal;
    visibilityRow.spacing = 6;
    visibilityRow.alignment = UIStackViewAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        _metaLabel, row1, row2, opacityRow, visibilityRow]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    [_propertyPanel addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_propertyPanel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_propertyPanel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_propertyPanel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                                 constant:6],

        [stack.topAnchor constraintEqualToAnchor:_propertyPanel.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:_propertyPanel.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:_propertyPanel.trailingAnchor constant:-8],
        [stack.bottomAnchor constraintEqualToAnchor:_propertyPanel.bottomAnchor constant:-8],
    ]];
}

- (void)buildLayerPanel {
    _layerPanel = [[A2ControlLayerPanel alloc] initWithLayers:self.layout.layers];
    _layerPanel.hidden = YES;
    _layerPanel.selectedLayer = self.selectedLayer;
    [self.view addSubview:_layerPanel];

    __weak typeof(self) weakSelf = self;
    _layerPanel.onLayersChanged = ^{
        __strong typeof(weakSelf) self = weakSelf;
        // 面板里的改动（顺序/可见性/增删）已经生效，这里记录一次变更
        [self recordChange];
        [self.renderer reload];
    };
    _layerPanel.onLayerSelected = ^(A2ControlLayer *layer) {
        __strong typeof(weakSelf) self = weakSelf;
        self.selectedLayer = layer;
        [self.renderer reload];
    };

    [NSLayoutConstraint activateConstraints:@[
        [_layerPanel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_layerPanel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_layerPanel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                constant:-68],
    ]];
}

#pragma mark - 撤销 / 重做

- (void)recordChange {
    NSDictionary *current = [self.layout snapshotJSON];
    if (!self.currentSnapshot) {
        self.currentSnapshot = current;
        return;
    }
    if ([current isEqualToDictionary:self.currentSnapshot]) return;

    [self.undoStack addObject:self.currentSnapshot];
    if (self.undoStack.count > 50) [self.undoStack removeObjectAtIndex:0];
    [self.redoStack removeAllObjects];
    self.currentSnapshot = current;
}

- (void)applySnapshot:(NSDictionary *)snapshot {
    A2ControlLayout *restored = [A2ControlLayout layoutFromSnapshot:snapshot];
    if (!restored) return;

    // 原地替换：SurfaceViewController 持有同一个 layout 对象
    self.layout.layers = restored.layers;
    self.layout.name = restored.name;
    self.layout.author = restored.author;
    self.layout.aspectRatio = restored.aspectRatio;
    self.layout.version = restored.version;
    self.layout.sourceFormat = restored.sourceFormat;
    self.layout.buttonStyles = restored.buttonStyles;
    self.layout.joystickStyles = restored.joystickStyles;

    if (![self.layout.layers containsObject:self.selectedLayer]) {
        self.selectedLayer = self.layout.layers.firstObject;
    }
    self.layerPanel.selectedLayer = self.selectedLayer;
    [self.layerPanel reload];
    [self.renderer reload];
    self.renderer.selectedWidget = nil;
    [self updatePropertyPanelForWidget:nil];
}

- (void)undo {
    if (self.undoStack.count == 0) {
        [A2Toast show:@"没有可撤销的操作" inView:self.view];
        return;
    }
    NSDictionary *previous = self.undoStack.lastObject;
    [self.undoStack removeLastObject];
    [self.redoStack addObject:self.currentSnapshot ?: [self.layout snapshotJSON]];
    [self applySnapshot:previous];
    self.currentSnapshot = previous;
}

- (void)redo {
    if (self.redoStack.count == 0) {
        [A2Toast show:@"没有可重做的操作" inView:self.view];
        return;
    }
    NSDictionary *next = self.redoStack.lastObject;
    [self.redoStack removeLastObject];
    [self.undoStack addObject:self.currentSnapshot ?: [self.layout snapshotJSON]];
    [self applySnapshot:next];
    self.currentSnapshot = next;
}

#pragma mark - 增删 / 复制粘贴 / 层级

- (A2ControlLayer *)targetLayer {
    if (self.selectedLayer && [self.layout.layers containsObject:self.selectedLayer]) {
        return self.selectedLayer;
    }
    return self.layout.layers.firstObject;
}

- (void)addWidget {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"新增控件"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSNumber *> *types = @[@(A2ControlWidgetTypeButton),
                                   @(A2ControlWidgetTypeJoystick),
                                   @(A2ControlWidgetTypeView),
                                   @(A2ControlWidgetTypeScroll),
                                   @(A2ControlWidgetTypeHotbar),
                                   @(A2ControlWidgetTypeGyroscope),
                                   @(A2ControlWidgetTypeGamepad),
                                   @(A2ControlWidgetTypeTextBox)];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *num in types) {
        A2ControlWidgetType type = (A2ControlWidgetType)num.integerValue;
        [sheet addAction:[UIAlertAction actionWithTitle:A2WidgetTypeName(type)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            __strong typeof(weakSelf) self = weakSelf;
            [self insertWidgetOfType:type];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                            handler:nil]];

    // iPad 上 action sheet 需要锚点
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetHeight(self.view.bounds) - 40, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)insertWidgetOfType:(A2ControlWidgetType)type {
    A2ControlLayer *layer = [self targetLayer];
    if (!layer) return;

    A2ControlWidget *w = [A2ControlWidget newWidgetOfType:type];
    CGFloat width = w.widthPercent;
    CGFloat height = w.heightPercent;
    A2DefaultSizeForType(type, &width, &height);
    if (type == A2ControlWidgetTypeHotbar || type == A2ControlWidgetTypeScroll ||
        type == A2ControlWidgetTypeGyroscope) {
        // 这两个的默认尺寸已经算好，沿用
        width = w.widthPercent;
        height = w.heightPercent;
    }
    w.xPercent = MAX(0, MIN(100 - width, 50 - width / 2));
    w.yPercent = MAX(0, MIN(100 - height, 50 - height / 2));
    w.widthPercent = width;
    w.heightPercent = height;
    w.layerID = layer.identifier;

    [layer.widgets addObject:w];
    [self recordChange];
    [self.renderer reload];
    self.renderer.selectedWidget = w;
    [self updatePropertyPanelForWidget:w];
    [A2Toast show:[NSString stringWithFormat:@"已添加%@", A2WidgetTypeName(type)]
            inView:self.view];
}

- (void)copyWidget {
    A2ControlWidget *sel = self.renderer.selectedWidget;
    if (!sel) {
        [A2Toast show:@"先选中一个控件" inView:self.view];
        return;
    }
    self.clipboard = @{@"type": @(sel.type), @"json": [sel toJSON]};
    [A2Toast show:@"已复制" inView:self.view];
}

- (void)pasteWidget {
    if (!self.clipboard) {
        [A2Toast show:@"剪贴板是空的" inView:self.view];
        return;
    }
    A2ControlLayer *layer = [self targetLayer];
    if (!layer) return;

    NSNumber *typeNum = self.clipboard[@"type"];
    NSDictionary *json = self.clipboard[@"json"];
    if (![typeNum isKindOfClass:NSNumber.class] || ![json isKindOfClass:NSDictionary.class]) {
        return;
    }

    A2ControlWidget *w = [A2ControlWidget widgetFromJSON:json
                                                    type:(A2ControlWidgetType)typeNum.integerValue
                                                 layerID:layer.identifier];
    if (!w) return;
    w.identifier = [[NSUUID UUID] UUIDString];
    // 偏移一点，避免和原件完全重叠看不出来
    w.xPercent = MAX(0, MIN(100 - w.widthPercent, w.xPercent + 2));
    w.yPercent = MAX(0, MIN(100 - w.heightPercent, w.yPercent + 2));
    w.layerID = layer.identifier;

    [layer.widgets addObject:w];
    [self recordChange];
    [self.renderer reload];
    self.renderer.selectedWidget = w;
    [self updatePropertyPanelForWidget:w];
}

- (void)deleteWidget {
    A2ControlWidget *sel = self.renderer.selectedWidget;
    if (!sel) {
        [A2Toast show:@"先选中一个控件" inView:self.view];
        return;
    }

    for (A2ControlLayer *l in self.layout.layers) {
        [l.widgets removeObject:sel];
    }
    self.renderer.selectedWidget = nil;
    [self recordChange];
    [self.renderer reload];
    [self updatePropertyPanelForWidget:nil];
}

/// 层级：上移 = 更晚绘制（更上层）
- (void)bringForward {
    A2ControlWidget *sel = self.renderer.selectedWidget;
    if (!sel) return;
    A2ControlLayer *layer = [self layerContainingWidget:sel];
    NSUInteger index = [layer.widgets indexOfObject:sel];
    if (index == NSNotFound || index + 1 >= layer.widgets.count) return;

    [layer.widgets exchangeObjectAtIndex:index withObjectAtIndex:index + 1];
    [self recordChange];
    [self.renderer reload];
    self.renderer.selectedWidget = sel;
}

- (void)sendBackward {
    A2ControlWidget *sel = self.renderer.selectedWidget;
    if (!sel) return;
    A2ControlLayer *layer = [self layerContainingWidget:sel];
    NSUInteger index = [layer.widgets indexOfObject:sel];
    if (index == NSNotFound || index == 0) return;

    [layer.widgets exchangeObjectAtIndex:index withObjectAtIndex:index - 1];
    [self recordChange];
    [self.renderer reload];
    self.renderer.selectedWidget = sel;
}

- (A2ControlLayer *)layerContainingWidget:(A2ControlWidget *)w {
    for (A2ControlLayer *l in self.layout.layers) {
        if ([l.widgets containsObject:w]) return l;
    }
    return nil;
}

- (void)toggleGrid {
    BOOL on = (self.renderer.snapStep <= 0.01);
    self.renderer.snapStep = on ? 0.5 : 0;
    _gridButton.alpha = on ? 1.0 : 0.45;
    [A2Toast show:(on ? @"网格吸附已开启（0.5%）" : @"网格吸附已关闭") inView:self.view];
}

- (void)toggleLayerPanel {
    if (!_layerPanel) return;
    BOOL show = _layerPanel.hidden;
    _layerPanel.hidden = !show;
    _layerButton.alpha = show ? 1.0 : 0.5;
}

#pragma mark - 属性面板

- (void)updatePropertyPanelForWidget:(A2ControlWidget *)w {
    if (!w) {
        _propertyPanel.hidden = YES;
        return;
    }
    self.applyingPannelUpdate = YES;
    _propertyPanel.hidden = NO;

    _textField.text = w.text ?: @"";
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (A2ControlEvent *e in w.clickEvents) {
        if (e.key.length) [keys addObject:e.key];
    }
    _keyField.text = [keys componentsJoinedByString:@" "];

    [self refreshGeometryFieldsForWidget:w];

    _opacitySlider.value = MAX(0.05, MIN(1.0, w.opacity));
    _opacityLabel.text = [NSString stringWithFormat:@"%d%%", (int)lround(w.opacity * 100)];

    switch (w.visibility) {
        case A2ControlVisibilityInGame: _visibilityControl.selectedSegmentIndex = 1; break;
        case A2ControlVisibilityInMenu: _visibilityControl.selectedSegmentIndex = 2; break;
        default:                        _visibilityControl.selectedSegmentIndex = 0; break;
    }

    A2ControlLayer *layer = [self layerContainingWidget:w];
    _metaLabel.text = [NSString stringWithFormat:@"%@ · 层「%@」",
                       A2WidgetTypeName(w.type), layer.name ?: @"-"];
    self.applyingPannelUpdate = NO;
}

- (void)refreshGeometryFieldsForWidget:(A2ControlWidget *)w {
    if (!w) return;
    BOOL wasApplying = self.applyingPannelUpdate;
    self.applyingPannelUpdate = YES;
    _xField.text = [NSString stringWithFormat:@"%.1f", w.xPercent];
    _yField.text = [NSString stringWithFormat:@"%.1f", w.yPercent];
    _widthField.text = [NSString stringWithFormat:@"%.1f", w.widthPercent];
    _heightField.text = [NSString stringWithFormat:@"%.1f", w.heightPercent];
    self.applyingPannelUpdate = wasApplying;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    A2ControlWidget *sel = self.renderer.selectedWidget;
    if (!sel) return;

    if (textField == _textField) {
        sel.text = textField.text ?: @"";
    } else if (textField == _keyField) {
        [self applyKeyFieldText:textField.text toWidget:sel];
    } else if (textField == _xField || textField == _yField ||
               textField == _widthField || textField == _heightField) {
        [self applyGeometryFieldsToWidget:sel];
    }

    [self recordChange];
    [self.renderer reload];
    self.renderer.selectedWidget = sel;
    [self updatePropertyPanelForWidget:sel];
}

/// 按键字段：支持空格/逗号分隔的多个键；支持 GLFW 名称、
/// launcher.event.*、scroll 事件，统一规范化成运行时认的数字键。
- (void)applyKeyFieldText:(NSString *)text toWidget:(A2ControlWidget *)w {
    NSArray<NSString *> *tokens = [text componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@", \n\t"]];
    NSMutableArray<A2ControlEvent *> *events = [NSMutableArray array];
    for (NSString *raw in tokens) {
        if (raw.length == 0) continue;

        NSInteger code = -1;
        A2ControlInputKind kind = [A2ControlEventKey kindForRawKey:raw outCode:&code];
        switch (kind) {
            case A2ControlInputKindKey:
            case A2ControlInputKindMouseButton: {
                NSString *normalized = [A2ControlEventKey normalizedKey:raw];
                if (normalized.length) [events addObject:[A2ControlEvent keyEventWithCode:normalized]];
                break;
            }
            case A2ControlInputKindScroll:
                [events addObject:[A2ControlEvent launcherEvent:raw]];
                break;
            case A2ControlInputKindLauncher:
                [events addObject:[A2ControlEvent launcherEvent:raw]];
                break;
            default:
                break;
        }
    }
    w.clickEvents = events;
}

- (void)applyGeometryFieldsToWidget:(A2ControlWidget *)w {
    CGFloat x = _xField.text.doubleValue;
    CGFloat y = _yField.text.doubleValue;
    CGFloat width = _widthField.text.doubleValue;
    CGFloat height = _heightField.text.doubleValue;
    if (!isfinite(x)) x = w.xPercent;
    if (!isfinite(y)) y = w.yPercent;
    if (!isfinite(width) || width < 2) width = w.widthPercent;
    if (!isfinite(height) || height < 2) height = w.heightPercent;

    width = MAX(2, MIN(100, width));
    height = MAX(2, MIN(100, height));
    w.widthPercent = width;
    w.heightPercent = height;
    w.xPercent = MAX(0, MIN(100 - width, x));
    w.yPercent = MAX(0, MIN(100 - height, y));
}

- (void)opacityChanged {
    A2ControlWidget *sel = self.renderer.selectedWidget;
    if (!sel || self.applyingPannelUpdate) return;
    sel.opacity = MAX(0.05, _opacitySlider.value);
    _opacityLabel.text = [NSString stringWithFormat:@"%d%%", (int)lround(sel.opacity * 100)];
    [self.renderer reload];
    self.renderer.selectedWidget = sel;
}

- (void)opacityCommitted {
    [self recordChange];
}

- (void)visibilityChanged {
    A2ControlWidget *sel = self.renderer.selectedWidget;
    if (!sel || self.applyingPannelUpdate) return;
    switch (_visibilityControl.selectedSegmentIndex) {
        case 1: sel.visibility = A2ControlVisibilityInGame; break;
        case 2: sel.visibility = A2ControlVisibilityInMenu; break;
        default: sel.visibility = A2ControlVisibilityAlways; break;
    }
    [self recordChange];
    [self.renderer reload];
    self.renderer.selectedWidget = sel;
}

#pragma mark - 保存 / 取消

- (void)save {
    NSError *err = nil;
    BOOL ok = NO;

    if (self.filePath.length) {
        // 外部传了文件路径：按布局的来源格式写回，避免把 ZL2/FCL 的
        // 文件覆盖成 Air2 格式（对方就再也读不了）。
        A2ControlFormatKind kind = [A2ControlFormat kindForName:self.layout.sourceFormat];
        if (kind == A2ControlFormatKindUnknown) kind = A2ControlFormatKindAir2;
        ok = [A2ControlFormat writeLayout:self.layout
                                   toFile:self.filePath
                                   format:kind
                                    error:&err];
    } else {
        // 游戏内编辑器（宿主传 nil）：写内部持久化路径，
        // 宿主加载控件时的回退路径 A2DefaultControls.makeLayout 会读到它。
        ok = [A2ControlStore saveLayout:self.layout
                                 toPath:[A2ControlStore defaultLayoutPath]
                                  error:&err];
    }

    if (!ok) {
        [A2Toast show:(err.localizedDescription ?: @"保存失败") inView:self.view];
        return;
    }

    // 同时刷一次内存里的"已提交"状态
    self.currentSnapshot = [self.layout snapshotJSON];
    if (self.onSave) self.onSave(self.layout);
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)cancel {
    // 恢复打开前的状态：SurfaceViewController 持有同一个 layout，
    // 不恢复的话取消后它下次重载会拿到被改坏的布局。
    if (self.originalSnapshot) {
        [self applySnapshot:self.originalSnapshot];
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end
