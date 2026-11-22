//
//  A2AccountLeftPanel.m
//  Air2
//

#import "A2AccountLeftPanel.h"
#import "A2Account.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"
#import "A2PrimaryButton.h"
#import "A2SkinHeadView.h"

@interface A2AccountLeftPanel ()
@property (nonatomic, strong) UIView *avatarContainer;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *typeLabel;
@property (nonatomic, strong) A2PrimaryButton *addButton;
@end

@implementation A2AccountLeftPanel

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [self build];
    [self applyTheme];
    return self;
}

- (void)build {
    // ---- 头像区（将来换 3D 预览就是替换这一块）----
    _avatarContainer = [[UIView alloc] initWithFrame:CGRectZero];
    _avatarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarContainer.layer.cornerRadius = A2RadiusXL;
    _avatarContainer.layer.cornerCurve = kCACornerCurveContinuous;
    _avatarContainer.clipsToBounds = YES;

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _nameLabel.textAlignment = NSTextAlignmentCenter;
    _nameLabel.numberOfLines = 1;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.7;
    _nameLabel.text = @"未登录";

    _typeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _typeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _typeLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _typeLabel.textAlignment = NSTextAlignmentCenter;
    _typeLabel.text = @"";

    // ---- 添加账号按钮 ----
    _addButton = [[A2PrimaryButton alloc] initWithTitle:@"添加账号"
                                                   style:A2ButtonStylePrimary];
    _addButton.icon = [UIImage systemImageNamed:@"person.badge.plus"];
    [_addButton addTarget:self action:@selector(addTapped)
         forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[_avatarContainer, _nameLabel, _typeLabel, _addButton]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = A2SpaceS;
    stack.alignment = UIStackViewAlignmentFill;
    [stack setCustomSpacing:A2SpaceM afterView:_typeLabel];

    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:A2SpaceM],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor
                                                     constant:-A2SpaceM],

        [_avatarContainer.heightAnchor constraintEqualToAnchor:_avatarContainer.widthAnchor],
        [_addButton.heightAnchor constraintEqualToConstant:A2ButtonHeight],
    ]];
}

- (void)updateWithAccount:(A2Account *)account {
    if (!account) {
        _nameLabel.text = @"未登录";
        _typeLabel.text = @"选择或添加一个账号";
        _addButton.title = @"添加账号";
        [self.avatarContainer.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
        return;
    }

    _nameLabel.text = account.username;
    _typeLabel.text = account.typeDisplayName;
    _addButton.title = @"添加账号";

    // 头像：有皮肤用头部视图，没有就放大号首字母
    [self.avatarContainer.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    if (account.skinPath.length > 0) {
        A2SkinHeadView *head = [[A2SkinHeadView alloc] initWithFrame:CGRectZero];
        head.translatesAutoresizingMaskIntoConstraints = NO;
        head.skinPath = account.skinPath;
        [_avatarContainer addSubview:head];
        [NSLayoutConstraint activateConstraints:@[
            [head.centerXAnchor constraintEqualToAnchor:_avatarContainer.centerXAnchor],
            [head.centerYAnchor constraintEqualToAnchor:_avatarContainer.centerYAnchor],
            [head.widthAnchor constraintEqualToAnchor:_avatarContainer.widthAnchor multiplier:0.7],
            [head.heightAnchor constraintEqualToAnchor:head.widthAnchor],
        ]];
    } else {
        UILabel *initial = [[UILabel alloc] initWithFrame:CGRectZero];
        initial.translatesAutoresizingMaskIntoConstraints = NO;
        initial.text = account.username.length > 0
            ? [[account.username substringToIndex:1] uppercaseString] : @"?";
        initial.font = [UIFont systemFontOfSize:64 weight:UIFontWeightBold];
        initial.textAlignment = NSTextAlignmentCenter;
        initial.textColor = A2ThemeManager.shared.scheme.cOnPrimaryContainer;
        [_avatarContainer addSubview:initial];
        [NSLayoutConstraint activateConstraints:@[
            [initial.centerXAnchor constraintEqualToAnchor:_avatarContainer.centerXAnchor],
            [initial.centerYAnchor constraintEqualToAnchor:_avatarContainer.centerYAnchor],
        ]];
    }
}

- (void)addTapped {
    if (self.onAddAccount) self.onAddAccount();
}

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;
    self.avatarContainer.backgroundColor = t.cPrimaryContainer;
    _nameLabel.textColor = t.cOnSurface;
    _typeLabel.textColor = t.cOnSurfaceVariant;
}

@end
