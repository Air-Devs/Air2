# 贡献指南

## 核心原则：禁止石山代码

Air2 对代码质量的要求是**硬性**的。合并不是看你写了多少功能，是看代码有没有让后来人难受。

### 提交前必须自查

- [ ] 没有跨层依赖（Core 不 import UI，Bridge 不含业务逻辑）
- [ ] 没有超过 400 行的文件（超过 800 行直接打回）
- [ ] 没有 `Utils2` / `ManagerNew` / `Helper` 这类命名
- [ ] 没有注释掉的死代码
- [ ] 新增目录已在 `docs/ARCHITECTURE.md` 登记
- [ ] 新增依赖已在 `docs/DEPENDENCIES.md` 登记
- [ ] 本地 `make lint` 通过

---

## 开发流程

```bash
# 1. 从 dev 切分支
git checkout dev && git pull
git checkout -b feat/your-feature

# 2. 开发，随时自检
make lint

# 3. 提交
git commit -m "feat(scope): 一句话说清做了什么"

# 4. 推送并发起 PR 到 dev
```

## 提交信息规范

```
<类型>(<范围>): <描述>

类型：feat | fix | refactor | perf | docs | test | chore | build
范围：app | ui | core | bridge | natives | java | ci | docs
```

示例：
- `feat(core): 下载引擎支持分片断点续传`
- `fix(natives): 修复 surface 重建时的层泄漏`
- `refactor(ui): 拆分版本列表页为独立组件`

**描述必须说清「做了什么」，不写「优化代码」这种废话。**

---

## 代码要求

### Swift

- 优先值类型（`struct`）而非引用类型
- 并发用 `async/await`，不用回调地狱
- 可失败的操作用 `throws`，不用返回 `Optional` 表示错误
- 面向协议编程，具体类型只在装配点出现

### Objective-C / C

- 类名前缀 `A2`，C 函数前缀 `a2_`
- 头文件必须能独立编译（自带 include）
- 不在原生层出现业务概念（"版本""账号"等）

### 注释

只写**为什么**，不写**是什么**。

```swift
// 好：解释非显然的决策
// Metal 层必须在 JVM 启动前创建，否则 GLFW 拿不到 valid drawable
createMetalLayer()

// 差：复述代码
// 创建 Metal 层
createMetalLayer()
```

---

## 目录变更

新增目录 = 架构变更。必须在 PR 描述中说明：

1. 为什么现有目录放不下
2. 职责边界是什么
3. 依赖方向如何保证无环

未在 `docs/ARCHITECTURE.md` 登记的目录，CI 的 `lint` job 会直接失败。
