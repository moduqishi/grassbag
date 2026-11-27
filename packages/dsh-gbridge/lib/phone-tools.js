import { request as httpRequest } from 'node:http';
import { existsSync } from 'node:fs';
import {
  imageExtensionForMediaType,
  normalizeImageMediaType,
  toCanonicalImageAttachmentRef,
} from './session-image-repair.js';
import { sanitizeToolContentBlocks, validateToolContentBlock } from './content-contract.js';
import { ignoreCleanupError, logSuppressed } from './diagnostics.js';

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
    description: 'Type text into the currently focused Android input field (password/OTP fields blocked by SafetyGate). Set submit=true to press IME Enter/Search immediately after typing.',
    properties: {
      text: { type: 'string', description: 'Text to enter into the focused editable field.' },
      submit: { type: 'boolean', description: 'Optional: press IME Enter/Search action after typing (default false).' },
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
  {
    name: 'phone_return_app',
    description: 'Bring GrassBag app back to the foreground immediately (Note: GrassBag also returns automatically when the turn finishes).',
    properties: {
      summary: { type: 'string', description: 'Optional brief Chinese completion summary shown on the floating island.' },
    },
  },
];

/**
 * Render and strictly contract-validate a phone tool's structured execution result into
 * canonical DSH content blocks (`text` / durable `image` attachment ref).
 * Exported so unit & round-trip tests can verify fail-closed payload validation directly.
 */
export function renderPhoneToolOutput(toolName, value, { logger, onViolation } = {}) {
  let candidateBlocks;
  if (value && typeof value === 'object') {
    const rawAttachment = value.image ?? value.attachment;
    const attachment = toCanonicalImageAttachmentRef(rawAttachment);
    if (attachment) {
      const { image: _img, attachment: _att, base64: _b64, ...meta } = value;
      const summary = {
        ...meta,
        width: meta.width ?? attachment.width,
        height: meta.height ?? attachment.height,
        mediaType: attachment.mediaType,
        bytes: attachment.bytes,
      };
      candidateBlocks = [
        { type: 'text', text: JSON.stringify(summary) },
        { type: 'image', attachment },
      ];
    } else if (rawAttachment && typeof rawAttachment === 'object') {
      // Malformed attachment object without valid attachmentId — let contract guard log & block cleanly.
      const { image: _img, attachment: _att, base64: _b64, ...meta } = value;
      candidateBlocks = [
        { type: 'text', text: JSON.stringify(meta) },
        { type: 'image', attachment: rawAttachment },
      ];
    } else if (typeof value.base64 === 'string') {
      // Never emit an inline `{ type: 'image', data, mimeType }` block without a durable
      // `attachment` ref — `dsh-llm-pi-ai` and `dsh-llm-deepseek` crash when replaying it!
      const { base64: _b64, ...meta } = value;
      logger?.warn?.(
        `[gbridge:phone-tools] ${toolName} stripped unpersisted inline base64 payload before DSH render`,
      );
      candidateBlocks = [
        { type: 'text', text: JSON.stringify(meta) },
      ];
    } else {
      candidateBlocks = [
        { type: 'text', text: JSON.stringify(value) },
      ];
    }
  } else {
    candidateBlocks = [
      { type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value ?? {}) },
    ];
  }
  return sanitizeToolContentBlocks(toolName, candidateBlocks, { logger, onViolation });
}

/**
 * Zero-patch native Phone Control tool bridge for Android local hosts.
 * Activates ONLY when GBRIDGE_PHONE_SOCKET and GBRIDGE_PHONE_TOKEN are provided.
 *
 * Confirmation & handoff are handled NATIVELY on Android via `TYPE_ACCESSIBILITY_OVERLAY`
 * (`PhoneOverlayController`), so phone control works reliably outside GrassBag in BOTH
 * `workspace-write` and `danger-full-access` modes with zero DSH approval deadlock!
 */
export function mountPhoneTools(ctx, { socketPath, token, logger, onContractViolation } = {}) {
  if (!socketPath || !token) {
    return { active: false, registered: 0, reason: 'not-android-host', dispose: () => {} };
  }
  if (!existsSync(socketPath)) {
    logger?.info?.(`[gbridge] phone socket not yet created at ${socketPath}; tools registered lazily`);
  }

  const disposers = [];
  const activeTurnBySession = new Map();
  const trackedActiveJobs = new Set();
  const phoneActiveSessions = new Set();
  let keepaliveTimer = null;
  let lastReportedActive = false;
  let lastReportedTurns = 0;
  let lastReportedJobs = 0;

  const isTerminalJobStatus = (rawStatus) => {
    const s = String(rawStatus || '').trim().toLowerCase();
    return s === 'completed' ||
      s === 'done' ||
      s === 'finished' ||
      s === 'success' ||
      s === 'succeeded' ||
      s === 'failed' ||
      s === 'error' ||
      s === 'killed' ||
      s === 'exited' ||
      s === 'stopped' ||
      s === 'cancelled' ||
      s === 'canceled' ||
      s === 'aborted';
  };

  const isRunningJobStatus = (rawStatus) => {
    const s = String(rawStatus || '').trim().toLowerCase();
    return s === 'running' || s === 'starting' || s === 'queued' || s === 'pending' || s === 'active';
  };

  const countActiveJobs = () => {
    const activeIds = new Set(trackedActiveJobs);
    try {
      const jobsSvc = ctx.get?.('jobs');
      const list = typeof jobsSvc?.list === 'function' ? jobsSvc.list() : [];
      if (Array.isArray(list)) {
        const seenFromService = new Set();
        for (const j of list) {
          if (!j || typeof j !== 'object') continue;
          const jid = String(j.id ?? j.jobId ?? '');
          const status = j.status ?? j.state ?? (j.running === true ? 'running' : '');
          if (jid) seenFromService.add(jid);
          if (j.running === true || isRunningJobStatus(status)) {
            if (jid) {
              activeIds.add(jid);
              trackedActiveJobs.add(jid);
            } else {
              activeIds.add(`__anon_${activeIds.size}`);
            }
          } else if (jid && isTerminalJobStatus(status)) {
            activeIds.delete(jid);
            trackedActiveJobs.delete(jid);
          }
        }
        // Reconcile any tracked job IDs removed from the live service registry as finished.
        if (typeof jobsSvc?.list === 'function' && seenFromService.size > 0) {
          for (const tracked of [...trackedActiveJobs]) {
            if (!seenFromService.has(tracked)) {
              trackedActiveJobs.delete(tracked);
              activeIds.delete(tracked);
            }
          }
        }
      }
    } catch (err) {
      logSuppressed(logger, 'phone-tools', err, { level: 'debug', detail: 'jobs.list() probe failed during keepalive' });
    }
    return activeIds.size;
  };

  const ensureKeepaliveHeartbeat = (activeCount) => {
    if (activeCount > 0) {
      if (!keepaliveTimer) {
        keepaliveTimer = setInterval(() => {
          syncKeepaliveState('heartbeat', { force: true });
        }, 90_000);
        keepaliveTimer.unref?.();
      }
    } else if (keepaliveTimer) {
      clearInterval(keepaliveTimer);
      keepaliveTimer = null;
    }
  };

  const syncKeepaliveState = (reason = '', { force = false } = {}) => {
    const activeTurns = activeTurnBySession.size;
    const activeJobs = countActiveJobs();
    const active = activeTurns > 0 || activeJobs > 0;
    const changed = active !== lastReportedActive ||
      activeTurns !== lastReportedTurns ||
      activeJobs !== lastReportedJobs;
    ensureKeepaliveHeartbeat(activeTurns + activeJobs);
    if (!force && !changed) return false;
    // On heartbeat ticks when nothing is active anymore, still emit once if previously active to release locks.
    if (!active && !lastReportedActive && !changed) return false;
    lastReportedActive = active;
    lastReportedTurns = activeTurns;
    lastReportedJobs = activeJobs;
    callDaemon('/v1/keepalive', {
      active,
      activeTurns,
      activeJobs,
      ...(reason ? { reason } : {}),
    }, undefined, 8_000).catch(() => {});
    return true;
  };

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
      res.on('error', reject);
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
    } catch (err) {
      logSuppressed(logger, 'phone-tools', err, { level: 'debug', detail: 'permission preset resolution failed' });
    }
    return null;
  };

  const normalizeTurnEndReason = (rawReason) => {
    let tag = '';
    if (typeof rawReason === 'string') {
      tag = rawReason.trim().toLowerCase();
    } else if (rawReason && typeof rawReason === 'object') {
      tag = String(rawReason.kind ?? rawReason.status ?? rawReason.type ?? rawReason.reason ?? '').trim().toLowerCase();
    }
    if (!tag || tag === 'completed' || tag === 'ok' || tag === 'done' || tag === 'success' || tag === 'end_turn' || tag === 'stop') {
      return 'completed';
    }
    if (tag.includes('emergency')) return 'emergency_stop';
    if (tag.includes('abort') || tag.includes('cancel') || tag === 'stopped' || tag === 'interrupted') {
      return 'stopped';
    }
    if (tag.includes('err') || tag.includes('fail') || tag.includes('timeout')) {
      return 'error';
    }
    return tag;
  };

  const notifyTurnStart = (sessionId, turnId = null) => {
    const sid = sessionId ? String(sessionId) : null;
    if (!sid) return false;
    activeTurnBySession.set(sid, String(turnId || `turn-${Date.now()}`));
    syncKeepaliveState('turn_start');
    return true;
  };

  const notifyTurnEnd = (sessionId, reason = 'completed', summary = '') => {
    const sid = sessionId ? String(sessionId) : null;
    if (sid) {
      activeTurnBySession.delete(sid);
    } else {
      activeTurnBySession.clear();
    }
    const shouldNotifyPhone = sid ? phoneActiveSessions.delete(sid) : phoneActiveSessions.size > 0;
    if (!sid && shouldNotifyPhone) phoneActiveSessions.clear();
    if (shouldNotifyPhone) {
      callDaemon('/v1/turn-end', {
        sessionId: sid,
        reason: normalizeTurnEndReason(reason),
        ...(summary ? { summary: String(summary).slice(0, 120) } : {}),
      }, undefined, 10_000).catch(() => {});
    }
    // Always reconcile native keepalive state on EVERY turn-end path (including fallback
    // `session.status === false` callbacks) so CPU/Wi-Fi locks never remain stuck until stale timeout!
    syncKeepaliveState('turn_end');
    return shouldNotifyPhone;
  };

  const notifyJobState = (jobId, status, reason = '') => {
    const jid = jobId ? String(jobId).trim() : '';
    const rawStatus = typeof status === 'string' ? status.trim().toLowerCase() : '';
    if (jid) {
      if (isTerminalJobStatus(rawStatus)) {
        trackedActiveJobs.delete(jid);
      } else if (isRunningJobStatus(rawStatus) || rawStatus === '') {
        trackedActiveJobs.add(jid);
      }
    }
    const tag = reason || (isTerminalJobStatus(rawStatus) ? 'job_end' : 'job_start');
    return syncKeepaliveState(tag);
  };

  // Track active turns & standalone background jobs process-wide through ONE unified keepalive
  // state updater so Android native GrassBagEngineService ALWAYS holds CPU/Wi-Fi locks while ANY
  // DSH turn or background job runs, and ALWAYS releases locks cleanly the moment work finishes!
  if (typeof ctx.on === 'function') {
    const offSession = ctx.on('session/event', (session, event) => {
      const sid = session?.id ?? null;
      if (event?.type === 'turn/start' && sid) {
        const tid = event?.data?.turnId ?? (event?.data?.turn !== undefined ? `turn-${event.data.turn}` : `seq-${event?.seq ?? Date.now()}`);
        notifyTurnStart(sid, tid);
      } else if (event?.type === 'turn/end') {
        notifyTurnEnd(sid, event?.data?.reason ?? 'completed');
      }
    });
    if (typeof offSession === 'function') disposers.push(offSession);

    const handleJobEvent = (defaultStatus) => (payloadOrId, maybeJob) => {
      const obj = (maybeJob && typeof maybeJob === 'object')
        ? maybeJob
        : ((payloadOrId && typeof payloadOrId === 'object') ? payloadOrId : null);
      const jobObj = obj?.job && typeof obj.job === 'object' ? obj.job : obj;
      const jid = jobObj?.id ?? jobObj?.jobId ?? (typeof payloadOrId === 'string' ? payloadOrId : null);
      const status = jobObj?.status ?? jobObj?.state ?? obj?.status ?? obj?.state ?? defaultStatus;
      notifyJobState(jid, status);
    };

    const jobEvents = [
      ['job/start', 'running'],
      ['job/started', 'running'],
      ['job/created', 'running'],
      ['job/updated', ''],
      ['job/state', ''],
      ['job/event', ''],
      ['job/complete', 'completed'],
      ['job/completed', 'completed'],
      ['job/end', 'completed'],
      ['job/exit', 'exited'],
      ['job/exited', 'exited'],
      ['job/fail', 'failed'],
      ['job/failed', 'failed'],
      ['job/kill', 'killed'],
      ['job/killed', 'killed'],
      ['jobs/changed', ''],
    ];
    for (const [evName, defStatus] of jobEvents) {
      try {
        const offJob = ctx.on(evName, handleJobEvent(defStatus));
        if (typeof offJob === 'function') disposers.push(offJob);
      } catch (err) {
        logSuppressed(logger, 'phone-tools', err, { level: 'debug', detail: `ctx.on(${evName}) skipped` });
      }
    }
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
            render: (_args, value) => renderPhoneToolOutput(def.name, value, {
              logger,
              onViolation: onContractViolation,
            }),
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
            const result = await callDaemon('/v1/tool', payload, execCtx?.signal);
            if (result && typeof result === 'object' && typeof result.base64 === 'string' && result.base64.length > 0) {
              const { base64, ...meta } = result;
              const mediaType = normalizeImageMediaType(result.mimeType ?? result.mediaType);
              const attachments = ctx.get?.('attachments');
              if (attachments && typeof attachments.saveImage === 'function') {
                try {
                  const bytes = Buffer.from(base64, 'base64');
                  if (bytes.length > 0) {
                    const ext = imageExtensionForMediaType(mediaType);
                    const ref = await attachments.saveImage({
                      data: bytes,
                      mediaType,
                      name: `phone-screenshot-${Date.now()}.${ext}`,
                    });
                    const canonical = toCanonicalImageAttachmentRef(ref);
                    const check = canonical ? validateToolContentBlock({ type: 'image', attachment: canonical }) : null;
                    if (canonical && check?.ok) {
                      return {
                        ...meta,
                        mediaType: check.normalized.attachment.mediaType,
                        width: check.normalized.attachment.width,
                        height: check.normalized.attachment.height,
                        bytes: check.normalized.attachment.bytes,
                        image: check.normalized.attachment,
                      };
                    }
                    logger?.warn?.(
                      `[gbridge:phone-tools] ${def.name} saveImage returned invalid attachment ref: ${check?.detail || 'missing attachmentId'}`,
                    );
                    return {
                      ...meta,
                      imageError: check?.reason || 'invalid_attachment_ref',
                    };
                  }
                } catch (err) {
                  logger?.warn?.(`[gbridge] failed to persist ${def.name} screenshot via ctx.attachments.saveImage:`, err?.message || err);
                  return {
                    ...meta,
                    imageError: err?.message || 'save_image_failed',
                  };
                }
              }
              logger?.warn?.(`[gbridge] ${def.name} omitted image block because ctx.attachments is unavailable`);
              return {
                ...meta,
                imageError: 'attachments_service_unavailable',
              };
            }
            return result;
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
              try { fn(); } catch (err) { ignoreCleanupError(err); }
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
    notifyTurnStart,
    notifyTurnEnd,
    notifyJobState,
    syncKeepalive: syncKeepaliveState,
    dispose() {
      if (keepaliveTimer) {
        clearInterval(keepaliveTimer);
        keepaliveTimer = null;
      }
      activeTurnBySession.clear();
      trackedActiveJobs.clear();
      if (lastReportedActive) {
        lastReportedActive = false;
        lastReportedTurns = 0;
        lastReportedJobs = 0;
        callDaemon('/v1/keepalive', {
          active: false,
          activeTurns: 0,
          activeJobs: 0,
          reason: 'dispose',
        }, undefined, 8_000).catch(() => {});
      }
      phoneActiveSessions.clear();
      for (const fn of disposers) {
        try { fn(); } catch (err) { ignoreCleanupError(err); }
      }
    },
  };
}
