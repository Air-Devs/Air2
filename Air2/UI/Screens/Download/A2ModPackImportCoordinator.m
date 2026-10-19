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
//  见头文件。实现要点：
//    · 每个弹窗都在「上一个弹窗退场完成」之后再弹 —— 同一回调栈里连续
//      present 会被系统吞掉，这是本项目踩过的坑。
//    · 安装进度换算交给 A2ModPackInstaller 的 phase API，本类不碰进度阈值。
//

#import "A2ModPackImportCoordinator.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "A2ModPackInstaller.h"
#import "A2AlertDialog.h"
#import "A2InputDialog.h"
#import "A2InstallProgressDialog.h"
#import "A2TaskLogOutput.h"
#import "A2VersionManager.h"
#import "A2Log.h"

@interface A2ModPackImportCoordinator () <UIDocumentPickerDelegate>

@property (nonatomic, weak, nullable) UIViewController *host;

/// 选中的文件（已复制进沙盒，安装过程会持续读它）
@property (nonatomic, copy, nullable) NSString *pickedPath;

/// 安装器：安装期间必须保住 —— 它内部用 weak self，提前释放会让安装半路中断
@property (nonatomic, strong, nullable) A2ModPackInstaller *packInstaller;

/// 进度弹窗（用户手动取消后置空）
@property (nonatomic, strong, nullable) A2InstallProgressDialog *progressDialog;
@property (nonatomic, strong, nullable) A2TaskLogOutput *logOutput;

/// 当前进行到第几步（失败时要停在这一步上写错误）
@property (nonatomic, assign) NSInteger currentStep;

/// 用户是否点了进度弹窗的取消
@property (nonatomic, assign) BOOL cancelling;

/// 流程是否已收尾（保证 onFinish 只回调一次）
@property (nonatomic, assign) BOOL finished;

@end

@implementation A2ModPackImportCoordinator

- (instancetype)initWithHost:(UIViewController *)host {
    self = [super init];
    if (!self) return nil;
    _host = host;
    return self;
}

#pragma mark - 入口

- (void)start {
    if (!self.host) { [self finish]; return; }
    [self presentDisclaimer];
}

/// 流程结束：回调 onFinish（调用方在此放掉对协调器的持有）。幂等。
- (void)finish {
    if (self.finished) return;
    self.finished = YES;

    void (^callback)(void) = self.onFinish;
    self.onFinish = nil;
    if (callback) callback();
}

#pragma mark - 1. 免责 / 兼容性提示

- (void)presentDisclaimer {
    NSString *message =
        @"本地整合包会被解压到游戏目录，并可能覆盖已有文件，请确认来源可信。\n"
         "支持格式：Modrinth（.mrpack）、CurseForge、MCBBS、MultiMC / Prism。\n"
         "导入过程中可能需要下载游戏本体与模组，建议在 Wi-Fi 下进行。";

    __weak typeof(self) weakSelf = self;
    [A2AlertDialog presentFrom:self.host
                         title:@"导入整合包"
                       message:message
                  confirmTitle:@"导入"
                   cancelTitle:@"取消"
                      onFinish:^(BOOL confirmed) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (!confirmed) { [self finish]; return; }
        [self presentPicker];
    }];
}

#pragma mark - 2. 选文件

- (void)presentPicker {
    if (!self.host) { [self finish]; return; }

    // iOS 14 起用 forOpeningContentTypes:，旧的 initWithDocumentTypes:inMode: 已废弃。
    // 用 UTTypeData 而不是具体类型 —— 整合包扩展名多样（.mrpack / .zip / .mcpack），
    // 限制死类型反而会选不中。
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc]
                  initForOpeningContentTypes:@[UTTypeData]
                                     asCopy:YES];
    } else {
        picker = [[UIDocumentPickerViewController alloc]
                  initWithDocumentTypes:@[@"public.data"]
                                 inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self.host presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;

    // 先把选择器收掉，再走后续弹窗 —— 同一回调栈里 present 会被系统吞掉
    [controller dismissViewControllerAnimated:YES completion:^{
        __strong typeof(self) self = self;
        if (!self) return;
        if (!url) { [self finish]; return; }
        [self handlePickedURL:url];
    }];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self finish];
}

- (void)handlePickedURL:(NSURL *)url {
    // 复制到沙盒 —— 系统给的是临时授权路径，安装过程会持续读它
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
    [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    NSError *copyError = nil;
    if (![NSFileManager.defaultManager copyItemAtURL:url
                                               toURL:[NSURL fileURLWithPath:tmp]
                                               error:&copyError]) {
        [self failWithMessage:(copyError.localizedDescription ?: @"无法读取文件")];
        return;
    }

    self.pickedPath = tmp;
    [self parseManifest];
}

#pragma mark - 3. 解析清单

- (void)parseManifest {
    A2ModPackFormat format = [A2ModPackInstaller detectFormatAtPath:self.pickedPath];
    if (format == A2ModPackFormatUnknown) {
        [self failWithMessage:@"无法识别此整合包格式（支持 Modrinth / CurseForge / MCBBS / MultiMC）"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [[A2ModPackInstaller new] parseManifestAtPath:self.pickedPath
        completion:^(A2ModPackManifest *manifest, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (!manifest) {
            [self failWithMessage:(error.localizedDescription ?: @"清单解析失败")];
            return;
        }
        [self presentConfirmDialogWithManifest:manifest];
    }];
}

#pragma mark - 4. 清单摘要 + 版本命名（MD3 输入弹窗）

- (void)presentConfirmDialogWithManifest:(A2ModPackManifest *)manifest {
    A2InputDialog *dialog =
        [A2InputDialog dialogWithTitle:@"导入整合包"
                              message:[self summaryTextForManifest:manifest]
                                label:@"版本名称"
                          initialText:[self defaultVersionNameForManifest:manifest]];
    dialog.confirmTitle = @"开始安装";

    dialog.validator = ^NSString *(NSString *text) {
        NSString *name = [text stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length == 0) return @"版本名称不能为空";
        if ([name containsString:@"/"] || [name containsString:@":"]) {
            return @"版本名称不能包含 / 或 :";
        }
        return nil;
    };

    __weak typeof(self) weakSelf = self;
    dialog.onFinish = ^(BOOL committed, NSString *text) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (!committed) { [self finish]; return; }
        [self startInstallWithVersionName:
         [text stringByTrimmingCharactersInSet:
          NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    };

    [dialog presentFrom:self.host];
}

/// 清单摘要 —— 用换行排成「字段：值」，与输入框一起构成确认步骤。
- (NSString *)summaryTextForManifest:(A2ModPackManifest *)manifest {
    NSString *loader = manifest.loaderIdentifier.length
        ? [NSString stringWithFormat:@"%@ %@",
           manifest.loaderIdentifier, manifest.loaderVersion ?: @""]
        : @"原版（无加载器）";

    return [NSString stringWithFormat:@"格式：%@\n游戏版本：%@\n加载器：%@\n待下载文件：%lu 个",
            [self formatDisplayName:manifest.format],
            manifest.gameVersion.length ? manifest.gameVersion : @"未知",
            loader,
            (unsigned long)manifest.files.count];
}

- (NSString *)formatDisplayName:(A2ModPackFormat)format {
    switch (format) {
        case A2ModPackFormatModrinth:   return @"Modrinth";
        case A2ModPackFormatCurseForge: return @"CurseForge";
        case A2ModPackFormatMCBBS:      return @"MCBBS";
        case A2ModPackFormatMultiMC:    return @"MultiMC / Prism";
        default:                        return @"未知";
    }
}

/// 版本名默认取整合包名，去掉路径不合法字符。
- (NSString *)defaultVersionNameForManifest:(A2ModPackManifest *)manifest {
    NSString *name = manifest.name.length ? manifest.name : @"Imported Pack";
    name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    name = [name stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    return name;
}

#pragma mark - 5. 安装（MD3 进度弹窗）

- (void)startInstallWithVersionName:(NSString *)versionName {
    if (!self.host) { [self finish]; return; }

    self.logOutput = [[A2TaskLogOutput alloc]
                      initWithTitle:[NSString stringWithFormat:@"导入 %@", versionName]];

    A2InstallProgressDialog *dialog =
        [[A2InstallProgressDialog alloc] initWithLogOutput:self.logOutput];
    dialog.dialogTitle = @"导入整合包";
    [dialog setSteps:[A2ModPackInstaller phaseTitles]];

    __weak typeof(self) weakSelf = self;
    dialog.onCancel = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // 弹窗由它自己先收起；这里标记取消并传达给安装器，
        // 安装器取消后会用 A2ModPackErrorCancelled 回调收尾。
        self.progressDialog = nil;
        self.cancelling = YES;
        [self.packInstaller cancel];
    };

    self.progressDialog = dialog;
    self.currentStep = 0;

    [self.host presentViewController:dialog animated:YES completion:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self.logOutput start];
        [self runInstallWithVersionName:versionName];
    }];
}

- (void)runInstallWithVersionName:(NSString *)versionName {
    self.packInstaller = [[A2ModPackInstaller alloc] init];

    __weak typeof(self) weakSelf = self;
    [self.packInstaller installPackAtPath:self.pickedPath
                              versionName:versionName
                                 gameHome:A2VersionManager.shared.gameHome
                                 progress:^(double progress, NSString *message) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self renderOverallProgress:progress message:message];
    }
                               completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self handleCompletion:success error:error versionName:versionName];
    }];
}

/// 总体进度 → 阶段 + 该阶段百分比（换算逻辑在 A2ModPackInstaller）。
- (void)renderOverallProgress:(double)progress message:(NSString *)message {
    // progress 回调来自安装器；保险起见统一切主线程再动 UI。
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf renderOverallProgress:progress message:message];
        });
        return;
    }

    A2InstallProgressDialog *dialog = self.progressDialog;
    if (!dialog) return;

    NSInteger step = [A2ModPackInstaller phaseForOverallProgress:progress];
    double local = [A2ModPackInstaller fractionWithinPhaseForOverallProgress:progress];
    local = MAX(0, MIN(1, local));
    self.currentStep = step;

    for (NSInteger i = 0; i < step; i++) {
        [dialog updateStepAtIndex:i
                            stage:A2ProgressStepStageCompleted
                          message:nil
                         progress:1.0
                             rate:nil];
    }
    [dialog updateStepAtIndex:step
                        stage:A2ProgressStepStageRunning
                      message:message
                     progress:local
                         rate:nil];

    if (message.length > 0) [self.logOutput appendProgress:message];
}

- (void)handleCompletion:(BOOL)success error:(NSError *)error versionName:(NSString *)versionName {
    // 与进度回调同样：先切回主线程
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleCompletion:success error:error versionName:versionName];
        });
        return;
    }

    BOOL cancelled = self.cancelling
        || ([error.domain isEqualToString:A2ModPackInstallErrorDomain] &&
            error.code == A2ModPackErrorCancelled);

    [self.logOutput append:(cancelled ? @"导入已取消"
        : (success ? @"导入完成"
           : [NSString stringWithFormat:@"导入失败：%@",
              error.localizedDescription ?: @"未知错误"]))];
    [self.logOutput stop];

    A2InstallProgressDialog *dialog = self.progressDialog;
    self.progressDialog = nil;

    __weak typeof(self) weakSelf = self;
    void (^showResult)(void) = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (cancelled) {
            [self presentResultWithTitle:@"已取消"
                                 message:@"导入已取消。"
                            confirmTitle:@"知道了"];
        } else if (success) {
            [self presentResultWithTitle:@"导入完成"
                                 message:[NSString stringWithFormat:
                                          @"已导入「%@」，可在版本列表中找到。", versionName]
                            confirmTitle:@"完成"];
        } else {
            [self presentResultWithTitle:@"导入失败"
                                 message:(error.localizedDescription ?: @"未知错误")
                            confirmTitle:@"知道了"];
        }
    };

    // 取消：进度弹窗早在用户点取消时已收起，直接出结果
    if (!dialog || cancelled) { showResult(); return; }

    // 先把各步标记到位，留一眼再收弹窗，否则用户来不及看到成功/失败停在哪
    NSArray<NSString *> *titles = [A2ModPackInstaller phaseTitles];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        if (success || i < self.currentStep) {
            [dialog updateStepAtIndex:i
                                stage:A2ProgressStepStageCompleted
                              message:nil
                             progress:1.0
                                 rate:nil];
        } else if (i == self.currentStep) {
            // 失败停在这一步上，把原因写在它的说明行里
            [dialog updateStepAtIndex:i
                                stage:A2ProgressStepStagePreparing
                              message:(error.localizedDescription ?: @"安装失败")
                             progress:1.0
                                 rate:nil];
        }
    }

    // 已完成，尾段不允许再取消 —— 免得用户在这段窗口点取消把状态搅乱
    dialog.onCancel = nil;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // 弹窗可能已被收起（用户在这段窗口点了取消），那时 dismiss 的 completion
        // 不会触发 —— 直接出结果，避免流程卡住永远收不了尾
        if (dialog.view.window) {
            [dialog dismissWithCompletion:showResult];
        } else {
            showResult();
        }
    });
}

#pragma mark - 6. 结果提示

- (void)presentResultWithTitle:(NSString *)title
                       message:(NSString *)message
                  confirmTitle:(NSString *)confirmTitle {
    if (!self.host) { [self finish]; return; }

    __weak typeof(self) weakSelf = self;
    [A2AlertDialog presentFrom:self.host
                         title:title
                       message:message
                  confirmTitle:confirmTitle
                   cancelTitle:nil
                      onFinish:^(BOOL confirmed) {
        (void)confirmed;
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self finish];
    }];
}

#pragma mark - 失败兜底

/// 流程前段（选文件 / 解析 / 复制）的失败：结果弹窗 + 收尾
- (void)failWithMessage:(NSString *)message {
    [A2Log log:@"modpack-import: 流程中止"];
    [self presentResultWithTitle:@"无法导入整合包"
                         message:message
                    confirmTitle:@"知道了"];
}

@end
