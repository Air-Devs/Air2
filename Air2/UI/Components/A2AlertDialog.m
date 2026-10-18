//
//  A2AlertDialog.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#import "A2AlertDialog.h"
#import "A2ThemeManager.h"
#import "A2Metrics.h"
#import "A2Typography.h"

@interface A2AlertDialog ()

@property (nonatomic, copy) NSArray<NSString *> *paragraphs;
@property (nonatomic, strong) NSMutableArray<UILabel *> *paragraphLabels;

@end

@implementation A2AlertDialog

- (instancetype)initWithTitle:(NSString *)title paragraphs:(NSArray<NSString *> *)paragraphs {
    self = [super init];
    if (self) {
        self.titleText = title;
        _paragraphs = [paragraphs copy] ?: @[];
        _paragraphLabels = [NSMutableArray array];
    }
    return self;
}

- (instancetype)init {
    return [self initWithTitle:nil paragraphs:@[]];
}

+ (void)presentOver:(UIViewController *)host
              title:(NSString *)title
         paragraphs:(NSArray<NSString *> *)paragraphs
        cancelTitle:(NSString *)cancelTitle
       confirmTitle:(NSString *)confirmTitle
          onConfirm:(A2AlertDialogAction)onConfirm {
    A2AlertDialog *dialog = [[A2AlertDialog alloc] initWithTitle:title paragraphs:paragraphs];
    [dialog addButtonRowWithCancelTitle:cancelTitle
                           cancelAction:nil
                           confirmTitle:confirmTitle
                          confirmAction:onConfirm];
    [dialog presentOver:host];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    if (self.paragraphs.count > 0) {
        UIStackView *textStack = [[UIStackView alloc] initWithFrame:CGRectZero];
        textStack.axis = UILayoutConstraintAxisVertical;
        textStack.alignment = UIStackViewAlignmentFill;
        textStack.spacing = A2SpaceS;

        for (NSString *text in self.paragraphs) {
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
            label.numberOfLines = 0;
            label.font = [A2Typography body];
            label.text = text;
            [textStack addArrangedSubview:label];
            [self.paragraphLabels addObject:label];
        }

        [self.contentStack addArrangedSubview:textStack];
    }

    [self applyTheme];
}

- (void)applyTheme {
    [super applyTheme];

    A2ColorScheme *scheme = A2ThemeManager.shared.scheme;
    for (UILabel *label in self.paragraphLabels) {
        label.textColor = scheme.cOnSurfaceVariant;
    }
}

@end
