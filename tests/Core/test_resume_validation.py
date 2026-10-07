#!/usr/bin/env python3
"""
验证断点续传的响应校验逻辑。

对照 ZL2 的 Fetcher.ResumeContext.canResume —— 这是最容易出错的
地方：接受「看起来差不多」的 206 响应会导致文件静默损坏
（大小对、内容错）。

核心规则：
  1. 必须是 206（200 说明服务端忽略了 Range）
  2. Content-Encoding 必须是 identity（压缩传输时 Range 语义错乱）
  3. contentLength == bodyLength + 已收字节
  4. strong ETag 存在则必须一致；否则校验 URL + Last-Modified
  5. Content-Range 的 start/end/total 精确匹配
  6. end - start + 1 == bodyLength
"""
import re


def can_resume(code, encoding, headers, received, content_length, url, resolved_url=None):
    """复刻 ResumeContext.canResume"""
    # 1. 必须 206
    if code != 206:
        return False
    # 2. 不能是压缩传输
    if encoding and encoding.lower() != "identity":
        return False
    # 3. 长度对得上
    body_length = headers.get("content-length", -1)
    if content_length != body_length + received:
        return False
    # 4/5. 校验器
    strong_etag = headers.get("_strong_etag")
    if strong_etag:
        if strong_etag != headers.get("etag"):
            return False
    else:
        if resolved_url is not None and url != resolved_url:
            return False
        if headers.get("_last_modified", "") != headers.get("last-modified", ""):
            return False
    # Content-Range 精确匹配
    cr = headers.get("content-range", "")
    m = re.match(r"bytes (\d+)-(\d+)/(\d+)", cr)
    if not m:
        return False
    start, end, total = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if start != received:
        return False
    if end < start:
        return False
    if total != content_length:
        return False
    return end - start + 1 == body_length


def check(name, got, want):
    ok = got == want
    print(f"  {'✓' if ok else '✗'} {name}")
    if not ok:
        print(f"      got  = {got}")
        print(f"      want = {want}")
    return ok


all_ok = True
TOTAL = 1000
URL = "https://cdn.example.com/file.jar"

print("=" * 68)
print("断点续传响应校验（对照 ZL2 Fetcher.ResumeContext.canResume）")
print("=" * 68)

# ---- 正常续传 ----
print("\n[1] 正常续传：已收 400，服务端从 400 给剩余 600")
h = {
    "content-length": 600,
    "etag": '"abc123"',
    "_strong_etag": '"abc123"',
    "content-range": "bytes 400-999/1000",
}
all_ok &= check("接受", can_resume(206, "identity", h, 400, TOTAL, URL), True)

# ---- 拒绝：不是 206 ----
print("\n[2] 服务端返回 200（忽略 Range）→ 必须拒绝")
all_ok &= check("拒绝 200", can_resume(200, "identity", h, 400, TOTAL, URL), False)

# ---- 拒绝：压缩传输 ----
print("\n[3] Content-Encoding: gzip → 必须拒绝（Range 语义错乱）")
all_ok &= check("拒绝 gzip", can_resume(206, "gzip", h, 400, TOTAL, URL), False)

# ---- 拒绝：ETag 变了（文件被改了）----
print("\n[4] ETag 不匹配（服务端文件已更新）→ 必须拒绝")
h2 = dict(h)
h2["etag"] = '"different"'
all_ok &= check("拒绝 ETag 变化", can_resume(206, "identity", h2, 400, TOTAL, URL), False)

# ---- 拒绝：Content-Range 起点不对 ----
print("\n[5] Content-Range 起点与本地进度不符 → 必须拒绝")
h3 = dict(h)
h3["content-range"] = "bytes 300-999/1000"   # 起点错
all_ok &= check("拒绝起点错位", can_resume(206, "identity", h3, 400, TOTAL, URL), False)

# ---- 拒绝：总长度不符 ----
print("\n[6] Content-Range 总长度与 Content-Length 不符 → 必须拒绝")
h4 = dict(h)
h4["content-range"] = "bytes 400-999/2000"
all_ok &= check("拒绝总长不符", can_resume(206, "identity", h4, 400, TOTAL, URL), False)

# ---- 拒绝：bodyLength 与区间长度不符 ----
print("\n[7] bodyLength 与 Content-Range 区间长度不符 → 必须拒绝")
h5 = dict(h)
h5["content-length"] = 500    # 应为 600
all_ok &= check("拒绝长度矛盾", can_resume(206, "identity", h5, 400, TOTAL, URL), False)

# ---- 无 strong ETag 时用 Last-Modified ----
print("\n[8] 无 strong ETag → 用 URL + Last-Modified 校验")
h6 = {
    "content-length": 600,
    "_strong_etag": None,
    "_last_modified": "Wed, 21 Oct 2026 07:28:00 GMT",
    "last-modified": "Wed, 21 Oct 2026 07:28:00 GMT",
    "content-range": "bytes 400-999/1000",
}
all_ok &= check("URL 与 LM 都匹配 → 接受",
                can_resume(206, "identity", h6, 400, TOTAL, URL, URL), True)

h7 = dict(h6)
h7["last-modified"] = "Thu, 22 Oct 2026 07:28:00 GMT"
all_ok &= check("Last-Modified 变化 → 拒绝",
                can_resume(206, "identity", h7, 400, TOTAL, URL, URL), False)

all_ok &= check("URL 变化 → 拒绝",
                can_resume(206, "identity", h6, 400, TOTAL, URL, "https://other.com/x"), False)

# ---- 弱 ETag 不应作为依据（解析层已过滤，这里模拟传 None）----
print("\n[9] 弱 ETag 已被上层过滤为 None → 走 URL+LM 分支")
h8 = dict(h6)
all_ok &= check("弱 ETag 不作依据", can_resume(206, "identity", h8, 400, TOTAL, URL, URL), True)

# ---- 边界：已收 0（不是续传）----
print("\n[10] 已收 0 字节时不应走续传分支（由调用方判断）")
all_ok &= check("0 字节（调用方会跳过校验）", can_resume(206, "identity", h, 0, TOTAL, URL), False)

print("\n" + "=" * 68)
if all_ok:
    print("全部通过")
else:
    print("有失败项")
print("=" * 68)
