# dsh-gbridge

零侵入的 DeepSeek Harness (DSH) Cordis 桥插件，为 **GrassBag** 原生 Android 客户端提供稳定、抗上游演进的 `/gbridge/v1` 协议面。

## 特性

- **零依赖、零补丁**：纯 Node.js 22+ 标准库实现（含内置 RFC 6455 WebSocket 服务端），无需修改 `@deepseek-ai/dsh` 源码。
- **双监听安全隔离**：
  - 远程主机：直接挂载于 DSH `webServer`（`/gbridge/v1/*` 与 `/gbridge/v1/stream`），100% 复用 DSH `connection.admit(req)` 鉴权与 30 天 Cookie。
  - Android 本机：配置 `GBRIDGE_UNIX_SOCKET` 与 `GBRIDGE_TOKEN` 后额外启动 `0600` 权限私有 Unix Domain Socket，通过内核 UID 隔离手机上其他应用。
- **单连接多路复用与断线续传**：`/gbridge/v1/stream` 支持全局递增 `seq`、2000 帧环形缓冲 `resumeFromSeq` 补帧、35ms 流式聚合与引用计数上游流管理。
- **12 大隔离域适配器 + SDUI v1 + 逃生舱换票**：通过 `ctx.typertGateway` 进程内零网络调用全部官方能力，按 `GET /gbridge/v1/capabilities` 动态发现。

## 运行与测试

```bash
# 单元测试与契约测试
npm test

# 针对真实 dsh web 的隔离端到端冒烟测试（不碰 ~/.dsh）
DSH_BIN=/path/to/dsh node scripts/live-dsh-smoke.mjs
```

## 加载方式

- **电脑/服务器远程主机**：`dsh plugin add <path-or-pkg>`（或由 GrassBag 在引导模式下远程一键安装）
- **临时挂接调试**：`dsh web --patch ./cordis.patch.yml`
