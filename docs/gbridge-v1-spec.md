# GrassBag · `/gbridge/v1` 完整协议契约规范（Phase 2 冻结草案）

> **包名**：`dsh-gbridge`（Cordis 插件名：`gbridge`）  
> **路由前缀**：`/gbridge/v1/*`（WebSocket：`/gbridge/v1/stream`）  
> **核心技术基石**：经实测核对官方 DSH（`0.1.7-rc.2` / `0.2.2-rc.x`）源码，DSH 内部暴露了标准 Cordis 服务 **`ctx.typert`**（运行时枚举全部 `namespace/method`）与 **`ctx.typertGateway`**（进程内零网络直接调用任意 Typert RPC 与流），配合 `ctx.webServer` 与 `ctx.on(...)` 即可实现 **100% 零补丁覆盖 `dsh web` 全部能力**！

---

## 一、接入层、鉴权与传输安全

### 1.1 双监听模式（同一份桥代码，自动适配本机与远程）

| 部署形态 | 监听载体 | 鉴权方式 | 说明 |
| --- | --- | --- | --- |
| **Android 本机容器** | 启动环境变量 `GBRIDGE_UNIX_SOCKET=/run/gbridge/bridge.sock`（`0600` 权限 UDS） | `Authorization: Bearer <GBRIDGE_TOKEN>`（每次启动随机 256-bit 令牌，通过环境变量/0600 文件注入） | **内核 UID 级物理隔离**，手机上其他 App 连 Socket 文件都打不开；同时仍挂载在 `webServer` 上供隐蔽 WebView 换票使用 |
| **远程主机（PC / Mac / 服务器 / AVF）** | 直接挂载在 `dsh web` 的 `ctx.webServer` 上（前缀 `/gbridge/v1`） | **完全复用 DSH 原生鉴权**：`ctx.get('connection').requestRejection(req)`（支持 30 天 `dsh-auth-*` Cookie 及 Host/Origin 守卫） | 无需多开端口！用户直接输入原本的局域网/公网 `dsh web` 地址即可无缝走 `/gbridge/v1` |

> [!IMPORTANT]
> **防裸露守卫铁律**：只要 `ctx.get('connection')` 尚未就绪或 `requestRejection(req)` 返回非 `undefined`（如 401/403/503），`/gbridge/v1/*` 的所有 HTTP 与 WS Upgrade 请求必须**第一时间拒绝**，绝不允许未认证访问。

### 1.2 统一 HTTP 响应与错误信封

- 所有 JSON 响应强制带 `Cache-Control: no-store`、`X-Content-Type-Options: nosniff`。
- 成功响应：`200 OK` 直接返回强类型 JSON 对象（带 `v: 1` 用于顶层关键契约校验，支持 `ETag` / `304 Not Modified` 节省流量）。
- 失败响应统一信封（永不把 HTML 报错页吐给客户端）：
  ```json
  {
    "error": {
      "code": "domain/machine_code",
      "message": "人类可读错误说明",
      "retryable": false,
      "details": {}
    }
  }
  ```
- 稳定错误码规范：`gbridge/unauthorized` (401)、`gbridge/forbidden` (403)、`gbridge/not_found` (404)、`gbridge/domain_unavailable` (503，某适配器熔断时)、`gbridge/upstream_error` (502，透传 DSH 原始错误码到 `details.upstreamCode`)、`gbridge/validation_error` (400)。

---

## 二、能力协商（`GET /gbridge/v1/capabilities`）

这是客户端区分**满血模式**与**引导模式**、以及在 DSH 跨版本演进时**按模块优雅降级**的唯一入口：

```json
{
  "v": 1,
  "bridgeVersion": "0.1.0",
  "dshVersion": "0.2.2-rc.5",
  "bootId": "uuid-per-process-boot",
  "host": {
    "platform": "linux",
    "arch": "arm64",
    "isLocalAndroid": true,
    "homeDir": "/root"
  },
  "transport": {
    "wsPath": "/gbridge/v1/stream",
    "compression": ["permessage-deflate"],
    "coalesceMs": 35,
    "replayCapacity": 2000
  },
  "domains": {
    "chat":        { "ok": true,  "features": ["steer", "queue", "fork", "export", "search", "feedback"] },
    "files":       { "ok": true,  "features": ["changes", "upload", "officeToPdf"] },
    "terminal":    { "ok": true,  "features": ["multiTab", "resize"] },
    "subagents":   { "ok": true,  "features": ["tree", "prompt", "interrupt", "agentTeam", "worktree"] },
    "jobs":        { "ok": true },
    "schedule":    { "ok": true },
    "plugins":     { "ok": true,  "features": ["market", "install", "inventory", "cordisDynamic"] },
    "settings":    { "ok": true,  "features": ["schemastery", "presets", "accounts", "appAuth"] },
    "experimental":{ "ok": true,  "features": ["cotTranslation", "speech", "stats", "forge", "liveshare"] },
    "sdui":        { "ok": true,  "version": 1 },
    "webTicket":   { "ok": true },
    "phoneTools":  { "ok": false, "reason": "not-android-host" }
  }
}
```

- **核心规则**：客户端**不得缓存跨 `bootId` 的能力表**；未知的 `domains` 键与未知的 `features` 字符串一律宽容忽略；`ok: false` 仅隐藏/灰置对应入口并附带 `reason`，不影响其他域。

---

## 三、统一多路复用 WebSocket（`WS /gbridge/v1/stream`）

单连接承载全部实时流，彻底消灭手机弱网下多条 WS 竞态断连。

### 3.1 连接握手与游标续传（`resumeFromSeq`）

1. **客户端首帧 `hello`**：
   ```json
   {
     "op": "hello",
     "v": 1,
     "clientId": "grassbag-device-uuid",
     "lastBootId": "prev-boot-id-or-null",
     "resumeFromSeq": 1042,
     "coalesceMs": 35
   }
   ```
2. **服务端回应 `welcome`**：
   ```json
   {
     "op": "welcome",
     "v": 1,
     "bootId": "current-boot-id",
     "currentSeq": 1058,
     "resumed": true,
     "replayedCount": 16,
     "heartbeatMs": 20000
   }
   ```
   - 若 `lastBootId == bootId` 且 `resumeFromSeq` 仍在环形缓冲窗口内 → `resumed: true`，服务端立刻顺序回放 `1043..1058` 丢帧！
   - 若服务已重启或断线太久超出缓冲窗口 → `resumed: false`，客户端收到后只对当前打开的活跃页面静默拉一次增量快照，无需重建整个 App 状态！

### 3.2 多路复用频道（`sub` / `unsub`）与帧词汇

客户端按当前打开的页面**动态按需订阅**频道，离页即退订（省电省流量）：

| 频道标识 (`channel`) | 触发订阅时机 | 推送事件类型 |
| --- | --- | --- |
| `host` | 连接建立默认订阅 | `session.changed`、`workspace.changed`、`interaction.requested`（审批/提问/Cordis 运行确认）、`interaction.resolved`、`plugins.changed`、`schedule.changed`、`auth.expired` |
| `session:<sessionId>` | 进入对应聊天页 | `turn.snapshot`、`turn.delta`（35ms 聚合的文本/思考/工具参数增量）、`turn.tool_update`、`turn.completed`、`projection.updated`（`todos`/`plan`/`goal`/`contextPressure`/`subagents`/`queue`） |
| `terminal:<termId>` | 打开终端页签 | `term.data`（支持 Base64 或二进制帧）、`term.exit`（客户端上行发 `op: "term.input"` / `"term.resize"`） |
| `job:<jobId>` | 点开后台任务详情 | `job.output`、`job.done` |
| `install:<reqId>` | 安装插件或工具包 | `install.log`、`install.state`、`install.done` |

**上行帧词汇**：`hello`、`sub`、`unsub`、`ack`（确认已消费的最大 `seq`）、`ping`、`term.input`、`term.resize`  
**下行帧词汇**：`welcome`、`event`（带 `seq`、`channel`、`type`、`data`）、`delta`（聚合流式增量）、`pong`、`error`

---

## 四、12 大功能域完整契约（零补丁映射官方 `typertGateway`）

桥内部通过**薄适配调用器 `callGateway(endpoint, args)`**（走 `ctx.typertGateway.invoke`）+ 鸭子类型探测来对接 DSH，彻底免疫大部分内部重构：

| # | 域 | `/gbridge/v1` 稳定接口 | 底层对接的官方 DSH 能力（零补丁） |
| --- | --- | --- | --- |
| **1** | **会话与聊天** (`chat`) | `GET/POST /sessions`、`GET /sessions/search`、`PATCH/DELETE /sessions/:id`、`GET /sessions/:id/turns?beforeTurn=&limit=`、`GET /sessions/:id/tools/:callId`、`POST /sessions/:id/messages`（`auto`/`steer`/`queue`/`interrupt`）、`PATCH /sessions/:id/queue`、`POST /sessions/:id/cancel`、`POST /sessions/:id/fork`、`POST /sessions/:id/commands`、`GET /sessions/:id/export`、`PUT/DELETE /sessions/:id/feedback` | `session/{list,create,rename,search,page,follow,prompt,updateQueue,cancel,fork,projections}`、`commands/execute`、`session.export`、`messageFeedback/*` |
| **2** | **输入辅助与附件** (`composer`) | `GET /sessions/:id/references?q=`、`GET /commands`、`GET /skills`、`POST /uploads`（支持分块流式二进制上传）、`GET /attachments/:id` | `fileReferences/list`、`sessionReferenceResolver/candidates`、`skills/list`、`fileUploads/upload`、`session/uploadFileBinary`、`session/attachment` |
| **3** | **交互审批与目标** (`interactions`) | `GET /interactions/pending`、`POST /interactions/:id/respond`（统一结算工具审批 / 提问卡 / 计划审阅 / Cordis 运行确认）、`GET/PUT /sessions/:id/permission`、`GET/POST/PATCH/DELETE /sessions/:id/goals` | Cordis `waterfall` (`approval/request`、`user-questions/request`) + `cordis/request-run` + `userQuestions/answer` + `permissionPresets/catalog` + `goals/*` |
| **4** | **工作区与文件** (`files`) | `GET/POST/PATCH/DELETE /workspaces`、`POST /workspaces/:id/pin`、`GET /fs/browse?path=`、`POST /fs/mkdir`、`GET /workspaces/:id/files/tree`、`GET /workspaces/:id/files/read`、`GET /workspaces/:id/files/changes`、`POST /workspaces/:id/files/office-preview` | `workspace/{create,rename,delete,pinSession,unpinSession,archiveSession,unarchiveSession,insertBefore}`、`directoryPicker/*`、`workspaceFiles/{list,read,readBytes,stat,changes}`、`officeToPdf/render` |
| **5** | **终端** (`terminal`) | `GET /terminals`、`GET /terminals/shells`、`POST /terminals`、`PATCH/DELETE /terminals/:id`（数据流走 WS `terminal:<id>`） | `terminal/{list,shells,create,attach,follow,write,resize,rename,retain,close,environment}` |
| **6** | **子代理、团队与任务** (`subagents` & `jobs`) | `GET /sessions/:id/subagents`、`POST /subagents/:id/prompt`、`POST /subagents/:id/interrupt`、`GET /sessions/:id/team`、`GET /sessions/:id/trajectory`、`GET /jobs`、`POST /jobs/:id/kill` | `subagents/{prompt,interruptByParent}`、`session/projections`（子代理/团队/轨迹投影）、`job/kill` + `job/follow` |
| **7** | **自动化任务** (`schedule`) | `GET /schedules`、`GET /schedules/:id/history`、`PATCH/DELETE /schedules/:id`、`POST /schedules/:id/run` | `schedule/{catalog,history,update,edit,delete,run}` |
| **8** | **账号与模型渠道** (`accounts`) | `GET /models`、`PUT /sessions/:id/model`、`GET /providers`、`GET/PUT/DELETE /credentials`、`GET /auth/subscriptions`、`POST /auth/subscriptions/begin\|answer\|poll\|cancel\|signout`、`GET /auth/usage` | `session/{modelCatalog,selectModel}`、`llm/{listProviders,listConfigurableProviders}`、`credentials/*`、`appAuth/*` |
| **9** | **插件与动态 Cordis** (`plugins`) | `GET /plugins/bundles`、`GET /plugins/entries`、`GET /plugins/inventory`、`GET /plugins/registries`、`POST /plugins/inspect`、`POST /plugins/install`、`POST /plugins/install/:reqId/cancel`、`PATCH /plugins/bundles/:name`、`PATCH /plugins/entries/:id`、`DELETE /plugins/bundles/:name`、`GET /cordis/dynamic`、`POST /cordis/dynamic/:id/stop\|undefine` | `pluginManager/*`、`pluginInventory/list`、`dynamicCordisRunner/*` |
| **10** | **设置与预设** (`settings`) | `GET /settings/schema`（完整 Schemastery JSON + 多语言文案 + 当前值）、`PATCH /settings`、`GET/POST/PUT /presets`、`POST /presets/select` | `settings/{describe,mutate,update}`、`agentPresets/{list,read,select}` |
| **11** | **实验特性** (`experimental`) | `POST /tools/translate-cot`、`GET/PUT /speech/config`、`POST /speech/transcribe`、以及 `stats`/`forge`/`liveshare` 统一经 SDUI 暴露 | `cotTranslation/{limits,translate}`、`speech/*` 及实验包动态探测 |
| **12** | **总览、SDUI & 逃生舱** (`overview` / `sdui` / `webTicket`) | `GET /overview`（单次聚合设置概览卡与抽屉身份栏所需的账号/余额/主机/待审批摘要）、`GET /sdui/surfaces`、`GET /sdui/views/:viewId`、`POST /sdui/action`、`POST /web-ticket`（生成 60 秒一次性免登路径票据供隐蔽 WebView 使用） | 桥内建聚合缓存 + SDUI 注册表 + 复用 `dsh-client-connection` 会话令牌 |

---

## 五、规范化对话视图模型（核心防重构契约）

桥插件在服务端把 DSH 原始流规整成以下冻结结构，保证上游改存储格式时 Flutter 聊天页**一行代码都不用动**：

```typescript
interface NormalizedTurn {
  turnId: string;
  seqStart: number;
  seqEnd: number;
  status: "streaming" | "completed" | "cancelled" | "error";
  userMessage?: {
    id: string;
    text: string;
    attachments: AttachmentRef[];
    references: EntityRef[];
    maskedRanges?: SecretRange[];   // 凭据遮挡区间
    createdAt: number;
  };
  steps: Array<
    | { kind: "reasoning"; id: string; text: string; collapsedPreview: string; durationMs?: number }
    | { kind: "tool"; callId: string; name: string; title: string; status: "pending" | "running" | "ok" | "error"; summary: string; hasFullOutput: boolean; diffSummary?: DiffFileStat[]; subagentSessionId?: string; durationMs?: number }
    | { kind: "action_card"; id: string; sdui: SduiNode }
    | { kind: "notice"; level: "info" | "warn" | "error"; text: string }
  >;
  assistantText: string;            // 最终回复正文（折叠过程后永远留在外层）
  deliverables: DeliverableRef[];   // 产物交付文件卡
  usage?: { inputTokens: number; outputTokens: number; cacheReadTokens?: number; cost?: number; durationMs?: number };
}
```

---

## 六、最小 SDUI v1 声明式原生组件契约

任何未来新增的 DSH 功能或桥插件页面，只需下发 JSON 树，老版本 GrassBag 即可直接用 Flutter 原生组件渲染（支持 `liquid_glass_widgets` 风格卡片容器）：

```typescript
type SduiNode =
  | { type: "column" | "row"; gap?: number; children: SduiNode[] }
  | { type: "card" | "section"; title?: string; subtitle?: string; collapsible?: boolean; collapsed?: boolean; children: SduiNode[] }
  | { type: "tabs"; items: Array<{ id: string; label: string; child: SduiNode }> }
  | { type: "text"; value: string; style?: "title" | "body" | "caption" | "mono"; tone?: "default" | "muted" | "accent" | "warn" | "danger" }
  | { type: "markdown"; value: string }
  | { type: "code_diff"; path: string; language?: string; diff: string }
  | { type: "metric"; label: string; value: string; delta?: string; tone?: "default" | "good" | "warn" | "bad" }
  | { type: "kv_list"; items: Array<{ key: string; value: string; copyable?: boolean }> }
  | { type: "progress"; value: number; max?: number; label?: string }
  | { type: "badge"; label: string; tone?: "default" | "accent" | "good" | "warn" | "danger" }
  | { type: "table"; columns: string[]; rows: string[][] }
  | { type: "chart"; chartType: "line" | "bar" | "pie"; series: Array<{ name: string; points: Array<{ x: string; y: number }> }> }
  | { type: "schema_form"; schema: Record<string, unknown>; values: Record<string, unknown>; submitActionId: string }
  | { type: "actions"; items: Array<{ id: string; label: string; style?: "primary" | "secondary" | "danger"; confirmText?: string; payload?: Record<string, unknown> }> };
```

用户点击按钮或提交表单 → 客户端发 `POST /gbridge/v1/sdui/action`（`{ viewId, actionId, payload }`）→ 桥返回 `{ toast?, patchView?, navigateToSessionId? }`。

---

## 七、极简「未装桥引导模式（Bootstrap Mode）」契约

仅当连上远程 `dsh web` 且 `GET /gbridge/v1/capabilities` 返回 `404` 时启用。客户端**严格限定只依赖上游以下 6 组最底层稳定接口**，代码量控制在 300 行以内：

1. **认证换 Cookie**：`GET /?token=<token>`（换 30 天 `dsh-auth-*` Cookie）
2. **远程一键装桥**：`POST /api/pluginManager/installBundle` + `POST /api/pluginManager/waitForInstall`（安装 `dsh-gbridge` 包或自定义 `.tgz`/Git spec，装完自动重探 `/gbridge/v1/capabilities` 秒切满血！）
3. **基础会话列表**：`POST /api/session/list` + `POST /api/session/create`
4. **基础对话流**：`WS /api/remote.mux`（开 `$events` + `session/follow`）
5. **基础发消息与停止**：`POST /api/session/prompt` + `POST /api/session/cancel`
6. **基础审批应答 & 官方 WebUI**：`POST /api/$events/result` + 携带同源 Cookie 直接打开官方 WebView

---

## 八、零补丁手机操控原生工具桥（仅 Android 本机激活）

- 当环境变量 `GBRIDGE_PHONE_SOCKET` 与 `GBRIDGE_PHONE_TOKEN` 存在且用户在 App 打开手机操控开关时，`dsh-gbridge` 直接在 Cordis 内核里注册手机操控工具集（`phone_screen`、`phone_tap`、`phone_type`、`phone_open`、`phone_intent`、`phone_handoff`、`phone_shell`）。
- 每次工具被 Agent 调用时，`dsh-gbridge` 直接从 Cordis 工具上下文读取真实 `sessionId`、`turnId` 与 `AbortSignal` 随请求发往 Kotlin 原生 `SafetyGate` + 无障碍/Shizuku 执行器；同时通过 `ctx.on('session/event')` 监听 `turn/end` 主动通知 Kotlin 收尾悬浮条与任务状态——**彻底零补丁，完全不需要修改 DSH 任何源码！**
