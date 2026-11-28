# 统一输入映射层（[INPUT-MAP-1]）

> **状态**：键盘已实现；虚拟按钮 / 手柄**只有接口**（分别由 [INPUT-MAP-2] / [INPUT-MAP-3] 补实现）。
> **代码**：`Natives/Input/A2Input*.h|.m`（映射层）+ `A2KernelInputSink`（内核汇）+ `A2KeyboardInputSource`（键盘源）
> **测试**：`python3 tests/Input/run_input_mapping_tests.py`（86 例，真编译真运行）
> **决策**：`docs/DECISIONS.md` ADR-015

---

## 0. 一句话

**虚拟按钮 / 键盘 / 手柄三种源共用一套接口，经一张绑定表映射到「键盘任意键」或「手柄任意键」，
再由内核汇投给所有 MC 内核（≤26.2 的 GLFW 总线 / 26.3 的 SDL3 队列）。**

---

## 1. 为什么要有这一层

[INPUT-MAP-1] 之前，输入是这样分叉的：

| 输入 | 老路径 | 后果 |
|---|---|---|
| 触摸（指针） | `A2GlfwView` → `a2_glfw_event_post` | 只能当鼠标用 |
| 外接键盘 | `A2GlfwView.pressesBegan` → 内联 HID 表 → `a2_glfw_event_post` | 键位写死、无改绑；且**没有**镜像给 26.3 的 SDL 队列 |
| 屏幕控件 | `A2GameControlsView` → `a2_glfw_input_post_key` | 每个控件各自算键码、各自发事件 |
| 手柄 | 无 | — |

问题不在「少一个功能」，而在这四条路各写各的翻译：加一种输入就要在每个调用点再抄一遍键码，
改绑无处安放，26.3 的 SDL 镜像也只能一处一处补。**再加手柄就是第五份。**

所以这一层只做一件事：**把「谁按了什么」和「按了应该变成什么」分开。**
源只报触发，绑定表决定落点，内核汇负责投递。

---

## 2. 数据流

```
虚拟按钮源 ─┐
键盘源     ─┼─ A2InputTrigger ─▶ A2InputRouter ─ A2InputEvent ─▶ A2InputSink（每个内核一份）
手柄源     ─┘                        │                              ├─ ≤26.2：GLFW 事件总线
                                     │                              └─ 26.3 ：SDL3 事件队列
                                     └─ A2InputBindingTable（改绑的唯一数据源）
```

关键点：

- **源不知道落点**。键盘源只知道「按了 GLFW 键码 65」，不知道 65 该变成什么 —— 那是绑定表的事。
- **路由器是唯一入口**。改绑、防卡键、多源同落点、内核能力差异，四件事都要看「全局正在按什么」，
  分散在各源里必然出现「松手了还在走」。
- **汇按内核分**。加内核 = 加一个汇，映射层与源一行不改。

---

## 3. 接口清单

| 文件 | 角色 | 本迭代状态 |
|---|---|---|
| `A2InputTypes.h/.m` | 词汇表：三种源、两个目标空间、触发/事件、GLFW 全键目录 | 完成 |
| `A2InputSource.h` | 源协议（`startWithError:` / `stop` / `enabled` / `delegate`） | 完成 |
| `A2InputSink.h` | 汇协议（`emitEvent:` 返回 `BOOL`） | 完成 |
| `A2InputBinding.h/.m` | 一条绑定 + 绑定表（覆盖、查表、JSON 往返、严格解析） | 完成 |
| `A2InputRouter.h/.m` | 唯一入口：解算、引用计数、防卡键、拒绝计数 | 完成 |
| `A2KeyboardInputSource.h/.m` | 键盘源：HID usage → GLFW 键码（**唯一一份表**） | **已实现** |
| `A2VirtualButtonInputSource.h/.m` | 虚拟按钮源：控件 id 触发 | 只有接口（`start` 如实报 `NotImplemented`） |
| `A2GamepadInputSource.h/.m` | 手柄源：`A2GamepadButton` 触发 | 只有接口（同上） |
| `A2KernelInputSink.h/.m` | 内核汇：投给 GLFW 总线 + 26.3 SDL 镜像 | 完成 |

装配点：`a2_glfw_input_router(long window)`（`a2_glfw_input.m`）—— 每个窗口一份，
视图强持有、窗口表弱登记（视图没了条目自动消失，不需要在窗口销毁路径挂钩子）。

---

## 4. 绑定模型

### 4.1 触发与落点

```objc
typedef struct {
    A2InputSourceKind sourceKind;   // 虚拟按钮 / 键盘 / 手柄
    int code;                       // 键盘 = GLFW 键码；手柄 = A2GamepadButton；虚拟按钮 = 0
    NSString *identifier;           // 虚拟按钮的控件 id（其余为 nil）
    int mods;                       // GLFW mods 位
    A2InputAction action;           // 按下 / 抬起
    int scancode;                   // 键盘 HID usage（供按 scancode 认键的 Mod）
} A2InputTrigger;

typedef struct {
    A2InputTargetKind targetKind;   // key / gamepad-button
    int code;                       // GLFW 键码 或 A2GamepadButton
    A2InputAction action;
    int mods;
    float value;                    // 轴（[INPUT-MAP-3] 摇杆用，本次恒 0）
    int scancode;
} A2InputEvent;
```

**两个目标空间必须分开**：`A2GamepadButtonA == 0`、`GLFW_KEY_SPACE == 32`、`GLFW_KEY_A == 65`……
数值会撞。共用一个 `int` 就会「手柄 A 变成键盘 A」，而这类串号在真机上只表现为「按了没反应/按错键」。

### 4.2 虚拟按钮为什么按 id 匹配

控件的**键位是用户可改的，id 不是**。用 id 当触发，改绑只改绑定表；用键码当触发，
改绑就等于换了一个控件 —— 用户看到的是「改完键位，控件失灵」。

### 4.3 键盘直通

`keyboardPassthrough = YES`（默认）：没有显式绑定的键盘键**就是它自己**。
一旦某键有显式绑定，直通对它失效（否则一个触发会落两次）。

### 4.4 序列化格式

```json
[
  {"source": "gamepad", "trigger": 0, "target": "key", "code": 32},
  {"source": "virtual-button", "trigger": "attack", "target": "key", "code": 0},
  {"source": "keyboard", "trigger": 87, "target": "key", "code": 83}
]
```

`trigger` 对键盘/手柄是编号、对虚拟按钮是 id 字符串。**反序列化是严格的**：
字段缺失、枚举不认识、虚拟按钮给了数字 ⇒ 整条 `nil`；一条坏 ⇒ 整表 `nil`。
绑定表是用户配置，静默纠错会造出「我明明绑了跳跃，怎么在挖矿」这种无法复现的问题。

### 4.5 出厂表

手柄 11 条，**刻意对齐 MC 默认键位**（插上就能玩，不必先绑十几条）：

| 手柄 | 键盘 | 用途 |
|---|---|---|
| A | SPACE | 跳跃 |
| B | LEFT_SHIFT | 潜行 |
| X | LEFT_CONTROL | 疾跑 |
| Y | E | 背包 |
| LB | Q | 丢弃 |
| RB | TAB | 玩家列表 |
| BACK | ESCAPE | 暂停/菜单 |
| ↑ ↓ ← → | UP DOWN LEFT RIGHT | 菜单/热键栏 |

虚拟按钮**没有出厂绑定**：控件键位来自布局模型（每个控件自带 `key`），
由 [INPUT-MAP-2] 接控件层时按布局灌进来 —— 在这里编一套默认只会和布局打架。

---

## 5. 覆盖所有 MC 内核

| 内核 | 输入栈 | 汇怎么投 |
|---|---|---|
| ≤26.2 | GLFW 事件总线 | `a2_glfw_event_post`（`A2_GLFW_EVENT_KEY`） |
| 26.3 | SDL3 事件队列 | `a2_sdl_input_key`（GLFW 事件收不到，必须镜像） |

两条栈的「同一份输入」在 `a2_glfw_input_post_key_event()` 内部一次做完，
**汇里没有任何版本判断** —— 在汇里再判一次就是两处真相。

**新增内核**：实现 `A2InputSink`（`emitEvent:` 返回 `BOOL`），`[router addSink:]` 注册。
映射层、源、绑定表都不改。

**内核收不了的目标空间要如实返回 `NO`**：当前 MC 没有原生手柄通道，手柄落点投进来会被拒，
映射层计数并打一条判据行（见 §8）。「投了就算成功」会让「手柄为什么没反应」永远查不出断在哪。

---

## 6. 语义保证（防卡键五条）

1. **按下时解算，松开复用**：按着 W 时改绑 W，松开仍落回原来那个键。
   若松开时再查一次表，旧键永远抬不起来（MC 里表现为角色一直往前走）。
2. **落点引用计数**：虚拟按钮「跳跃」和手柄 A 都 → SPACE 时，先松一个**不**发 RELEASE。
3. **重复按下忽略**：同一个触发连按两次（UIKit 重发 / 控件抖动）只算一次，
   否则计数被灌大，松开时抬不起来。
4. **未按先松忽略**：进游戏前就按着某个键，不该给内核发一个「凭空松开」。
5. **`releaseAllHeldTargets`**：窗口销毁 / 摘汇 / 换绑定表前自动抬起；
   **退后台也自动抬起**（映射层自己监听 `UIApplicationDidEnterBackgroundNotification`，
   用通知名而不 import UIKit —— 本层只依赖 Foundation，测试才能直接在 macOS 上跑）。
   玩家按着 W 切出去、MC 收不到抬手 ⇒ 回来还在走，就是这一条挡住的。

**主线程契约**：UIKit 事件与窗口生命周期都在主线程，映射层不加锁（不给死锁与错序留机会）。
非主线程投递会记一条日志而不是崩 —— 崩在输入路径上等于整局游戏陪葬。

---

## 7. 本迭代边界（诚实清单）

**已实现**

- 键盘源：字母/数字/标点/编辑键/方向键/F1–F24/小键盘/修饰键全表；
- 键盘直通 + 任意改绑（键 → 任意 GLFW 键）；
- 绑定表 JSON 往返与严格解析；
- 内核汇（GLFW 总线 + 26.3 SDL 镜像）；
- 防卡键五条语义、被拒/未映射计数、判据行；
- 86 例单测（键目录、HID 表、绑定表、路由器状态机、未实现源如实报错）。

**只有接口（不假装能用）**

- 虚拟按钮源：`start` 返回 `NO` + `A2InputErrorCodeNotImplemented`；
  控件层此刻仍直接投 GLFW 事件（那条路是通的，接进来会变成按一下投两次）。
- 手柄源：同上，`start` 如实失败，等 `GCController` 接入。

**未做**

- 手柄摇杆/扳机模拟量（`A2InputEvent.value` 已预留，但**没有内核收**，先不给假接口）；
- 映射编辑器 UI（`UI/Control/` 仍为空；绑定表已可序列化，编辑器只需读写它）；
- 绑定持久化（属 App 层：拿 `dictionaryRepresentation` 存 `NSUserDefaults` / `A2Settings`）；
- 软键盘文本输入（阶段 B，CHAR 通道另有归属）。

---

## 8. 判据行（真机 grep）

| 行 | 含义 |
|---|---|
| `[INPUT-MAP] 输入映射层已装配 window=` | 映射层在该窗口装好了 |
| `[INPUT-MAP] 首个 keyboard 触发已到达映射层：keyboard 直通 → key A` | 该源真的通了，并直接写出「落到了哪」（直通还是改绑，一眼可见；每种源只报一次） |
| `[INPUT-MAP] 没有内核接收落点种类 …` | 该目标空间在当前内核没有通道（例如手柄键直接投递） |
| `[RT] [INPUT-MAP] 源 virtual-button 未启动：…` | 未实现的源被如实拒绝启动 |
| `[INPUT-MAP] 键盘 HID usage 未覆盖：0x..` | 有个物理键没有对应 GLFW 键码（只报一次） |
| `[RT] [INPUT-MAP] 已抬起全部仍按着的落点：N 个` | 退后台/换表时的防卡键动作 |

---

## 9. 怎么扩展

| 要加什么 | 改哪里 |
|---|---|
| 一种新输入源 | 实现 `A2InputSource`（`sourceKind` / `startWithError:` / `stop`），`[router addSource:]` |
| 一个新内核 | 实现 `A2InputSink`（`isAvailable` + `emitEvent:`），`[router addSink:]` |
| 一个新的落点空间 | 加 `A2InputTargetKind` + 各汇里处理（`A2InputEventTargetKey` 自动带新种类） |
| 手柄摇杆 | `A2GamepadInputSource` 填 `value`，并在汇里新增轴通道（**先确认有内核收**） |

---

## 10. 测试

```sh
python3 tests/Input/run_input_mapping_tests.py
```

- 真编译、真运行 `A2InputTypes` / `A2InputBinding` / `A2InputRouter` / `A2KeyboardInputSource` /
  两个未实现源 + `a2_log`；
- 覆盖：键目录完整性（名字唯一 + 往返）、HID 表 15 个点、默认表、改绑覆盖、JSON 往返与严格解析、
  直通、多源引用计数、未映射/被拒计数、重复按下、未按先松、`releaseAll`、改绑时抬键、源禁用、汇不可用；
- **不覆盖**：`a2_glfw_input.m`（要 UIKit）。它接映射层的那几行由真机构建与判据行把关。
