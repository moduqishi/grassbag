import { randomUUID } from 'node:crypto';
import { isPlainObject } from './http-util.js';
import { extractFailureInfo } from './normalizer.js';
import { ignoreCleanupError, logSuppressed } from './diagnostics.js';

const DEFAULT_REPLAY_CAPACITY = 2000;
const DEFAULT_REPLAY_MAX_BYTES = 4 * 1024 * 1024;
const DEFAULT_DURABLE_REPLAY_MAX_BYTES = 2 * 1024 * 1024;
const DEFAULT_COALESCE_MS = 35;
const HEARTBEAT_MS = 20000;
const MAX_CHANNELS_PER_CLIENT = 64;

function estimateDeltaBytes(data) {
  if (!data || typeof data !== 'object') return 128;
  let n = 128;
  const ch = data.chunk;
  if (typeof ch === 'string') {
    n += ch.length * 2;
  } else if (ch && typeof ch === 'object') {
    if (typeof ch.text === 'string') n += ch.text.length * 2;
    else if (typeof ch.delta === 'string') n += ch.delta.length * 2;
    else if (Array.isArray(ch.texts)) {
      for (const s of ch.texts) if (typeof s === 'string') n += s.length * 2;
    } else {
      n += 128;
    }
  }
  return n;
}

function normalizeTurnEndReasonTag(rawReason, hasFailure = false) {
  if (hasFailure) return 'error';
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
}

/**
 * Plane A Multiplexed Stream Hub (`/gbridge/v1/stream`):
 * - Global monotonic `seq` + bounded ring buffer for `resumeFromSeq` reconnect replay
 * - Ref-counted upstream DSH streams (`session/follow`, `terminal/follow`, `job/follow`)
 * - Single shared `$events` pump tracking live pending interactions (approvals / questions / cordis)
 * - Per-client 35ms delta coalescing for smooth 120Hz mobile streaming
 */
function createAsyncQueue(signal) {
  const items = [];
  const waiters = [];
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    while (waiters.length > 0) waiters.shift()({ value: undefined, done: true });
  };
  signal?.addEventListener?.('abort', close, { once: true });
  return {
    push(value) {
      if (closed) return;
      if (waiters.length > 0) waiters.shift()({ value, done: false });
      else items.push(value);
    },
    close,
    [Symbol.asyncIterator]() {
      return {
        next() {
          if (items.length > 0) return Promise.resolve({ value: items.shift(), done: false });
          if (closed) return Promise.resolve({ value: undefined, done: true });
          return new Promise((resolve) => waiters.push(resolve));
        },
        return() {
          close();
          return Promise.resolve({ value: undefined, done: true });
        },
      };
    },
  };
}

function sessionFollowUsesAddress(gateway) {
  try {
    const desc = gateway?.typert?.local?.get?.('session/follow');
    return Boolean(desc?.parameters?.[0]?.codec?.jsonSchema?.properties?.address);
  } catch {
    return false;
  }
}

export class StreamHub {
  constructor({
    bootId,
    gateway,
    normalizer,
    logger,
    replayCapacity = DEFAULT_REPLAY_CAPACITY,
    durableReplayMaxBytes = DEFAULT_DURABLE_REPLAY_MAX_BYTES,
  } = {}) {
    this.bootId = bootId || randomUUID();
    this.gateway = gateway;
    this.normalizer = normalizer;
    this.logger = logger;
    this.replayCapacity = replayCapacity;
    this.durableReplayMaxBytes = durableReplayMaxBytes;

    this.seq = 0;
    this.ring = []; // { seq, bytes, frame }
    this.ringHead = 0;
    this.ringEvictedSeq = 0;
    this.durableRing = []; // { seq, bytes, frame } (bounded non-delta events protected from high-rate delta eviction)
    this.durableRingHead = 0;
    this.latestSnapshots = new Map(); // channel -> latest snapshot frame for late-joining subscribers
    this.ringBytes = 0;
    this.durableRingBytes = 0;

    this.clients = new Map(); // clientId -> ClientState
    this.upstreamStreams = new Map(); // channel -> { subscribers: Set<clientId>, abort: AbortController }
    this.activeTurns = new Map(); // sessionId -> active server turnId (e.g. 'turn-1')
    this.pendingTurnEndTimers = new Map(); // sessionId -> fallback timer handle
    this.tornDownChannels = new Set(); // channels whose upstream closed after idle grace (must force client resync)
    this.pendingInteractions = new Map(); // interactionId -> { id, kind, event, eventId, gatewayClientId, sessionId, payload, createdAt }
    this.sessionAlwaysAllowed = new Map(); // sessionId -> Set<toolKey> (honors 'always' approval within the session)

    this._eventsAbort = null;
    this._eventsClientId = null;
    this._eventsPeer = null;
    this._eventsReconnectTimer = null;
    this._onTurnStarted = null;
    this._onTurnCompleted = null;
    this._onJobStateChanged = null;
    this._disposed = false;
    this._heartbeatTimer = setInterval(() => this._sendHeartbeats(), HEARTBEAT_MS);
    this._heartbeatTimer.unref?.();
  }

  /** Register an internal observer notified whenever a session begins a turn/run. */
  setOnTurnStarted(fn) {
    this._onTurnStarted = typeof fn === 'function' ? fn : null;
  }

  /** Register an internal observer notified whenever a session finishes a turn/run. */
  setOnTurnCompleted(fn) {
    this._onTurnCompleted = typeof fn === 'function' ? fn : null;
  }

  /** Register an internal observer notified whenever a background job reports running/terminal state. */
  setOnJobStateChanged(fn) {
    this._onJobStateChanged = typeof fn === 'function' ? fn : null;
  }

  _scheduleHostEventReconnect(delayMs) {
    if (this._disposed || !this.gateway?.ready) return;
    if (this._eventsReconnectTimer) {
      clearTimeout(this._eventsReconnectTimer);
      this._eventsReconnectTimer = null;
    }
    this._eventsReconnectTimer = setTimeout(() => {
      this._eventsReconnectTimer = null;
      this.startHostEventPump();
    }, delayMs);
    this._eventsReconnectTimer.unref?.();
  }

  /** Start background pump consuming DSH's official `$events` stream. */
  startHostEventPump() {
    if (this._disposed || this._eventsAbort) return;
    if (!this.gateway?.ready) return;
    const peer = this.gateway.resolvePeer();
    if (!peer) {
      this._scheduleHostEventReconnect(500);
      return;
    }
    this._eventsPeer = peer;
    const abort = new AbortController();
    this._eventsAbort = abort;
    let stream = null;
    try {
      stream = this.gateway.openRemoteEvents(abort.signal, peer);
    } catch (err) {
      this.logger?.warn?.('[gbridge] openRemoteEvents failed:', err?.message || err);
      this._eventsAbort = null;
      this._eventsPeer = null;
      this._scheduleHostEventReconnect(1500);
      return;
    }
    if (!stream) {
      this._eventsAbort = null;
      this._eventsPeer = null;
      this._scheduleHostEventReconnect(1500);
      return;
    }
    const signal = abort.signal;
    (async () => {
      try {
        for await (const frame of stream) {
          if (signal.aborted || this._disposed) break;
          this._handleHostEventFrame(frame);
        }
      } catch (err) {
        if (!signal.aborted && !this._disposed) {
          this.logger?.warn?.('[gbridge] host $events pump ended:', err?.message || err);
        }
      } finally {
        const staleClientId = this._eventsClientId;
        this._eventsClientId = null;
        this._eventsAbort = null;
        this._eventsPeer = null;
        if (staleClientId) {
          for (const [id, item] of [...this.pendingInteractions.entries()]) {
            if (item.gatewayClientId === staleClientId) {
              this.pendingInteractions.delete(id);
              this.publish('host', 'interaction.resolved', { id, kind: item.kind, reason: 'host_disconnected' });
            }
          }
        }
        this._scheduleHostEventReconnect(1500);
      }
    })();
  }

  _handleHostEventFrame(frame) {
    if (!frame || typeof frame !== 'object') return;
    if (frame.type === 'ready') {
      this._eventsClientId = frame.clientId || null;
      this.publish('host', 'host.ready', { home: frame.host?.home ?? null });
      return;
    }
    if (frame.type === 'emit') {
      const ev = String(frame.event || '');
      const args = Array.isArray(frame.args) ? frame.args : [];
      if (ev === 'cordis/request-run') {
        const req = args[0] ?? {};
        const id = String(req.id || req.requestId || randomUUID());
        const item = {
          id,
          kind: 'cordis_run',
          event: ev,
          sessionId: req.agentId ?? req.sessionId ?? null,
          gatewayClientId: this._eventsClientId,
          gatewayPeer: this._eventsPeer,
          payload: req,
          createdAt: Date.now(),
        };
        this.pendingInteractions.set(id, item);
        this.publish('host', 'interaction.requested', sanitizeInteraction(item));
        return;
      }
      if (ev === 'cordis/request-run-resolved') {
        const req = args[0] ?? {};
        const id = String(req.id || req.requestId || '');
        if (id && this.pendingInteractions.delete(id)) {
          this.publish('host', 'interaction.resolved', { id, kind: 'cordis_run', resolution: req });
        }
        return;
      }
      if (ev === 'api-session/removed' || ev === 'api-session/archived') {
        const sid = args[0]?.sessionId ?? args[0]?.id ?? (typeof args[0] === 'string' ? args[0] : null);
        if (sid) this.sessionAlwaysAllowed.delete(String(sid));
      }
      const mapped = mapHostEmitEvent(ev, args);
      if (mapped.type === 'session.status' && Array.isArray(args) && args.length >= 2) {
        const statusSid = args[0] != null ? String(args[0]) : null;
        if (statusSid && args[1] === true) {
          this._clearPendingTurnEndTimer(statusSid);
          try {
            this._onTurnStarted?.({ sessionId: statusSid, turnId: this.activeTurns.get(statusSid) ?? null });
          } catch (err) {
            logSuppressed(this.logger, 'stream-hub', err, { detail: `onTurnStarted failed for ${statusSid}` });
          }
        } else if (statusSid && args[1] === false) {
          this._clearPendingTurnEndTimer(statusSid);
          // Defer fallback turn-end notification briefly so the authoritative `turn/end` event
          // (carrying error/abort/completed reason) wins first and is never overwritten as 'completed'.
          const fallbackTimer = setTimeout(() => {
            this.pendingTurnEndTimers.delete(statusSid);
            if (this._disposed) return;
            try {
              this._onTurnCompleted?.({ sessionId: statusSid, reason: 'completed' });
            } catch (err) {
              logSuppressed(this.logger, 'stream-hub', err, { detail: `fallback onTurnCompleted failed for ${statusSid}` });
            }
          }, 250);
          fallbackTimer.unref?.();
          this.pendingTurnEndTimers.set(statusSid, fallbackTimer);
        }
      }
      this.publish(mapped.channel, mapped.type, mapped.data);
      return;
    }
    if (frame.type === 'waterfall' || frame.type === 'request') {
      const ev = String(frame.event || '');
      const eventId = String(frame.eventId || randomUUID());
      const kind = ev === 'approval/request'
        ? 'approval'
        : ev === 'user-questions/request'
          ? 'user_questions'
          : 'request';
      const item = {
        id: eventId,
        kind,
        event: ev,
        eventId,
        gatewayClientId: this._eventsClientId,
        gatewayPeer: this._eventsPeer,
        sessionId: frame.agentId ?? frame.request?.sessionId ?? null,
        payload: frame.request ?? frame.payload ?? frame,
        createdAt: Date.now(),
      };
      // Honor prior session-wide "本次均允许" (`always`) for the exact same session & concrete tool!
      // NEVER record/match wildcard '*' or auto-approve `phone_*` tools across turns.
      if (kind === 'approval' && item.sessionId && item.gatewayClientId) {
        const sidKey = String(item.sessionId);
        const toolKey = String(
          item.payload?.toolName ?? item.payload?.tool ?? item.payload?.name ?? item.payload?.kind ?? '',
        ).trim().toLowerCase();
        const allowedTools = this.sessionAlwaysAllowed.get(sidKey);
        if (toolKey && toolKey !== '*' && !toolKey.startsWith('phone_') && allowedTools && allowedTools.has(toolKey)) {
          this.gateway.respondRemoteEvent(
            item.gatewayClientId,
            item.eventId,
            { kind: 'result', value: 'allowed-once' },
            undefined,
            item.gatewayPeer,
          ).catch(() => {
            if (!this._disposed && this._eventsClientId === item.gatewayClientId && !this.pendingInteractions.has(eventId)) {
              this.pendingInteractions.set(eventId, item);
              this.publish('host', 'interaction.requested', sanitizeInteraction(item));
            }
          });
          return;
        }
      }
      this.pendingInteractions.set(eventId, item);
      this.publish('host', 'interaction.requested', sanitizeInteraction(item));
      return;
    }
    if (frame.type === 'cancel' || frame.type === 'resolved') {
      const eventId = String(frame.eventId || '');
      if (eventId && this.pendingInteractions.delete(eventId)) {
        this.publish('host', 'interaction.resolved', { id: eventId, reason: frame.reason || 'settled_elsewhere' });
      }
    }
  }

  listPendingInteractions() {
    return [...this.pendingInteractions.values()].map(sanitizeInteraction);
  }

  async respondInteraction(id, { decision, answers, outcome } = {}, signal) {
    const item = this.pendingInteractions.get(id);
    if (!item || item._settling) return null;
    item._settling = true;
    try {
      if (item.kind === 'cordis_run') {
        const isAllow = decision === 'allow' || decision === 'approve' || decision === 'allowed-once' || decision === 'always';
        if (this.gateway?.has('dynamicCordisRunner/resolveRequestRun')) {
          let resolution;
          if (isAllow) {
            let pluginRunId = null;
            if (this.gateway?.has('dynamicCordisRunner/runHostHalf') && item.payload?.pluginId && item.payload?.packageId) {
              const runRes = await this.gateway.call('dynamicCordisRunner/runHostHalf', {
                agentId: item.sessionId ?? item.payload.agentId,
                pluginId: item.payload.pluginId,
                packageId: item.payload.packageId,
                mode: item.payload.mode ?? 'host',
                requestId: id,
                approveFutureVersions: decision === 'always',
              }, { signal, peer: item.gatewayPeer });
              pluginRunId = runRes?.pluginRunId ?? runRes?.id ?? null;
            }
            resolution = pluginRunId ? { ok: true, pluginRunId } : { ok: true, approved: true };
          } else {
            resolution = { ok: false, reason: 'rejected' };
          }
          await this.gateway.call('dynamicCordisRunner/resolveRequestRun', {
            requestId: id,
            resolution,
          }, { signal, peer: item.gatewayPeer });
        } else if (isAllow) {
          throw new Error('host DSH does not expose dynamicCordisRunner/resolveRequestRun');
        }
      } else if (item.gatewayClientId && item.eventId) {
        let wireOutcome = outcome;
        if (!wireOutcome) {
          if (decision === 'pass') {
            wireOutcome = { kind: 'next' };
          } else if (item.kind === 'approval') {
            const d = String(decision || '').toLowerCase();
            if (d === 'always' && item.sessionId) {
              const sidKey = String(item.sessionId);
              const toolKey = String(
                item.payload?.toolName ?? item.payload?.tool ?? item.payload?.name ?? item.payload?.kind ?? '',
              ).trim().toLowerCase();
              if (toolKey && toolKey !== '*' && !toolKey.startsWith('phone_')) {
                let set = this.sessionAlwaysAllowed.get(sidKey);
                if (!set) {
                  if (this.sessionAlwaysAllowed.size >= 256) {
                    const oldestKey = this.sessionAlwaysAllowed.keys().next().value;
                    if (oldestKey !== undefined) this.sessionAlwaysAllowed.delete(oldestKey);
                  }
                  set = new Set();
                  this.sessionAlwaysAllowed.set(sidKey, set);
                }
                set.add(toolKey);
              }
            }
            const normalized = (d === 'allow' || d === 'approve' || d === 'allowed-once' || d === 'always')
              ? 'allowed-once'
              : (d === 'cancel' || d === 'cancelled')
                ? 'cancelled'
                : 'rejected';
            wireOutcome = { kind: 'result', value: normalized };
          } else if (item.kind === 'user_questions') {
            const dLow = typeof decision === 'string' ? decision.trim().toLowerCase() : '';
            if (answers === undefined && (dLow === 'cancel' || dLow === 'cancelled' || dLow === 'dismiss' || dLow === 'skip')) {
              wireOutcome = { kind: 'next' };
            } else {
              const rawAns = answers !== undefined ? answers : decision;
              let wrapped = rawAns;
              if (Array.isArray(rawAns)) {
                const qs = Array.isArray(item.payload?.questions) ? item.payload.questions : [];
                const alreadyStructured = rawAns.every((a) => a && typeof a === 'object' && typeof a.id === 'string');
                wrapped = {
                  answers: alreadyStructured
                    ? rawAns
                    : [{ id: String(qs[0]?.id ?? 'q-0'), selected: rawAns.map(String) }],
                };
              } else if (typeof rawAns === 'string') {
                const qs = Array.isArray(item.payload?.questions) ? item.payload.questions : [];
                wrapped = { answers: [{ id: String(qs[0]?.id ?? 'q-0'), selected: [rawAns], custom: rawAns }] };
              } else if (rawAns && typeof rawAns === 'object' && !Array.isArray(rawAns.answers)) {
                wrapped = {
                  answers: Object.entries(rawAns).map(([qid, val]) => ({
                    id: qid,
                    selected: Array.isArray(val) ? val.map(String) : [String(val)],
                  })),
                };
              }
              wireOutcome = { kind: 'result', value: wrapped };
            }
          } else {
            wireOutcome = { kind: 'result', value: answers !== undefined ? answers : decision };
          }
        }
        await this.gateway.respondRemoteEvent(
          item.gatewayClientId,
          item.eventId,
          wireOutcome,
          signal,
          item.gatewayPeer,
        );
      }
      this.pendingInteractions.delete(id);
      this.publish('host', 'interaction.resolved', { id, kind: item.kind, settledBy: 'gbridge' });
      return { id, settled: true };
    } catch (err) {
      item._settling = false;
      throw err;
    }
  }

  _clearPendingTurnEndTimer(sessionId) {
    if (!sessionId) return;
    const t = this.pendingTurnEndTimers.get(sessionId);
    if (t) {
      clearTimeout(t);
      this.pendingTurnEndTimers.delete(sessionId);
    }
  }

  /** Publish a durable event into the ring buffer and deliver to subscribed clients. */
  publish(channel, type, data, { isDelta = false } = {}) {
    const seq = ++this.seq;
    const frame = {
      op: isDelta ? 'delta' : 'event',
      seq,
      channel,
      type,
      ts: Date.now(),
      data,
    };
    // Avoid wasted JSON.stringify on coalesced high-rate deltas; serialize lazily only when sent directly.
    let serialized = null;
    const getSerialized = () => {
      if (serialized === null) serialized = JSON.stringify(frame);
      return serialized;
    };
    const bytes = isDelta ? estimateDeltaBytes(data) : Buffer.byteLength(getSerialized());
    this.ring.push({ seq, bytes, frame });
    this.ringBytes += bytes;
    while (
      (this.ring.length - this.ringHead) > this.replayCapacity ||
      (this.ringBytes > DEFAULT_REPLAY_MAX_BYTES && (this.ring.length - this.ringHead) > 1)
    ) {
      const dropped = this.ring[this.ringHead];
      this.ring[this.ringHead] = undefined;
      this.ringHead += 1;
      this.ringBytes -= dropped.bytes;
      if (dropped && typeof dropped.seq === 'number' && dropped.seq > this.ringEvictedSeq) {
        this.ringEvictedSeq = dropped.seq;
      }
    }
    if (this.ringHead >= 256 && this.ringHead * 2 >= this.ring.length) {
      this.ring = this.ring.slice(this.ringHead);
      this.ringHead = 0;
    }
    if (!isDelta) {
      if (type === 'turn.snapshot' || type === 'term.snapshot') {
        this.latestSnapshots.set(channel, frame);
        if (this.latestSnapshots.size > 64) {
          const oldestCh = this.latestSnapshots.keys().next().value;
          if (oldestCh !== undefined) this.latestSnapshots.delete(oldestCh);
        }
      } else {
        this.durableRing.push({ seq, bytes, frame });
        this.durableRingBytes += bytes;
        while (
          (this.durableRing.length - this.durableRingHead) > 250 ||
          (this.durableRingBytes > this.durableReplayMaxBytes &&
            (this.durableRing.length - this.durableRingHead) > 1)
        ) {
          const dropped = this.durableRing[this.durableRingHead];
          this.durableRing[this.durableRingHead] = undefined;
          this.durableRingHead += 1;
          this.durableRingBytes -= dropped.bytes;
        }
        if (this.durableRingHead >= 64 && this.durableRingHead * 2 >= this.durableRing.length) {
          this.durableRing = this.durableRing.slice(this.durableRingHead);
          this.durableRingHead = 0;
        }
        if (
          channel.startsWith('session:') &&
          (type === 'turn.start' ||
            type === 'turn.completed' ||
            type === 'turn.cancelled' ||
            type === 'turn.error' ||
            type === 'session.event' ||
            type === 'projection.updated')
        ) {
          // Invalidate cached initial turn.snapshot once newer durable session frames arrive
          // so re-subscribing during the 8s grace window never rewinds the client to an old turn!
          this.latestSnapshots.delete(channel);
        }
      }
    }

    const MAX_CLIENT_BUFFER_BYTES = 4 * 1024 * 1024;
    const HARD_CLIENT_BUFFER_BYTES = 8 * 1024 * 1024;
    for (const client of [...this.clients.values()]) {
      if (!client.welcomed || !client.channels.has(channel)) continue;
      const buffered = client.ws.socket?.writableLength ?? 0;
      if (buffered > HARD_CLIENT_BUFFER_BYTES || (isDelta && buffered > MAX_CLIENT_BUFFER_BYTES)) {
        // Disconnect congested slow consumer cleanly so it reconnects & resyncs instead of
        // silently corrupting streaming text/terminal output or growing write buffers unboundedly!
        try { client.ws.close(1013, 'slow consumer'); } catch (err) { ignoreCleanupError(err); }
        try { client.ws.terminate?.(); } catch (err) { ignoreCleanupError(err); }
        this._detachClient(client);
        continue;
      }
      if (isDelta && client.coalesceMs > 0) {
        this._enqueueDelta(client, frame);
      } else {
        this._flushClientDeltas(client);
        client.ws.sendText(getSerialized());
      }
    }
    return frame;
  }

  /** Attach an upgraded WebSocket connection to the hub. */
  attachClient(ws, { peer, mode = 'webServer' } = {}) {
    if (this._disposed) {
      try { ws.close(1001, 'gbridge reloading'); } catch (err) { ignoreCleanupError(err); }
      return null;
    }
    const connId = randomUUID();
    const state = {
      id: connId,
      clientId: null,
      mode,
      ws,
      peer,
      welcomed: false,
      coalesceMs: DEFAULT_COALESCE_MS,
      channels: new Set(['host']),
      pendingDeltas: new Map(), // `${channel}:${type}` -> merged frame
      coalesceTimer: null,
      lastAckSeq: 0,
      missedPongs: 0,
    };
    this.clients.set(connId, state);

    ws.on('pong', () => {
      state.missedPongs = 0;
    });

    ws.on('message', (raw, isBinary) => {
      state.missedPongs = 0;
      if (isBinary) return;
      let msg;
      try {
        msg = JSON.parse(raw);
      } catch {
        ws.sendJson({ op: 'error', code: 'gbridge/invalid_frame', message: 'frame must be valid JSON' });
        return;
      }
      if (!isPlainObject(msg) || typeof msg.op !== 'string') {
        ws.sendJson({ op: 'error', code: 'gbridge/invalid_frame', message: 'frame requires string op' });
        return;
      }
      this._onClientMessage(state, msg);
    });

    ws.on('close', () => this._detachClient(state));
    ws.on('error', () => this._detachClient(state));
    return connId;
  }

  /** Immediately disconnect active WebSocket clients attached via a specific listener mode (e.g. 'lan' on token rotation). */
  disconnectByMode(mode, code = 4001, reason = 'authorization revoked') {
    let closedCount = 0;
    for (const client of [...this.clients.values()]) {
      if (client.mode !== mode) continue;
      closedCount++;
      this._detachClient(client);
      try { client.ws.close(code, reason); } catch (err) { ignoreCleanupError(err); }
    }
    return closedCount;
  }

  _onClientMessage(client, msg) {
    if (msg.op !== 'hello' && msg.op !== 'ping' && !client.welcomed) {
      client.ws.sendJson({ op: 'error', code: 'gbridge/handshake_required', message: 'send hello before other frames' });
      return;
    }
    switch (msg.op) {
      case 'hello': {
        client.clientId = typeof msg.clientId === 'string' ? msg.clientId.slice(0, 128) : client.id;
        if (typeof msg.coalesceMs === 'number' && Number.isFinite(msg.coalesceMs)) {
          client.coalesceMs = Math.max(0, Math.min(250, Math.round(msg.coalesceMs)));
        }
        const requestedChannels = [];
        if (Array.isArray(msg.channels)) {
          for (const ch of msg.channels) {
            if (requestedChannels.length >= MAX_CHANNELS_PER_CLIENT) break;
            if (typeof ch === 'string' && ch.length > 0 && ch.length <= 160) {
              requestedChannels.push(ch);
            }
          }
        }
        const replayChannelSet = new Set([...client.channels, ...requestedChannels]);
        client.welcomed = true;

        const oldestRingSeq = this.ringHead < this.ring.length ? this.ring[this.ringHead].seq : this.seq + 1;
        const oldestDurableSeq = this.durableRingHead < this.durableRing.length
          ? this.durableRing[this.durableRingHead].seq
          : oldestRingSeq;
        let requiresContiguousRing = false;
        let hasStreamChannel = false;
        let hasTornDownChannel = false;
        for (const ch of replayChannelSet) {
          if (this.tornDownChannels.has(ch)) {
            hasTornDownChannel = true;
          }
          if (ch.startsWith('session:')) {
            hasStreamChannel = true;
            const sid = ch.slice('session:'.length);
            if (this.activeTurns.has(sid)) {
              requiresContiguousRing = true;
            }
          } else if (ch.startsWith('terminal:') || ch.startsWith('job:')) {
            hasStreamChannel = true;
            requiresContiguousRing = true;
          }
        }
        // When an active streaming turn or terminal/job delta channel is subscribed, ephemeral
        // delta frames only live in `this.ring`; also require `resumeFromSeq >= this.ringEvictedSeq`
        // for any stream channel so completed turns whose deltas/snapshots were evicted from `ring`
        // during disconnect cleanly return `resumed: false` and trigger a full resync.
        const oldestSeq = requiresContiguousRing
          ? oldestRingSeq
          : Math.min(oldestRingSeq, oldestDurableSeq);
        const minResumeSeq = hasStreamChannel
          ? Math.max(oldestSeq - 1, this.ringEvictedSeq)
          : oldestSeq - 1;
        const canResume = !hasTornDownChannel &&
          msg.lastBootId === this.bootId &&
          typeof msg.resumeFromSeq === 'number' &&
          Number.isInteger(msg.resumeFromSeq) &&
          msg.resumeFromSeq >= minResumeSeq &&
          msg.resumeFromSeq <= this.seq;

        let replayFrames = [];
        if (canResume) {
          const bySeq = new Map();
          for (let i = this.durableRingHead; i < this.durableRing.length; i++) {
            const entry = this.durableRing[i];
            if (entry && entry.seq > msg.resumeFromSeq && replayChannelSet.has(entry.frame.channel)) {
              bySeq.set(entry.seq, entry);
            }
          }
          for (let i = this.ringHead; i < this.ring.length; i++) {
            const entry = this.ring[i];
            if (entry && entry.seq > msg.resumeFromSeq && replayChannelSet.has(entry.frame.channel)) {
              bySeq.set(entry.seq, entry);
            }
          }
          replayFrames = [...bySeq.values()].sort((a, b) => a.seq - b.seq);
        }

        client.ws.sendJson({
          op: 'welcome',
          v: 1,
          bootId: this.bootId,
          currentSeq: this.seq,
          resumed: canResume,
          replayedCount: replayFrames.length,
          heartbeatMs: HEARTBEAT_MS,
          pendingInteractions: this.listPendingInteractions(),
        });
        let lastDeliveredSeq = canResume ? msg.resumeFromSeq : 0;
        for (const entry of replayFrames) {
          client.ws.sendJson(entry.frame);
          if (typeof entry.seq === 'number' && entry.seq > lastDeliveredSeq) {
            lastDeliveredSeq = entry.seq;
          }
        }
        // Start upstream channel pumps AFTER `welcome` is sent so any synchronous `.unavailable`
        // error frame reaches the welcomed client and never skews `welcome.currentSeq`!
        // Pass `minSnapshotSeq` on resumed reconnects so cached snapshots older than already-replayed
        // frames NEVER rewind client state!
        for (const ch of requestedChannels) {
          this._subscribeChannel(client, ch, { minSnapshotSeq: canResume ? lastDeliveredSeq : 0 });
        }
        break;
      }
      case 'sub': {
        const list = Array.isArray(msg.channels) ? msg.channels : (typeof msg.channel === 'string' ? [msg.channel] : []);
        for (const ch of list) {
          if (typeof ch === 'string' && ch.length > 0 && ch.length <= 160) {
            this._subscribeChannel(client, ch);
          }
        }
        break;
      }
      case 'unsub': {
        const list = Array.isArray(msg.channels) ? msg.channels : (typeof msg.channel === 'string' ? [msg.channel] : []);
        for (const ch of list) {
          if (typeof ch === 'string' && ch !== 'host') {
            this._unsubscribeChannel(client, ch);
          }
        }
        break;
      }
      case 'ack': {
        if (typeof msg.seq === 'number') client.lastAckSeq = Math.max(client.lastAckSeq, msg.seq);
        break;
      }
      case 'ping': {
        client.ws.sendJson({ op: 'pong', ts: Date.now(), ...(msg.id !== undefined ? { id: msg.id } : {}) });
        break;
      }
      case 'term.input': {
        if (typeof msg.terminalId === 'string' && typeof msg.data === 'string') {
          const entry = this._findTerminalUpstream(msg.terminalId);
          if (entry?.uplink) {
            entry.uplinkSeq = (entry.uplinkSeq || 0) + 1;
            entry.uplink.push({ type: 'write', sequence: entry.uplinkSeq, data: msg.data, typed: true });
          } else if (this.gateway?.has('terminal/write')) {
            this.gateway.call('terminal/write', {
              terminalId: msg.terminalId,
              data: msg.data,
            }, { peer: client.peer }).catch((err) => {
              client.ws.sendJson({ op: 'error', code: 'terminal/write_failed', message: err?.message || 'write failed' });
            });
          }
        }
        break;
      }
      case 'term.resize': {
        if (
          typeof msg.terminalId === 'string' &&
          typeof msg.cols === 'number' &&
          typeof msg.rows === 'number' &&
          Number.isFinite(msg.cols) &&
          Number.isFinite(msg.rows)
        ) {
          const cols = Math.max(1, Math.min(500, Math.round(msg.cols)));
          const rows = Math.max(1, Math.min(200, Math.round(msg.rows)));
          const entry = this._findTerminalUpstream(msg.terminalId);
          if (entry?.uplink) {
            entry.uplinkSeq = (entry.uplinkSeq || 0) + 1;
            entry.uplink.push({ type: 'resize', sequence: entry.uplinkSeq, cols, rows });
          } else if (this.gateway?.has('terminal/resize')) {
            this.gateway.call('terminal/resize', {
              terminalId: msg.terminalId,
              cols,
              rows,
            }, { peer: client.peer }).catch(() => {});
          }
        }
        break;
      }
      default:
        client.ws.sendJson({ op: 'error', code: 'gbridge/unknown_op', message: `unknown op ${msg.op}` });
    }
  }

  _subscribeChannel(client, channel, opts = {}) {
    const isUpstream = channel.startsWith('session:') || channel.startsWith('terminal:') || channel.startsWith('job:');
    if (client.channels.has(channel)) {
      // If a previously subscribed upstream stream terminated on error/end, re-subscribing must restart it!
      if (!isUpstream || this.upstreamStreams.has(channel)) return;
    } else {
      if (client.channels.size >= MAX_CHANNELS_PER_CLIENT) {
        client.ws.sendJson({ op: 'error', code: 'gbridge/channel_limit', message: `maximum ${MAX_CHANNELS_PER_CLIENT} subscribed channels reached` });
        return;
      }
      client.channels.add(channel);
    }
    if (isUpstream) {
      this._retainUpstreamStream(channel, client.id, client.peer, opts);
    }
  }

  _unsubscribeChannel(client, channel) {
    if (!client.channels.delete(channel)) return;
    this._releaseUpstreamStream(channel, client.id);
  }

  _findTerminalUpstream(terminalId) {
    const direct = this.upstreamStreams.get(`terminal:${terminalId}`);
    if (direct) return direct;
    for (const [ch, entry] of this.upstreamStreams.entries()) {
      if (ch.startsWith('terminal:') && (ch.endsWith(`:${terminalId}`) || entry.terminalId === terminalId)) {
        return entry;
      }
    }
    return null;
  }

  _retainUpstreamStream(channel, clientId, peer, { minSnapshotSeq = 0 } = {}) {
    this.tornDownChannels.delete(channel);
    let entry = this.upstreamStreams.get(channel);
    if (entry) {
      if (entry.releaseTimer) {
        clearTimeout(entry.releaseTimer);
        entry.releaseTimer = null;
      }
      entry.subscribers.add(clientId);
      const cachedSnap = this.latestSnapshots.get(channel);
      const joining = this.clients.get(clientId);
      if (cachedSnap && joining?.welcomed && !(minSnapshotSeq > 0 && (cachedSnap.seq ?? 0) <= minSnapshotSeq)) {
        joining.ws.sendJson(cachedSnap);
      }
      return;
    }
    const abort = new AbortController();
    const [prefix, targetId] = [channel.slice(0, channel.indexOf(':')), channel.slice(channel.indexOf(':') + 1)];

    let endpoint;
    let args;
    let uplink;
    let effectiveTermId = targetId;

    if (prefix === 'session') {
      endpoint = 'session/follow';
      args = sessionFollowUsesAddress(this.gateway)
        ? { address: { kind: 'session', sessionId: targetId }, assistantStream: true, activate: true }
        : { sessionId: targetId };
    } else if (prefix === 'terminal') {
      if (this.gateway?.has('terminal/attach')) {
        endpoint = 'terminal/attach';
        const sep = targetId.indexOf(':');
        const agentId = sep > 0 ? targetId.slice(0, sep) : targetId;
        effectiveTermId = sep > 0 ? targetId.slice(sep + 1) : targetId;
        args = { agentId, id: effectiveTermId };
        uplink = createAsyncQueue(abort.signal);
      } else {
        endpoint = 'terminal/follow';
        args = { terminalId: targetId };
      }
    } else {
      endpoint = 'job/follow';
      const sep = targetId.indexOf(':');
      if (sep > 0) {
        const sid = targetId.slice(0, sep);
        effectiveTermId = targetId.slice(sep + 1);
        args = { request: { sessionId: sid, jobId: effectiveTermId } };
      } else {
        args = { request: { jobId: targetId } };
      }
    }

    if (!this.gateway?.has(endpoint)) {
      this.publish(channel, `${prefix}.unavailable`, { id: targetId, endpoint });
      return;
    }

    this.latestSnapshots.delete(channel);
    entry = { subscribers: new Set([clientId]), abort, uplink, uplinkSeq: 0, terminalId: effectiveTermId };
    this.upstreamStreams.set(channel, entry);

    (async () => {
      try {
        const iterable = await this.gateway.openStream(endpoint, args, {
          signal: abort.signal,
          peer,
          ...(uplink ? { uplink } : {}),
        });
        for await (const item of iterable) {
          if (abort.signal.aborted || this._disposed) break;
          this._forwardUpstreamStreamItem(prefix, effectiveTermId, channel, item);
        }
        if (!abort.signal.aborted && !this._disposed) {
          this.publish(channel, `${prefix}.stream_end`, { id: effectiveTermId });
        }
      } catch (err) {
        if (!abort.signal.aborted && !this._disposed) {
          this.publish(channel, `${prefix}.stream_error`, { id: effectiveTermId, message: err?.message || String(err) });
        }
      } finally {
        if (entry.releaseTimer) {
          clearTimeout(entry.releaseTimer);
          entry.releaseTimer = null;
        }
        uplink?.close?.();
        if (this.upstreamStreams.get(channel) === entry) {
          this.upstreamStreams.delete(channel);
          this.latestSnapshots.delete(channel);
          if (channel.startsWith('session:')) {
            const sid = channel.slice(8);
            this.activeTurns.delete(sid);
            this.normalizer?.clearSessionStat(sid);
          }
        }
      }
    })();
  }

  _forwardUpstreamStreamItem(prefix, targetId, channel, item) {
    if (prefix === 'terminal') {
      if (item?.type === 'snapshot' && typeof item.screen === 'string') {
        this.publish(channel, 'term.snapshot', { terminalId: targetId, screen: item.screen });
        return;
      }
      if (item?.type === 'output' && typeof item.data === 'string') {
        this.publish(channel, 'term.data', { terminalId: targetId, chunk: item.data }, { isDelta: true });
        return;
      }
      if (item?.type === 'state' && item.info?.state === 'exited') {
        this.publish(channel, 'term.exit', { terminalId: targetId, code: item.info.exitCode ?? null });
        return;
      }
      const data = typeof item === 'string' ? item : (item?.data ?? item?.chunk ?? '');
      if (data) {
        this.publish(channel, 'term.data', { terminalId: targetId, chunk: String(data) }, { isDelta: true });
      } else if (item?.type === 'exit') {
        this.publish(channel, 'term.exit', { terminalId: targetId, code: item.code ?? null });
      }
      return;
    }
    if (prefix === 'job') {
      let chunk = '';
      if (item?.type === 'output' && Array.isArray(item.chunks)) {
        chunk = item.chunks.map((c) => String(c?.text ?? '')).join('');
      } else {
        chunk = typeof item === 'string' ? item : String(item?.chunk ?? item?.data ?? '');
      }
      const extractedStatus = extractJobStatusFromItem(item);
      const extractedExitCode = item?.exitCode ?? item?.job?.exitCode ?? item?.info?.exitCode ?? null;
      if (chunk) {
        try {
          this._onJobStateChanged?.({ jobId: targetId, status: extractedStatus || 'running' });
        } catch (err) {
          logSuppressed(this.logger, 'stream-hub', err, { detail: `onJobStateChanged failed for ${targetId}` });
        }
        this.publish(channel, 'job.output', { jobId: targetId, chunk }, { isDelta: true });
      } else {
        if (extractedStatus) {
          try {
            this._onJobStateChanged?.({ jobId: targetId, status: extractedStatus });
          } catch (err) {
            logSuppressed(this.logger, 'stream-hub', err, { detail: `onJobStateChanged failed for ${targetId}` });
          }
        }
        this.publish(channel, 'job.event', {
          jobId: targetId,
          ...(extractedStatus ? { status: extractedStatus } : {}),
          ...(extractedExitCode !== null && extractedExitCode !== undefined ? { exitCode: extractedExitCode } : {}),
          raw: item,
        });
      }
      return;
    }
    // session/follow
    const kind = item?.type || '';
    if (kind === 'assistant-stream') {
      const frame = item.frame ?? item;
      const activeTid = this.activeTurns.get(targetId);
      if (frame?.type === 'chunk' && frame.chunk) {
        const inner = frame.chunk;
        const activity = this.normalizer?.observeStreamChunk(targetId, inner);
        this.publish(channel, 'turn.delta', {
          sessionId: targetId,
          ...(activeTid ? { turnId: activeTid } : {}),
          chunk: inner,
          ...(activity ? { activity } : {}),
        }, { isDelta: true });
      } else if (frame?.type === 'start') {
        const tid = (activeTid && !activeTid.startsWith('turn-'))
          ? activeTid
          : (frame.turn !== undefined ? `turn-${frame.turn}` : activeTid);
        if (tid) this.activeTurns.set(targetId, tid);
        this.normalizer?.observeStreamChunk(targetId, { type: 'step/start' });
        this.publish(channel, 'turn.delta', {
          sessionId: targetId,
          ...(tid ? { turnId: tid } : {}),
          chunk: { type: 'turn/start', turn: frame.turn, step: frame.step },
        });
      } else if (frame?.type === 'end' && frame?.outcome?.kind === 'abandoned') {
        this.publish(channel, 'turn.delta', {
          sessionId: targetId,
          ...(activeTid ? { turnId: activeTid } : {}),
          chunk: { type: 'assistant-stream/abandoned', turn: frame.turn, step: frame.step },
        });
      }
      return;
    }
    if (kind === 'text-chunks' || kind === 'reasoning-chunks' || kind === 'tool-call-chunks' || kind === 'chunk') {
      const activeTid = this.activeTurns.get(targetId);
      const activity = this.normalizer?.observeStreamChunk(targetId, item);
      this.publish(channel, 'turn.delta', {
        sessionId: targetId,
        ...(activeTid ? { turnId: activeTid } : {}),
        chunk: item,
        ...(activity ? { activity } : {}),
      }, { isDelta: true });
      return;
    }
    if (kind === 'snapshot') {
      const rawRecords = item.records ?? item.events ?? item.history ?? [];
      const turns = this.normalizer?.normalizeEvents(targetId, rawRecords) ?? [];
      const last = turns.length > 0 ? turns[turns.length - 1] : null;
      if (last && last.status === 'streaming' && last.turnId) {
        this.activeTurns.set(targetId, last.turnId);
      } else {
        this.activeTurns.delete(targetId);
      }
      this.publish(channel, 'turn.snapshot', {
        sessionId: targetId,
        turns,
        projections: item.projections ?? {},
        rawRevision: item.revision ?? item.cursor ?? null,
      });
      return;
    }
    if (kind === 'event' && item.event) {
      const ev = item.event;
      const eventSeq = typeof ev.seq === 'number' ? ev.seq : undefined;
      if (ev.type === 'turn/start' || ev.type === 'turn_start') {
        this._clearPendingTurnEndTimer(targetId);
        const turnId = ev.data?.turnId ||
          (ev.data?.turn !== undefined ? `turn-${ev.data.turn}` : (ev.id || `turn-${ev.seq ?? Date.now()}`));
        this.activeTurns.set(targetId, turnId);
        try {
          this._onTurnStarted?.({ sessionId: targetId, turnId });
        } catch (err) {
          logSuppressed(this.logger, 'stream-hub', err, { detail: `onTurnStarted failed for ${targetId}` });
        }
        this.publish(channel, 'turn.start', {
          sessionId: targetId,
          turnId,
          ...(eventSeq !== undefined ? { eventSeq } : {}),
          raw: ev,
        });
        return;
      }
      if (ev.type === 'turn/end' || ev.type === 'turn_end') {
        this._clearPendingTurnEndTimer(targetId);
        const turnId = ev.data?.turnId || (ev.data?.turn !== undefined ? `turn-${ev.data.turn}` : this.activeTurns.get(targetId));
        this.activeTurns.delete(targetId);
        const failCtx = this.normalizer?.getSessionFailureContext?.(targetId) ?? null;
        this.normalizer?.clearSessionStat(targetId);
        const fail = extractFailureInfo(ev.data?.reason, ev.data ?? ev, failCtx);
        try {
          this._onTurnCompleted?.({
            sessionId: targetId,
            turnId,
            reason: normalizeTurnEndReasonTag(ev.data?.reason, Boolean(fail)),
          });
        } catch (err) {
          logSuppressed(this.logger, 'stream-hub', err, { detail: `onTurnCompleted failed for ${targetId}` });
        }
        this.publish(channel, 'turn.completed', {
          sessionId: targetId,
          ...(turnId ? { turnId } : {}),
          ...(eventSeq !== undefined ? { eventSeq } : {}),
          raw: ev,
          ...(fail ? { errorMessage: fail.message, ...(fail.code ? { errorCode: fail.code } : {}) } : {}),
        });
        return;
      }
      const activeTurnId = this.activeTurns.get(targetId) ?? null;
      const deltaTurns = this.normalizer?.normalizeEvents(targetId, [ev], {
        incremental: true,
        activeTurnId,
      }) ?? [];
      // When normalizedTurn is produced, avoid duplicating massive raw tool outputs/base64 payloads over WS;
      // retain full `raw: ev` for non-normalized events (e.g. `todo/write`, `goal/*`).
      const wireRaw = deltaTurns.length > 0
        ? { type: ev.type, ...(eventSeq !== undefined ? { seq: eventSeq } : {}) }
        : ev;
      this.publish(channel, 'session.event', {
        sessionId: targetId,
        ...(eventSeq !== undefined ? { eventSeq } : {}),
        raw: wireRaw,
        ...(deltaTurns.length > 0 ? { normalizedTurn: deltaTurns[0] } : {}),
      });
      return;
    }
    if (kind === 'projections' || kind === 'projection') {
      this.publish(channel, 'projection.updated', {
        sessionId: targetId,
        projections: item.projections ?? item.data ?? item,
      });
      return;
    }
    if (kind === 'turn/end' || kind === 'turn_end' || item?.event?.type === 'turn/end' || item?.event?.type === 'turn_end') {
      this._clearPendingTurnEndTimer(targetId);
      const evData = item?.event?.data ?? item?.data ?? item;
      const turnId = evData?.turnId || (evData?.turn !== undefined ? `turn-${evData.turn}` : this.activeTurns.get(targetId));
      this.activeTurns.delete(targetId);
      const failCtx = this.normalizer?.getSessionFailureContext?.(targetId) ?? null;
      this.normalizer?.clearSessionStat(targetId);
      const fail = extractFailureInfo(evData?.reason, evData, failCtx);
      try {
        this._onTurnCompleted?.({
          sessionId: targetId,
          turnId,
          reason: normalizeTurnEndReasonTag(evData?.reason, Boolean(fail)),
        });
      } catch (err) {
        logSuppressed(this.logger, 'stream-hub', err, { detail: `onTurnCompleted failed for ${targetId}` });
      }
      this.publish(channel, 'turn.completed', {
        sessionId: targetId,
        ...(turnId ? { turnId } : {}),
        raw: item,
        ...(fail ? { errorMessage: fail.message, ...(fail.code ? { errorCode: fail.code } : {}) } : {}),
      });
      return;
    }
    this.publish(channel, 'session.event', { sessionId: targetId, raw: item });
  }

  _releaseUpstreamStream(channel, clientId) {
    const entry = this.upstreamStreams.get(channel);
    if (!entry) return;
    entry.subscribers.delete(clientId);
    if (entry.subscribers.size === 0) {
      const teardown = () => {
        if (this.upstreamStreams.get(channel) !== entry || entry.subscribers.size > 0) return;
        this.upstreamStreams.delete(channel);
        this.latestSnapshots.delete(channel);
        this.tornDownChannels.add(channel);
        if (this.tornDownChannels.size > 512) {
          const oldest = this.tornDownChannels.values().next().value;
          if (oldest !== undefined) this.tornDownChannels.delete(oldest);
        }
        if (channel.startsWith('session:')) {
          const sid = channel.slice(8);
          this.activeTurns.delete(sid);
          this.normalizer?.clearSessionStat(sid);
        }
        entry.abort.abort();
      };
      // Generous 30s grace window for `session:` streams so mobile app switches during phone
      // control or Wi-Fi/5G handoffs reconnect with zero-gap deltas and zero forced resyncs!
      if (channel.startsWith('session:') && !this._disposed) {
        if (entry.releaseTimer) clearTimeout(entry.releaseTimer);
        entry.releaseTimer = setTimeout(teardown, 30000);
        entry.releaseTimer.unref?.();
      } else {
        teardown();
      }
    }
  }

  _enqueueDelta(client, frame) {
    const key = `${frame.channel}:${frame.type}`;
    // Only coalesce contiguous deltas belonging to the exact same (channel, type)!
    // Flushing before switching keys guarantees strictly monotonic seq delivery on the wire so
    // a client disconnecting after receiving seq N can NEVER miss an earlier seq < N on resume.
    if (client.pendingDeltas.size > 0 && !client.pendingDeltas.has(key)) {
      this._flushClientDeltas(client);
    }
    const existing = client.pendingDeltas.get(key);
    const chunkBytes = estimateDeltaBytes(frame.data);
    if (!existing) {
      client.pendingDeltas.set(key, { ...frame, batch: [frame.data] });
    } else {
      existing.seq = frame.seq;
      existing.ts = frame.ts;
      existing.batch.push(frame.data);
      existing.data = frame.data;
    }
    client.pendingDeltaBytes = (client.pendingDeltaBytes || 0) + chunkBytes;
    if (client.pendingDeltaBytes >= 512 * 1024) {
      this._flushClientDeltas(client);
      return;
    }
    if (!client.coalesceTimer) {
      client.coalesceTimer = setTimeout(() => this._flushClientDeltas(client), client.coalesceMs);
      client.coalesceTimer.unref?.();
    }
  }

  _flushClientDeltas(client) {
    if (client.coalesceTimer) {
      clearTimeout(client.coalesceTimer);
      client.coalesceTimer = null;
    }
    client.pendingDeltaBytes = 0;
    if (client.pendingDeltas.size === 0) return;
    const ordered = client.pendingDeltas.size > 1
      ? [...client.pendingDeltas.values()].sort((a, b) => a.seq - b.seq)
      : client.pendingDeltas.values();
    for (const merged of ordered) {
      if (merged.batch.length === 1) {
        client.ws.sendJson({
          op: 'delta',
          seq: merged.seq,
          channel: merged.channel,
          type: merged.type,
          ts: merged.ts,
          data: merged.batch[0],
        });
      } else if (merged.type === 'term.data' || merged.type === 'job.output') {
        const joined = merged.batch.map((b) => b.chunk || '').join('');
        client.ws.sendJson({
          op: 'delta',
          seq: merged.seq,
          channel: merged.channel,
          type: merged.type,
          ts: merged.ts,
          data: { ...merged.batch[merged.batch.length - 1], chunk: joined },
        });
      } else {
        const { chunk: _omittedChunk, ...rest } = merged.batch[merged.batch.length - 1];
        client.ws.sendJson({
          op: 'delta',
          seq: merged.seq,
          channel: merged.channel,
          type: merged.type,
          ts: merged.ts,
          data: {
            ...rest,
            chunks: merged.batch.map((b) => b.chunk ?? b),
          },
        });
      }
    }
    client.pendingDeltas.clear();
  }

  _detachClient(client) {
    if (!this.clients.delete(client.id)) return;
    if (client.coalesceTimer) clearTimeout(client.coalesceTimer);
    for (const ch of client.channels) {
      this._releaseUpstreamStream(ch, client.id);
    }
    client.channels.clear();
  }

  _sendHeartbeats() {
    for (const client of [...this.clients.values()]) {
      if (client.ws.closed) continue;
      // Allow up to 4 missed pings (80s) so backgrounded mobile clients waiting on phone-control
      // confirmation cards or brief OEM timer coalescing are never dropped mid-turn.
      if (client.missedPongs >= 4) {
        client.ws.terminate();
        this._detachClient(client);
        continue;
      }
      client.missedPongs += 1;
      client.ws.ping();
    }
  }

  dispose() {
    this._disposed = true;
    clearInterval(this._heartbeatTimer);
    if (this._eventsReconnectTimer) {
      clearTimeout(this._eventsReconnectTimer);
      this._eventsReconnectTimer = null;
    }
    if (this._eventsAbort) this._eventsAbort.abort();
    for (const entry of this.upstreamStreams.values()) {
      if (entry.releaseTimer) clearTimeout(entry.releaseTimer);
      entry.abort.abort();
    }
    for (const t of this.pendingTurnEndTimers.values()) clearTimeout(t);
    this.pendingTurnEndTimers.clear();
    this.upstreamStreams.clear();
    this.pendingInteractions.clear();
    this.sessionAlwaysAllowed.clear();
    this.activeTurns.clear();
    this.tornDownChannels.clear();
    this.ring.length = 0;
    this.ringHead = 0;
    this.durableRing.length = 0;
    this.durableRingHead = 0;
    this.latestSnapshots.clear();
    this.ringBytes = 0;
    this.durableRingBytes = 0;
    for (const client of [...this.clients.values()]) {
      client.ws.close(1001, 'gbridge shutting down');
    }
    this.clients.clear();
  }
}

function extractJobStatusFromItem(item) {
  if (!item || typeof item !== 'object') return null;
  const raw = item.status ??
    item.state ??
    item.job?.status ??
    item.job?.state ??
    item.info?.status ??
    item.info?.state ??
    item.data?.status ??
    item.data?.state ??
    item.data?.job?.status ??
    item.data?.job?.state ??
    null;
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  return trimmed || null;
}

function sanitizeInteraction(item) {
  return {
    id: item.id,
    kind: item.kind,
    event: item.event,
    sessionId: item.sessionId,
    payload: item.payload,
    createdAt: item.createdAt,
  };
}

function mapHostEmitEvent(event, args) {
  if (event.startsWith('api-session/')) {
    return { channel: 'host', type: `session.${event.slice('api-session/'.length)}`, data: { args } };
  }
  if (event.startsWith('plugin-manager/')) {
    const suffix = event.slice('plugin-manager/'.length);
    const reqId = args[0]?.requestId;
    if (reqId && (suffix === 'install-log' || suffix === 'install-state')) {
      return { channel: `install:${reqId}`, type: `install.${suffix.replace('install-', '')}`, data: args[0] };
    }
    return { channel: 'host', type: `plugins.${suffix}`, data: { args } };
  }
  if (event.startsWith('deepseek-account/')) {
    return { channel: 'host', type: 'auth.notice', data: { event, args } };
  }
  if (event === 'schedule/changed') return { channel: 'host', type: 'schedule.changed', data: { args } };
  if (event === 'settings/document-updated' || event === 'web/providers-changed') {
    return { channel: 'host', type: 'settings.updated', data: { event, args } };
  }
  if (event === 'commands/change') return { channel: 'host', type: 'commands.changed', data: { args } };
  if (event === 'llm/adapters-updated' || event === 'llm/models-updated') {
    return { channel: 'host', type: 'models.updated', data: { event, args } };
  }
  if (event === 'credentials/reference-updated' || event === 'credentials/record-updated') {
    return { channel: 'host', type: 'credentials.updated', data: { event, args } };
  }
  if (event === 'goal/activation-changed') return { channel: 'host', type: 'goal.changed', data: { args } };
  if (event === 'agent-preset/selected' || event === 'permission-presets/catalog-changed') {
    return { channel: 'host', type: 'presets.changed', data: { event, args } };
  }
  return { channel: 'host', type: 'host.event', data: { event, args } };
}
