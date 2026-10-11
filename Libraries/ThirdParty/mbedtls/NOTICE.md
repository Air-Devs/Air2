# 第三方组件：Mbed TLS（mbedTLS）3.6.2

- **用途**：仅用于 Air2 的「TLS-PSK 隧道」后端（RPPairing 规格 §12）。
  接口在 `Natives/Support/a2_tlspsk_tunnel.h`（可替换门面），本库只在
  `Natives/Support/a2_tlspsk_mbedtls.m` 里被调用；**默认关**（隧道 `enabled` 默认 NO）。
- **许可**：Apache-2.0（上游双许可 Apache-2.0 OR GPL-2.0-or-later；本仓选 **Apache-2.0**）。
  许可原文见同目录 `LICENSE`。
- **版本**：3.6.2（LTS）。
- **形态**：随仓预编译的 iOS arm64 静态库
  - `lib/libmbedtls.a`、`lib/libmbedx509.a`、`lib/libmbedcrypto.a`
  - `include/{mbedtls,psa}/*.h`
- **重建配方**：`scripts/build_mbedtls_ios.sh`（★离线★；只吃本地源码 tarball，不联网取依赖、不引包管理器、不上云）。
  - 编译参数：`xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=14.0 -O2 -fno-common -DMBEDTLS_ENTROPY_HARDWARE_ALT`
  - 熵源：库以 `MBEDTLS_ENTROPY_HARDWARE_ALT` 编成 ⇒ 由 App 侧
    `Natives/Support/a2_tlspsk_mbedtls.m` 的 `mbedtls_hardware_poll`（iOS 公开 API
    `SecRandomCopyBytes`）提供；**库本身不读 `/dev/urandom`**。
- **链接**：`scripts/gen_xcodeproj.py` 的 `MBEDTLS_LDFLAGS`
  （`-L…/lib -lmbedtls -lmbedx509 -lmbedcrypto`，顺序固定）。
- **未引入**：不使用 mbedTLS 的 x509 信任链校验（PSK 模式 `MBEDTLS_SSL_VERIFY_NONE`），
  不启用任何云服务/远端 CA。隧道另有「不上云」主机准入策略（只允许本机/私有网段/链路本地/.local）。
