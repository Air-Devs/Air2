//
//  A2ModPackImportCoordinator.m
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

#import "A2ModPackImportCoordinator.h"
#import "A2AlertDialog.h"
#import "A2InputDialog.h"
#import "A2ProgressDialog.h"
#import "A2ModPack.h"
#import "A2ModPackInstaller.h"
#import "A2VersionManager.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface A2ModPackImportCoordinator () <UIDocumentPickerDelegate>

@property (nonatomic, weak, nullable) UIViewController *host;

/// 选中的本地整合包路径
@property (nonatomic, copy, nullable) NSString *archivePath;
@property (nonatomic, strong, nullable) A2ModPackInstaller *installer;
@property (nonatomic, strong, nullable) A2ProgressDialog *progressDialog;

@end

@implementation A2ModPackImportCoordinator

#pragma mark - 流程入口

- (void)startFrom:(UIViewController *)host {
    self.host = host;
    [self presentDisclaimer];
}

/// 第一步：先把「会发生什么」讲清楚，用户确认后再去选文件（对齐 ZL2 的提示顺序）
- (void)presentDisclaimer {
    __weak typeof(self) weakSelf = self;
    [A2AlertDialog presentOver:self.host
                         title:@"导入整合包"
                    paragraphs:@[@"支持 CurseForge 与 Modrinth 两种格式：含 manifest.json 的 .zip，或 .mrpack 文件。其它格式无法自动导入。",
                                 @"导入会按整合包声明安装游戏版本与模组加载器，并把 mods、config 等文件写入该版本自己的目录（自动开启版本隔离），不影响其它版本。",
                                 @"整合包内容由第三方提供，请确认来源可信后再导入。"]
                   cancelTitle:@"取消"
                  confirmTitle:@"导入"
                     onConfirm:^{
                         __strong typeof(weakSelf) strongSelf = weakSelf;
                         [strongSelf presentArchivePicker];
                     }];
}

#pragma mark - 第二步：选文件

/// 游戏安装 / 整合包安装是本项目允许使用系统文件选择器的场景；
/// 这里要求「拷贝一份」（asCopy:YES），之后的解析与安装都读这份副本。
- (void)presentArchivePicker {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self.host presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (url.path.length == 0) {
        return;
    }
    self.archivePath = url.path;

    // 解析只读清单，但可能是个几百 MB 的包，别卡在主线程
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *parseError = nil;
        A2ModPackPlan *plan = [A2ModPackParser parseZipAtPath:url.path error:&parseError];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (plan) {
                [strongSelf presentNameDialogWithSuggestedName:plan.name];
            } else {
                [strongSelf showParseFailure:parseError];
            }
        });
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.archivePath = nil;
}

#pragma mark - 第三步：版本命名

- (void)presentNameDialogWithSuggestedName:(NSString *)suggestedName {
    __weak typeof(self) weakSelf = self;
    [A2InputDialog presentOver:self.host
                         title:@"版本名称"
                   placeholder:@"给这个版本起个名字"
                   initialText:suggestedName.length > 0 ? suggestedName : @"整合包"
                      validate:^NSString *(NSString *text) {
                          __strong typeof(weakSelf) strongSelf = weakSelf;
                          return [strongSelf nameValidationMessageForText:text];
                      }
                  cancelTitle:@"取消"
                 confirmTitle:@"开始导入"
                    onConfirm:^(NSString *text) {
                        __strong typeof(weakSelf) strongSelf = weakSelf;
                        [strongSelf startImportWithVersionName:text];
                    }];
}

/// 空名会被拼成空目录；重名会覆盖已有版本 —— 两者都在这里拦下
- (NSString *)nameValidationMessageForText:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        return @"版本名不能为空";
    }
    for (A2Version *version in A2VersionManager.shared.versions) {
        if ([version.name isEqualToString:trimmed]) {
            return @"已存在同名版本，请换一个名字";
        }
    }
    return nil;
}

#pragma mark - 第四步：执行导入

- (void)startImportWithVersionName:(NSString *)versionName {
    if (self.archivePath.length == 0) {
        return;
    }

    A2ModPackImportRequest *request = [A2ModPackImportRequest new];
    request.archivePath = self.archivePath;
    request.gameHome = A2VersionManager.shared.gameHome;
    request.versionName = versionName;

    A2ProgressDialog *dialog = [[A2ProgressDialog alloc] initWithTitle:@"正在导入整合包"
                                                          stageTitles:[self stageTitles]];
    __weak typeof(self) weakSelf = self;
    dialog.onCancel = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf cancelImport];
    };
    [dialog presentOver:self.host];
    self.progressDialog = dialog;

    A2ModPackInstaller *installer = [[A2ModPackInstaller alloc] init];
    self.installer = installer;
    [installer importRequest:request
        progress:^(A2ModPackImportStage stage, double progress, NSString *message) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            [strongSelf.progressDialog updateStage:(NSInteger)stage progress:progress message:message];
        }
        completion:^(BOOL success, NSString *versionName, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            [strongSelf finishImport:success versionName:versionName error:error];
        }];
}

- (void)cancelImport {
    // 取消后安装器不再回调完成，UI 收尾只能自己做
    [self.installer cancel];
    self.installer = nil;
    self.progressDialog = nil;
    self.archivePath = nil;
}

/// 阶段短名，顺序必须与 A2ModPackImportStage 一致
- (NSArray<NSString *> *)stageTitles {
    return @[@"解析整合包", @"安装本体与加载器", @"下载整合包内容", @"解压覆盖文件", @"收尾"];
}

#pragma mark - 第五步：结果

- (void)finishImport:(BOOL)success versionName:(NSString *)versionName error:(NSError *)error {
    self.installer = nil;
    A2ProgressDialog *dialog = self.progressDialog;
    self.progressDialog = nil;

    __weak typeof(self) weakSelf = self;
    void (^showResult)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (success) {
            [strongSelf showSuccessWithVersionName:versionName];
        } else {
            [strongSelf showImportFailure:error];
        }
        strongSelf.archivePath = nil;
    };

    // 先收起进度弹窗再报结果，避免两个弹窗叠在一起
    if (dialog) {
        [dialog dismissDialogWithCompletion:showResult];
    } else {
        showResult();
    }
}

- (void)showSuccessWithVersionName:(NSString *)versionName {
    [A2VersionManager.shared reload];

    NSString *name = versionName.length > 0 ? versionName : @"整合包";
    [A2AlertDialog presentOver:self.host
                         title:@"导入完成"
                    paragraphs:@[[NSString stringWithFormat:@"版本「%@」已创建，mods 与配置写在该版本目录内，可直接启动。", name]]
                   cancelTitle:nil
                  confirmTitle:@"知道了"
                     onConfirm:nil];
}

- (void)showImportFailure:(NSError *)error {
    [A2AlertDialog presentOver:self.host
                         title:@"导入失败"
                    paragraphs:@[error.localizedDescription ?: @"导入过程中出现问题，版本未创建。"]
                   cancelTitle:nil
                  confirmTitle:@"知道了"
                     onConfirm:nil];
}

- (void)showParseFailure:(NSError *)error {
    [A2AlertDialog presentOver:self.host
                         title:@"无法导入"
                    paragraphs:@[error.localizedDescription ?: @"这个文件不是可识别的整合包。"]
                   cancelTitle:nil
                  confirmTitle:@"知道了"
                     onConfirm:nil];
}

@end
