import { homedir, hostname, arch, platform } from 'node:os';
import { randomBytes } from 'node:crypto';
import { readFileSync, realpathSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { GbridgeError, readJsonBody, sendJson } from '../http-util.js';
import { logSuppressed } from '../diagnostics.js';

const TICKET_TTL_MS = 60_000;
let cachedDiscoveredDshVersion = null;

export function detectDshVersion(ctx) {
  try {
    const envVer = process.env.DSH_VERSION?.trim();
    if (envVer) return envVer;
    if (cachedDiscoveredDshVersion) return cachedDiscoveredDshVersion;
    if (process.argv[1]) {
      const realEntry = realpathSync(process.argv[1]);
      for (const rel of ['../package.json', '../../package.json']) {
        try {
          const pkg = JSON.parse(readFileSync(resolve(dirname(realEntry), rel), 'utf8'));
          if (pkg?.name === '@deepseek-ai/dsh' && typeof pkg?.version === 'string') {
            cachedDiscoveredDshVersion = pkg.version;
            return pkg.version;
          }
        } catch (_missingPkg) {
          // Candidate relative package.json path not present in this layout.
        }
      }
    }
    const loader = ctx.get?.('loader');
    for (const entry of loader?.entries?.() ?? []) {
      const pkg = entry?.options?.name;
      if (pkg === '@deepseek-ai/dsh' && entry?.version) {
        const ver = String(entry.version);
        cachedDiscoveredDshVersion = ver;
        return ver;
      }
    }
  } catch (err) {
    logSuppressed(ctx?.logger, 'meta', err, { level: 'debug', detail: 'detectDshVersion failed' });
  }
  return 'unknown';
}

export function buildCapabilities({ ctx, gateway, bridgeVersion, bootId, phoneState, isLocalAndroid, mode } = {}) {
  const has = (ep) => gateway.has(ep);
  const featuresOf = (pairs) => pairs.filter(([, ok]) => ok).map(([name]) => name);

  const chatFeatures = featuresOf([
    ['steer', has('session/prompt')],
    ['queue', has('session/updateQueue')],
    ['fork', has('session/fork')],
    ['export', has('session.export')],
    ['search', has('session/search')],
    ['feedback', has('messageFeedback/put')],
    ['commands', has('commands/execute')],
    ['skills', has('skills/list')],
  ]);

  const filesFeatures = featuresOf([
    ['workspaces', has('workspace/create')],
    ['browse', true],
    ['changes', has('workspaceFiles/changes')],
    ['upload', has('fileUploads/upload') || has('session/uploadFileBinary')],
    ['officeToPdf', has('officeKit/render') || has('officeToPdf/render')],
  ]);

  const subagentFeatures = featuresOf([
    ['prompt', has('subagents/prompt')],
    ['interrupt', has('subagents/interruptByUser') || has('subagents/interruptByParent')],
    ['projections', has('session/projections')],
  ]);

  const pluginFeatures = featuresOf([
    ['bundles', has('pluginManager/listBundles')],
    ['install', has('pluginManager/installBundle')],
    ['registries', has('pluginManager/registries')],
    ['market', has('pluginMarket/listIndexes')],
    ['mcp', has('mcpManager/watch') || has('mcpManager/probe')],
    ['inventory', has('pluginInventory/list')],
    ['cordisDynamic', has('dynamicCordisRunner/inventory')],
  ]);

  const settingsFeatures = featuresOf([
    ['schemastery', has('settings/describe')],
    ['presets', has('agentPresets/list')],
    ['models', has('session/modelCatalog')],
    ['providers', has('llm/listProviders') || has('llm/listConfigurableProviders')],
    ['credentials', has('credentials/describe')],
    ['account', has('account/getState')],
    ['webProviders', has('web/listProviders')],
    ['appAuth', has('appAuth/list')],
  ]);

  const experimentalFeatures = featuresOf([
    ['cotTranslation', has('cotTranslation/translate')],
    ['speech', has('speech/catalog') || has('speech/transcribe')],
  ]);

  return {
    v: 1,
    bridgeVersion,
    dshVersion: detectDshVersion(ctx),
    bootId,
    host: {
      name: hostname(),
      platform: platform(),
      arch: arch(),
      isLocalAndroid: Boolean(isLocalAndroid),
      homeDir: homedir(),
    },
    transport: {
      wsPath: '/gbridge/v1/stream',
      coalesceMs: 35,
      replayCapacity: 2000,
    },
    domains: {
      chat: { ok: has('session/list') && has('session/prompt'), features: chatFeatures },
      files: { ok: has('workspaceFiles/list') || has('directoryPicker/list'), features: filesFeatures },
      terminal: { ok: has('terminal/list') || has('terminal/create'), features: has('terminal/resize') ? ['multiTab', 'resize'] : ['multiTab'] },
      subagents: { ok: has('subagents/prompt') || has('session/projections'), features: subagentFeatures },
      jobs: { ok: has('job/kill') || has('job/follow') },
      schedule: { ok: has('schedule/catalog') },
      plugins: { ok: has('pluginManager/listBundles') || has('pluginManager/listPlugins'), features: pluginFeatures },
      settings: { ok: has('settings/describe'), features: settingsFeatures },
      experimental: { ok: experimentalFeatures.length > 0, features: experimentalFeatures },
      sdui: { ok: true, version: 1 },
      webTicket: { ok: mode !== 'lan' && ctx.get?.('webServer') !== undefined },
      phoneTools: { ok: Boolean(phoneState?.active), reason: phoneState?.reason ?? 'disabled' },
    },
    endpointsCount: gateway.listEndpoints().length,
  };
}

export function registerMetaDomain(router, { ctx, gateway, hub, sdui, bridgeVersion, bootId, phoneState, isLocalAndroid }) {
  // Register built-in Host Inspector SDUI surface as live proof of SDUI v1.
  sdui.register({
    id: 'host-diagnostics',
    title: '主机运行状态',
    subtitle: 'DSH 能力与 gbridge 通道诊断',
    icon: 'pulse',
    placement: 'settings',
    order: 10,
    render: () => {
      const caps = buildCapabilities({ ctx, gateway, bridgeVersion, bootId, phoneState, isLocalAndroid });
      const enabledDomains = Object.entries(caps.domains).filter(([, d]) => d.ok).length;
      return {
        type: 'column',
        gap: 12,
        children: [
          {
            type: 'row',
            gap: 12,
            children: [
              { type: 'metric', label: 'DSH 版本', value: caps.dshVersion },
              { type: 'metric', label: '可用域', value: `${enabledDomains}/12`, tone: 'good' },
              { type: 'metric', label: '已发现 RPC', value: String(caps.endpointsCount) },
            ],
          },
          {
            type: 'card',
            title: '宿主机信息',
            children: [
              {
                type: 'kv_list',
                items: [
                  { key: '主机名', value: caps.host.name, copyable: true },
                  { key: '平台', value: `${caps.host.platform}/${caps.host.arch}` },
                  { key: 'gbridge 版本', value: caps.bridgeVersion },
                  { key: 'Boot ID', value: caps.bootId, copyable: true },
                  { key: 'WS 活跃客户端', value: String(hub.clients.size) },
                  { key: '待处理交互', value: String(hub.pendingInteractions.size) },
                ],
              },
            ],
          },
        ],
      };
    },
  });

  router.get('/capabilities', async (_req, res, { mode } = {}) => {
    sendJson(res, 200, buildCapabilities({ ctx, gateway, bridgeVersion, bootId, phoneState, isLocalAndroid, mode }));
  });

  // Single-request aggregate for Settings OverviewCard & Drawer IdentityBar.
  router.get('/overview', async (_req, res, { peer }) => {
    const overview = {
      v: 1,
      bootId,
      bridgeVersion,
      dshVersion: detectDshVersion(ctx),
      host: {
        name: hostname(),
        platform: platform(),
        arch: arch(),
        isLocalAndroid: Boolean(isLocalAndroid),
        homeDir: homedir(),
      },
      pendingInteractionsCount: hub.pendingInteractions.size,
      activeStreamsCount: hub.upstreamStreams.size,
      account: null,
      sessionsCount: null,
    };

    const tasks = [];
    if (gateway.has('appAuth/usage')) {
      tasks.push(gateway.call('appAuth/usage', {}, { peer }).then((u) => { overview.account = u; }).catch(() => {}));
    } else if (gateway.has('account/getState')) {
      tasks.push(gateway.call('account/getState', {}, { peer }).then((s) => { overview.account = s; }).catch(() => {}));
    }
    if (gateway.has('session/list')) {
      tasks.push(gateway.call('session/list', {}, { peer }).then((list) => {
        const items = Array.isArray(list)
          ? list
          : (Array.isArray(list?.items) ? list.items : (Array.isArray(list?.sessions) ? list.sessions : null));
        if (items) overview.sessionsCount = items.length;
      }).catch(() => {}));
    }
    await Promise.allSettled(tasks);
    sendJson(res, 200, overview);
  });

  // SDUI v1 endpoints
  router.get('/sdui/surfaces', async (_req, res) => {
    sendJson(res, 200, { v: 1, surfaces: sdui.listSurfaces() });
  });

  router.get('/sdui/views/:viewId', async (_req, res, { params, searchParams, peer }) => {
    const view = await sdui.renderView(params.viewId, {
      sessionId: searchParams.get('sessionId') || undefined,
      peer,
    });
    sendJson(res, 200, view);
  });

  router.post('/sdui/action', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    if (typeof body.viewId !== 'string' || typeof body.actionId !== 'string') {
      throw new GbridgeError(400, 'gbridge/validation_error', 'viewId and actionId are required');
    }
    const result = await sdui.invokeAction(body.viewId, body.actionId, body.payload, { peer });
    sendJson(res, 200, { v: 1, ...result });
  });

  // Official WebUI Escape Hatch ticket
  router.post('/web-ticket', async (req, res, { mode } = {}) => {
    if (mode === 'lan') {
      throw new GbridgeError(501, 'gbridge/web_unavailable_on_lan_bridge', 'Desktop LAN Bridge (:3081) is an API-only bridge; launch `dsh web` for Official WebUI');
    }
    const body = await readJsonBody(req);
    const webServer = ctx.get?.('webServer');
    if (!webServer) {
      throw new GbridgeError(503, 'gbridge/web_unavailable', 'DSH webServer is not mounted on this host');
    }
    const connection = ctx.get?.('connection');
    // On Android UDS (`mode === 'uds'`), Host header is synthetic `localhost` (port 80) — always use webServer origin!
    // Only trust X-Forwarded-* headers when DSH explicitly allows remote reverse-proxy authorities,
    // and strictly validate host[:port] syntax to prevent host-header injection leaking DSH launch tokens.
    const strictHostRe = /^(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+)(:\d{1,5})?$/;
    const trustForwarded = Boolean(connection?.allowsRemoteAuthorities);
    const rawXfProto = trustForwarded ? String(req.headers['x-forwarded-proto'] || '').split(',')[0].trim().toLowerCase() : '';
    const xfProto = rawXfProto === 'http' || rawXfProto === 'https' ? rawXfProto : '';
    const rawXfHost = trustForwarded ? String(req.headers['x-forwarded-host'] || '').split(',')[0].trim() : '';
    const rawHostHeader = String(req.headers.host || '').trim();
    const candidateHost = (rawXfHost && strictHostRe.test(rawXfHost))
      ? rawXfHost
      : (rawHostHeader && strictHostRe.test(rawHostHeader) ? rawHostHeader : '');
    let baseUrl;
    if (mode !== 'uds' && candidateHost && !candidateHost.includes('gbridge.local')) {
      const proto = xfProto || (req.socket?.encrypted ? 'https' : 'http');
      const constructed = `${proto}://${candidateHost}`;
      try {
        const parsed = new URL(constructed);
        const defaultPort = parsed.protocol === 'https:' ? '443' : '80';
        const effectiveParsedHost = `${parsed.hostname}:${parsed.port || defaultPort}`.toLowerCase();
        const candLower = candidateHost.toLowerCase();
        const candWithDefault = /:\d+$/.test(candLower) && !candLower.endsWith(']')
          ? candLower
          : `${candLower}:${defaultPort}`;
        if (!parsed.username && !parsed.password && parsed.pathname === '/' && effectiveParsedHost === candWithDefault) {
          baseUrl = `${parsed.protocol}//${parsed.host}`;
        }
      } catch (err) {
        logSuppressed(ctx?.logger, 'meta', err, { level: 'debug', detail: 'rejected invalid candidateHost for web-ticket' });
      }
    }
    if (!baseUrl) {
      if (typeof webServer.getOrigin === 'function') {
        baseUrl = webServer.getOrigin();
      } else {
        const rawHost = webServer.host || '127.0.0.1';
        const normalizedHost = rawHost === '0.0.0.0' || rawHost === '::'
          ? '127.0.0.1'
          : (rawHost.includes(':') && !rawHost.startsWith('[') ? `[${rawHost}]` : rawHost);
        baseUrl = `http://${normalizedHost}:${webServer.port}`;
      }
    }
    let authenticatedUrl = typeof connection?.authenticatedUrl === 'function'
      ? connection.authenticatedUrl(baseUrl)
      : baseUrl;
    const sessionId = typeof body.sessionId === 'string' && body.sessionId.trim() ? body.sessionId.trim() : null;
    if (sessionId) {
      try {
        const u = new URL(authenticatedUrl);
        u.hash = `/sessions/${encodeURIComponent(sessionId)}`;
        authenticatedUrl = u.toString();
      } catch (err) {
        logSuppressed(ctx?.logger, 'meta', err, { level: 'warn', detail: 'failed to append session hash to web-ticket URL' });
      }
    }

    const ticket = randomBytes(24).toString('base64url');
    const expiresAt = Date.now() + TICKET_TTL_MS;

    sendJson(res, 200, {
      v: 1,
      ticket,
      expiresAt,
      authenticatedUrl,
      sessionId,
    });
  });
}
