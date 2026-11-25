import { GbridgeError, isPlainObject } from './http-util.js';

/**
 * Thin, resilient zero-patch adapter around DSH's official Cordis services
 * (`ctx.typertGateway`, `ctx.typert`, `ctx.connection`).
 */
export class GatewayAdapter {
  constructor(ctx) {
    this.ctx = ctx;
    this._ownerPeerScope = null;
  }

  resolvePeer(peer) {
    if (peer && !peer.signal?.aborted) return peer;
    const gw = this.gateway;
    if (typeof gw?.operatorPeer === 'function') {
      const p = gw.operatorPeer();
      if (p && !p.signal?.aborted) return p;
    }
    const connection = this.ctx.get?.('connection');
    if (connection?.browserPeer && !connection.browserPeer.signal?.aborted) {
      return connection.browserPeer;
    }
    if (connection?.operator && !connection.operator.signal?.aborted) {
      return connection.operator;
    }
    if (typeof connection?.createPeer === 'function') {
      if (!this._ownerPeerScope || this._ownerPeerScope.peer?.signal?.aborted) {
        try { this._ownerPeerScope?.dispose?.(); } catch {}
        this._ownerPeerScope = connection.createPeer({ principal: { kind: 'owner' } });
      }
      return this._ownerPeerScope.peer ?? this._ownerPeerScope;
    }
    return undefined;
  }

  dispose() {
    try { this._ownerPeerScope?.dispose?.(); } catch {}
    this._ownerPeerScope = null;
  }

  get gateway() {
    return this.ctx.get?.('typertGateway');
  }

  get typert() {
    return this.ctx.get?.('typert');
  }

  get ready() {
    return this.gateway !== undefined;
  }

  has(endpoint) {
    const gw = this.gateway;
    if (!gw || typeof gw.claimsEndpoint !== 'function') return false;
    try {
      return Boolean(gw.claimsEndpoint(endpoint));
    } catch {
      return false;
    }
  }

  hasAny(endpoints) {
    return endpoints.some((ep) => this.has(ep));
  }

  listEndpoints() {
    const set = new Set();
    try {
      const localList = this.typert?.local?.list?.();
      if (Array.isArray(localList)) {
        for (const item of localList) {
          if (item?.namespace && item?.method) set.add(`${item.namespace}/${item.method}`);
        }
      }
    } catch {}
    try {
      const gw = this.gateway;
      if (gw && typeof gw.collectSrcClaims === 'function') {
        for (const ep of gw.collectSrcClaims()) set.add(ep);
      }
    } catch {}
    return [...set].sort();
  }

  /**
   * Automatically align flat caller args with the live Typert descriptor's
   * exact parameter wire names (e.g., wrapping `{ _request: args }` or
   * `{ request: args }` when the endpoint takes a single JSON request object).
   */
  adaptArgs(endpoint, args = {}) {
    const clean = isPlainObject(args) ? args : {};
    let descriptor;
    try {
      descriptor = this.typert?.local?.get?.(endpoint);
    } catch {}
    if (!descriptor || !Array.isArray(descriptor.parameters)) {
      return clean;
    }
    const params = descriptor.parameters.map((p) => ({
      wire: p.wire ?? p.name,
      schema: p.codec?.jsonSchema,
    }));
    if (params.length === 0) return {};
    if (params.length === 1) {
      const only = params[0];
      if (Object.hasOwn(clean, only.wire)) return { [only.wire]: clean[only.wire] };
      const schemaType = only.schema?.type;
      const isObj = schemaType === 'object' || (Array.isArray(schemaType) && schemaType.includes('object')) ||
        Boolean(only.schema?.properties) || Boolean(only.schema?.anyOf) || Boolean(only.schema?.oneOf);
      if (isObj || only.wire === 'request' || only.wire === '_request' || only.wire === 'input') {
        return { [only.wire]: clean };
      }
      const keys = Object.keys(clean);
      if (keys.length === 1) return { [only.wire]: clean[keys[0]] };
      return clean;
    }
    // Multiple parameters: keep explicitly matching wire keys; if one missing param is an object wrapper, pack remaining keys.
    const out = {};
    const wireSet = new Set(params.map((p) => p.wire));
    const extras = {};
    for (const [k, v] of Object.entries(clean)) {
      if (wireSet.has(k)) out[k] = v;
      else extras[k] = v;
    }
    const missing = params.filter((p) => !Object.hasOwn(out, p.wire));
    if (missing.length === 1 && Object.keys(extras).length > 0) {
      const m = missing[0];
      if (m.schema?.type === 'object' || m.wire === 'options' || m.wire === 'request' || m.wire === '_request') {
        out[m.wire] = extras;
      }
    }
    return out;
  }

  /**
   * Call a unary Typert RPC endpoint in-process (zero network overhead).
   */
  async call(endpoint, args = {}, { signal, peer } = {}) {
    const gw = this.gateway;
    if (!gw) {
      throw new GbridgeError(503, 'gbridge/gateway_unavailable', 'DSH typertGateway is not ready', { retryable: true });
    }
    if (!this.has(endpoint)) {
      throw new GbridgeError(501, 'gbridge/endpoint_unsupported', `host DSH does not expose ${endpoint}`, {
        details: { endpoint },
      });
    }
    const cleanArgs = this.adaptArgs(endpoint, args);
    const effectivePeer = this.resolvePeer(peer);

    if (typeof gw.dispatchRpc === 'function') {
      const res = await gw.dispatchRpc(endpoint, { args: cleanArgs }, signal, effectivePeer);
      if (res && res.ok === true) return rehydrateAttachments(res.value, res.attachments);
      const errObj = res?.error;
      const upstreamCode = typeof errObj?.code === 'string' ? errObj.code : 'unknown';
      const message = typeof errObj?.message === 'string' ? errObj.message : `DSH call ${endpoint} failed`;
      const status = mapUpstreamStatus(upstreamCode);
      throw new GbridgeError(status, 'gbridge/upstream_error', message, {
        retryable: status >= 500,
        details: { endpoint, upstreamCode, ...(errObj?.details ? { upstreamDetails: errObj.details } : {}) },
      });
    }

    if (typeof gw.invoke === 'function') {
      const [namespace, method] = endpoint.split('/');
      try {
        return await gw.invoke({ namespace, method, args: cleanArgs, signal, peer: effectivePeer });
      } catch (err) {
        const upstreamCode = typeof err?.code === 'string' ? err.code : 'unknown';
        throw new GbridgeError(mapUpstreamStatus(upstreamCode), 'gbridge/upstream_error', err?.message || `DSH call ${endpoint} failed`, {
          details: { endpoint, upstreamCode },
        });
      }
    }

    throw new GbridgeError(503, 'gbridge/gateway_incompatible', 'typertGateway exposes neither dispatchRpc nor invoke');
  }

  /**
   * Open an in-process AsyncIterable stream for streaming endpoints (session/follow, terminal/follow, job/follow).
   */
  async openStream(endpoint, args = {}, { signal, peer, uplink } = {}) {
    const gw = this.gateway;
    if (!gw || typeof gw.stream !== 'function') {
      throw new GbridgeError(503, 'gbridge/gateway_unavailable', 'DSH stream gateway is not ready', { retryable: true });
    }
    if (!this.has(endpoint)) {
      throw new GbridgeError(501, 'gbridge/endpoint_unsupported', `host DSH does not expose stream ${endpoint}`, {
        details: { endpoint },
      });
    }
    const [namespace, method] = endpoint.split('/');
    const effectivePeer = this.resolvePeer(peer);
    return gw.stream({
      namespace,
      method,
      args: this.adaptArgs(endpoint, args),
      signal,
      peer: effectivePeer,
      ...(uplink !== undefined ? { uplink } : {}),
    });
  }

  /**
   * Open DSH's official forwarded `$events` stream (emit + waterfall requests).
   */
  openRemoteEvents(signal, peer) {
    const gw = this.gateway;
    if (!gw || typeof gw.openRemoteEvents !== 'function') return null;
    const effectivePeer = this.resolvePeer(peer);
    if (!effectivePeer) return null;
    return gw.openRemoteEvents({ args: {} }, signal, effectivePeer);
  }

  /**
   * Settle a pending waterfall interaction (approval/request, user-questions/request).
   */
  async respondRemoteEvent(clientId, eventId, outcome, signal, peer) {
    const gw = this.gateway;
    if (!gw || typeof gw.dispatchRpc !== 'function') {
      throw new GbridgeError(503, 'gbridge/gateway_unavailable', 'DSH gateway unavailable for event response');
    }
    const res = await gw.dispatchRpc('$events/result', {
      args: { clientId, eventId, outcome },
    }, signal, this.resolvePeer(peer));
    if (res && res.ok === true) return true;
    throw new GbridgeError(409, 'gbridge/interaction_settlement_failed', res?.error?.message || 'failed to settle interaction', {
      details: { upstreamCode: res?.error?.code },
    });
  }
}

function rehydrateAttachments(value, attachments) {
  if (!Array.isArray(attachments) || attachments.length === 0) return value;
  let root = value;
  for (const att of attachments) {
    if (!att || !(att.bytes instanceof Uint8Array || Buffer.isBuffer(att.bytes))) continue;
    const path = Array.isArray(att.path) ? att.path : [];
    if (path.length === 0) {
      root = att.bytes;
      continue;
    }
    const isUnsafeSeg = (s) => s === '__proto__' || s === 'constructor' || s === 'prototype';
    if (path.some((seg) => isUnsafeSeg(String(seg)))) continue;
    if (!root || typeof root !== 'object') continue;
    let cur = root;
    for (let i = 0; i < path.length - 1; i++) {
      const seg = path[i];
      if (cur == null || typeof cur !== 'object' || !Object.prototype.hasOwnProperty.call(cur, seg)) {
        cur = null;
        break;
      }
      cur = cur[seg];
    }
    if (cur && typeof cur === 'object') {
      cur[path[path.length - 1]] = att.bytes;
    }
  }
  return root;
}

function mapUpstreamStatus(code) {
  if (!code) return 502;
  const lower = String(code).toLowerCase();
  if (lower.includes('not-found') || lower.includes('not_found')) return 404;
  if (lower.includes('invalid') || lower.includes('arguments') || lower.includes('validation')) return 400;
  if (lower.includes('unauthorized') || lower.includes('auth')) return 401;
  if (lower.includes('forbidden') || lower.includes('denied')) return 403;
  if (lower.includes('conflict') || lower.includes('busy')) return 409;
  if (lower.includes('unavailable')) return 503;
  return 502;
}
