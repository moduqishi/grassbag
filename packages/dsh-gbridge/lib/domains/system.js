import { GbridgeError, readJsonBody, sendJson } from '../http-util.js';
import { detectDshVersion } from './meta.js';

const DEFAULT_CREDENTIAL_REFS = [
  'DEEPSEEK_API_KEY',
  'OPENAI_API_KEY',
  'ANTHROPIC_API_KEY',
  'GEMINI_API_KEY',
  'OPENROUTER_API_KEY',
  'GOOGLE_API_KEY',
  'TAVILY_API_KEY',
  'EXA_API_KEY',
];

function parseSemver(v) {
  const m = String(v || '').trim().replace(/^v/, '').match(/^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$/);
  if (!m) return null;
  return {
    major: Number(m[1]),
    minor: Number(m[2]),
    patch: Number(m[3]),
    pre: m[4] || null,
  };
}

function compareSemver(a, b) {
  const pa = parseSemver(a);
  const pb = parseSemver(b);
  if (!pa || !pb) return String(a || '').localeCompare(String(b || ''));
  if (pa.major !== pb.major) return pa.major - pb.major;
  if (pa.minor !== pb.minor) return pa.minor - pb.minor;
  if (pa.patch !== pb.patch) return pa.patch - pb.patch;
  if (!pa.pre && !pb.pre) return 0;
  if (!pa.pre) return 1; // release > prerelease
  if (!pb.pre) return -1;
  return pa.pre.localeCompare(pb.pre, undefined, { numeric: true });
}

function pickLocalizedText(val, fallback = '') {
  if (typeof val === 'string') return val;
  if (val && typeof val === 'object') {
    return String(val.zh ?? val['zh-CN'] ?? val.en ?? Object.values(val)[0] ?? fallback);
  }
  return fallback;
}

const BUILTIN_SECTION_NAMESPACES = {
  general: ['ui-chat', 'ui-conversation', 'ui-theme', 'locale', 'session-log-deepseek', 'permission', 'agent-preset-registry', 'ui-settings-account'],
  models: ['agent-default-model', 'llm-deepseek', 'llm-deepseek-account', 'llm-pi-ai'],
  'web-search': ['web', 'web-deepseek-api', 'web-search-deepseek'],
  'agent-runtime': ['subagent', 'subagent-model-selection-settings', 'agent-loop', 'bash-sandbox'],
  mcp: ['mcp-manager'],
  hidden: ['ui-settings', 'ui-settings-general'],
};

const KNOWN_NS_SET = new Set(Object.values(BUILTIN_SECTION_NAMESPACES).flat());

async function readFirstStreamFrame(gateway, endpoint, args, peer, timeoutMs = 1500) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const iterable = await gateway.openStream(endpoint, args, { signal: controller.signal, peer });
    for await (const frame of iterable) {
      controller.abort();
      return frame;
    }
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export function registerSystemDomain(router, { ctx, gateway }) {
  // ---------------- Accounts, Models & Providers ----------------
  router.get('/models', async (_req, res, { searchParams, peer }) => {
    const args = searchParams.get('sessionId') ? { sessionId: searchParams.get('sessionId') } : {};
    const [catalog, providers, configurable] = await Promise.allSettled([
      gateway.call('session/modelCatalog', args, { peer }),
      gateway.has('llm/listProviders') ? gateway.call('llm/listProviders', {}, { peer }) : [],
      gateway.has('llm/listConfigurableProviders') ? gateway.call('llm/listConfigurableProviders', {}, { peer }) : [],
    ]);
    if (catalog.status === 'rejected') throw catalog.reason;
    sendJson(res, 200, {
      v: 1,
      catalog: catalog.value,
      providers: providers.status === 'fulfilled' ? providers.value : [],
      configurable: configurable.status === 'fulfilled' ? configurable.value : [],
    });
  }, { domain: 'settings' });

  router.put('/sessions/:id/model', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const result = await gateway.call('session/selectModel', { sessionId: params.id, ...body }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'settings' });

  router.get('/providers', async (_req, res, { peer }) => {
    const [providers, configurable] = await Promise.allSettled([
      gateway.has('llm/listProviders') ? gateway.call('llm/listProviders', {}, { peer }) : [],
      gateway.has('llm/listConfigurableProviders') ? gateway.call('llm/listConfigurableProviders', {}, { peer }) : [],
    ]);
    sendJson(res, 200, {
      v: 1,
      providers: providers.status === 'fulfilled' ? providers.value : [],
      configurable: configurable.status === 'fulfilled' ? configurable.value : [],
    });
  }, { domain: 'settings' });

  const VALID_CRED_REF_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
  const LOOPBACK_ORIGIN_RE = /^http:\/\/(?:localhost|127\.0\.0\.1|\[::1\]):([0-9]+)\/?$/i;

  router.post('/providers/discover', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const settingsNs = body.settingsNs ?? body.ns ?? 'llm-pi-ai';
    let requestObj = body.request;
    if (!requestObj || typeof requestObj !== 'object') {
      requestObj = {};
      for (const k of ['provider', 'baseURL', 'api', 'apiKey']) {
        if (body[k] !== undefined && body[k] !== '') requestObj[k] = body[k];
      }
    }
    // Resolve stored DSH credential ref server-side ONLY via DSH's credentials service (never arbitrary process.env!).
    const envRef = typeof body.apiKeyEnv === 'string' ? body.apiKeyEnv.trim() : '';
    if (!requestObj.apiKey && envRef && VALID_CRED_REF_RE.test(envRef)) {
      try {
        const credsSvc = ctx.get?.('credentials');
        const resolved =
          (typeof credsSvc?.resolve === 'function' ? await credsSvc.resolve(envRef) : null) ??
          (typeof credsSvc?.get === 'function' ? await credsSvc.get(envRef) : null) ??
          (typeof credsSvc?.getValue === 'function' ? await credsSvc.getValue(envRef) : null);
        const secret = typeof resolved === 'string' ? resolved : (resolved?.value ?? resolved?.secret);
        if (typeof secret === 'string' && secret.trim()) {
          requestObj = { ...requestObj, apiKey: secret.trim() };
        }
      } catch {}
    }
    const result = await gateway.call('llm/discoverModels', {
      settingsNs,
      request: requestObj,
    }, { peer });
    sendJson(res, 200, { v: 1, models: result });
  }, { domain: 'settings' });

  router.get('/credentials', async (_req, res, { searchParams, peer }) => {
    const rawRefs = searchParams.get('refs');
    const refSet = new Set();
    const addValidRef = (r) => {
      const clean = typeof r === 'string' ? r.trim() : '';
      if (clean && VALID_CRED_REF_RE.test(clean)) refSet.add(clean);
    };
    for (const r of DEFAULT_CREDENTIAL_REFS) addValidRef(r);
    if (rawRefs) {
      for (const r of rawRefs.split(',')) addValidRef(r);
    }
    if (gateway.has('settings/describe')) {
      try {
        const desc = await gateway.call('settings/describe', {}, { peer });
        for (const ns of desc?.namespaces ?? []) {
          if (Array.isArray(ns?.secrets)) {
            for (const sec of ns.secrets) {
              addValidRef(typeof sec === 'string' ? sec : (sec?.ref ?? sec?.name));
            }
          }
          // Also collect custom apiKeyEnv refs from llm-pi-ai & llm-commandcode namespaces!
          const val = ns?.value;
          if (ns?.ns === 'llm-pi-ai' && val?.providers && typeof val.providers === 'object') {
            for (const cfg of Object.values(val.providers)) {
              addValidRef(cfg?.apiKeyEnv);
            }
          } else {
            addValidRef(val?.apiKeyEnv);
          }
        }
      } catch {}
    }
    const allRefs = [...refSet];
    let credentials;
    if (allRefs.length <= 64) {
      credentials = await gateway.call('credentials/describe', { refs: allRefs }, { peer });
    } else {
      const mergedMap = {};
      const mergedEntries = [];
      let sawMapShape = false;
      for (let i = 0; i < allRefs.length; i += 64) {
        const batch = await gateway.call('credentials/describe', { refs: allRefs.slice(i, i + 64) }, { peer });
        const list = Array.isArray(batch) ? batch : (batch?.entries ?? batch?.credentials ?? batch?.items ?? null);
        if (Array.isArray(list)) {
          for (const item of list) {
            mergedEntries.push(item);
            const k = item?.ref ?? item?.name ?? item?.key;
            if (typeof k === 'string' && k) mergedMap[k] = item;
          }
        } else if (batch && typeof batch === 'object') {
          sawMapShape = true;
          for (const [k, v] of Object.entries(batch)) {
            if (k === 'v') continue;
            mergedMap[k] = v;
          }
        }
      }
      credentials = sawMapShape || Object.keys(mergedMap).length > 0 ? mergedMap : { entries: mergedEntries };
    }
    sendJson(res, 200, { v: 1, credentials });
  }, { domain: 'settings' });

  router.put('/credentials', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const result = await gateway.call('credentials/set', body, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'settings' });

  router.delete('/credentials', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const result = await gateway.call('credentials/unset', body, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'settings' });

  // ---------------- DeepSeek Account ----------------
  const buildAccountClientMeta = (input) => ({
    version: String(input?.version || '0.1.0'),
    locale: String(input?.locale || 'zh-CN'),
    timezoneOffsetSeconds: Number.isFinite(Number(input?.timezoneOffsetSeconds))
      ? Number(input.timezoneOffsetSeconds)
      : -new Date().getTimezoneOffset() * 60,
  });

  router.get('/account', async (_req, res, { peer }) => {
    const clientMeta = buildAccountClientMeta();
    const [state, profile, balance] = await Promise.allSettled([
      gateway.has('account/getState') ? gateway.call('account/getState', {}, { peer }) : null,
      gateway.has('account/getProfile') ? gateway.call('account/getProfile', { client: clientMeta }, { peer }) : null,
      gateway.has('account/getBalance') ? gateway.call('account/getBalance', { client: clientMeta }, { peer }) : null,
    ]);
    sendJson(res, 200, {
      v: 1,
      state: state.status === 'fulfilled' ? state.value : null,
      profile: profile.status === 'fulfilled' ? profile.value : null,
      balance: balance.status === 'fulfilled' ? balance.value : null,
    });
  }, { domain: 'settings' });

  router.post('/account/:action', async (req, res, { params, peer, mode }) => {
    const allowed = new Set(['startSignIn', 'cancelSignIn', 'signOut', 'getBalance', 'getProfile']);
    if (!allowed.has(params.action)) {
      throw new GbridgeError(400, 'gbridge/validation_error', `unsupported account action "${params.action}"`);
    }
    const body = await readJsonBody(req);
    const clientMeta = buildAccountClientMeta(body.client);
    let payload;
    if (params.action === 'cancelSignIn') {
      payload = { attemptId: body.attemptId };
    } else if (params.action === 'startSignIn') {
      const webServer = ctx.get?.('webServer');
      const requestedOrigin = typeof body.callbackOrigin === 'string' ? body.callbackOrigin.trim() : '';
      // DSH `dsh-deepseek-account` strictly requires an HTTP loopback callbackOrigin (127.0.0.1 / localhost / [::1]).
      let safeLoopbackOrigin = `http://127.0.0.1:${webServer?.port || 3080}`;
      if (typeof webServer?.getOrigin === 'function') {
        const wsOrig = String(webServer.getOrigin() || '').trim();
        if (LOOPBACK_ORIGIN_RE.test(wsOrig)) safeLoopbackOrigin = wsOrig;
      }
      const callbackOrigin = LOOPBACK_ORIGIN_RE.test(requestedOrigin)
        ? requestedOrigin
        : safeLoopbackOrigin;
      payload = {
        client: clientMeta,
        callbackOrigin,
        loginSource: body.loginSource === 'desktop' ? 'desktop' : 'web',
      };
    } else {
      payload = { client: clientMeta };
    }
    let result = await gateway.call(`account/${params.action}`, payload, { peer });
    // `account/startSignIn` initializes asynchronously (`phase: "initializing"` with no `authorizeUrl` yet).
    // Poll briefly up to 8s so the client immediately receives `authorizeUrl` once `waiting-browser` is reached.
    if (params.action === 'startSignIn' && gateway.has('account/getState')) {
      const hasUrl = (r) => Boolean(r?.authorizeUrl || r?.attempt?.authorizeUrl);
      const isInit = (r) => {
        const phase = String(r?.attempt?.phase ?? r?.phase ?? '').toLowerCase();
        return !hasUrl(r) && (phase === '' || phase === 'initializing' || phase === 'starting');
      };
      if (isInit(result)) {
        const deadline = Date.now() + 8000;
        while (Date.now() < deadline && isInit(result)) {
          await new Promise((r) => setTimeout(r, 200));
          try {
            const nextState = await gateway.call('account/getState', {}, { peer });
            if (nextState && typeof nextState === 'object') {
              result = nextState;
            }
          } catch {
            break;
          }
        }
      }
    }
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'settings' });

  router.get('/auth/subscriptions', async (_req, res, { peer }) => {
    if (!gateway.has('appAuth/list')) {
      sendJson(res, 200, { v: 1, subscriptions: [] });
      return;
    }
    const list = await gateway.call('appAuth/list', {}, { peer });
    sendJson(res, 200, { v: 1, subscriptions: list });
  }, { domain: 'settings' });

  router.post('/auth/subscriptions/:action', async (req, res, { params, peer }) => {
    const allowed = new Set(['begin', 'answer', 'poll', 'cancel', 'signOut']);
    if (!allowed.has(params.action)) {
      throw new GbridgeError(400, 'gbridge/validation_error', `unsupported subscription action "${params.action}"`);
    }
    const body = await readJsonBody(req);
    const result = await gateway.call(`appAuth/${params.action}`, body, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'settings' });

  router.get('/auth/usage', async (_req, res, { peer }) => {
    if (gateway.has('appAuth/usage')) {
      const usage = await gateway.call('appAuth/usage', {}, { peer });
      sendJson(res, 200, { v: 1, usage });
      return;
    }
    const clientMeta = buildAccountClientMeta();
    const balance = gateway.has('account/getBalance')
      ? await gateway.call('account/getBalance', { client: clientMeta }, { peer }).catch(() => null)
      : null;
    sendJson(res, 200, { v: 1, usage: balance });
  }, { domain: 'settings' });

  // ---------------- MCP Manager & Web Search Providers ----------------
  router.get('/mcp', async (_req, res, { peer }) => {
    const svc = ctx.get?.('mcpManager');
    if (svc && typeof svc.list === 'function') {
      const servers = await Promise.resolve(svc.list());
      sendJson(res, 200, { v: 1, servers });
      return;
    }
    if (gateway.has('mcpManager/watch')) {
      const servers = await readFirstStreamFrame(gateway, 'mcpManager/watch', {}, peer).catch(() => []);
      sendJson(res, 200, { v: 1, servers: Array.isArray(servers) ? servers : [] });
      return;
    }
    sendJson(res, 200, { v: 1, servers: [] });
  }, { domain: 'plugins' });

  router.post('/mcp/:name/:action', async (_req, res, { params, peer }) => {
    if (params.action !== 'probe' && params.action !== 'restart') {
      throw new GbridgeError(400, 'gbridge/validation_error', `unsupported mcp action "${params.action}"`);
    }
    const result = await gateway.call(`mcpManager/${params.action}`, { name: params.name }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'plugins' });

  router.get('/web/providers', async (_req, res, { peer }) => {
    const providers = gateway.has('web/listProviders')
      ? await gateway.call('web/listProviders', {}, { peer })
      : [];
    sendJson(res, 200, { v: 1, providers });
  }, { domain: 'settings' });

  // ---------------- Plugins, Market & Dynamic Cordis ----------------
  router.get('/plugins/bundles', async (_req, res, { peer }) => {
    const bundles = await gateway.call('pluginManager/listBundles', {}, { peer });
    sendJson(res, 200, { v: 1, bundles });
  }, { domain: 'plugins' });

  router.get('/plugins/entries', async (_req, res, { peer }) => {
    const entries = await gateway.call('pluginManager/listPlugins', {}, { peer });
    sendJson(res, 200, { v: 1, entries });
  }, { domain: 'plugins' });

  router.get('/plugins/inventory', async (_req, res, { peer }) => {
    const inventory = await gateway.call('pluginInventory/list', {}, { peer });
    sendJson(res, 200, { v: 1, inventory });
  }, { domain: 'plugins' });

  router.get('/plugins/registries', async (_req, res, { peer }) => {
    const registries = await gateway.call('pluginManager/registries', {}, { peer });
    sendJson(res, 200, { v: 1, registries });
  }, { domain: 'plugins' });

  router.get('/plugins/market/indexes', async (_req, res, { peer }) => {
    const indexes = gateway.has('pluginMarket/listIndexes')
      ? await gateway.call('pluginMarket/listIndexes', {}, { peer })
      : [];
    sendJson(res, 200, { v: 1, indexes });
  }, { domain: 'plugins' });

  router.post('/plugins/market/search', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const rawQuery = typeof body.query === 'string'
      ? body.query
      : (typeof body.q === 'string' ? body.q : String(body.query?.text ?? ''));
    const text = rawQuery.trim();
    const rawLimit = Number(body.limit ?? body.query?.limit ?? 20);
    const limit = Number.isFinite(rawLimit) ? Math.max(1, Math.min(50, Math.round(rawLimit))) : 20;

    if (gateway.has('pluginMarket/search')) {
      let url = typeof body.url === 'string' && body.url.trim() ? body.url.trim() : null;
      if (url) {
        try {
          const parsedUrl = new URL(url);
          if (parsedUrl.protocol !== 'https:' && parsedUrl.protocol !== 'http:') {
            throw new GbridgeError(400, 'gbridge/validation_error', 'market index URL must use http or https');
          }
        } catch (err) {
          if (err instanceof GbridgeError) throw err;
          throw new GbridgeError(400, 'gbridge/validation_error', 'invalid market index URL');
        }
      }
      if (!url && gateway.has('pluginMarket/listIndexes')) {
        const indexes = await gateway.call('pluginMarket/listIndexes', {}, { peer }).catch(() => []);
        if (Array.isArray(indexes) && indexes.length > 0) {
          url = indexes[0]?.url ?? null;
        }
      }
      if (url) {
        try {
          const rawOff = Number(typeof body.query === 'object' && body.query !== null ? (body.query.offset ?? 0) : (body.offset ?? 0));
          const offset = Number.isFinite(rawOff) ? Math.max(0, Math.round(rawOff)) : 0;
          const queryObj = (typeof body.query === 'object' && body.query !== null)
            ? {
                sort: body.query.sort ?? (text ? { kind: 'relevance' } : { kind: 'index' }),
                offset,
                limit,
                ...(text ? { text } : {}),
              }
            : {
                sort: text ? { kind: 'relevance' } : { kind: 'index' },
                offset,
                limit,
                ...(text ? { text } : {}),
              };
          const result = await gateway.call('pluginMarket/search', {
            url,
            query: queryObj,
          }, { peer });
          sendJson(res, 200, { v: 1, result });
          return;
        } catch {}
      }
    }

    // Live npm registry fallback (China npmmirror first -> official npmjs fallback)
    const searchTerm = text || '@deepseek-ai/dsh';
    const searchRegistries = [
      'https://registry.npmmirror.com',
      'https://registry.npmjs.org',
    ];
    let lastSearchError = null;
    try {
      let data = null;
      for (const regBase of searchRegistries) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 5000);
        try {
          const npmUrl = `${regBase}/-/v1/search?text=${encodeURIComponent(searchTerm)}&size=${limit}`;
          const resp = await fetch(npmUrl, {
            headers: { accept: 'application/json' },
            signal: controller.signal,
          });
          if (resp.ok) {
            data = await resp.json();
            break;
          }
          lastSearchError = `HTTP ${resp.status}`;
        } catch (err) {
          lastSearchError = err?.name === 'AbortError' ? '搜索插件市场超时' : String(err?.message || err);
        } finally {
          clearTimeout(timer);
        }
      }
      if (!data) {
        sendJson(res, 200, { v: 1, result: { source: 'npm-registry', items: [], error: lastSearchError || '无法连接插件仓库' } });
        return;
      }
      const objects = Array.isArray(data?.objects) ? data.objects : [];
      const items = objects.map((o) => {
        const pkg = o?.package ?? {};
        return {
          name: String(pkg.name ?? ''),
          version: String(pkg.version ?? ''),
          description: String(pkg.description ?? ''),
          author: typeof pkg.author === 'string'
            ? pkg.author
            : String(pkg.author?.name ?? pkg.publisher?.username ?? ''),
          keywords: Array.isArray(pkg.keywords) ? pkg.keywords : [],
          homepage: pkg.links?.homepage ?? pkg.links?.npm ?? null,
          date: pkg.date ?? null,
        };
      }).filter((it) => it.name);
      sendJson(res, 200, { v: 1, result: { source: 'npm-registry', items } });
    } catch (err) {
      sendJson(res, 200, {
        v: 1,
        result: {
          source: 'npm-registry',
          items: [],
          error: err?.name === 'AbortError' ? '搜索插件市场超时' : String(err?.message || err),
        },
      });
    }
  }, { domain: 'plugins' });

  router.post('/plugins/inspect', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const result = await gateway.call('pluginManager/inspect', body, { peer });
    sendJson(res, 200, { v: 1, inspection: result });
  }, { domain: 'plugins' });

  router.post('/plugins/install', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const result = await gateway.call('pluginManager/installBundle', body, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'plugins' });

  router.post('/plugins/install/:reqId/cancel', async (_req, res, { params, peer }) => {
    const result = await gateway.call('pluginManager/cancelInstall', { requestId: params.reqId }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'plugins' });

  router.patch('/plugins/bundles/:name', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const result = await gateway.call('pluginManager/setBundleEnabled', {
      name: params.name,
      enabled: Boolean(body.enabled),
    }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'plugins' });

  router.post('/plugins/bundles/:name/update', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    let version = typeof body.version === 'string' && body.version.trim() ? body.version.trim() : 'latest';
    if (version === 'latest' && gateway.has('pluginManager/listVersions')) {
      const vers = await gateway.call('pluginManager/listVersions', { name: params.name }, { peer }).catch(() => null);
      const list = Array.isArray(vers) ? vers : (vers?.versions ?? []);
      if (list.length > 0) {
        const top = list[0];
        version = typeof top === 'string' ? top : String(top?.version ?? 'latest');
      }
    }
    const result = await gateway.call('pluginManager/updateBundle', {
      name: params.name,
      version,
      ...(body.options ? { options: body.options } : {}),
    }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'plugins' });

  router.patch('/plugins/entries/:id', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const result = await gateway.call('pluginManager/setPluginEnabled', {
      id: params.id,
      enabled: Boolean(body.enabled),
    }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'plugins' });

  router.delete('/plugins/bundles/:name', async (_req, res, { params, peer }) => {
    const result = await gateway.call('pluginManager/removeBundle', { name: params.name }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'plugins' });

  router.get('/cordis/dynamic', async (_req, res, { peer }) => {
    const inventory = await gateway.call('dynamicCordisRunner/inventory', {}, { peer });
    sendJson(res, 200, { v: 1, inventory });
  }, { domain: 'plugins' });

  router.post('/cordis/dynamic/:id/:action', async (req, res, { params, peer }) => {
    const map = {
      stop: 'dynamicCordisRunner/stopFromPanel',
      undefine: 'dynamicCordisRunner/undefineFromPanel',
    };
    const ep = map[params.action];
    if (!ep) throw new GbridgeError(400, 'gbridge/validation_error', `unsupported cordis action "${params.action}"`);
    const body = await readJsonBody(req);
    let agentId = body.agentId ? String(body.agentId) : null;
    if (!agentId && gateway.has('dynamicCordisRunner/inventory')) {
      const inv = await gateway.call('dynamicCordisRunner/inventory', {}, { peer }).catch(() => []);
      const list = Array.isArray(inv) ? inv : (inv?.items ?? inv?.plugins ?? []);
      const hit = list.find((it) => String(it?.pluginId ?? it?.id ?? '') === params.id);
      if (hit?.agentId) agentId = String(hit.agentId);
    }
    const result = await gateway.call(ep, {
      pluginId: params.id,
      ...(agentId ? { agentId } : {}),
    }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'plugins' });

  // ---------------- Settings (Schemastery), Dynamic Manifest & Agent Presets ----------------
  router.get('/settings/schema', async (_req, res, { peer }) => {
    const description = await gateway.call('settings/describe', {}, { peer });
    sendJson(res, 200, { v: 1, description });
  }, { domain: 'settings' });

  router.get('/settings/manifest', async (_req, res, { peer }) => {
    const [descRes, webProvRes, presetsRes, permsRes, bundlesRes] = await Promise.allSettled([
      gateway.has('settings/describe') ? gateway.call('settings/describe', {}, { peer }) : null,
      gateway.has('web/listProviders') ? gateway.call('web/listProviders', {}, { peer }) : null,
      gateway.has('agentPresets/list') ? gateway.call('agentPresets/list', {}, { peer }) : null,
      gateway.has('permissionPresets/catalog') ? gateway.call('permissionPresets/catalog', {}, { peer }) : null,
      gateway.has('pluginManager/listBundles') ? gateway.call('pluginManager/listBundles', {}, { peer }) : null,
    ]);

    const desc = descRes.status === 'fulfilled' ? descRes.value : null;
    const allNamespaces = Array.isArray(desc?.namespaces) ? desc.namespaces : [];
    const nsNames = allNamespaces.map((n) => String(n?.ns || '')).filter(Boolean);
    const nsSet = new Set(nsNames);

    const WEB_PROVIDER_META = {
      'deepseek-official': {
        label: 'DeepSeek 官方联网搜索',
        description: '使用 DeepSeek 官方账号或 API Key 的内置搜索能力，不单独按次计费。',
      },
      'deepseek-search-api': {
        label: 'DeepSeek Search API',
        description: '调用独立搜索 API 接口，按实际请求计费并支持 QPS 速率控制。',
      },
      commandcode: {
        label: 'CommandCode 聚合搜索',
        description: '通过 CommandCode 渠道提供高速联网搜索能力，适合代码与技术文档检索。',
      },
      'deepseek-fetch-api': {
        label: 'DeepSeek 网页抓取 API',
        description: '支持动态渲染网页与 PDF 解析，需消耗对应 API 额度（不可访问本机内网）。',
      },
      http: {
        label: '直连 HTTP 抓取（免费）',
        description: '直接由本机 HTTP 客户端拉取静态网页内容，支持内网与本机地址，免费无额度消耗。',
      },
    };
    const webProv = webProvRes.status === 'fulfilled' ? webProvRes.value : null;
    const normalizeWebOpts = (list) => (Array.isArray(list) ? list : []).map((p) => {
      const id = String(p?.id ?? p?.name ?? '');
      const meta = WEB_PROVIDER_META[id];
      const rawLabel = pickLocalizedText(p?.title ?? p?.name, '');
      const rawDesc = pickLocalizedText(p?.description, '');
      const label = (rawLabel && rawLabel !== id) ? rawLabel : (meta?.label || id);
      const description = rawDesc || meta?.description || '';
      return { value: id, label, description };
    }).filter((o) => o.value);

    const searchProviders = normalizeWebOpts(webProv?.search);
    const fetchProviders = normalizeWebOpts(webProv?.fetch);

    const rawPerms = permsRes.status === 'fulfilled' ? permsRes.value : null;
    const permissionOptions = (Array.isArray(rawPerms?.options) ? rawPerms.options : []).map((o) => ({
      value: String(o?.value ?? ''),
      label: String(o?.name ?? o?.value ?? ''),
    })).filter((o) => o.value);

    const rawPresetsWrap = presetsRes.status === 'fulfilled' ? presetsRes.value : null;
    const rawPresets = Array.isArray(rawPresetsWrap) ? rawPresetsWrap : (rawPresetsWrap?.presets ?? []);
    const presetOptions = (Array.isArray(rawPresets) ? rawPresets : []).map((p) => ({
      value: String(p?.id ?? ''),
      label: String(p?.title ?? p?.name ?? p?.id ?? ''),
      description: String(p?.description ?? ''),
    })).filter((o) => o.value);

    const bundles = bundlesRes.status === 'fulfilled' && Array.isArray(bundlesRes.value) ? bundlesRes.value : [];
    const customNamespaces = nsNames.filter((n) => !KNOWN_NS_SET.has(n));

    // Mirror `@deepseek-ai/dsh-client-ui-settings*` dynamically based on what this host actually loads!
    const sections = [];
    if (gateway.has('account/getState') || nsSet.has('ui-settings-account')) {
      sections.push({
        id: 'account',
        group: 'dsh',
        title: '账号与余额',
        subtitle: 'DeepSeek 官方登录、额度与 API 凭据',
        icon: 'person',
        order: 10,
        namespaces: ['ui-settings-account'].filter((n) => nsSet.has(n)),
      });
    }
    const generalNs = BUILTIN_SECTION_NAMESPACES.general.filter((n) => nsSet.has(n));
    if (generalNs.length > 0 || permissionOptions.length > 0 || presetOptions.length > 0) {
      sections.push({
        id: 'general',
        group: 'dsh',
        title: '通用与对话',
        subtitle: '对话展示密度、回车行为、权限预设、角色与日志上传',
        icon: 'chat',
        order: 20,
        namespaces: generalNs,
      });
    }
    const modelNs = [
      ...BUILTIN_SECTION_NAMESPACES.models.filter((n) => nsSet.has(n)),
      ...customNamespaces.filter((n) => n.startsWith('llm-')),
    ];
    if (modelNs.length > 0 || gateway.has('session/modelCatalog')) {
      sections.push({
        id: 'models',
        group: 'dsh',
        title: '模型与渠道',
        subtitle: '默认模型、推理深度、官方与自定义渠道配置',
        icon: 'sparkles',
        order: 30,
        namespaces: modelNs,
      });
    }
    const webNs = [
      ...BUILTIN_SECTION_NAMESPACES['web-search'].filter((n) => nsSet.has(n)),
      ...customNamespaces.filter((n) => n.startsWith('web-')),
    ];
    if (webNs.length > 0 || searchProviders.length > 0 || fetchProviders.length > 0) {
      sections.push({
        id: 'web-search',
        group: 'dsh-capabilities',
        title: '联网搜索与抓取',
        subtitle: '搜索与网页抓取提供方、计费模式与速率限制',
        icon: 'globe',
        order: 40,
        namespaces: webNs,
      });
    }
    const agentNs = BUILTIN_SECTION_NAMESPACES['agent-runtime'].filter((n) => nsSet.has(n));
    if (agentNs.length > 0) {
      sections.push({
        id: 'agent-runtime',
        group: 'dsh-capabilities',
        title: '智能体与终端',
        subtitle: '子智能体层级与选模、并发工具上限、Shell 超时与输出',
        icon: 'cpu',
        order: 50,
        namespaces: agentNs,
      });
    }
    const mcpNs = BUILTIN_SECTION_NAMESPACES.mcp.filter((n) => nsSet.has(n));
    if (mcpNs.length > 0 || gateway.has('mcpManager/watch')) {
      sections.push({
        id: 'mcp',
        group: 'dsh-capabilities',
        title: 'MCP 工具服务',
        subtitle: '配置 stdio / HTTP MCP 服务器并实时探测连接状态',
        icon: 'antenna',
        order: 60,
        namespaces: mcpNs,
      });
    }
    const thirdPartyNs = customNamespaces.filter((n) => !n.startsWith('llm-') && !n.startsWith('web-'));
    sections.push({
      id: 'plugins',
      group: 'dsh-capabilities',
      title: '插件与扩展',
      subtitle: thirdPartyNs.length > 0
        ? `已安装 ${bundles.length} 个扩展 · ${thirdPartyNs.length} 组自定义插件配置`
        : '管理已安装插件、浏览市场与动态 Cordis 模块',
      icon: 'stack',
      order: 70,
      namespaces: thirdPartyNs,
    });

    sendJson(res, 200, {
      v: 1,
      writable: desc?.writable !== false,
      sections,
      dynamicOptions: {
        'web.searchProvider': searchProviders,
        'web.fetchProvider': fetchProviders,
        'permission.defaultPreset': permissionOptions,
        'agent-preset-registry.selectedDefault': presetOptions,
      },
      namespacesCount: nsNames.length,
    });
  }, { domain: 'settings' });

  router.get('/system/check-update', async (_req, res) => {
    const currentVersion = detectDshVersion(ctx);
    const updateSources = [
      { label: 'npmmirror', url: 'https://registry.npmmirror.com/-/package/%40deepseek-ai%2Fdsh/dist-tags', isDistTags: true },
      { label: 'npmjs', url: 'https://registry.npmjs.org/@deepseek-ai/dsh', isDistTags: false },
    ];
    let distTags = null;
    let lastError = null;
    let sourceUsed = '';
    for (const src of updateSources) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 5000);
      try {
        const resp = await fetch(src.url, {
          headers: { accept: 'application/vnd.npm.install-v1+json, application/json' },
          signal: controller.signal,
        });
        if (!resp.ok) {
          lastError = `${src.label} returned HTTP ${resp.status}`;
          continue;
        }
        const data = await resp.json();
        const candidateTags = src.isDistTags
          ? (data && typeof data === 'object' ? data : null)
          : (data && typeof data['dist-tags'] === 'object' ? data['dist-tags'] : null);
        if (candidateTags && (typeof candidateTags.latest === 'string' || typeof candidateTags.next === 'string')) {
          distTags = candidateTags;
          sourceUsed = src.label;
          break;
        }
        lastError = `${src.label} returned empty dist-tags`;
      } catch (err) {
        lastError = err?.name === 'AbortError' ? '检查更新超时，请检查网络连接' : String(err?.message || err);
      } finally {
        clearTimeout(timer);
      }
    }
    if (!distTags) {
      sendJson(res, 200, {
        v: 1,
        currentVersion,
        latestVersion: currentVersion,
        nextVersion: null,
        hasUpdate: false,
        checkedAt: Date.now(),
        error: lastError || '检查更新失败，请检查网络连接',
      });
      return;
    }
    const latestTag = typeof distTags.latest === 'string' ? distTags.latest : null;
    const nextTag = typeof distTags.next === 'string' ? distTags.next : null;
    const isPrerelease = currentVersion.includes('-');
    const candidates = [latestTag, ...(isPrerelease ? [nextTag] : [])].filter(Boolean);
    let recommended = currentVersion;
    for (const c of candidates) {
      if (compareSemver(c, recommended) > 0) recommended = c;
    }
    const hasUpdate = compareSemver(recommended, currentVersion) > 0;
    sendJson(res, 200, {
      v: 1,
      currentVersion,
      latestVersion: latestTag ?? currentVersion,
      nextVersion: nextTag,
      recommendedVersion: recommended,
      distTags,
      source: sourceUsed,
      hasUpdate,
      checkedAt: Date.now(),
    });
  }, { domain: 'meta' });

  router.patch('/settings', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const ns = body.ns ?? body.namespace;
    let ep;
    let args;
    if (Array.isArray(body.ops) && gateway.has('settings/mutate')) {
      ep = 'settings/mutate';
      args = {
        ns,
        ops: body.ops,
        ...(body.expectedRevision !== undefined ? { expectedRevision: body.expectedRevision } : {}),
      };
    } else if (body.section !== undefined && gateway.has('settings/replace')) {
      ep = 'settings/replace';
      args = {
        ns,
        section: body.section,
        ...(body.expectedRevision !== undefined ? { expectedRevision: body.expectedRevision } : {}),
      };
    } else if (gateway.has('settings/update')) {
      ep = 'settings/update';
      args = {
        ns,
        patch: body.patch ?? body.value ?? {},
        ...(body.expectedRevision !== undefined ? { expectedRevision: body.expectedRevision } : {}),
      };
    } else {
      ep = 'settings/mutate';
      args = body;
    }
    try {
      const result = await gateway.call(ep, args, { peer });
      sendJson(res, 200, { v: 1, result });
    } catch (err) {
      // Path-addressed `settings/mutate` and partial `settings/update` are applied by DSH
      // against the latest stored section inside `configEditor.edit`. When a caller supplies
      // a stale `expectedRevision` (e.g. after `session/selectModel` asynchronously bumped
      // `agent-default-model`), safely retry once without `expectedRevision` instead of
      // failing with a spurious HTTP 409 conflict. Keep strict conflict checks for `replace`.
      const upCode = String(err?.details?.upstreamCode || err?.code || '').toLowerCase();
      const msg = String(err?.message || '').toLowerCase();
      const isConflict =
        (err?.status === 409 ||
          upCode.includes('settings/conflict') ||
          upCode.includes('settings_conflict') ||
          msg.includes('changed since it was read')) &&
        args &&
        args.expectedRevision !== undefined &&
        (ep === 'settings/mutate' || ep === 'settings/update');
      if (!isConflict) throw err;
      const retryArgs = { ...args };
      delete retryArgs.expectedRevision;
      const result = await gateway.call(ep, retryArgs, { peer });
      sendJson(res, 200, { v: 1, result, conflictRecovered: true });
    }
  }, { domain: 'settings' });

  router.get('/presets', async (_req, res, { peer }) => {
    const presets = await gateway.call('agentPresets/list', {}, { peer });
    sendJson(res, 200, { v: 1, presets });
  }, { domain: 'settings' });

  router.get('/presets/:id', async (_req, res, { params, peer }) => {
    const preset = await gateway.call('agentPresets/read', { agentPreset: params.id, id: params.id }, { peer });
    sendJson(res, 200, { v: 1, preset });
  }, { domain: 'settings' });

  router.post('/presets/select', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const agentPreset = String(body.agentPreset ?? body.preset ?? body.id ?? '').trim();
    if (!agentPreset) {
      throw new GbridgeError(400, 'gbridge/validation_error', 'agentPreset is required');
    }
    const agentId = body.agentId ?? body.sessionId;
    if (agentId && gateway.has('agentPresets/select')) {
      try {
        const result = await gateway.call('agentPresets/select', {
          agentId: String(agentId),
          agentPreset,
        }, { peer });
        sendJson(res, 200, { v: 1, scope: 'session', agentPreset, result });
        return;
      } catch (err) {
        const msg = String(err?.message || '');
        const upCode = String(err?.details?.upstreamCode || '');
        const isLocked = upCode === 'agent-preset/locked' || msg.includes('already started');
        if (!isLocked || !gateway.has('settings/update')) throw err;
        const result = await gateway.call('settings/update', {
          ns: 'agent-preset-registry',
          patch: { selectedDefault: agentPreset },
        }, { peer });
        sendJson(res, 200, { v: 1, scope: 'default', lockedSession: true, agentPreset, result });
        return;
      }
    }
    if (gateway.has('settings/update')) {
      const result = await gateway.call('settings/update', {
        ns: 'agent-preset-registry',
        patch: { selectedDefault: agentPreset },
      }, { peer });
      sendJson(res, 200, { v: 1, scope: 'default', agentPreset, result });
      return;
    }
    throw new GbridgeError(400, 'gbridge/validation_error', 'sessionId is required to select an agent preset');
  }, { domain: 'settings' });

  // ---------------- Experimental (CoT Translation & Speech) ----------------
  router.post('/tools/translate-cot', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const result = await gateway.call('cotTranslation/translate', {
      ...body,
      targetLanguage: body.targetLanguage ?? body.targetLang ?? 'zh-CN',
    }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'experimental' });

  router.get('/speech/catalog', async (_req, res, { peer }) => {
    const catalog = await gateway.call('speech/catalog', {}, { peer });
    sendJson(res, 200, { v: 1, catalog });
  }, { domain: 'experimental' });

  router.get('/speech/config', async (_req, res, { peer }) => {
    if (!gateway.has('speech/catalog')) {
      sendJson(res, 200, { v: 1, available: false, configured: false, catalog: null });
      return;
    }
    const catalog = await gateway.call('speech/catalog', {}, { peer }).catch(() => null);
    const selectedId = catalog?.selection?.providerId;
    const configured = Boolean(
      catalog?.configured ||
      (selectedId && Array.isArray(catalog?.providers) &&
        catalog.providers.some((p) => p?.id === selectedId && (p?.preparation?.phase === 'ready' || p?.ready === true))),
    );
    sendJson(res, 200, { v: 1, available: Boolean(catalog), configured, catalog });
  }, { domain: 'experimental' });

  router.put('/speech/config', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const result = await gateway.call('speech/configure', body, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'experimental' });

  router.post('/speech/transcribe', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const result = await gateway.call('speech/transcribe', body, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'experimental' });
}
