//
//  A2HomeGridView.m
//  Air2
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  卡片区实现。三条行为的落点：
//    · 排布：每次 layout 用 A2HomePacker 从「顺序 / 存储坐标」重算显示坐标；
//    · 窄屏：列数由宽度算，跨度只压列（displayColumnSpan），档位值不动；
//    · 拖拽：长按 0.4s 浮起 → 跟手 → 松手提交（网格改顺序 / 自由改坐标并吸附空格）。
//  显示坐标一律不写回存储，这是「显示位置 ≠ 存储位置」的实现点。
//

#import "A2HomeGridView.h"

#import "A2HomeLayout.h"

#import "A2ColorScheme.h"
#import "A2HomeCardView.h"
#import "A2Log.h"
#import "A2Metrics.h"
#import "A2ThemeManager.h"
#import "A2Typography.h"
#import "A2VersionManager.h"

#include <math.h>

static CGFloat const A2HomeGridMargin = 24.0;
static NSTimeInterval const A2HomeGridLongPressDuration = 0.4;
static CGFloat const A2HomeGridEmptyHeight = 220.0;
static CGFloat const A2HomeGridBannerHeight = 34.0;

@interface A2HomeGridView () <A2HomeCardViewDelegate>

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *canvas;
@property (nonatomic, strong) UILabel *bannerLabel;
@property (nonatomic, strong) UIView *emptyView;
@property (nonatomic, strong) UIImageView *emptyIconView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIButton *emptyButton;
@property (nonatomic, strong) NSMutableArray<A2HomeCardView *> *cardViews;
@property (nonatomic, strong) UILongPressGestureRecognizer *dragGesture;

@property (nonatomic, strong, nullable) NSArray<A2HomePlacement *> *lastPlacements;
@property (nonatomic, assign, readwrite) NSInteger currentColumnCount;

/// 布局期算出来的几何量（拖拽提交时要用同一套，避免用第二份公式）。
@property (nonatomic, assign) CGFloat cardWidthUsed;
@property (nonatomic, assign) CGFloat contentTopUsed;

@property (nonatomic, strong, nullable) A2HomeCardView *draggingView;
@property (nonatomic, assign) CGPoint dragStartCenter;
@property (nonatomic, assign) CGPoint dragStartTouch;
@property (nonatomic, assign) NSInteger dragStartColumn;
@property (nonatomic, assign) NSInteger dragStartRow;

- (void)setupSubviews;
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture;
- (nullable A2HomeCardView *)cardViewAtPoint:(CGPoint)point;
- (void)liftCardView:(A2HomeCardView *)cardView;
- (void)dropCardView:(A2HomeCardView *)cardView atPoint:(CGPoint)point;
- (void)commitGridReorderForCardView:(A2HomeCardView *)cardView atPoint:(CGPoint)point;
- (void)syncCardViewsOrderWithProfile;
- (void)commitFreePositionForCardView:(A2HomeCardView *)cardView atPoint:(CGPoint)point;
- (void)handleAddCardTap;
- (void)cancelDragWithoutCommit;

@end

@implementation A2HomeGridView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self setupSubviews];
    return self;
}

- (void)setupSubviews {
    _cardViews = [NSMutableArray array];

    _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.showsVerticalScrollIndicator = YES;
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self addSubview:_scrollView];

    _canvas = [[UIView alloc] initWithFrame:CGRectZero];
    [_scrollView addSubview:_canvas];

    _bannerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _bannerLabel.font = [A2Typography caption];
    _bannerLabel.numberOfLines = 2;
    _bannerLabel.textAlignment = NSTextAlignmentCenter;
    _bannerLabel.layer.cornerRadius = A2RadiusS;
    _bannerLabel.layer.cornerCurve = kCACornerCurveContinuous;
    _bannerLabel.clipsToBounds = YES;
    _bannerLabel.hidden = YES;
    [self addSubview:_bannerLabel];

    _emptyView = [[UIView alloc] initWithFrame:CGRectZero];
    _emptyView.hidden = YES;
    [_canvas addSubview:_emptyView];

    _emptyIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _emptyIconView.image = [UIImage systemImageNamed:@"square.grid.2x2"];
    _emptyIconView.contentMode = UIViewContentModeScaleAspectFit;
    [_emptyView addSubview:_emptyIconView];

    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLabel.text = @"添加卡片来布置主页";
    _emptyLabel.font = [A2Typography body];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    [_emptyView addSubview:_emptyLabel];

    _emptyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_emptyButton setTitle:@"＋ 添加卡片" forState:UIControlStateNormal];
    _emptyButton.titleLabel.font = [A2Typography button];
    [_emptyButton addTarget:self action:@selector(handleAddCardTap) forControlEvents:UIControlEventTouchUpInside];
    [_emptyView addSubview:_emptyButton];

    // 长按 0.4s 浮起：触屏没有 hover / drag 语义，长按浮起是 iOS 的惯例手势。
    _dragGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                               action:@selector(handleLongPress:)];
    _dragGesture.minimumPressDuration = A2HomeGridLongPressDuration;
    _dragGesture.allowableMovement = 14;
    _dragGesture.enabled = NO;   // 只有编辑态才允许拖
    [_canvas addGestureRecognizer:_dragGesture];
}

#pragma mark - 对外

- (void)setProfile:(nullable A2HomeProfile *)profile {
    _profile = profile;
    [self reloadCards];
}

- (void)setEditing:(BOOL)editing {
    _editing = editing;
    _dragGesture.enabled = editing;
    if (!editing && self.draggingView) [self cancelDragWithoutCommit];
    for (A2HomeCardView *cardView in self.cardViews) cardView.editing = editing;
    [self setNeedsLayout];
}

- (void)setBannerText:(nullable NSString *)bannerText {
    _bannerText = bannerText.copy;
    _bannerLabel.text = bannerText;
    _bannerLabel.hidden = (bannerText.length == 0);
    [self setNeedsLayout];
}

- (void)reloadCards {
    for (A2HomeCardView *cardView in self.cardViews) [cardView removeFromSuperview];
    [self.cardViews removeAllObjects];

    for (A2HomeCard *card in self.profile.cards) {
        A2HomeCardView *cardView = [[A2HomeCardView alloc] initWithCard:card];
        cardView.delegate = self;
        cardView.editing = self.editing;
        [_canvas addSubview:cardView];
        [self.cardViews addObject:cardView];
    }
    _emptyView.hidden = (self.cardViews.count > 0);
    [self applyTheme];
    [self setNeedsLayout];
}

- (void)applyTheme {
    A2ColorScheme *s = A2ThemeManager.shared.scheme;
    self.backgroundColor = UIColor.clearColor;
    // M3：提示条用 secondaryContainer 语义色（不改色值、不自己算透明度）。
    _bannerLabel.backgroundColor = s.cSecondaryContainer;
    _bannerLabel.textColor = s.cOnSecondaryContainer;
    _emptyIconView.tintColor = s.cOnSurfaceVariant;
    _emptyView.layer.borderWidth = 1.2;
    _emptyView.layer.borderColor = s.cOutlineVariant.CGColor;
    _emptyView.layer.cornerRadius = A2RadiusXL;
    _emptyLabel.textColor = s.cOnSurfaceVariant;
    _emptyButton.tintColor = s.cPrimary;
    for (A2HomeCardView *cardView in self.cardViews) [cardView applyTheme];
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];

    _scrollView.frame = self.bounds;

    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat contentWidth = MAX(0.0, width - A2HomeGridMargin * 2);
    NSInteger columns = A2HomeColumnCountForWidth(contentWidth);
    self.currentColumnCount = columns;
    CGFloat cardWidth = columns > 0
        ? (contentWidth - A2HomeGridGap * (CGFloat)(columns - 1)) / (CGFloat)columns
        : contentWidth;
    self.cardWidthUsed = cardWidth;

    CGFloat bannerHeight = self.bannerText.length ? A2HomeGridBannerHeight : 0.0;
    _bannerLabel.hidden = (bannerHeight == 0.0);
    _bannerLabel.frame = CGRectMake(A2HomeGridMargin, 0, contentWidth, bannerHeight);

    CGFloat contentTop = bannerHeight + (bannerHeight > 0 ? A2SpaceS : 0.0);
    self.contentTopUsed = contentTop;
    CGFloat rowPitch = A2HomeCardRowHeight + A2HomeGridGap;

    NSArray<A2HomePlacement *> *placements = nil;
    if (self.profile.layout == A2HomeLayoutModeFree) {
        placements = [A2HomePacker freeDisplayPlacementsForCards:self.profile.cards columns:columns];
    } else {
        placements = [A2HomePacker gridPlacementsForCards:self.profile.cards columns:columns];
    }
    self.lastPlacements = placements;

    CGFloat maxBottom = 0.0;
    if (self.cardViews.count > 0) {
        for (NSUInteger i = 0; i < placements.count && i < self.cardViews.count; i++) {
            A2HomePlacement *placement = placements[i];
            A2HomeCardView *cardView = self.cardViews[i];
            cardView.displayColumnSpan = placement.columnSpan;
            if (cardView == self.draggingView) continue;   // 跟手的那张不抢位置

            CGFloat x = A2HomeGridMargin + (CGFloat)placement.column * (cardWidth + A2HomeGridGap);
            CGFloat y = contentTop + (CGFloat)placement.row * rowPitch;
            CGFloat w = cardWidth * (CGFloat)placement.columnSpan
                      + A2HomeGridGap * (CGFloat)(placement.columnSpan - 1);
            CGFloat h = A2HomeCardRowHeight * (CGFloat)placement.rowSpan
                      + A2HomeGridGap * (CGFloat)(placement.rowSpan - 1);
            cardView.frame = CGRectMake(x, y, MAX(0.0, w), MAX(0.0, h));
            maxBottom = MAX(maxBottom, CGRectGetMaxY(cardView.frame));
        }
    }

    // 自由布局空画布不塌成 0（否则连「点空白处」都没有落点）。
    CGFloat emptyHeight = (self.cardViews.count == 0) ? A2HomeGridEmptyHeight : 0.0;
    CGFloat canvasHeight = MAX(A2HomeGridEmptyHeight,
                              MAX(maxBottom, contentTop + emptyHeight) + A2HomeGridMargin);
    _canvas.frame = CGRectMake(0, 0, width, canvasHeight);
    _scrollView.contentSize = CGSizeMake(width, canvasHeight);

    _emptyView.frame = CGRectMake(A2HomeGridMargin, contentTop, contentWidth, A2HomeGridEmptyHeight);
    _emptyView.layer.borderWidth = 1.2;
    _emptyIconView.frame = CGRectMake((contentWidth - 24) / 2, A2HomeGridEmptyHeight / 2 - 62, 24, 24);
    _emptyLabel.frame = CGRectMake(A2SpaceL, A2HomeGridEmptyHeight / 2 - 30,
                                   contentWidth - A2SpaceL * 2, 22);
    _emptyButton.frame = CGRectMake(A2SpaceL, A2HomeGridEmptyHeight / 2 + 4,
                                    contentWidth - A2SpaceL * 2, A2MinTouchTarget);
}

#pragma mark - 拖拽

- (nullable A2HomeCardView *)cardViewAtPoint:(CGPoint)point {
    for (A2HomeCardView *cardView in self.cardViews.reverseObjectEnumerator) {
        if (CGRectContainsPoint(cardView.frame, point)) return cardView;
    }
    return nil;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:_canvas];

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            A2HomeCardView *cardView = [self cardViewAtPoint:point];
            if (!cardView) return;
            self.draggingView = cardView;
            self.dragStartCenter = cardView.center;
            self.dragStartTouch = point;
            self.dragStartColumn = cardView.card.column;
            self.dragStartRow = cardView.card.row;
            _scrollView.scrollEnabled = NO;
            [self liftCardView:cardView];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            A2HomeCardView *cardView = self.draggingView;
            if (!cardView) return;
            CGPoint delta = CGPointMake(point.x - self.dragStartTouch.x, point.y - self.dragStartTouch.y);
            cardView.center = CGPointMake(self.dragStartCenter.x + delta.x, self.dragStartCenter.y + delta.y);
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            A2HomeCardView *cardView = self.draggingView;
            if (!cardView) return;
            [self dropCardView:cardView atPoint:point];
            break;
        }
        default:
            break;
    }
}

- (void)liftCardView:(A2HomeCardView *)cardView {
    cardView.layer.zPosition = 1000;
    // 触觉：M3 / iOS 惯例的「浮起」反馈（air2-ui §五：中=impact）。
    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    // 浮起只抬 elevation 档 + state layer（M3），不自己编阴影/缩放数值。
    [cardView setLifted:YES];
}

- (void)dropCardView:(A2HomeCardView *)cardView atPoint:(CGPoint)point {
    self.draggingView = nil;
    _scrollView.scrollEnabled = YES;
    cardView.layer.zPosition = 0;
    [cardView setLifted:NO];

    if (self.profile.layout == A2HomeLayoutModeFree) {
        [self commitFreePositionForCardView:cardView atPoint:point];
    } else {
        [self commitGridReorderForCardView:cardView atPoint:point];
    }
    [self setNeedsLayout];
}

/// 网格模式：松手只改「顺序」，位置由装箱重算 —— 不留洞、不重叠，也不会存坐标。
- (void)commitGridReorderForCardView:(A2HomeCardView *)cardView atPoint:(CGPoint)point {
    NSArray<A2HomePlacement *> *placements = self.lastPlacements;
    if (placements.count == 0 || !self.profile) return;

    CGFloat rowPitch = A2HomeCardRowHeight + A2HomeGridGap;
    NSInteger targetColumn = (NSInteger)floor((point.x - A2HomeGridMargin) / MAX(1.0, self.cardWidthUsed + A2HomeGridGap));
    NSInteger targetRow = (NSInteger)floor((point.y - self.contentTopUsed) / MAX(1.0, rowPitch));
    targetColumn = MAX((NSInteger)0, targetColumn);
    targetRow = MAX((NSInteger)0, targetRow);

    // 落点 → 新顺序是纯函数（Core 里单测过），视图只负责「变了才提交」。
    NSArray<A2HomeCard *> *reordered =
        [A2HomePacker cardsByMovingCardID:cardView.card.cardID
                                       in:self.profile.cards
                               placements:placements
                                 toColumn:targetColumn
                                      row:targetRow];

    BOOL unchanged = (reordered.count == self.profile.cards.count);
    if (unchanged) {
        for (NSUInteger i = 0; i < reordered.count; i++) {
            if (reordered[i] != self.profile.cards[i]) { unchanged = NO; break; }
        }
    }
    if (unchanged) return;   // 没动，不写盘

    NSUInteger from = [self.profile.cards indexOfObjectIdenticalTo:cardView.card];
    [self.profile.cards setArray:reordered];
    NSUInteger to = [self.profile.cards indexOfObjectIdenticalTo:cardView.card];

    // ★视图数组必须跟着卡片顺序走★：只改 profile.cards 而 cardViews 还是旧序，
    //  layoutSubviews 按「第 i 张卡 = 第 i 个 view」放位，混尺寸时就会张冠李戴。
    [self syncCardViewsOrderWithProfile];

    [A2Log log:@"[A2-HOME] 网格排序：『%@』从 %lu → %lu（共 %lu 张，不存坐标）",
                A2HomeKindDisplayName(cardView.card.kind),
                (unsigned long)from, (unsigned long)to, (unsigned long)self.profile.cards.count];
    [self.delegate homeGridViewDidChangeLayout:self];
}

/// 把 cardViews 重排成 profile.cards 的顺序（同一个 view 对象，不重建、不丢状态）。
- (void)syncCardViewsOrderWithProfile {
    if (!self.profile) return;
    NSMutableDictionary<NSString *, A2HomeCardView *> *byID = [NSMutableDictionary dictionary];
    for (A2HomeCardView *view in self.cardViews) {
        if (view.card.cardID) byID[view.card.cardID] = view;
    }
    NSMutableArray<A2HomeCardView *> *ordered = [NSMutableArray arrayWithCapacity:byID.count];
    for (A2HomeCard *card in self.profile.cards) {
        A2HomeCardView *view = byID[card.cardID];
        if (view) [ordered addObject:view];
    }
    if (ordered.count == byID.count) self.cardViews = ordered;
}

/// 自由模式：松手只改「自己」的坐标，并按最近空格吸附（不推动别人）。
- (void)commitFreePositionForCardView:(A2HomeCardView *)cardView atPoint:(CGPoint)point {
    if (!self.profile) return;
    A2HomeCard *card = cardView.card;
    NSInteger columns = MAX((NSInteger)1, self.currentColumnCount);
    CGFloat pitchX = MAX(1.0, self.cardWidthUsed + A2HomeGridGap);
    CGFloat pitchY = A2HomeCardRowHeight + A2HomeGridGap;

    NSInteger deltaColumn = (NSInteger)lround((point.x - self.dragStartTouch.x) / pitchX);
    NSInteger deltaRow = (NSInteger)lround((point.y - self.dragStartTouch.y) / pitchY);
    // 窄屏（列数不足最宽）只允许改行：压列的结果不该被写回坐标，
    // 否则在 iPhone 上拖一下就把 iPad 的横向位置永久丢掉。
    if (columns < A2HomeMaxColumns) deltaColumn = 0;

    A2HomeSpan span = A2HomeSpanCompressedToColumns(card.span, columns);
    NSInteger column = MAX((NSInteger)0, self.dragStartColumn + deltaColumn);
    NSInteger row = MAX((NSInteger)0, self.dragStartRow + deltaRow);
    NSSet<NSNumber *> *occupied = [A2HomePacker occupiedIndexesForPlacements:self.lastPlacements
                                                                 excludingID:card.cardID
                                                                     columns:columns];
    [A2HomePacker nearestFreeColumn:&column row:&row forSpan:span columns:columns occupied:occupied];

    if (card.hasPosition && card.column == column && card.row == row) return;   // 没动，不写盘
    card.hasPosition = YES;
    card.column = column;
    card.row = row;
    [A2Log log:@"[A2-HOME] 自由布局：『%@』吸附到 (%ld,%ld)，列数=%ld",
                A2HomeKindDisplayName(card.kind), (long)column, (long)row, (long)columns];
    [self.delegate homeGridViewDidChangeLayout:self];
}

#pragma mark - 卡片回调

- (void)homeCardViewDidActivate:(A2HomeCardView *)view {
    [self.delegate homeGridView:self didActivateCard:view.card];
}

- (void)homeCardView:(A2HomeCardView *)view didActivateVersion:(A2Version *)version {
    [self.delegate homeGridView:self didActivateVersion:version];
}

- (void)homeCardViewDidRequestMenu:(A2HomeCardView *)view {
    [self.delegate homeGridView:self didRequestMenuForCard:view.card];
}

- (void)handleAddCardTap {
    [self.delegate homeGridViewDidRequestAddCard:self];
}

/// 退出编辑态时正在拖的那张：只复位视觉，**不提交**（退出编辑不该改布局）。
- (void)cancelDragWithoutCommit {
    A2HomeCardView *cardView = self.draggingView;
    if (!cardView) return;
    self.draggingView = nil;
    _scrollView.scrollEnabled = YES;
    cardView.layer.zPosition = 0;
    [cardView setLifted:NO];
    [self setNeedsLayout];
}

@end
