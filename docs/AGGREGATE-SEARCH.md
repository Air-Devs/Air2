# 聚合搜索（Modrinth + CurseForge 同屏）

一个界面、两个源：同一份筛选条件同时打 Modrinth 与 CurseForge，两源结果交错合并后
用同一套结果行呈现，来源由行内品牌药丸（`A2ResourceBadge`）区分。

---

## 1. 分层与调用链

```
A2AggregateSearchViewController   （UI/Screens/Download）
        │  筛选条件 → A2ContentFilter（含 offset/limit）
        ▼
A2AggregateSearchService          （Core/Addons）   ← 新增
        │  扇出两路 + 交错合并 + 单源降级
        ▼
A2ContentSource（platform = Modrinth / CurseForge）  ← 既有，未改
        ▼
A2ModrinthAPI / A2CurseForgeAPI                      ← 既有，未改
```

**没有复制任何网络代码**：聚合层只负责「扇出 + 合并 + 降级」，
每一条路仍是既有的 `A2ContentSource`（它内部才是 `A2ModrinthAPI` / `A2CurseForgeAPI`）。

---

## 2. `A2AggregateSearchService` 接口

```objc
typedef NS_ENUM(NSInteger, A2AggregateSourceMode) {
    A2AggregateSourceModeBoth = 0,
    A2AggregateSourceModeModrinth,
    A2AggregateSourceModeCurseForge,
};

@interface A2AggregateSearchOutcome : NSObject
@property (copy, readonly) NSArray<A2ContentItem *> *items;   // 已交错合并
@property (assign, readonly) NSInteger modrinthCount;         // 折叠前，判分页
@property (assign, readonly) NSInteger curseForgeCount;
@property (copy, readonly, nullable) NSError *error;          // 两路都失败才有
@property (copy, readonly, nullable) NSString *degradedReason;// 单源降级原因
@property (copy, readonly) NSArray<NSNumber *> *engagedPlatforms;
@end

- (void)searchWithFilter:(A2ContentFilter *)filter
            contentClass:(A2ContentClass)contentClass
                    mode:(A2AggregateSourceMode)mode
              completion:(void (^)(A2AggregateSearchOutcome *outcome))completion;
```

契约：
- completion **恒在主线程**、且**一定回调一次**；
- 源不可用（CurseForge 无 Key）或该源不支持本资源大类 ⇒ 等于「不参与」，
  不阻断另一路，原因写进 `degradedReason`；
- 分页判据：`hasMore = (modrinthCount >= limit || curseForgeCount >= limit)`。

---

## 3. 合并口径

- **逐条交错**：同一序号 CurseForge 在前、Modrinth 在后。
  理由：按源分块排会让第二源在翻页前完全不可见。
- **同名折叠**：键 = 标题去掉非字母数字并小写；撞键时保留下载量更高的一条，
  **位置不变**（否则翻页时列表会跳动）。
- **取不到的字段不猜**：统一模型 `A2ContentItem` 目前不带 slug / dateModified，
  所以不做「同 slug + 7 天窗口」那种时间窗折叠；宁可退化成同名 + 下载量取高。
  若后续给 `A2ContentItem` 补上这两个字段，改动点只在本类。

---

## 4. UI（`A2AggregateSearchViewController`，MD3，非液态玻璃）

- 顶部 `A2SegmentedControl`：**聚合 / Modrinth / CurseForge**（检索范围，互斥三选一）。
- `A2TextField`（填充式、紧凑 44pt）搜索名 + 搜索按钮；游戏版本可选输入。
- `A2FilterChip` 两组：加载器（全部/Fabric/Quilt/Forge/NeoForge）、排序（相关/下载量/最新）。
- 统计行：`Modrinth N · CurseForge M → 合并 K 条`，单源降级时附一行原因。
- 结果：复用 `A2ResourceResultCell`（内部即 `A2ResourceCard`，自带来源药丸），
  点击进 `A2ResourceDetailViewController`；分页用 `A2PaginationBar` + 页缓存。
- 四态：加载 / 有结果 / 空 / 错误，各走独立文案。
- 存档（World）只有 CurseForge 一家 ⇒ 进页即锁到单源并如实提示。

入口：`A2DownloadViewController` 侧栏新增「聚合」分类（**追加在末尾**，
避免平移既有的分类索引 ↔ 页面映射）。

---

## 5. 与既有单源页的分工

| 页面 | 语义 |
|---|---|
| `A2ResourceSearchViewController` | 单源搜索 + 右侧常驻筛选面板（平台互斥单选，分类随平台重取） |
| `A2AggregateSearchViewController` | 多源同搜 + 顶部筛选条（来源混排，靠药丸区分） |

后者不改造前者：前者的 `platform` 字段贯穿分类标识、Key 弹框、回退逻辑，
塞进第三种「聚合」会让每个分支都要特判；独立页面把这段特判收敛在一处。
