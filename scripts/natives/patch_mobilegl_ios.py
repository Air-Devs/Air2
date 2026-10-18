#!/usr/bin/env python3
"""
patch_mobilegl_ios.py

修 iOS 上 MobileGL DirectGLES 后端的启动崩溃。

问题（根因来自上游分析，见 Taylen-chud/Amethyst-iOS 的 patch_mobilegl.py）：

  DirectGLES::ProbeTexture() 只要函数指针非空就会调用
  glTexStorage2DMultisample / glTexStorage3DMultisample。但"指针非空"只说明
  符号通过 dlsym 解析成功了，并不代表当前 GLES 上下文真的支持多重采样纹理存储：

    - GL_TEXTURE_2D_MULTISAMPLE        需要 GLES 3.1+
    - GL_TEXTURE_2D_MULTISAMPLE_ARRAY  需要 GLES 3.2+

  ANGLE 的 Metal 后端即使在能力没接上的上下文里也会导出这些入口点，
  无条件调用会在 ANGLE 内部（gl::State::getTargetTexture）直接段错误，
  而不是干净地返回失败 —— 这就是 iOS 上 MobileGL-gles.dylib 的崩溃。

本补丁的做法与上游脚本不同：不去改 ProbeTexture 的签名把 GLESCapabilities
透传进去（当前 vendored 版本比上游脚本对应的版本新，签名已多出
`Int samples = 1`，且多了一个 ProbeTextureSampleCounts 调用点，改签名要动
四个位置并同步匿名命名空间内的声明，风险高）。

改为在 iOS 构建下直接跳过多重采样纹理的能力探测，走已有的"不支持"回退路径：
  - 只影响 iOS（#if defined(MOBILEGL_IOS)）
  - 不改任何函数签名，不动调用点
  - 后果是 MobileGL 不再声明支持多重采样纹理，MC 会退回普通纹理 —— 优雅降级

幂等：已打过则跳过，重复运行安全。
"""
import sys
import pathlib

TARGET_REL = "MobileGL/MG_Backend/DirectGLES/BackendObject_DirectGLES.cpp"
MARKER = "MOBILEGL_IOS_MULTISAMPLE_PROBE_SKIP"

OLD = """            const Bool isMultisample = IsGLESProbeMultisampleTarget(target);
            if (isMultisample) {
                const auto probeSamples = static_cast<GLsizei>(std::max(samples, 1));
                if (target == TextureTarget::Texture2DMultisample && gl.glTexStorage2DMultisample) {"""

NEW = """            const Bool isMultisample = IsGLESProbeMultisampleTarget(target);
            if (isMultisample) {
                const auto probeSamples = static_cast<GLsizei>(std::max(samples, 1));
#if defined(MOBILEGL_IOS)
                // %s
                // iOS 上不做多重采样纹理存储的能力探测：符号能 dlsym 到 ≠ 当前上下文
                // 真的支持，ANGLE/Metal 下无条件调用会在 gl::State::getTargetTexture
                // 里段错误。走下面的"不支持"回退路径，代价是不声明多重采样纹理支持。
                {
                    gl.glBindTexture(glTarget, static_cast<GLuint>(previousBinding));
                    gl.glDeleteTextures(1, &texture);
                    return false;
                }
#endif
                if (target == TextureTarget::Texture2DMultisample && gl.glTexStorage2DMultisample) {""" % MARKER


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} /path/to/MobileGL/checkout", file=sys.stderr)
        return 1
    target = pathlib.Path(sys.argv[1]) / TARGET_REL
    if not target.is_file():
        print(f"ERROR: {target} not found.", file=sys.stderr)
        return 1

    text = target.read_text()
    if MARKER in text:
        print("[patch_mobilegl_ios] already applied, skipping.")
        return 0
    if text.count(OLD) != 1:
        print(f"ERROR: pattern matched {text.count(OLD)} times (expected 1). "
              f"MobileGL source likely changed upstream; update this script.", file=sys.stderr)
        return 1

    target.write_text(text.replace(OLD, NEW))
    print(f"[patch_mobilegl_ios] Applied. Wrote {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
