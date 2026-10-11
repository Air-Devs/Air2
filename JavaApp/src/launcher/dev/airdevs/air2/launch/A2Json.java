package dev.airdevs.air2.launch;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 极简 JSON 读取器（只读、递归下降）。
 *
 * <p>为什么自己写：启动核心<b>不引入任何第三方库</b>（见 docs/DEPENDENCIES.md「不引入新第三方库」），
 * 而启动计划是 JSON。只覆盖 JSON 的完整语法（object / array / string / number / true / false / null），
 * 不做流式、不做增量、不做注释兼容。
 *
 * <p>产出：{@code Map<String,Object>} / {@code List<Object>} / {@code String} / {@code Long} /
 * {@code Double} / {@code Boolean} / {@code null}。解析失败抛 {@link A2LaunchFailure}，
 * 绝不静默返回半个对象。
 */
final class A2Json {

    private final String src;
    private int pos;

    private A2Json(String src) {
        this.src = src;
    }

    static Object parse(String text) throws A2LaunchFailure {
        if (text == null) {
            throw new A2LaunchFailure("JSON 输入为空");
        }
        A2Json p = new A2Json(text);
        p.skipWhitespace();
        Object value = p.value();
        p.skipWhitespace();
        if (p.pos != p.src.length()) {
            throw new A2LaunchFailure("JSON 尾部有多余内容 @ " + p.pos);
        }
        return value;
    }

    private void skipWhitespace() {
        while (pos < src.length()) {
            char c = src.charAt(pos);
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                pos++;
            } else {
                return;
            }
        }
    }

    private Object value() throws A2LaunchFailure {
        if (pos >= src.length()) {
            throw new A2LaunchFailure("JSON 意外结束");
        }
        char c = src.charAt(pos);
        switch (c) {
            case '{':
                return object();
            case '[':
                return array();
            case '"':
                return string();
            case 't':
                literal("true");
                return Boolean.TRUE;
            case 'f':
                literal("false");
                return Boolean.FALSE;
            case 'n':
                literal("null");
                return null;
            default:
                return number();
        }
    }

    private Map<String, Object> object() throws A2LaunchFailure {
        Map<String, Object> out = new LinkedHashMap<String, Object>();
        pos++;                                   // '{'
        skipWhitespace();
        if (pos < src.length() && src.charAt(pos) == '}') {
            pos++;
            return out;
        }
        while (true) {
            skipWhitespace();
            String key = string();
            skipWhitespace();
            if (pos >= src.length() || src.charAt(pos) != ':') {
                throw new A2LaunchFailure("JSON 对象缺 ':' @ " + pos);
            }
            pos++;
            skipWhitespace();
            out.put(key, value());
            skipWhitespace();
            if (pos >= src.length()) {
                throw new A2LaunchFailure("JSON 对象未闭合");
            }
            char c = src.charAt(pos++);
            if (c == '}') {
                return out;
            }
            if (c != ',') {
                throw new A2LaunchFailure("JSON 对象期望 ',' 或 '}' @ " + (pos - 1));
            }
        }
    }

    private List<Object> array() throws A2LaunchFailure {
        List<Object> out = new ArrayList<Object>();
        pos++;                                   // '['
        skipWhitespace();
        if (pos < src.length() && src.charAt(pos) == ']') {
            pos++;
            return out;
        }
        while (true) {
            skipWhitespace();
            out.add(value());
            skipWhitespace();
            if (pos >= src.length()) {
                throw new A2LaunchFailure("JSON 数组未闭合");
            }
            char c = src.charAt(pos++);
            if (c == ']') {
                return out;
            }
            if (c != ',') {
                throw new A2LaunchFailure("JSON 数组期望 ',' 或 ']' @ " + (pos - 1));
            }
        }
    }

    private String string() throws A2LaunchFailure {
        if (pos >= src.length() || src.charAt(pos) != '"') {
            throw new A2LaunchFailure("JSON 期望字符串 @ " + pos);
        }
        pos++;
        StringBuilder sb = new StringBuilder();
        while (pos < src.length()) {
            char c = src.charAt(pos++);
            if (c == '"') {
                return sb.toString();
            }
            if (c != '\\') {
                sb.append(c);
                continue;
            }
            if (pos >= src.length()) {
                break;
            }
            char esc = src.charAt(pos++);
            switch (esc) {
                case '"':  sb.append('"');  break;
                case '\\': sb.append('\\'); break;
                case '/':  sb.append('/');  break;
                case 'b':  sb.append('\b'); break;
                case 'f':  sb.append('\f'); break;
                case 'n':  sb.append('\n'); break;
                case 'r':  sb.append('\r'); break;
                case 't':  sb.append('\t'); break;
                case 'u':
                    if (pos + 4 > src.length()) {
                        throw new A2LaunchFailure("JSON \\u 转义不完整 @ " + pos);
                    }
                    try {
                        sb.append((char) Integer.parseInt(src.substring(pos, pos + 4), 16));
                    } catch (NumberFormatException e) {
                        throw new A2LaunchFailure("JSON \\u 转义非法 @ " + pos);
                    }
                    pos += 4;
                    break;
                default:
                    throw new A2LaunchFailure("JSON 非法转义 \\" + esc + " @ " + (pos - 1));
            }
        }
        throw new A2LaunchFailure("JSON 字符串未闭合");
    }

    private Object number() throws A2LaunchFailure {
        int start = pos;
        while (pos < src.length()) {
            char c = src.charAt(pos);
            if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E') {
                pos++;
            } else {
                break;
            }
        }
        String raw = src.substring(start, pos);
        if (raw.isEmpty()) {
            throw new A2LaunchFailure("JSON 无法识别的字面量 @ " + start);
        }
        try {
            if (raw.indexOf('.') < 0 && raw.indexOf('e') < 0 && raw.indexOf('E') < 0) {
                return Long.valueOf(Long.parseLong(raw));
            }
            return Double.valueOf(Double.parseDouble(raw));
        } catch (NumberFormatException e) {
            throw new A2LaunchFailure("JSON 非法数字: " + raw);
        }
    }

    private void literal(String expected) throws A2LaunchFailure {
        if (!src.startsWith(expected, pos)) {
            throw new A2LaunchFailure("JSON 期望 " + expected + " @ " + pos);
        }
        pos += expected.length();
    }
}
