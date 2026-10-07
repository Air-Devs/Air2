//
//  A2CardPosition.m
//  Air2
//

#import "A2CardPosition.h"

CACornerMask A2CornerMaskForPosition(A2CardPosition position) {
    switch (position) {
        case A2CardPositionTop:
            // 上两角大圆角，下两角小圆角
            return kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        case A2CardPositionBottom:
            return kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        case A2CardPositionSingle:
            return kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                   kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        case A2CardPositionMiddle:
        default:
            return 0;   // 四角都是小圆角
    }
}
