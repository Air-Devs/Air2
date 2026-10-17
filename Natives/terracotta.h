#ifndef TERRACOTTA_H
#define TERRACOTTA_H

/* libterracotta C ABI —— 与 HMCL/FCL/ZL2 v0.4.2 同源
 *
 * 来源：burningtnt/Terracotta + iOS 移植补丁（terracotta_ios_start_host_with_port）
 * 二进制位置：Natives/terracotta/libterracotta.xcframework/
 *
 * 线程安全：所有函数内部用 Mutex 保护，可从任意线程调用。
 * 字符串所有权：返回的 char* 必须用 terracotta_ios_free_string 释放。
 *
 * Weak linking：所有函数用 TERRACOTTA_API 弱符号声明。libterracotta.a 不存在时，
 * 链接器把这些符号当作 undefined weak，运行时函数指针为 NULL。
 * TerracottaBridge.m 在调用前必须检查 terracotta_ios_available()。
 */

#include <stdint.h>

/* Weak symbol 宏：让链接器在符号未定义时不报错（运行时为 NULL） */
#define TERRACOTTA_API __attribute__((weak))

#ifdef __cplusplus
extern "C" {
#endif

/* 初始化 Terracotta。整个进程生命周期调用一次。
 *   dir        工作目录（machine-id 持久化）
 *   logging_fd 日志文件描述符（-1 表示不写文件）
 * 返回 0 表示成功。 */
TERRACOTTA_API int terracotta_ios_start(const char *dir, int logging_fd);

/* 读取当前状态（JSON 字符串）。调用方负责 free_string。
 * JSON schema：
 *   {"state":"waiting|host-scanning|host-starting|host-ok|guest-connecting|guest-starting|guest-ok|exception",
 *    "index":int, "room":string?, "url":string?,
 *    "profile_index":int?, "profiles":[...],
 *    "difficulty":string?, "type":int?} */
TERRACOTTA_API char *terracotta_ios_get_state(void);

/* 回到 Waiting 状态（终止当前会话）。Idempotent。 */
TERRACOTTA_API void terracotta_ios_set_waiting(void);

/* 房主：开始扫描本地 MC 的「对局域网开放」多播广播。 */
TERRACOTTA_API void terracotta_ios_set_scanning(const char *room, const char *player);

/* 房主（手动端口模式）：绕过多播扫描，直接用用户输入的 MC LAN 端口启动 host。
 * 返回 1 表示已开始启动；0 表示当前不在 Waiting 状态。 */
TERRACOTTA_API int terracotta_ios_start_host_with_port(const char *room, uint16_t port, const char *player);

/* 访客：加入房间。
 * 返回 1 表示已开始加入；0 表示邀请码无效或当前不在 Waiting 状态。 */
TERRACOTTA_API int terracotta_ios_set_guesting(const char *room, const char *player);

/* 仅校验邀请码格式，不加入。
 * 返回 3 表示合法的 Scaffolding 邀请码；其他值表示非法。 */
TERRACOTTA_API int terracotta_ios_verify_room_code(const char *code);

/* 元数据：(version, compile_timestamp_ms, easytier_version)。
 * 返回 NUL 分隔的 UTF-8 字符串。调用方负责 free_string。 */
TERRACOTTA_API char *terracotta_ios_get_metadata(void);

/* 释放 terracotta_ios_get_state / _get_metadata 返回的字符串。 */
TERRACOTTA_API void terracotta_ios_free_string(char *ptr);

/* 仅供调试：触发 Rust 侧 panic（不应被调用）。 */
TERRACOTTA_API void terracotta_ios_panic(void);

#ifdef __cplusplus
}
#endif

/* 运行时检查 libterracotta 是否可用 */
#define terracotta_ios_available() (terracotta_ios_start != NULL)

#endif /* TERRACOTTA_H */
