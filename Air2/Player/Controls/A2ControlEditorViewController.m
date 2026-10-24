//
//  A2ControlEditorViewController.m
//  Air2
//

#import "A2ControlEditorViewController.h"
#import "A2ControlRenderer.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Toast.h"

/// 撤销/重做的快照
@interface A2LayoutSnapshot : NSObject
@property (nonatomic, strong) NSDictionary *json;
@end
@implementation A2LayoutSnapshot
@end

@interface A2ControlEditorViewController ()
@property (nonatomic, strong) A2ControlLayout *layout;
@property (nonatomic, strong) A2ControlRenderer *renderer;
@property (nonatomic, strong) UIView *toolbar;
@property (nonatomic, strong) UIView *propertyPanel;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UILabel *sizeLabel;
@property (nonatomic, strong) NSMutableArray<A2LayoutSnapshot *> *undoStack;
@property (nonatomic, strong) NSMutableArray<A2LayoutSnapshot *> *redoStack;
@property (nonatomic, assign) BOOL gridEnabled;
@property (nonatomic, strong) UIButton *gridButton;
@end

@implementation A2ControlEditorViewController

- (instancetype)initWithLayout:(A2ControlLayout *)layout {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _layout = layout;
    _undoStack = [NSMutableArray array];
    _redoStack = [NSMutableArray array];
    _gridEnabled = YES;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"编辑控件";
    self.view.backgroundColor = A2ThemeManager.shared.scheme.cSurface;

    [self buildRenderer];
    [self buildToolbar];
    [self buildPropertyPanel];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(save)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(cancel)];
}

#pragma mark - 构件

- (void)buildRenderer {
    _renderer = [[A2ControlRenderer alloc] initWithLayout:self.layout];
    _renderer.translatesAutoresizingMaskIntoConstraints = NO;
    _renderer.editing = YES;
    [self.view addSubview:_renderer];

    __weak typeof(self) weakSelf = self;
    _renderer.onSelectionChanged = ^(A2ControlWidget *w) {
        __strong typeof(weakSelf) self = weakSelf;
        [self updatePropertyPanelForWidget:w];
    };

    [NSLayoutConstraint activateConstraints:@[
        [_renderer.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_renderer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_renderer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_renderer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                               constant:-72],
    ]];
}

- (void)buildToolbar {
    _toolbar = [[UIView alloc] initWithFrame:CGRectZero];
    _toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_toolbar];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = A2SpaceS;
    [_toolbar addSubview:stack];

    // 新增按钮
    UIButton *add = [self barButton:@"加" symbol:@"plus" action:@selector(addWidget)];
    // 删除
    UIButton *del = [self barButton:@"删" symbol:@"trash" action:@selector(deleteWidget)];
    // 撤销
    UIButton *undo = [self barButton:@"撤销" symbol:@"arrow.uturn.backward" action:@selector(undo)];
    // 重做
    UIButton *redo = [self barButton:@"重做" symbol:@"arrow.uturn.forward" action:@selector(redo)];
    // 网格吸附
    _gridButton = [self barButton:@"网格" symbol:@"grid" action:@selector(toggleGrid)];

    for (UIButton *b in @[add, del, undo, redo, _gridButton]) [stack addArrangedSubview:b];

    [NSLayoutConstraint activateConstraints:@[
        [_toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_toolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [_toolbar.heightAnchor constraintEqualToConstant:56],

        [stack.centerXAnchor constraintEqualToAnchor:_toolbar.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:_toolbar.centerYAnchor],
    ]];
}

- (UIButton *)barButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:[@"  " stringByAppendingString:title] forState:UIControlStateNormal];
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    b.layer.cornerRadius = 16;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    [b.heightAnchor constraintEqualToConstant:32].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildPropertyPanel {
    _propertyPanel = [[UIView alloc] initWithFrame:CGRectZero];
    _propertyPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _propertyPanel.hidden = YES;
    [self.view addSubview:_propertyPanel];

    _textField = [[UITextField alloc] initWithFrame:CGRectZero];
    _textField.translatesAutoresizingMaskIntoConstraints = NO;
    _textField.placeholder = @"按钮文字";
    _textField.font = [UIFont systemFontOfSize:14];
    _textField.borderStyle = UITextBorderStyleRoundedRect;
    [_textField addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];

    _sizeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _sizeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _sizeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_textField, _sizeLabel]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    [_propertyPanel addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_propertyPanel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_propertyPanel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_propertyPanel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                                 constant:8],
        [_propertyPanel.heightAnchor constraintEqualToConstant:90],

        [stack.topAnchor constraintEqualToAnchor:_propertyPanel.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_propertyPanel.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_propertyPanel.trailingAnchor],
    ]];
}

#pragma mark - 操作

- (void)pushUndo {
    [self.undoStack addObject:[self snapshot]];
    [self.redoStack removeAllObjects];
    if (self.undoStack.count > 50) [self.undoStack removeObjectAtIndex:0];
}

- (A2LayoutSnapshot *)snapshot {
    A2LayoutSnapshot *s = [A2LayoutSnapshot new];
    s.json = [self.layout.layers.firstObject toJSON];
    return s;
}

- (void)addWidget {
    [self pushUndo];

    A2ControlWidget *w = [A2ControlWidget newButtonAtX:40 y:40];
    A2ControlLayer *layer = self.layout.layers.firstObject;
    [layer.widgets addObject:w];

    [self.renderer reload];
    [A2Toast show:@"已添加按钮，拖动调整位置" inView:self.view];
}

- (void)deleteWidget {
    A2ControlWidget *sel = self.renderer.selectedWidget;
    if (!sel) {
        [A2Toast show:@"先选中一个控件" inView:self.view];
        return;
    }

    [self pushUndo];

    for (A2ControlLayer *l in self.layout.layers) {
        [l.widgets removeObject:sel];
    }
    self.renderer.selectedWidget = nil;
    [self.renderer reload];
    _propertyPanel.hidden = YES;
}

- (void)undo {
    if (self.undoStack.count == 0) return;
    A2LayoutSnapshot *s = self.undoStack.lastObject;
    [self.undoStack removeLastObject];
    [self.redoStack addObject:[self snapshot]];
    [self applySnapshot:s];
}

- (void)redo {
    if (self.redoStack.count == 0) return;
    A2LayoutSnapshot *s = self.redoStack.lastObject;
    [self.redoStack removeLastObject];
    [self.undoStack addObject:[self snapshot]];
    [self applySnapshot:s];
}

- (void)applySnapshot:(A2LayoutSnapshot *)s {
    // 用快照重建布局（简化实现：整层替换）
    A2ControlLayer *layer = self.layout.layers.firstObject;
    NSDictionary *json = s.json;
    layer.widgets = [NSMutableArray array];

    // 从 JSON 重新解析控件
    NSArray *keys = @[@"normalButtons", @"buttonList", @"buttons"];
    for (NSString *k in keys) {
        NSArray *arr = json[k];
        if (![arr isKindOfClass:NSArray.class]) continue;
        for (NSDictionary *j in arr) {
            A2ControlWidget *w = [A2ControlWidget widgetFromJSON:j
                                                            type:A2ControlWidgetTypeButton
                                                         layerID:layer.identifier];
            if (w) [layer.widgets addObject:w];
        }
        break;
    }

    [self.renderer reload];
}

- (void)toggleGrid {
    _gridEnabled = !_gridEnabled;
    _gridButton.alpha = _gridEnabled ? 1.0 : 0.4;
    [A2Toast show:_gridEnabled ? @"网格吸附已开启" : @"网格吸附已关闭" inView:self.view];
}

- (void)updatePropertyPanelForWidget:(A2ControlWidget *)w {
    if (!w) {
        _propertyPanel.hidden = YES;
        return;
    }
    _propertyPanel.hidden = NO;
    _textField.text = w.text;
    _sizeLabel.text = [NSString stringWithFormat:@"位置 %.1f%%, %.1f%%  尺寸 %.1f%% × %.1f%%",
                       w.xPercent, w.yPercent, w.widthPercent, w.heightPercent];
}

- (void)textChanged {
    A2ControlWidget *sel = self.renderer.selectedWidget;
    if (!sel) return;
    sel.text = _textField.text;
    [self.renderer reload];
}

#pragma mark - 保存

- (void)save {
    if (self.filePath.length) {
        NSError *err = nil;
        if (![self.layout writeToFile:self.filePath error:&err]) {
            [A2Toast show:(err.localizedDescription ?: @"保存失败") inView:self.view];
            return;
        }
    }
    if (self.onSave) self.onSave(self.layout);
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)cancel {
    [self.navigationController popViewControllerAnimated:YES];
}

@end
