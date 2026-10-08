//
//  A2LoginViewController.h
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
//
//  三种登录方式共用一个页面，靠 mode 区分。
//  微软是「展示设备码 + 轮询」，其余是「表单输入」。
//

#import <UIKit/UIKit.h>
#import "A2BaseViewController.h"
#import "A2Account.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, A2LoginMode) {
    A2LoginModeMicrosoft = 0,
    A2LoginModeOffline,
    A2LoginModeThirdParty,
};

@interface A2LoginViewController : A2BaseViewController

- (instancetype)initWithMode:(A2LoginMode)mode;
/// 登录成功回调
@property (nonatomic, copy, nullable) void (^onSuccess)(A2Account *account);

@end

NS_ASSUME_NONNULL_END
