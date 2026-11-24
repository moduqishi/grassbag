import { request as httpRequest } from 'node:http';
import { existsSync } from 'node:fs';

const PHONE_TOOL_DEFS = [
  {
    name: 'phone_screen',
    description: 'Read current Android screen accessibility tree through SafetyGate. Returns element nodeIds (n0, n1...) with labels and centers; sensitive fields are redacted.',
    properties: {
      maxNodes: { type: 'integer', description: 'Maximum UI nodes to return (default 140).' },
    },
  },
  {
    name: 'phone_screenshot',
    description: 'Capture a compact JPEG screenshot of the current Android screen (Android 11+, hides GrassBag HUD automatically).',
    properties: {
      maxWidth: { type: 'integer', description: 'Max image width in pixels (default 720).' },
      quality: { type: 'integer', description: 'JPEG quality 35-90 (default 68).' },
    },
  },
  {
    name: 'phone_apps',
    description: 'List installed launchable Android apps (display name + package name). Optional fuzzy query filter.',
    properties: {
      query: { type: 'string', description: 'Optional Chinese or English app name / package filter.' },
    },
  },
  {
    name: 'phone_tap',
    description: 'Tap an element by nodeId from phone_screen (preferred) or screen coordinates (x, y) through native SafetyGate.',
    properties: {
      nodeId: { type: 'string', description: 'Element nodeId from latest phone_screen (e.g. "n5").' },
      x: { type: 'number', description: 'Horizontal screen coordinate in pixels.' },
      y: { type: 'number', description: 'Vertical screen coordinate in pixels.' },
    },
  },
  {
    name: 'phone_long_press',
    description: 'Long-press an element by nodeId or screen coordinates (x, y) through native SafetyGate.',
    properties: {
      nodeId: { type: 'string', description: 'Element nodeId from latest phone_screen.' },
      x: { type: 'number', description: 'Horizontal screen coordinate in pixels.' },
      y: { type: 'number', description: 'Vertical screen coordinate in pixels.' },
      durationMs: { type: 'integer', description: 'Hold duration in ms (default 650).' },
    },
  },
  {
    name: 'phone_swipe',
    description: 'Swipe from (x1, y1) to (x2, y2) on the Android display through SafetyGate.',
    properties: {
      x1: { type: 'number', description: 'Start X coordinate in pixels.' },
      y1: { type: 'number', description: 'Start Y coordinate in pixels.' },
      x2: { type: 'number', description: 'End X coordinate in pixels.' },
      y2: { type: 'number', description: 'End Y coordinate in pixels.' },
      durationMs: { type: 'integer', description: 'Swipe duration in milliseconds (default 300).' },
    },
    required: ['x1', 'y1', 'x2', 'y2'],
  },
  {
    name: 'phone_key',
    description: 'Press an Android system navigation action (back, home, recents, notifications).',
    properties: {
      action: { type: 'string', enum: ['back', 'home', 'recents', 'notifications'] },
    },
    required: ['action'],
  },
  {
    name: 'phone_type',
    description: 'Type text into the currently focused Android input field (password/OTP fields blocked by SafetyGate).',
    properties: {
      text: { type: 'string', description: 'Text to enter into the focused editable field.' },
    },
    required: ['text'],
  },
  {
    name: 'phone_open',
    description: 'Open an Android app by display name (appName, e.g. "计算器"/"微信"), package name, or http(s) URL through SafetyGate.',
    properties: {
      appName: { type: 'string', description: 'Human-readable app name (fuzzy matched against installed apps).' },
      package: { type: 'string', description: 'Android application package name (e.g. com.android.chrome).' },
      url: { type: 'string', description: 'HTTP or HTTPS URL to open.' },
    },
  },
  {
    name: 'phone_intent',
    description: 'Invoke a safe Android system intent (alarm, timer, calendar, share, navigation).',
    properties: {
      kind: { type: 'string', enum: ['alarm', 'timer', 'calendar', 'share', 'navigation'] },
      hour: { type: 'integer' },
      minute: { type: 'integer' },
      seconds: { type: 'integer' },
      label: { type: 'string' },
      title: { type: 'string' },
      description: { type: 'string' },
      text: { type: 'string' },
      query: { type: 'string' },
    },
    required: ['kind'],
  },
  {
    name: 'phone_wait',
    description: 'Wait briefly (100-10000ms) for UI transitions or animations to settle before reading the screen again.',
    properties: {
      ms: { type: 'integer', description: 'Wait duration in milliseconds (default 1000).' },
    },
  },
  {
    name: 'phone_handoff',
    description: 'Pause and display a native overlay card asking the human user to complete a sensitive/manual step (passwords, OTP, payment, system settings), then resume when they tap Continue.',
    properties: {
      message: { type: 'string', description: 'Clear Chinese instruction shown on the floating handoff card.' },
    },
  },
];

/**
 * Zero-patch native Phone Control tool bridge for Android local hosts.
 * Activates ONLY when GBRIDGE_PHONE_SOCKET and GBRIDGE_PHONE_TOKEN are provided.
 *
 * Confirmation & handoff are handled NATIVELY on Android via `TYPE_ACCESSIBILITY_OVERLAY`
 * (`PhoneOverlayController`), so phone control works reliably outside GrassBag in BOTH
 * `workspace-write` and `danger-full-access` modes with zero DSH approval deadlock!
 */
export function mountPhoneTools(ctx, { socketPath, token, logger } = {}) {
  if (!socketPath || !token) {
    return { active: false, registered: 0, reason: 'not-android-host', dispose: () => {} };
  }
  if (!existsSync(socketPath)) {
    logger?.info?.(`[gbridge] phone socket not yet created at ${socketPath}; tools registered lazily`);
  }

  const disposers = [];
  const activeTurnBySession = new Map();
  const phoneActiveSessions = new Set();

  const callDaemon = (path, payload, signal, timeoutMs = 195_000) => new Promise((resolve, reject) => {
    const body = JSON.stringify(payload);
    const req = httpRequest({
      socketPath,
      path,
      method: 'POST',
      timeout: timeoutMs,
      headers: {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(body),
        authorization: `Bearer ${token}`,
      },
      signal,
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        try {
          const json = text ? JSON.parse(text) : {};
          if (res.statusCode >= 200 && res.statusCode < 300) resolve(json);
          else if (res.statusCode === 403 && json && typeof json === 'object') {
            // Return structured SafetyGate block/cancel response cleanly to the model
            // instead of throwing an unhandled error or deadlocking DSH approval!
            resolve(json);
          } else {
            reject(new Error(json?.reason || json?.error?.message || `phone daemon HTTP ${res.statusCode}`));
          }
        } catch {
          reject(new Error(`phone daemon returned non-JSON HTTP ${res.statusCode}`));
        }
      });
    });
    req.on('timeout', () => {
      req.destroy(new Error('phone_daemon_timeout'));
    });
    req.on('error', reject);
    req.end(body);
  });

  const resolveSessionPermissionPreset = (execCtx) => {
    try {
      const session = execCtx?.agent?.session ?? execCtx?.session;
      const explicitPreset = session?.permissionPreset ?? session?.meta?.permissionPreset;
      if (typeof explicitPreset === 'string' && explicitPreset.trim()) {
        return explicitPreset.trim();
      }
      const approval = ctx.get?.('approval');
      if (approval && typeof approval.effectivePolicy === 'function' && session) {
        const pol = approval.effectivePolicy(session);
        if (pol === 'never') return 'danger-full-access';
        if (pol === 'ask' || pol === 'on-request') return 'workspace-write';
      }
      const permPresets = ctx.get?.('permissionPresets') ?? ctx.get?.('permission');
      if (permPresets && typeof permPresets.getDefaultPreset === 'function') {
        const def = permPresets.getDefaultPreset();
        if (typeof def === 'string' && def.trim()) return def.trim();
      }
    } catch {}
    return null;
  };

  // Track active turns & forward turn/end ONLY for sessions that actually used phone tools
  // (or when sessionId is known) so unrelated title/background sessions NEVER wipe ALLOW_TURN!
  if (typeof ctx.on === 'function') {
    const off = ctx.on('session/event', (session, event) => {
      const sid = session?.id ?? null;
      if (event?.type === 'turn/start' && sid) {
        const tid = event?.data?.turnId ?? (event?.data?.turn !== undefined ? `turn-${event.data.turn}` : `seq-${event?.seq ?? Date.now()}`);
        activeTurnBySession.set(sid, String(tid));
      } else if (event?.type === 'turn/end') {
        if (sid) activeTurnBySession.delete(sid);
        const shouldNotify = !sid || phoneActiveSessions.delete(sid);
        if (shouldNotify) {
          callDaemon('/v1/turn-end', {
            sessionId: sid,
            reason: event?.data?.reason ?? 'completed',
          }, undefined, 10_000).catch(() => {});
        }
      }
    });
    if (typeof off === 'function') disposers.push(off);
  }

  let registered = 0;
  const registerAllOn = (tools) => {
    if (!tools || typeof tools.register !== 'function') return;
    for (const def of PHONE_TOOL_DEFS) {
      try {
        const off = tools.register({
          name: def.name,
          description: def.description,
          parameters: {
            type: 'object',
            additionalProperties: true,
            properties: def.properties,
            ...(def.required ? { required: def.required } : {}),
          },
          output: {
            schema: { type: 'object', additionalProperties: true },
            render: (_args, value) => {
              if (value && typeof value === 'object' && typeof value.base64 === 'string' && value.mimeType) {
                const { base64, ...meta } = value;
                return [
                  { type: 'text', text: JSON.stringify(meta) },
                  { type: 'image', data: base64, mimeType: value.mimeType },
                ];
              }
              return [
                { type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value ?? {}) },
              ];
            },
          },
          async execute(args, execCtx) {
            const sessionId = execCtx?.agent?.session?.id ?? execCtx?.session?.id ?? null;
            if (sessionId) phoneActiveSessions.add(sessionId);
            const turnId = execCtx?.turnId
              ?? (sessionId ? activeTurnBySession.get(sessionId) : null)
              ?? execCtx?.rootCallId
              ?? execCtx?.callId
              ?? null;
            const permissionPreset = resolveSessionPermissionPreset(execCtx);
            const payload = {
              tool: def.name,
              args: args ?? {},
              caller: { sessionId, turnId },
              ...(permissionPreset ? { permissionPreset } : {}),
            };
            return await callDaemon('/v1/tool', payload, execCtx?.signal);
          },
        });
        if (typeof off === 'function') disposers.push(off);
        registered++;
      } catch (err) {
        logger?.warn?.(`[gbridge] phone tool ${def.name} skipped:`, err?.message || err);
      }
    }
  };

  const immediateTools = ctx.get?.('tools');
  if (immediateTools && typeof immediateTools.register === 'function') {
    registerAllOn(immediateTools);
  } else if (typeof ctx.inject === 'function') {
    ctx.inject(['tools'], (toolCtx) => {
      const targetTools = toolCtx.tools ?? toolCtx.get?.('tools');
      if (typeof toolCtx.effect === 'function') {
        toolCtx.effect(() => {
          const before = disposers.length;
          registerAllOn(targetTools);
          const added = disposers.splice(before);
          return () => {
            for (const fn of added) {
              try { fn(); } catch {}
            }
            registered = Math.max(0, registered - added.length);
          };
        }, 'gbridge: phone tools');
      } else {
        registerAllOn(targetTools);
      }
    });
  }

  return {
    get active() { return registered > 0; },
    get registered() { return registered; },
    get reason() { return registered > 0 ? 'ready' : 'tools-service-unavailable'; },
    dispose() {
      activeTurnBySession.clear();
      phoneActiveSessions.clear();
      for (const fn of disposers) {
        try { fn(); } catch {}
      }
    },
  };
}
