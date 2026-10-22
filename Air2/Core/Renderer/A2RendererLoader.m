//
//  A2RendererLoader.m
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
//
//  A2RendererLoader.m
//  Air2
//

#import "A2RendererLoader.h"
#import <dlfcn.h>
#import "A2Logger.h"

#pragma mark - 句柄

@interface A2RendererHandle ()
@property (nonatomic, assign, readwrite) void *glHandle;
@property (nonatomic, assign, readwrite) void *eglHandle;
@property (nonatomic, assign, readwrite) A2RendererLibraryLayout layout;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, NSString *> *appliedEnv;
@end

@implementation A2RendererHandle

- (void *)symbolGL:(const char *)name {
    if (!self.glHandle) return NULL;
    return dlsym(self.glHandle, name);
}

- (void *)symbolEGL:(const char *)name {
    if (!self.eglHandle) return NULL;
    return dlsym(self.eglHandle, name);
}

@end

#pragma mark - 加载器

@implementation A2RendererLoader

- (nullable A2RendererHandle *)loadPlugin:(A2RendererPlugin *)plugin
                              environment:(NSDictionary<NSString *, NSString *> *)env
                                    error:(NSError **)error {

    if (plugin.availability != A2RendererAvailabilityAvailable) {
        if (error) {
            *error = [self err:(plugin.unavailableReason ?: @"插件不可用")];
        }
        return nil;
    }

    return [self loadLibrariesAtGLPath:plugin.absoluteGLPath
                               eglPath:plugin.absoluteEGLPath
                                layout:plugin.libraryLayout
                           environment:env
                                 error:error];
}

- (nullable A2RendererHandle *)loadLibrariesAtGLPath:(NSString *)glPath
                                             eglPath:(NSString *)eglPath
                                              layout:(A2RendererLibraryLayout)layout
                                         environment:(NSDictionary<NSString *, NSString *> *)env
                                               error:(NSError **)error {

    if (glPath.length == 0) {
        if (error) *error = [self err:@"GL 库路径为空"];
        return nil;
    }

    // ---- 1. 先应用环境变量 ----
    //
    // 顺序很关键：有些库在 __attribute__((constructor)) 里
    // 读环境变量决定行为（例如选驱动、设版本上限）。
    // 先 dlopen 再 setenv 就晚了。
    for (NSString *key in env) {
        setenv(key.UTF8String, env[key].UTF8String, 1);
    }
    if (env.count > 0) {
        [A2Logger info:@"A2RendererLoader"
               message:[NSString stringWithFormat:@"设置环境变量: %@",
                        [[env allKeys] componentsJoinedByString:@", "]]];
    }

    [A2Logger info:@"A2RendererLoader"
           message:[NSString stringWithFormat:@"加载渲染器：布局=%@，GL=%@，EGL=%@",
                    A2RendererLayoutDescription(layout), glPath, eglPath ?: @"(同 GL)"]];

    A2RendererHandle *handle = [A2RendererHandle new];
    handle.layout = layout;
    handle.appliedEnv = env ?: @{};

    // ---- 2. 按布局加载 ----

    if (layout == A2RendererLibraryLayoutCombined) {
        // 合并库：一次 dlopen，GL 与 EGL 是同一个句柄。
        //
        // RTLD_GLOBAL 必须加 —— 游戏核心（LWJGL）会用 dlsym 按名字
        // 取 gl* 与 egl* 符号，句柄必须在这个模块的符号表里可见。
        void *h = dlopen(glPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        if (!h) {
            if (error) *error = [self dlError:@"加载合并库失败" path:glPath];
            return nil;
        }
        handle.glHandle = h;
        handle.eglHandle = h;   // 同一个

    } else if (layout == A2RendererLibraryLayoutSeparate) {
        // 分离库：EGL 必须【先】加载且 RTLD_GLOBAL。
        //
        // 原因：GL 库在加载时依赖 EGL 的符号（eglGetDisplay 等），
        // 如果 EGL 还没进全局符号表，dlopen(GL) 会报
        // "symbol not found" 或 "_eglGetDisplay, referenced from ..."。
        if (eglPath.length == 0) {
            if (error) *error = [self err:@"分离库布局需要 EGL 路径"];
            return nil;
        }

        void *eh = dlopen(eglPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        if (!eh) {
            if (error) *error = [self dlError:@"加载 EGL 库失败" path:eglPath];
            return nil;
        }
        handle.eglHandle = eh;

        void *gh = dlopen(glPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        if (!gh) {
            // GL 加载失败要回滚，避免留下半个渲染器
            dlclose(eh);
            handle.eglHandle = NULL;
            if (error) *error = [self dlError:@"加载 GL 库失败" path:glPath];
            return nil;
        }
        handle.glHandle = gh;

    } else {
        // 仅 GL
        void *gh = dlopen(glPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        if (!gh) {
            if (error) *error = [self dlError:@"加载 GL 库失败" path:glPath];
            return nil;
        }
        handle.glHandle = gh;
        handle.eglHandle = NULL;
    }

    // ---- 3. 验证关键符号 ----
    //
    // 注意：这里是【加载后】的校验 —— 此时 constructor 已经跑过了，
    // 说明库里对 EGL 的假设已经成立（或者它不依赖）。
    // 导入阶段的检查是静态的（A2RendererPlugin machO:exportsSymbol:），
    // 不执行代码。
    //
    // 加载成功不代表符号齐全。至少要有 glGetString 与 eglGetDisplay，
    // 否则后面会以更难懂的方式失败。
    if (![handle symbolGL:"glGetString"]) {
        [self unload:handle];
        if (error) {
            *error = [self err:@"库加载成功但没有 glGetString 符号 —— "
                               @"可能不是 GL 实现库"];
        }
        return nil;
    }

    if (layout != A2RendererLibraryLayoutGLOny &&
        ![handle symbolEGL:"eglGetDisplay"]) {
        [self unload:handle];
        if (error) {
            *error = [self err:@"库加载成功但没有 eglGetDisplay 符号 —— "
                               @"EGL 可能不在这个库里，检查 libraryLayout 是否应为 separate"];
        }
        return nil;
    }

    [A2Logger info:@"A2RendererLoader" message:@"渲染器加载成功（符号校验通过）"];
    return handle;
}

- (void)unload:(A2RendererHandle *)handle {
    if (!handle) return;

    // 合并库时两个句柄相同，只关一次
    if (handle.glHandle && handle.glHandle == handle.eglHandle) {
        dlclose(handle.glHandle);
    } else {
        if (handle.glHandle) dlclose(handle.glHandle);
        if (handle.eglHandle) dlclose(handle.eglHandle);
    }
    handle.glHandle = NULL;
    handle.eglHandle = NULL;
}

#pragma mark - 错误

- (NSError *)dlError:(NSString *)prefix path:(NSString *)path {
    const char *e = dlerror();
    NSString *detail = e ? [NSString stringWithUTF8String:e] : @"未知错误";

    NSString *msg;
    if ([detail containsString:@"code signature"] || [detail containsString:@"invalid"]) {
        msg = [NSString stringWithFormat:@"%@：代码签名无效（需要与 App 使用相同签名）",
               prefix];
    } else if ([detail containsString:@"image not found"] ||
               [detail containsString:@"not found"]) {
        msg = [NSString stringWithFormat:@"%@：缺少依赖库（%@）", prefix, detail];
    } else {
        msg = [NSString stringWithFormat:@"%@：%@", prefix, detail];
    }

    [A2Logger error:@"A2RendererLoader"
            message:[NSString stringWithFormat:@"%@ path=%@", msg, path]];

    return [self err:msg];
}

- (NSError *)err:(NSString *)msg {
    return [NSError errorWithDomain:@"A2RendererLoader" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"加载失败"}];
}

@end
