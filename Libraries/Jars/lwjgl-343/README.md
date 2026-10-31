# Libraries/Jars/lwjgl-343 —— LWJGL 3.4.3 纯 Java jar（MC 26.3 用）

用途：MC 26.3 的 version JSON 按 LWJGL **3.4.3** 声明依赖（含 `lwjgl-sdl`），
本目录提供该版本的**纯 Java**（不带 `-natives-<os>-<arch>` 后缀）classes jar。
**本目录不含 natives 动态库**，natives 另行处理。

- 下载源：Maven Central `https://repo1.maven.org/maven2/org/lwjgl/<artifact>/3.4.3/<artifact>-3.4.3.jar`
- 校验：每个文件均通过 `python zipfile` 打开 + `testzip()` 无损坏 + 含 `.class`；
  并用 Maven 官方 `.jar.sha1` 逐个比对 SHA-1，**9/9 全部 SHA1-OK**（非伪造/非截断）。
- 下载时间：2026-10-31

## 清单（9 个 jar，合计 4,511,062 字节 / 4.30 MiB）

| jar | 字节 | md5 | .class 数 |
|---|---:|---|---:|
| lwjgl-3.4.3.jar | 1,255,440 | `324da0b3e0524858c9e7c221e91cade0` | 540 |
| lwjgl-sdl-3.4.3.jar | 989,769 | `981a7b02e8e20f3c1fbd3fe877f1aa0a` | 520 |
| lwjgl-glfw-3.4.3.jar | 152,633 | `2ebd4411c09bb25a381cd99f422ecf88` | 116 |
| lwjgl-opengl-3.4.3.jar | 953,649 | `92b991954fc349f4201cc28f2df82e34` | 493 |
| lwjgl-opengles-3.4.3.jar | 377,594 | `c4f46db941d4c2e7e80ad6ef37c793e5` | 273 |
| lwjgl-stb-3.4.3.jar | 143,041 | `0edca5324f9aec48e244de134a3bc6fd` | 73 |
| lwjgl-freetype-3.4.3.jar | 468,438 | `2475f66fe2998cbc62e4dc7592837b1b` | 269 |
| lwjgl-openal-3.4.3.jar | 154,573 | `d545a021f1295c40aab4711ad9ace96a` | 95 |
| lwjgl-tinyfd-3.4.3.jar | 15,925 | `6f4a89880ea6d2b08017b7219bdd0b0c` | 3 |

逐条来源 URL：

```
https://repo1.maven.org/maven2/org/lwjgl/lwjgl/3.4.3/lwjgl-3.4.3.jar
https://repo1.maven.org/maven2/org/lwjgl/lwjgl-sdl/3.4.3/lwjgl-sdl-3.4.3.jar
https://repo1.maven.org/maven2/org/lwjgl/lwjgl-glfw/3.4.3/lwjgl-glfw-3.4.3.jar
https://repo1.maven.org/maven2/org/lwjgl/lwjgl-opengl/3.4.3/lwjgl-opengl-3.4.3.jar
https://repo1.maven.org/maven2/org/lwjgl/lwjgl-opengles/3.4.3/lwjgl-opengles-3.4.3.jar
https://repo1.maven.org/maven2/org/lwjgl/lwjgl-stb/3.4.3/lwjgl-stb-3.4.3.jar
https://repo1.maven.org/maven2/org/lwjgl/lwjgl-freetype/3.4.3/lwjgl-freetype-3.4.3.jar
https://repo1.maven.org/maven2/org/lwjgl/lwjgl-openal/3.4.3/lwjgl-openal-3.4.3.jar
https://repo1.maven.org/maven2/org/lwjgl/lwjgl-tinyfd/3.4.3/lwjgl-tinyfd-3.4.3.jar
```

## 未取到（404 / 不存在）

**无。** 9 个 artifact 在 3.4.3 全部存在，全部 HTTP 200 取回并校验通过。

## 关键证据

`lwjgl-sdl-3.4.3.jar` 内含真机日志卡住的那个类：

```
org/lwjgl/sdl/SDLKeyboard.class
org/lwjgl/sdl/SDLKeyboard$Functions.class   <- 真机日志停在 SDLKeyboard$Functions 类初始化
```

（SDL 模块是 3.4.0 新引入，3.4.1 的 classpath 上没有 `org.lwjgl.sdl.*`，
 26.3 用 3.4.1 的类跑 SDL 路径因此对不上。）

## 与现有 `Libraries/Jars/lwjgl-341/` 的对比

现有目录**只有 2 个 jar**（不是 3 个），且二者内容都不是 LWJGL 3.x 的模块化类：

| 现有文件 | 字节 | 实际内容 |
|---|---:|---|
| `lwjgl.jar` | 12,955,546 | LWJGL **2.x** 类（`org.lwjgl.LWJGLUtil` / `BufferChecks` / `Sys`），6227 项，含 `net/java/openjdk` |
| `lwjgl-lwjglx.jar` | 234,727 | LWJGL2 风格包 + `org/lwjgl/input|openal|opengl|util`，180 项 |

即便按文件名对齐，`lwjgl-341` 也**没有** `lwjgl-sdl.jar`、`lwjgl-glfw.jar`、
`lwjgl-opengles.jar` 等 3.4.x 模块 jar —— 这就是 26.3 拿不到 `org.lwjgl.sdl.*` 的原因。
本目录（`lwjgl-343`）按 3.4.3 artifact 命名，**文件名与 Maven 坐标一致**，
可直接按 `${artifact}-3.4.3.jar` 映射进 classpath。

## 边界（本单未做的事）

- 未修改任何 `.m` / `.java` / 启动逻辑 / classpath 拼装：本目录只是数据。
- 未下载 natives（`*-natives-linux.jar` / `*-natives-windows.jar` / `*-natives-macos.jar` 等），
  真机日志报的「缺少 30 个库」含 natives，需要单独一单处理。
- 未改动 `Libraries/Agent`、`gen_xcodeproj.py`。
