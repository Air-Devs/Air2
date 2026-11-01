// iOS 专用垫片：补上 libc++ 里“iOS 16.3 起可用”的浮点型 std::to_chars。
//
// 为什么需要它：
//   Apple SDK 的 libc++.1.dylib 把浮点 to_chars（std::format 的浮点格式化路径）标注为
//   iOS 16.3 起可用。本库部署目标是 iOS 14.0（与 Air2 主工程一致）。libc++ 的
//   formatter_floating_point 在实例化 std::format 时，无论实参类型都会实例化浮点格式化
//   模板，所以哪怕本库只在 GLSL 源码里格式化整数与字符串，也会带上这个引用。
//   直接引用该符号：编译期被可用性检查挡住；关掉检查后，iOS 14/15 上 dyld 会因为找不到
//   符号而整包加载失败。故这里按 ESSL 源码生成的真实需求自实现一份，彻底去掉这个依赖。
//
// 语义：按 [charconv.to.chars] 给出 shortest round-trip（未给精度）或按给定精度的
//   general / fixed / scientific / hex 表示。本库目前只格式化整数与字符串，浮点分支
//   不会被调用，但保留完整语义，避免将来静默失真。

#include <__charconv/chars_format.h>
#include <__charconv/to_chars_result.h>
#include <cstdio>
#include <cstdlib>
#include <system_error>

_LIBCPP_BEGIN_NAMESPACE_STD

namespace __sfpew_ios_shim {

inline to_chars_result deliver(char* first, char* last, const char* buf, int n) {
    if (n < 0)
        return to_chars_result{first, errc::value_too_large};
    if (first + n > last)
        return to_chars_result{first, errc::value_too_large};
    for (int i = 0; i < n; ++i)
        first[i] = buf[i];
    return to_chars_result{first + n, errc{}};
}

// 每种类型只需要知道：最大有效位数、printf 修饰符、能否反向解析回同值
template <class T> struct traits;
template <> struct traits<float> {
    static constexpr int max_digits = 9;
    static inline bool same(const char* s, float v) { return ::strtof(s, nullptr) == v; }
};
template <> struct traits<double> {
    static constexpr int max_digits = 17;
    static inline bool same(const char* s, double v) { return ::strtod(s, nullptr) == v; }
};
template <> struct traits<long double> {
    static constexpr int max_digits = 21;
    static inline bool same(const char* s, long double v) { return ::strtold(s, nullptr) == v; }
};

// printf 的转换符是常量，故每种格式各写一句，避免运行期拼格式串
inline int to_buf(char* b, size_t c, double v, chars_format f, int p) {
    switch (f) {
    case chars_format::scientific: return ::snprintf(b, c, "%.*e", p, v);
    case chars_format::fixed:      return ::snprintf(b, c, "%.*f", p, v);
    case chars_format::hex:        return ::snprintf(b, c, "%.*a", p, v);
    default:                       return ::snprintf(b, c, "%.*g", p, v);
    }
}
inline int to_buf(char* b, size_t c, long double v, chars_format f, int p) {
    switch (f) {
    case chars_format::scientific: return ::snprintf(b, c, "%.*Le", p, v);
    case chars_format::fixed:      return ::snprintf(b, c, "%.*Lf", p, v);
    case chars_format::hex:        return ::snprintf(b, c, "%.*La", p, v);
    default:                       return ::snprintf(b, c, "%.*Lg", p, v);
    }
}

template <class T>
int render(char* buf, size_t cap, T value, chars_format fmt, int precision) {
    if (precision >= 0)
        return to_buf(buf, cap, value, fmt, precision);
    // 未给精度：从最短有效位开始试，直到能原值往返
    const int start = fmt == chars_format::hex ? 0 : 1;
    for (int p = start; p <= traits<T>::max_digits; ++p) {
        int n = to_buf(buf, cap, value, fmt, p);
        if (n > 0 && traits<T>::same(buf, value))
            return n;
    }
    return to_buf(buf, cap, value, fmt, traits<T>::max_digits);
}

template <class T>
to_chars_result convert(char* first, char* last, T value, chars_format fmt, int precision) {
    // 需容纳 long double 的最大展开（约 21 位 + 指数 + 符号）
    char buf[512];
    int n = render(buf, sizeof buf, value, fmt, precision);
    if (n > 0 && fmt == chars_format::hex && n > 2 && buf[0] == '0' && (buf[1] == 'x' || buf[1] == 'X')) {
        // to_chars 的 hex 形式不带 0x 前缀
        return deliver(first, last, buf + 2, n - 2);
    }
    return deliver(first, last, buf, n);
}

} // namespace __sfpew_ios_shim

#define SFPEW_IOS_TO_CHARS(T)                                                                      \
    to_chars_result to_chars(char* first, char* last, T value) {                                   \
        return __sfpew_ios_shim::convert(first, last, value, chars_format::general, -1);           \
    }                                                                                              \
    to_chars_result to_chars(char* first, char* last, T value, chars_format fmt) {                  \
        return __sfpew_ios_shim::convert(first, last, value, fmt, -1);                             \
    }                                                                                              \
    to_chars_result to_chars(char* first, char* last, T value, chars_format fmt, int precision) {   \
        return __sfpew_ios_shim::convert(first, last, value, fmt, precision);                      \
    }

SFPEW_IOS_TO_CHARS(float)
SFPEW_IOS_TO_CHARS(double)
SFPEW_IOS_TO_CHARS(long double)

#undef SFPEW_IOS_TO_CHARS

_LIBCPP_END_NAMESPACE_STD
