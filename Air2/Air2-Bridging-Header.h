//
//  Air2-Bridging-Header.h
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Swift ↔ ObjC 桥接头 —— App/UI 层 Swift 可见的 ObjC 门面。
//  只放 Swift 实际引用的头文件（过渡期 Core/Utils 仍是 ObjC）。
//  某头被 Swift 重写后，把它从这里删掉；新增 Swift 对 ObjC 的引用时，
//  把对应头加进来（与 docs/ARCHITECTURE.md「新增即登记」同节奏）。
//  构建设置由 scripts/gen_xcodeproj.py 自动写入
//  （SWIFT_OBJC_BRIDGING_HEADER，本文件存在时才写），不要手改工程。
//
//  注意：A2Log 的 `+log:format,...` 是 C 可变参数，Swift 不可调用；
//  Swift 调用方一律用 `+logMessage:`（先插值再传整串）。

#import "Air2/Utils/A2Log.h"
#import "Air2/Core/Settings/A2Settings.h"
#import "Air2/Core/Account/A2Account.h"
#import "Air2/Core/Account/A2AccountManager.h"
#import "Air2/Core/Path/A2GameDirMigration.h"
