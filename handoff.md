# Handoff — 2026-07-01 Session

## 完成的改动

### 1. 编译性能：从 webpack 切换到 Turbopack

**文件**: `package.json`, `start.bat`

去掉了所有 `dev`/`build`/`dev:bun`/`build:bun` 脚本中的 `--webpack` 参数，让 Next.js 16 使用默认的 Turbopack 编译器。

- 原因：webpack 模式下大项目编译慢，每次切换页面/模块都要等待 compiling + rendering
- 影响：dev 模式下页面编译速度 5-10x 提升
- 注意：`next.config.mjs` 中已有的 `turbopack.root` 配置现在可以生效

### 2. 请求详情页显示上游 Key 名称（connectionName）

**文件**: 
- `open-sse/handlers/chatCore/requestDetail.js` — `buildRequestDetail` 增加 `connectionName` 字段
- `open-sse/handlers/chatCore.js` — 从 `credentials.connectionName` 提取，传入 `sharedCtx` 和所有 `buildRequestDetail` 调用
- `open-sse/handlers/chatCore/streamingHandler.js` — `handleStreamingResponse` 和 `buildOnStreamComplete` 接受并透传 `connectionName`
- `open-sse/handlers/chatCore/nonStreamingHandler.js` — `handleNonStreamingResponse` 接受并透传
- `open-sse/handlers/chatCore/sseToJsonHandler.js` — `handleForcedSSEToJson` 接受并透传
- `src/lib/db/repos/requestDetailsRepo.js` — `flushToDatabase` 的 `record` 对象中加入 `connectionName`，`getRequestDetails` 和 `getRequestDetailById` 对旧数据做 backfill
- `src/app/(dashboard)/dashboard/usage/components/RequestDetailsTab.js` — 表格新增 Account/Key 列，Drawer 详情中显示 Key 名称

**数据流**:
```
auth.js: connectionName = connection.displayName || connection.name || connection.email || connection.id
  → handleChat → handleChatCore → sharedCtx
    → buildOnStreamComplete / handleNonStreamingResponse / handleForcedSSEToJson
      → buildRequestDetail({ ..., connectionName, ... })
        → saveRequestDetail → flushToDatabase → requestDetails.data (JSON)
          → getRequestDetails → backfill 旧数据从 connectionId 查找
            → RequestDetailsTab → detail.connectionName
```

### 3. Usage by API Key 视图修复 keyName

**文件**: `src/lib/db/repos/usageRepo.js`

- `aggregateEntryToDay` 现在写入 `keyName` 到 `usageDaily.byApiKey` 条目
- `addToCounter` 支持 `keyName` 字段
- `getUsageStats` 在读取 daily 数据时自动 backfill 缺失的 `keyName`（旧数据只需回填一次）

### 4. 取消 OpenAI-compatible 等供应商的单 Key 限制

**文件**: `src/app/api/providers/route.js`

删除了创建 OpenAI-compatible、Anthropic-compatible、Custom Embedding 节点时「仅允许 1 个连接」的校验，现在允许多个 API Key 轮询。

### 5. 启用 standalone 输出

**文件**: `next.config.mjs`

取消注释 `output: "standalone"`，`next build` 后会生成 `.next/standalone/` 目录，包含最小化 Node.js 运行时，可直接拷贝部署。

### 6. 429 日配额检测机制（OpenAI/Anthropic Compatible 专用）

**文件**: 
- `src/lib/db/repos/settingsRepo.js` — `DEFAULT_SETTINGS` 新增 `provider429DailyQuota: {}`
- `open-sse/config/errorConfig.js` — 新增 `MAX_DAILY_QUOTA_COOLDOWN_MS = 24h`
- `open-sse/services/accountFallback.js` — 新增 `getNextCSTDayStartMs()` + `checkDailyQuotaMatch()`
- `src/sse/services/auth.js` — `markAccountUnavailable()` 新增 `maxCooldownMs` 参数
- `src/sse/handlers/chat.js` — 重试循环改造：429 分流日配额/临时两条路径
- `src/app/(dashboard)/dashboard/providers/[id]/page.js` — Details 卡片新增开关 + state/加载/保存 + 传 props
- `src/app/(dashboard)/dashboard/providers/[id]/CompatibleModelsSection.js` — 模型行新增 429 特征词输入框

**背景**: 某些供应商（如阿里云百炼）有两种 429：
- 日配额 429（含模型名，如 `exceeded today's quota for model X`）：该 key 当天不能再调用此模型
- 临时 429（如 `insufficient_quota`）：过一会就能恢复

**数据结构** (settings `provider429DailyQuota`):
```js
{
  "openai-compatible-xxx": {
    enabled: true,
    patterns: {
      "deepseek-ai/DeepSeek-V4-Pro": "exceeded today's quota",  // 显式特征词
      "deepseek-ai/DeepSeek-V4-Flash": "",                       // 空=匹配模型名
    }
  }
}
```

**运行时行为**:
- 开关 OFF（默认）：429 处理不变（指数退避 + 切换 key）
- 开关 ON：
  - 429 匹配特征词（或模型名）→ 锁定 key+model 到次日 CST (UTC+8) 00:05，切换其他 key
  - 429 不匹配 → 不切换 key，等待 5s 重试同一 key（最多 5 次），5 次后切换 key（不锁定）

**关键参数**:
- 次日重置时间：CST (UTC+8) 次日 00:05（5 分钟缓冲防时钟偏移）
- 临时 429 重试：5 次 × 5s 固定等待
- 日配额锁定上限：`MAX_DAILY_QUOTA_COOLDOWN_MS = 24h`（不 `MAX_RATE_LIMIT_COOLDOWN_MS = 30min` 截断）
- 适用范围：OpenAI + Anthropic Compatible provider

---

## 关键架构信息

### requestDetails 表的存储方式

- `requestDetails` 表有独立列 `id, timestamp, provider, model, connectionId, status`，外加 `data` 列（TEXT，JSON）
- **关键陷阱**：`flushToDatabase` 中的 `record` 对象是手动构造的，只包含选定的字段。**任何新增字段必须显式加入 `record` 对象**，否则会被丢弃
- `getRequestDetails` 返回的是 `parseJson(r.data, {})`，即 `record` 的 JSON 解析结果

### usageDaily 表的聚合逻辑

- `usageDaily` 是预聚合表，按日期存储 `byProvider, byModel, byAccount, byApiKey, byEndpoint` 五个维度的汇总
- `aggregateEntryToDay` 在每次 `saveRequestUsage` 时同步执行（在 better-sqlite3 的 transaction 内）
- **新增字段需要同时更新两处**：`aggregateEntryToDay`（写入路径）和 `getUsageStats`（读取路径，含 backfill）
- 7d/30d/60d 走 daily 路径，24h/today 走 history 直接查询路径

### connectionName 的来源

- `auth.js:171` 的 `getProviderCredentials` 返回 `connectionName: connection.displayName || connection.name || connection.email || connection.id`
- 对于 OpenAI-compatible 供应商的 bulk 导入 key，自动命名规则：`"Key 1"`, `"Key 2"`...
- `checkAndRefreshToken` 通过 `{ ...creds }` spread 保留 `connectionName`，token refresh 不会丢失它

### 429 日配额检测的关键函数

- `accountFallback.js:getNextCSTDayStartMs()` — 计算次日 CST 00:05 的 epoch ms（UTC+8 偏移计算）
- `accountFallback.js:checkDailyQuotaMatch(errorText, model, patterns)` — pattern 为空时用 model 名做子串匹配
- `auth.js:markAccountUnavailable(..., maxCooldownMs)` — 默认 `MAX_RATE_LIMIT_COOLDOWN_MS`(30min)；日配额传 `MAX_DAILY_QUOTA_COOLDOWN_MS`(24h)
- `chat.js` 重试循环中 `temp429RetryCount` 跟踪当前 key 的临时 429 重试次数，切换 key 时重置为 0

### 浏览器端 API Key vs 上游 Provider Key

- `usageHistory.apiKey` 存的是**客户端认证 9router 的 API Key 的原始值**
- `providerConnections.apiKey` 存的是**上游供应商的 API Key 的原始值**
- `connectionName` 是上游供应商 connection 的显示名称，用于标识 round-robin 轮询时用的是哪个 key

### 前端 Usage 页面结构

- `UsageStats.js`：Overview 视图，显示聚合统计（byModel/byAccount/byApiKey/byEndpoint）
- `RequestDetailsTab.js`：Details 视图，显示每条请求的详细记录（这是我修改的部分）
- 两者使用不同的 API：`/api/usage/stats` 和 `/api/usage/request-details`