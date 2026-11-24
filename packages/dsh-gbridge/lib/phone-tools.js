import { request as httpRequest } from 'node:http';
import { existsSync } from 'node:fs';

const PHONE_TOOL_DEFS = [
  {
    name: 'phone_screen',
    description: 'Read current Android screen accessibility tree through SafetyGate (sensitive fields are redacted).',
    properties: {
      maxNodes: { type: 'integer', description: 'Maximum UI nodes to return (default 120).' },
    },
  },
  {
    name: 'phone_tap',
    description: 'Tap screen coordinates (x, y) on the Android display through SafetyGate.',
    properties: {
      x: { type: 'number', description: 'Horizontal screen coordinate in pixels.' },
      y: { type: 'number', description: 'Vertical screen coordinate in pixels.' },
    },
    required: ['x', 'y'],
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
    description: 'Open an Android app package or http(s) URL through SafetyGate.',
    properties: {
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
    name: 'phone_handoff',
    description: 'Pause and hand control back to the human user for sensitive/manual steps.',
    properties: {
      message: { type: 'string', description: 'Instruction shown to the user.' },
    },
  },
];

/**
 * Zero-patch native Phone Control tool bridge for Android local hosts.
 * Activates ONLY when GBRIDGE_PHONE_SOCKET and GBRIDGE_PHONE_TOKEN are provided.
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

  const callDaemon = (path, payload, signal) => new Promise((resolve, reject) => {
    const body = JSON.stringify(payload);
    const req = httpRequest({
      socketPath,
      path,
      method: 'POST',
      timeout: 30_000,
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
          else reject(new Error(json?.reason || json?.error?.message || `phone daemon HTTP ${res.statusCode}`));
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

  // Track active turns & forward turn/end so Kotlin SafetyGate locks/unlocks accurately.
  if (typeof ctx.on === 'function') {
    const off = ctx.on('session/event', (session, event) => {
      const sid = session?.id ?? null;
      if (event?.type === 'turn/start' && sid) {
        const tid = event?.data?.turnId ?? (event?.data?.turn !== undefined ? `turn-${event.data.turn}` : `seq-${event?.seq ?? Date.now()}`);
        activeTurnBySession.set(sid, String(tid));
      } else if (event?.type === 'turn/end') {
        if (sid) activeTurnBySession.delete(sid);
        callDaemon('/v1/turn-end', {
          sessionId: sid,
          reason: event?.data?.reason ?? 'completed',
        }).catch(() => {});
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
            // DSH tools pipeline invokes `output.render(exec.arguments, value)` and expects `ContentPart[]`.
            render: (_args, value) => [
              { type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value ?? {}) },
            ],
          },
          async execute(args, execCtx) {
            const sessionId = execCtx?.agent?.session?.id ?? execCtx?.session?.id ?? null;
            const turnId = execCtx?.turnId
              ?? (sessionId ? activeTurnBySession.get(sessionId) : null)
              ?? execCtx?.rootCallId
              ?? execCtx?.callId
              ?? null;
            const payload = {
              tool: def.name,
              args: args ?? {},
              caller: { sessionId, turnId },
            };
            try {
              return await callDaemon('/v1/tool', payload, execCtx?.signal);
            } catch (err) {
              const msg = String(err?.message || '');
              const approval = ctx.get?.('approval');
              if (
                msg.includes('requires_user_confirmation') &&
                approval &&
                typeof approval.request === 'function' &&
                execCtx?.agent
              ) {
                const summaryArgs = JSON.stringify(args ?? {}).slice(0, 180);
                const outcome = await approval.request({
                  agent: execCtx.agent,
                  toolName: def.name,
                  callId: execCtx.callId,
                  reason: `手机操作确认：${def.name} ${summaryArgs}`,
                  signal: execCtx.signal,
                });
                if (outcome === 'allowed-once') {
                  return await callDaemon(
                    '/v1/tool',
                    { ...payload, userApproved: true },
                    execCtx?.signal,
                  );
                }
                const policy = typeof approval.effectivePolicy === 'function'
                  ? approval.effectivePolicy(execCtx.agent?.session)
                  : null;
                if (policy === 'never') {
                  return {
                    ok: false,
                    blocked: true,
                    reason: 'approval_policy_never_blocks_phone_confirm',
                    hint: '当前会话权限为完全放行(approval=never)不会弹出确认卡片；请在操控手机设置中切换为「本轮允许」或将对话权限切回「工作区内修改」',
                  };
                }
                return { ok: false, blocked: true, reason: `user_${outcome || 'rejected'}` };
              }
              throw err;
            }
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
      for (const fn of disposers) {
        try { fn(); } catch {}
      }
    },
  };
}
