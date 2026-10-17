//
//  A2PaginationBar.m
//  Air2
//

#import "A2PaginationBar.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2PaginationBar ()
@property (nonatomic, assign) NSInteger currentPage;
@property (nonatomic, assign) NSInteger totalPages;

@property (nonatomic, strong) UIButton *prevButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UILabel *pageLabel;
@property (nonatomic, strong) UISelectionFeedbackGenerator *feedback;
@end

@implementation A2PaginationBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self setup];
    return self;
}

- (void)setup {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _currentPage = 1;
    _totalPages = 0;
    _isLastPage = NO;
    _feedback = [UISelectionFeedbackGenerator new];

    _prevButton = [self makeButton:@"上一页" symbol:@"chevron.left" action:@selector(goPrevious)];
    _nextButton = [self makeButton:@"下一页" symbol:@"chevron.right" action:@selector(goNext)];
    // 下一页的图标在右
    [_nextButton setSemanticContentAttribute:UISemanticContentAttributeForceRightToLeft];

    _pageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _pageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _pageLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _pageLabel.textAlignment = NSTextAlignmentCenter;
    _pageLabel.text = @"第 1 页";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[_prevButton, _pageLabel, _nextButton]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = A2SpaceL;
    stack.alignment = UIStackViewAlignmentCenter;
    [self addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor],

        [self.heightAnchor constraintEqualToConstant:52],
    ]];

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applyTheme)
                                              name:A2ThemeDidChangeNotification
                                            object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UIButton *)makeButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    b.titleEdgeInsets = UIEdgeInsetsMake(0, 4, 0, -4);
    b.layer.cornerRadius = A2RadiusM;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);

    [b.heightAnchor constraintEqualToConstant:36].active = YES;
    [b.widthAnchor constraintGreaterThanOrEqualToConstant:96].active = YES;

    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - 状态

- (void)setCurrentPage:(NSInteger)page totalPages:(NSInteger)totalPages {
    _currentPage = MAX(1, page);
    _totalPages = totalPages;

    if (totalPages > 0) {
        _pageLabel.text = [NSString stringWithFormat:@"第 %ld / %ld 页",
                           (long)_currentPage, (long)totalPages];
    } else {
        _pageLabel.text = [NSString stringWithFormat:@"第 %ld 页", (long)_currentPage];
    }

    [self updateButtonStates];
}

- (void)setIsLastPage:(BOOL)isLastPage {
    _isLastPage = isLastPage;
    [self updateButtonStates];
}

/// 上一页可用条件：不是第一页
/// 下一页可用条件：不是最后一页（totalPages 已知时也检查页码）
- (void)updateButtonStates {
    BOOL canPrev = (_currentPage > 1);

    BOOL canNext = !_isLastPage;
    if (_totalPages > 0 && _currentPage >= _totalPages) canNext = NO;

    _prevButton.enabled = canPrev;
    _nextButton.enabled = canNext;
    _prevButton.alpha = canPrev ? 1.0 : 0.4;
    _nextButton.alpha = canNext ? 1.0 : 0.4;
}

#pragma mark - 交互

- (void)goPrevious {
    if (_currentPage <= 1) return;
    [_feedback selectionChanged];
    _currentPage -= 1;
    [self setCurrentPage:_currentPage totalPages:_totalPages];
    if (self.onNavigate) self.onNavigate(_currentPage);
}

- (void)goNext {
    if (_isLastPage) return;
    if (_totalPages > 0 && _currentPage >= _totalPages) return;

    [_feedback selectionChanged];
    _currentPage += 1;
    [self setCurrentPage:_currentPage totalPages:_totalPages];
    if (self.onNavigate) self.onNavigate(_currentPage);
}

#pragma mark - 主题

- (void)applyTheme {
    A2ColorScheme *t = A2ThemeManager.shared.scheme;

    for (UIButton *b in @[_prevButton, _nextButton]) {
        [b setTitleColor:t.cOnSurfaceVariant forState:UIControlStateNormal];
        [b setTitleColor:[t.cOnSurfaceVariant colorWithAlphaComponent:0.4]
                forState:UIControlStateDisabled];
        b.tintColor = t.cOnSurfaceVariant;
        b.backgroundColor = t.cSurfaceContainerHigh;
    }
    _pageLabel.textColor = t.cOnSurface;
}

@end
