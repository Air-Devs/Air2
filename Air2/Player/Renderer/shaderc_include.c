//
//  shaderc_include.c
//  Air2
//

#include "shaderc_include.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- 限制 ----

/// 最大嵌套深度。GLSL 的 include 一般不超过 3 层；
/// 给到 16 足够，超了说明有循环引用。
#define AME_INCLUDE_MAX_DEPTH 16

/// 展开后的总大小上限（32 MB）。
/// 着色器源码不该超过这个量级；超了说明 resolver 返回了错误内容。
#define AME_INCLUDE_MAX_TOTAL (32u * 1024u * 1024u)

// ---- 动态 buffer ----

typedef struct {
    char *data;
    size_t len;
    size_t cap;
    int oom;
} ame_buf;

static void ame_buf_init(ame_buf *b) {
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
    b->oom = 0;
}

static void ame_buf_free(ame_buf *b) {
    free(b->data);
    b->data = NULL;
    b->len = b->cap = 0;
}

static int ame_buf_reserve(ame_buf *b, size_t need) {
    if (b->oom) return 0;
    if (b->len + need <= b->cap) return 1;

    size_t want = b->cap ? b->cap : 4096;
    while (want < b->len + need) {
        if (want > AME_INCLUDE_MAX_TOTAL) {
            b->oom = 1;
            return 0;
        }
        want *= 2;
    }
    if (want > AME_INCLUDE_MAX_TOTAL) want = AME_INCLUDE_MAX_TOTAL;

    char *p = realloc(b->data, want);
    if (!p) {
        b->oom = 1;
        return 0;
    }
    b->data = p;
    b->cap = want;
    return 1;
}

static void ame_buf_append(ame_buf *b, const char *s, size_t n) {
    if (n == 0 || b->oom) return;
    if (!ame_buf_reserve(b, n)) return;
    memcpy(b->data + b->len, s, n);
    b->len += n;
}

/// 把一段跳过内容的换行数补回来，让编译诊断的行号尽可能对得上。
static void ame_buf_append_newlines(ame_buf *b, const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '\n') ame_buf_append(b, "\n", 1);
    }
}

// ---- 行扫描 ----

/// 从 p 起跳过一个行首空白，返回新位置
static const char *ame_skip_ws(const char *p, const char *end) {
    while (p < end && (*p == ' ' || *p == '\t')) p++;
    return p;
}

/// 跳过一行，返回下一行的起点（不含 '\n' 之后跳过的处理）
static const char *ame_next_line(const char *p, const char *end) {
    while (p < end && *p != '\n') p++;
    if (p < end) p++;   // 吃掉 '\n'
    return p;
}

/// 判断某行是否是 `#include <...>` 或 `#include "..."`。
///
/// 成功时写入 name（指向源内部，不拷贝）与长度。
static int ame_parse_include(const char *line, const char *end,
                             const char **name_begin, size_t *name_len) {
    const char *p = ame_skip_ws(line, end);
    if (p >= end || *p != '#') return 0;
    p = ame_skip_ws(p + 1, end);

    // 必须是以 include 关键字开头（后面跟空白）
    static const char kKey[] = "include";
    size_t klen = sizeof(kKey) - 1;
    if ((size_t)(end - p) < klen) return 0;
    if (memcmp(p, kKey, klen) != 0) return 0;
    p += klen;

    if (p >= end || (*p != ' ' && *p != '\t')) return 0;
    p = ame_skip_ws(p, end);
    if (p >= end) return 0;

    char open = *p;
    char close;
    if (open == '<') close = '>';
    else if (open == '"') close = '"';
    else return 0;

    const char *nb = p + 1;
    const char *q = nb;
    while (q < end && *q != close && *q != '\n') q++;
    if (q >= end || *q != close || q == nb) return 0;

    *name_begin = nb;
    *name_len = (size_t)(q - nb);
    return 1;
}

// ---- 展开 ----

static int ame_expand_into(ame_buf *out,
                           const char *source, size_t size,
                           const char *input_file,
                           ame_include_resolver_fn resolver, void *resolver_ud,
                           ame_include_releaser_fn releaser, void *releaser_ud,
                           int depth);

/// 处理单个 include：展开内容递归处理后再追加。
/// 返回 1 = 已处理（追加了内容），0 = 没处理（调用方原样保留该行）
static int ame_handle_include(ame_buf *out,
                              const char *name, size_t name_len,
                              const char *input_file,
                              ame_include_resolver_fn resolver, void *resolver_ud,
                              ame_include_releaser_fn releaser, void *releaser_ud,
                              int depth) {
    if (depth >= AME_INCLUDE_MAX_DEPTH) {
        fprintf(stderr, "[shaderc-include] %s: 嵌套超过 %d 层，放弃展开\n",
                input_file ? input_file : "<source>", AME_INCLUDE_MAX_DEPTH);
        return 0;
    }

    // resolver 要的是 NUL 结尾的名字
    char stack_name[512];
    char *heap_name = NULL;
    char *nm = stack_name;
    if (name_len + 1 > sizeof(stack_name)) {
        heap_name = malloc(name_len + 1);
        if (!heap_name) return 0;
        nm = heap_name;
    }
    memcpy(nm, name, name_len);
    nm[name_len] = '\0';

    size_t inc_size = 0;
    char *inc = resolver(resolver_ud, nm, &inc_size);

    if (heap_name) free(heap_name);

    if (!inc) {
        // resolver 不认这个名字 —— 保留原行，交给下游报错
        return 0;
    }

    if (inc_size == 0) {
        if (releaser) releaser(releaser_ud, inc);
        return 1;   // 空 include：什么都不追加，但算已处理
    }

    // 递归展开被包含的内容（它自己也可能带 include）
    ame_buf sub;
    ame_buf_init(&sub);
    ame_expand_into(&sub, inc, inc_size, nm, resolver, resolver_ud,
                    releaser, releaser_ud, depth + 1);

    if (sub.oom) {
        ame_buf_free(&sub);
        if (releaser) releaser(releaser_ud, inc);
        return 0;
    }

    ame_buf_append(out, sub.data ? sub.data : "", sub.len);
    ame_buf_free(&sub);

    if (releaser) releaser(releaser_ud, inc);
    return 1;
}

static int ame_expand_into(ame_buf *out,
                           const char *source, size_t size,
                           const char *input_file,
                           ame_include_resolver_fn resolver, void *resolver_ud,
                           ame_include_releaser_fn releaser, void *releaser_ud,
                           int depth) {
    const char *p = source;
    const char *end = source + size;
    int expanded_any = 0;

    while (p < end) {
        const char *line_end = p;
        while (line_end < end && *line_end != '\n') line_end++;

        const char *nb = NULL;
        size_t nl = 0;
        int is_inc = ame_parse_include(p, line_end, &nb, &nl);

        if (is_inc) {
            int done = ame_handle_include(out, nb, nl, input_file,
                                          resolver, resolver_ud,
                                          releaser, releaser_ud, depth);
            if (done) {
                expanded_any = 1;
                // 补一个换行，避免展开内容与下一行粘在一起
                ame_buf_append(out, "\n", 1);
                p = (line_end < end) ? line_end + 1 : end;
                continue;
            }
        }

        // 普通行：原样追加（含换行符）
        size_t n = (size_t)(line_end - p);
        ame_buf_append(out, p, n);
        if (line_end < end) {
            ame_buf_append(out, "\n", 1);
            p = line_end + 1;
        } else {
            p = line_end;
        }
    }

    return expanded_any;
}

// ---- 公开接口 ----

int ame_source_has_include(const char *source, size_t size) {
    if (!source || size == 0) return 0;

    // 快速扫：找 '#' 后面跟 include
    // 不追求绝对精确（可以是注释里的假阳性），
    // 因为这一步只决定「要不要走完整展开」，
    // 真正的解析在 ame_include_expand 里做。
    const char *p = source;
    const char *end = source + size;

    while (p < end) {
        const char *line_end = p;
        while (line_end < end && *line_end != '\n') line_end++;

        const char *nb = NULL;
        size_t nl = 0;
        if (ame_parse_include(p, line_end, &nb, &nl)) return 1;

        p = (line_end < end) ? line_end + 1 : end;
    }
    return 0;
}

char *ame_include_expand(const char *source,
                         size_t source_size,
                         const char *input_file,
                         ame_include_resolver_fn resolver,
                         void *resolver_ud,
                         ame_include_releaser_fn releaser,
                         void *releaser_ud,
                         size_t *out_size) {
    if (out_size) *out_size = 0;
    if (!source || source_size == 0) return NULL;
    if (!resolver) {
        fprintf(stderr, "[shaderc-include] %s: 没有 resolver，跳过展开\n",
                input_file ? input_file : "<source>");
        return NULL;
    }

    ame_buf out;
    ame_buf_init(&out);

    int any = ame_expand_into(&out, source, source_size, input_file,
                              resolver, resolver_ud, releaser, releaser_ud, 0);

    if (out.oom) {
        fprintf(stderr, "[shaderc-include] %s: 展开结果超过上限 %u 字节，放弃\n",
                input_file ? input_file : "<source>", AME_INCLUDE_MAX_TOTAL);
        ame_buf_free(&out);
        return NULL;
    }

    if (!any || out.len == 0) {
        ame_buf_free(&out);
        return NULL;   // 没有可展开的，让调用方用原文
    }

    // 补 NUL，方便调用方当 C 字符串用
    if (!ame_buf_reserve(&out, 1)) {
        ame_buf_free(&out);
        return NULL;
    }
    out.data[out.len] = '\0';

    if (out_size) *out_size = out.len;
    return out.data;   // 调用方 free()
}
