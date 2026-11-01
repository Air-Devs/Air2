# MC 1.12.2 固定管线入口的绑定取证 + 自研 GL2 层接入方案

> 结论先行：**既不是 (a) flat namespace 直拿 ANGLE，也不是 (b) liblwjgl.opengl 自己 dlsym**，
> 而是 **(c) 其它：`org.lwjgl.opengl.GL11` 的 `public static native` 方法 + `liblwjgl_opengl.dylib`
> 里的 JNI 中继**。这条路径**不经过任何按名字解析 GL 符号的环节**，所以
> `eglGetProcAddress` / `a2_gl_bridge_gles_getprocaddress` 两个钩子**结构上不可能**看到它，
> 也就解释了 1.7.10 的 `GL11.glLoadIdentity → GLES1State::loadMatrix` 为什么绕开了我们。
>
> 接入方案（唯一）：**JNI 绑定抢占（`RegisterNatives`）**，把 7 个固定管线入口换成自研层。
> 已实现并编译通过（`BUILD_RC=0`，0 error）。

---

## 一、取证（全部命令可复跑；机器 = 构建机 `/build/air2` + 本机 JDK）

### 1. 1.12.2 的 `GL11` 来自 `lwjgl.jar`，不是 lwjglx 兼容层

```
$ unzip -l Libraries/Jars/lwjgl-341/lwjgl-lwjglx.jar | grep -c 'org/lwjgl/opengl/GL11.class'
0                       # lwjglx 只有 Display/Context/AWTGLCanvas/ContextCapabilities/GLU…
$ ls l/org/lwjgl/opengl | grep -E '^GL11'    # 解包 lwjgl.jar
GL11.class  GL11C.class
```

### 2. 这 7 个入口在 Java 侧是 **native**，不是函数指针

```
$ javap -p -s org/lwjgl/opengl/GL11.class | grep -A1 'glBegin(int)'
  public static native void glBegin(int);
    descriptor: (I)V
```

| 入口 | 声明位置 | 描述符 | native |
|---|---|---|---|
| glBegin | `org.lwjgl.opengl.GL11` | `(I)V` | ✅ |
| glEnd | `GL11` | `()V` | ✅ |
| glVertex3f | `GL11` | `(FFF)V` | ✅ |
| glColor4f | `GL11` | `(FFFF)V` | ✅ |
| glMatrixMode | `GL11` | `(I)V` | ✅ |
| glLoadIdentity | `GL11` | `()V` | ✅ |
| glDrawArrays | **`GL11C`** | `(III)V` | ✅（`GL11.glDrawArrays` 是普通 Java 方法，转调 `GL11C`） |

**决定性旁证**：`GL11.class` / `GL11C.class` 里 `getFunctionAddress` 出现次数 = **0**
（`javap -v | grep -c getFunctionAddress` ⇒ 0）⇒ Java 侧从来没有解析过这些入口，
改 `opengl.libname` / 换 `FunctionProvider` 对它们**无效**（与 lastlog-93 的
`opengl provider .library = MacOSXLibraryDL` 只影响别的入口一致）。

### 3. 实现在 `liblwjgl_opengl.dylib`（274 条 `GL11_*` JNI 导出）

```
$ llvm-objdump-17 --macho --exports-trie Libraries/Frameworks/liblwjgl_opengl.dylib | grep -c '_Java_org_lwjgl_opengl_GL11_'
274
$ … | grep -x '.*_Java_org_lwjgl_opengl_GL11_glBegin'
0x0000A1CC  _Java_org_lwjgl_opengl_GL11_glBegin
```

### 4. 该 dylib **零外部导入**：没有 dlsym、没有 dlopen、不链 libGLESv2

```
$ llvm-objdump-17 --macho --dylibs-used liblwjgl_opengl.dylib
  bin/libs/native/macos/arm64/org/lwjgl/opengl/liblwjgl_opengl.dylib
  /usr/lib/libSystem.B.dylib
$ llvm-objdump-17 --macho --bind liblwjgl_opengl.dylib        # 空表
$ llvm-objdump-17 --macho --lazy-bind liblwjgl_opengl.dylib   # 空表
$ strings -a liblwjgl_opengl.dylib | grep -x 'glBegin'        # 0 条（没有名字字符串）
$ strings -a liblwjgl_opengl.dylib | grep -c getFunctionAddress  # 0
```

### 5. 每条 `glBegin` 实现是一段 **5 条指令的中继**

```
$ llvm-objdump-17 -d --start-address=0xa1cc --stop-address=0xa1e0 liblwjgl_opengl.dylib
    a1cc: f9400008  ldr x8, [x0]        ; x0 = JNIEnv*，[x0] = JNI 函数表
    a1d0: f9400d08  ldr x8, [x8, #0x18] ; 表里第 4 槽 ⇒ 一张「运行期提供的入口表」
    a1d4: f9401901  ldr x1, [x8, #0x30] ; glBegin 在该表里的固定偏移
    a1d8: aa0203e0  mov x0, x2          ; 第 3 个参数（jint mode）右移成第 1 个
    a1dc: d61f0020  br  x1              ; 尾跳，参数原样透传
```

每条入口的偏移都不同（glBegin=0x30、glArrayElement=0x40、glCallList=0x50、glClearAccum=0x68…），
形态就是「按固定偏移取一张入口表里的指针再尾跳」。**它不解任何符号**。

### ⇒ 结论

| 假设 | 判定 | 依据 |
|---|---|---|
| (a) flat namespace 直拿 ANGLE 入口 | ❌ | dylib 零外部导入（§4），不存在 `_glBegin` 未定义符号可供 dyld 绑定 |
| (b) liblwjgl.opengl 自己 dlsym | ❌ | 同一张 dylib 的 bind/lazy-bind 表为空、无 `dlsym`、无 `glBegin` 字符串（§4） |
| (c) JNI native 中继（其它） | ✅ | Java 侧 native 声明（§2）+ 274 条 JNI 导出（§3）+ 中继指令（§5） |

这同时解释了历史现象：KW 的解析器被问了 1 次就再没人问（`[A2-GL-STUB]` 0 条），
而 `GL11.glLoadIdentity` 仍落到 ANGLE 的 `GLES1State::loadMatrix` —— 因为调用**根本没走解析器**。

---

## 二、为什么不用「-export_dynamic + dlsym(RTLD_NEXT)」或「独立 liba2gl2.dylib 抢先解析」

两个方案的前提都是「进程里存在一个按名字解析 `glBegin` 的环节」。取证证明**不存在**：

- `glBegin` 不是 `libLWJGL` 的未定义符号（dylib 无导入表），dyld 没有可 interpose 的目标；
- 主镜像 `-export_dynamic` 导出 `_glBegin` 也不会被任何人查（没人 dlsym 它）；
- 独立 dylib 抢先加载只是让 `dlsym(RTLD_DEFAULT,"glBegin")` 命中我们 —— 而这条解析**从来没发生**。

> 反证：如果按这两个方案做，`[A2-GL2]` 会显示「已启用」，但 MC 的 `glBegin` 一次也不会进我们
> —— 正是 1.7.10 已经踩过的坑（改参数/加桩都无效）。所以本轮不采用。

---

## 三、确定方案：JNI 绑定抢占（`RegisterNatives`）

MC 的调用链是 `invokestatic org/lwjgl/opengl/GL11.glBegin(I)V` → JVM 的 native 入口。
`RegisterNatives` 在 **native 入口** 这一层把它换成我们的函数：

- 不依赖符号搜索顺序、不污染进程 flat namespace（不会误抢 ANGLE 内部对 `gl*` 的解析）；
- 只动 7 条方法，其它 267 条 GL11 入口与全部 GL11C 入口保持原样；
- 关掉时（两个判据都没设）**一条也不注册** ⇒ 与接入前逐字节一致。

### 落点与调用关系（每个新符号都指得出谁调它）

| 文件 | 符号 / 位置 | 谁调它 |
|---|---|---|
| `Natives/Renderer/a2_gl2_jni_probe.m:31` | `kA2GL2ProbeEntries[]`（7 条登记表） | `a2_gl2_probe_sample()` / bind 的注册循环 |
| `…probe.m:75` | `a2_gl2_probe_sample()` | `a2_gl2_probe_log()`、`Java_a2_A2Gl2Probe_report` |
| `…probe.m:96` | `a2_gl2_probe_log()` | `a2_gl2_jni_install()`（安装前取证） |
| `…probe.m:122` | `Java_a2_A2Gl2Probe_report`（JNI） | `A2Gl2Probe.java:166 report()` ← agent 注入的 `run()` |
| `Natives/Renderer/a2_gl2_jni_bind.m:105` | `a2gl2_enter()`（每入口只查一次本层实现） | 7 个 JNI 转发 |
| `…bind.m:138…` | 7 个 JNI 转发 `a2gl2_j_*` | `RegisterNatives`（`…bind.m:235`）← MC 的 `GL11.*` |
| `…bind.m:190` / `:200` | `kA2GL2MethodsGL11[]` / `kA2GL2MethodsGL11C[]` | `a2gl2_register_class()` |
| `…bind.m:212` | `a2gl2_verify_table()`（表序/条数核对） | `a2_gl2_jni_install()` |
| `…bind.m:235` | `a2gl2_register_class()`（验签名 + RegisterNatives） | `a2_gl2_jni_install()` |
| `…bind.m:266` | `a2_gl2_jni_install()` | `Java_dev_airdevs_air2_launch_A2Gl2Gl11Bind_install`（`…bind.m:305`） |
| `JavaApp/.../A2Gl2Gl11Bind.java:31` | `bind(ClassLoader)` | `A2Entry.java:57` |
| `JavaApp/.../A2Gl2Gl11Bind.java:54` | `native install(Class,Class)` | `bind()`（`A2Entry` 主线程，派发 MC 之前） |
| `JavaApp/src/a2ios_agent/a2/A2Gl2Probe.java:42` | `run()` | `A2IosCompatAgent.patchGl11Probe()` 注入的 `INVOKESTATIC`（`A2IosCompatAgent.java:187`，分派在 `:102`） |

实现层不变：仍然调 `a2_gl2_shim_lookup(name)`（`a2_gl2_shim.m:1128`，★唯一查询口★）。

### 判据（默认关）

| 环境变量 | 行为 |
|---|---|
| 都不设 | 一条都不注册，打一行「未启用」 |
| `A2_GL2_PROBE=1` | 注册 + 转发原实现（**行为不变**，只多几行日志）—— 真机验证抢占是否生效用这一档 |
| `A2_GL2_SHIM=1` | 注册 + 固定管线入口走自研层（实现见 `a2_gl2_shim.m`） |

---

## 四、真机怎么验（看哪一行、期望值、两种结果的含义）

1. `grep 'A2-GL2-PROBE' Documents/latestlog.txt`（或日志页），应有 8 行，形如：

```
[A2-GL2-PROBE] glBegin ← org/lwjgl/opengl/GL11.glBegin（JNI 实现镜像=liblwjgl_opengl.dylib，地址=0x…；进程 dlsym("glBegin") 命中镜像=libGLESv2.dylib）
…
[A2-GL2-PROBE] 结论：固定管线入口的实现镜像=liblwjgl_opengl.dylib ⇒ 绑定发生在 JNI native 层（Java 侧 native 声明 + JNI 符号解析），既不经过 eglGetProcAddress，也不经过 a2_gl_bridge_gles_getprocaddress ⇒ 两个解析器钩子对这批入口无效
```

- **期望值**：`JNI 实现镜像` = `liblwjgl_opengl.dylib`。
  - = `liblwjgl_opengl.dylib` ⇒ 与本报告一致，方案成立。
  - = 别的镜像（如 `libGLESv2.dylib` / `libnggl4es_kw.dylib`）⇒ 该设备上的 GL11 native 由别的库提供，
    说明 LWJGL 二进制不同，需要按同一思路改「注册到哪个类/哪个符号」（日志里有符号名可直接对）。
  - = `(无)` ⇒ 那一刻 LWJGL 的 native 库还没加载（在 `A2Entry` 阶段跑得偏早），此后由
    `[A2-GL2-PROBE] 抢占命中 …` 行补齐结论。
- `进程 dlsym("glBegin")` 那一列是**反证列**：它显示「如果按 flat namespace 直取会命中谁」
  （常是 ANGLE 的 libGLESv2）。它与 JNI 镜像不同 = 两者不是一条路，正是本报告的结论。

2. 抢占结果：

```
[A2-GL2] ★GL11 入口抢占=生效★ 已接管 7/7 个固定管线入口（A2_GL2_SHIM=1 A2_GL2_PROBE=0）—— MC 的 glBegin/glEnd/glVertex3f/glColor4f/glMatrixMode/glLoadIdentity/glDrawArrays 现在先到本进程
```

- `7/7` ⇒ 全部接管；`0/7` + `★签名不匹配★` ⇒ 该 LWJGL 版本的描述符变了（日志会打出期望的 `名字+描述符`）。
- 出现 `★拒绝安装★ 第 N 条名字=…` ⇒ 登记表被重排（不会装错入口，直接不装）。

3. 进入世界后（`A2_GL2_SHIM=1`）：

```
[A2-GL2-PROBE] 抢占命中 glBegin（JNI native 已被本层接管；本层实现=有）
```

- **有这行** ⇒ MC 真的在我们的层里画；**没有这行**（且 `7/7` 已生效）⇒ MC 走的是别的类/别名入口
  （例如某个 mod 自己包了 `GL11`），需要把该类加进登记表 —— 这就是下一轮唯一的扩展点。

---

## 四·附、构建证据（构建机 `/build/air2`，clang-17 + ld64.lld，Ubuntu 192.168.3.172）

```
$ /usr/bin/cmake -S . -B build/cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-ios-linux.cmake \
      -DiOS_SDK=/build/iossdk/iPhoneOS.sdk -DCMAKE_BUILD_TYPE=Release
-- [a2] 编译单元 230（Air2/ 186 + Natives/ 44）      # 新增 2 个 .m 已进源清单（228 → 230）

$ /usr/bin/cmake --build build/cmake -j8
[2/2] Linking C executable Air2
BUILD_RC=0        error: 计数 = 0
BIN = build/cmake/Air2 = 5,230,032 B
OBJECTS: a2_gl2_jni_bind.m.o = 16,672 B / a2_gl2_jni_probe.m.o = 5,376 B

$ llvm-nm-17 build/cmake/Air2 | grep 'A2Gl2\|a2_gl2_'
_Java_a2_A2Gl2Probe_report                                    (T，JNI 符号宿主 = 主可执行文件)
_Java_dev_airdevs_air2_launch_A2Gl2Gl11Bind_install           (T)
_a2_gl2_jni_install / _a2_gl2_probe_log / _a2_gl2_probe_sample / …（T）
```

Java 侧本地验证（不需要真机）：

```
$ javac -source 8 -target 8 … JavaApp/src/launcher/**        # 11 个源文件，产出 A2Gl2Gl11Bind.class
$ javac -source 8 -target 8 -cp <ASM> … JavaApp/src/a2ios_agent/a2/*.java   # agent 编译通过
$ java -javaagent:patchios_agent.jar -version                 # premain 正常加载（jar 已重打，191,861 B）

# 规则 F 的字节码自证：把 jar 里的 GL11.class 过一遍 transformer 再反汇编
$ javap -p -c org.lwjgl.opengl.GL11 | sed -n '/static {}/,/^$/p'
  static {};
    Code:
       0: invokestatic  #523   // Method org/lwjgl/opengl/GL11.initialize:()V
       3: invokestatic  #3011  // Method a2/A2Gl2Probe.run:()V      ← 注入点（原 class +38 B）
       6: return
```

---

## 五、已知边界（如实）
1. **只接管 7 条**：`glVertex2f/3fv`、`glTexCoord2f`、`glPushMatrix`、`glEnableClientState`、
   `glDrawElements`… 仍在原路径。它们要么由 `a2_gl2_shim` 的其余实现承担（下一步按同一张表扩，
   一行登记 + 一个转发），要么继续走 KW/ANGLE。
2. **`glDrawArrays` 注册在 `GL11C`**：因为 `GL11.glDrawArrays` 不是 native（§2）。若某个版本的
   jar 改成 native，`GetStaticMethodID` 会命中而 `RegisterNatives` 报错（日志有 `rc=-1`）。
3. **类加载器**：只对系统类加载器上的 `GL11` 生效。用独立 loader 再加载一份 LWJGL 的加载器
   （部分 mod 注入器）不在本轮范围。
4. **本层能否出画面**仍取决于 `a2_gl2_shim` 自身的完成度；本轮交付的是「入口真的到得了我们这里」。
