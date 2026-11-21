//
//  virgl_server.h
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
//  virgl_server.h
//  Amethyst-iOS-MyRemastered
//
//  Task 111：VirGLRenderer(≤26.2) 服务端引导桥对外接口。
//
#ifndef AMETHYST_VIRGL_SERVER_H
#define AMETHYST_VIRGL_SERVER_H

/// vtest server 宿主 dylib（virglrenderer 1.3.0 + libepoxy，Makefile dep_virgl 产物）
#define AME_VIRGL_VTEST_SERVER_LIB "libvtestserver.dylib"

/// virgl guest 库（Mesa 25.0.7 virgl 驱动 + osmesa 前端，Makefile dep_virgl 产物）
#define AME_VIRGL_GUEST_LIB "libOSMesaVirgl.dylib"

#if __cplusplus
extern "C" {
#endif

/// 启动 virgl vtest 服务（幂等）。
/// 设置 VTEST_SOCKET_NAME / GALLIUM_DRIVER=virgl，创建 ANGLE 离屏 ES3 宿主
/// 上下文，并拉起 libvtestserver.dylib 的 vtest_main 服务线程。
/// 返回 0 = 成功；非 0 = 引导失败（调用方记录日志后仍走 osm 桥，错误会在
/// guest 连接阶段显式暴露）。
int ame_virgl_start_server(void);

#if __cplusplus
}
#endif

#endif /* AMETHYST_VIRGL_SERVER_H */
