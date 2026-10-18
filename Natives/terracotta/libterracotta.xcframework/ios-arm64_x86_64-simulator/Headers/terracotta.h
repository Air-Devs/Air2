#ifndef TERRACOTTA_H
#define TERRACOTTA_H

/* libterracotta C ABI —— 与 HMCL/FCL/ZL2 v0.4.2 同源
 *
 * 来源：burningtnt/Terracotta + iOS 移植补丁（terracotta_ios_start_host_with_port）
 * 构建方式：见 Natives/terracotta/libterracotta.xcframework/
 *
 * 线程安全：所有函数内部用 Mutex 保护，可从任意线程调用。
 * 字符串所有权：返回的 char* 必须用 terracotta_ios_free_string 释放。
 *
 * Weak linking：所有函数用 TERRACOTTA_API 弱符号声明。libterracotta.a 不存在时，
 * 链接器把这些符号当作 undefined weak，运行时函数指针为 NULL。
 * TerracottaBridge.m 在调用前必须检查符号是否可用（用 terracotta_ios_available()）。
 */

#include <stdint.h>

/* Weak symbol 宏：让链接器在符号未定义时不报错（运行时为 NULL）。
 * - __attribute__((weak)) 直接弱化函数符号本身
 * - __attribute__((weak_import)) 仅适用于动态库 import，静态库不适用
 * 这里用 weak 让静态库缺失时仍能链接通过。 */
#define TERRACOTTA_API __attribute__((weak))

#ifdef __cplusplus
extern "C" {
#endif

/* 初始化 Terracotta。整个进程生命周期调用一次。
 *   dir        Terracotta 工作目录（machine-id 会写在这里，用于跨启动保持玩家身份）
 *   logging_fd 日志文件描述符（-1 表示不写文件，仅写 stderr）
 * 返回 0 表示成功。 */
TERRACOTTA_API int terracotta_ios_start(const char *dir, int logging_fd);

/* 读取当前状态（JSON 字符串）。调用方负责 free_string。
 * JSON schema：
 *   {"state":"waiting|host-scanning|host-starting|host-ok|guest-connecting|guest-starting|guest-ok|exception",
 *    "index":int, "room":string?, "url":string?,
 *    "profile_index":int?, "profiles":[{name,machine_id,easytier_id,vendor,kind}]?,
 *    "difficulty":string?, "type":int?} */
TERRACOTTA_API char *terracotta_ios_get_state(void);

/* 回到 Waiting 状态（终止当前会话）。Idempotent。 */
TERRACOTTA_API void terracotta_ios_set_waiting(void);

/* 房主：开始扫描本地 MC 的「对局域网开放」多播广播。
 *   room        可选，复用已有邀请码；NULL 让 Rust 侧生成
 *   player      可选，玩家昵称；NULL 用默认 */
TERRACOTTA_API void terracotta_ios_set_scanning(const char *room, const char *player);

/* 房主（手动端口模式）：绕过多播扫描，直接用用户输入的 MC LAN 端口启动 host。
 * iOS 多播接收受本地网络权限和签名影响，可能收不到 PojavLauncher 里 MC 发的 LAN 广播。
 * 用户在 MC「对局域网开放」后会看到端口号，直接输入即可。
 *   room        可选，复用已有邀请码；NULL 让 Rust 侧生成
 *   port        MC LAN 端口（如 25565 或 MC 显示的随机端口）
 *   player      可选，玩家昵称；NULL 用默认
 * 返回 1 表示已开始启动；0 表示当前不在 Waiting 状态。 */
TERRACOTTA_API int terracotta_ios_start_host_with_port(const char *room, uint16_t port, const char *player);

/* 访客：加入房间。
 *   room    必填，房主分享的 Scaffolding 邀请码
 *   player  可选，玩家昵称；NULL 用默认
 * 返回 1 表示已开始加入；0 表示邀请码无效或当前不在 Waiting 状态。 */
TERRACOTTA_API int terracotta_ios_set_guesting(const char *room, const char *player);

/* 仅校验邀请码格式，不加入。
 * 返回 3 表示合法的 Scaffolding 邀请码；其他值表示非法。 */
TERRACOTTA_API int terracotta_ios_verify_room_code(const char *code);

/* 元数据：(version, compile_timestamp_ms, easytier_version)。
 * 返回 NUL 分隔的 UTF-8 字符串："<version>\0<ts_ms>\0<et_version>\0"。
 * 调用方负责 free_string。 */
TERRACOTTA_API char *terracotta_ios_get_metadata(void);

/* 释放 terracotta_ios_get_state / _get_metadata 返回的字符串。 */
TERRACOTTA_API void terracotta_ios_free_string(char *ptr);

/* 仅供调试：触发 Rust 侧 panic（不应被调用）。 */
TERRACOTTA_API void terracotta_ios_panic(void);

#ifdef __cplusplus
}
#endif

/* 运行时检查 libterracotta 是否可用（terracotta_ios_start 符号是否解析成功）。
 * 库未链接时所有 terracotta_ios_* 函数指针为 NULL，TerracottaBridge 调用前必须检查。 */
#define terracotta_ios_available() (terracotta_ios_start != NULL)

#endif /* TERRACOTTA_H */
