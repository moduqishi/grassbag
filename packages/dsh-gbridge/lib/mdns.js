/**
 * Pure zero-dependency mDNS / DNS-SD responder (RFC 6762 / RFC 6763) for `dsh-gbridge`.
 *
 * Advertises `_grassbag._tcp.local.` with the bridge's ACTUAL bound port (including
 * zero-conflict fallback ports `3082..3099` and OS ephemeral ports), host display name,
 * surface (`desktop` / `web`), DSH version, and reachable LAN IPv4 addresses.
 *
 * Fails silently when UDP 5353 multicast is unavailable (e.g. restricted containers / CI),
 * so it NEVER blocks or degrades LAN bridge startup.
 */

import dgram from 'node:dgram';
import { logSuppressed, ignoreCleanupError } from './diagnostics.js';

export const MDNS_ADDR = '224.0.0.251';
export const MDNS_PORT = 5353;
export const GRASSBAG_SERVICE_TYPE = '_grassbag._tcp.local';
export const DNS_SD_ENUM_TYPE = '_services._dns-sd._udp.local';

export const DNS_TYPE_A = 1;
export const DNS_TYPE_PTR = 12;
export const DNS_TYPE_TXT = 16;
export const DNS_TYPE_SRV = 33;
export const DNS_TYPE_ANY = 255;
export const DNS_CLASS_IN = 1;
const DNS_CLASS_IN_FLUSH = 0x8001;

/** Sanitize a DNS label for safe single-label instance/host names (max 63 UTF-8 bytes). */
export function sanitizeDnsLabel(raw, fallback = 'GrassBag') {
  const cleaned = String(raw || '')
    .replace(/[\r\n\t\x00-\x1f.]+/g, '-')
    .replace(/\s+/g, ' ')
    .trim();
  const base = cleaned || fallback;
  let out = base;
  while (Buffer.byteLength(out, 'utf8') > 60 && out.length > 1) {
    out = out.slice(0, -1);
  }
  return out || fallback;
}

/** Encode a dot-separated DNS name into wire-format labels ending with 0x00. */
export function encodeDnsName(name) {
  const clean = String(name || '').replace(/\.+$/, '');
  if (!clean) return Buffer.from([0]);
  const parts = clean.split('.').filter(Boolean);
  const chunks = [];
  for (const label of parts) {
    const buf = Buffer.from(label, 'utf8');
    const len = Math.min(buf.length, 63);
    chunks.push(Buffer.from([len]), buf.subarray(0, len));
  }
  chunks.push(Buffer.from([0]));
  return Buffer.concat(chunks);
}

/** Decode a wire-format DNS name (supporting RFC 1035 compression pointers). */
export function decodeDnsName(buf, startOffset = 0) {
  const labels = [];
  let offset = startOffset;
  let jumped = false;
  let nextOffset = startOffset;
  let guard = 0;
  while (offset < buf.length && guard++ < 64) {
    const len = buf[offset];
    if (len === 0) {
      if (!jumped) nextOffset = offset + 1;
      break;
    }
    if ((len & 0xc0) === 0xc0) {
      if (offset + 1 >= buf.length) break;
      const ptr = ((len & 0x3f) << 8) | buf[offset + 1];
      if (!jumped) nextOffset = offset + 2;
      offset = ptr;
      jumped = true;
      continue;
    }
    offset += 1;
    if (offset + len > buf.length) break;
    labels.push(buf.subarray(offset, offset + len).toString('utf8'));
    offset += len;
    if (!jumped) nextOffset = offset;
  }
  return { name: labels.join('.'), nextOffset };
}

/** Encode DNS TXT key=value entries per RFC 6763 (length-prefixed strings). */
export function encodeTxtRecord(entries = []) {
  const list = [];
  for (const item of entries) {
    if (!item) continue;
    const raw = Buffer.from(String(item), 'utf8');
    const len = Math.min(raw.length, 255);
    list.push(Buffer.from([len]), raw.subarray(0, len));
  }
  if (list.length === 0) return Buffer.from([0]);
  return Buffer.concat(list);
}

function encodeResourceRecord({ name, type, cls = DNS_CLASS_IN, ttl = 120, rdata }) {
  const nameBuf = encodeDnsName(name);
  const head = Buffer.alloc(10);
  head.writeUInt16BE(type, 0);
  head.writeUInt16BE(cls, 2);
  head.writeUInt32BE(Math.max(0, ttl >>> 0), 4);
  head.writeUInt16BE(rdata.length, 8);
  return Buffer.concat([nameBuf, head, rdata]);
}

function encodeIpv4Rdata(ip) {
  const parts = String(ip || '').split('.').map((p) => Number(p));
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) {
    return null;
  }
  return Buffer.from(parts);
}

/**
 * Build a complete RFC 6762/6763 mDNS announcement / response packet containing:
 * - PTR `_grassbag._tcp.local` -> `<instance>._grassbag._tcp.local`
 * - SRV `<instance>._grassbag._tcp.local` -> `<host>.local:<actualPort>`
 * - TXT `<instance>._grassbag._tcp.local` -> metadata key/values
 * - A `<host>.local` -> each LAN IPv4 address
 */
export function buildMdnsAnnouncementPacket({
  instanceLabel,
  hostLabel,
  serviceType = GRASSBAG_SERVICE_TYPE,
  port,
  ipv4List = [],
  txtEntries = [],
  ttl = 120,
  includeServiceEnum = false,
} = {}) {
  const safeInst = sanitizeDnsLabel(instanceLabel, 'GrassBag');
  const safeHost = sanitizeDnsLabel(hostLabel || instanceLabel, 'grassbag').replace(/\s+/g, '-').toLowerCase();
  const instanceFqdn = `${safeInst}.${serviceType}`;
  const hostFqdn = `${safeHost}.local`;
  const validPort = Number.isInteger(port) && port > 0 && port <= 65535 ? port : 3081;

  const records = [];
  if (includeServiceEnum) {
    records.push(encodeResourceRecord({
      name: DNS_SD_ENUM_TYPE,
      type: DNS_TYPE_PTR,
      cls: DNS_CLASS_IN,
      ttl,
      rdata: encodeDnsName(serviceType),
    }));
  }
  records.push(encodeResourceRecord({
    name: serviceType,
    type: DNS_TYPE_PTR,
    cls: DNS_CLASS_IN,
    ttl,
    rdata: encodeDnsName(instanceFqdn),
  }));

  const srvHead = Buffer.alloc(6);
  srvHead.writeUInt16BE(0, 0); // priority
  srvHead.writeUInt16BE(0, 2); // weight
  srvHead.writeUInt16BE(validPort, 4);
  records.push(encodeResourceRecord({
    name: instanceFqdn,
    type: DNS_TYPE_SRV,
    cls: DNS_CLASS_IN_FLUSH,
    ttl,
    rdata: Buffer.concat([srvHead, encodeDnsName(hostFqdn)]),
  }));

  records.push(encodeResourceRecord({
    name: instanceFqdn,
    type: DNS_TYPE_TXT,
    cls: DNS_CLASS_IN_FLUSH,
    ttl,
    rdata: encodeTxtRecord(txtEntries),
  }));

  for (const ip of ipv4List) {
    const rdata = encodeIpv4Rdata(ip);
    if (!rdata) continue;
    records.push(encodeResourceRecord({
      name: hostFqdn,
      type: DNS_TYPE_A,
      cls: DNS_CLASS_IN_FLUSH,
      ttl,
      rdata,
    }));
  }

  const header = Buffer.alloc(12);
  header.writeUInt16BE(0, 0); // ID = 0 per RFC 6762
  header.writeUInt16BE(0x8400, 2); // QR=1 (response), AA=1 (authoritative)
  header.writeUInt16BE(0, 4); // QDCOUNT
  header.writeUInt16BE(records.length, 6); // ANCOUNT
  header.writeUInt16BE(0, 8); // NSCOUNT
  header.writeUInt16BE(0, 10); // ARCOUNT
  return Buffer.concat([header, ...records]);
}

/** Parse incoming mDNS query packet and extract question entries (`{ name, type }`). */
export function parseMdnsQueryQuestions(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 12) return [];
  const flags = buf.readUInt16BE(2);
  if ((flags & 0x8000) !== 0) return []; // Ignore responses (QR=1)
  const qdCount = buf.readUInt16BE(4);
  if (qdCount === 0 || qdCount > 32) return [];
  const questions = [];
  let offset = 12;
  for (let i = 0; i < qdCount && offset < buf.length; i++) {
    const decoded = decodeDnsName(buf, offset);
    offset = decoded.nextOffset;
    if (offset + 4 > buf.length) break;
    const type = buf.readUInt16BE(offset);
    offset += 4;
    if (decoded.name) {
      questions.push({ name: decoded.name.toLowerCase(), type });
    }
  }
  return questions;
}

/**
 * Start a lightweight best-effort mDNS / DNS-SD advertiser on `224.0.0.251:5353`.
 * Automatically re-announces when updated and sends a TTL=0 goodbye packet on dispose.
 */
export function startMdnsAdvertiser({
  hostName = 'GrassBag',
  port,
  surface = 'desktop',
  dshVersion = 'unknown',
  bridgeVersion = '0.2.0',
  requiresAuth = true,
  getIpv4List = () => [],
  logger = console,
} = {}) {
  let disposed = false;
  let current = {
    hostName,
    port,
    surface,
    dshVersion,
    bridgeVersion,
    requiresAuth,
  };
  let socket = null;
  let burstTimer = null;
  let ready = false;

  const instanceNameFor = () => {
    const base = sanitizeDnsLabel(current.hostName, 'DSH');
    return `${base} (${current.port})`;
  };

  const buildPacket = ({ ttl = 120, includeServiceEnum = false } = {}) => {
    const ips = (typeof getIpv4List === 'function' ? getIpv4List() : [])
      .filter((ip) => typeof ip === 'string' && !ip.startsWith('127.') && ip !== '0.0.0.0');
    if (ips.length === 0 || !current.port) return null;
    return buildMdnsAnnouncementPacket({
      instanceLabel: instanceNameFor(),
      hostLabel: current.hostName,
      port: current.port,
      ipv4List: ips,
      txtEntries: [
        'v=1',
        `host=${sanitizeDnsLabel(current.hostName, 'DSH')}`,
        `surface=${current.surface || 'desktop'}`,
        `dsh=${current.dshVersion || 'unknown'}`,
        `bridge=${current.bridgeVersion || '0.2.0'}`,
        `auth=${current.requiresAuth ? '1' : '0'}`,
        `port=${current.port}`,
      ],
      ttl,
      includeServiceEnum,
    });
  };

  const sendPacket = (pkt) => {
    if (!pkt || !socket || !ready || disposed) return;
    try {
      socket.send(pkt, 0, pkt.length, MDNS_PORT, MDNS_ADDR, () => {});
    } catch (err) {
      logSuppressed(logger, 'mdns', err, { level: 'debug', detail: 'mDNS multicast send failed' });
    }
  };

  const announce = (includeServiceEnum = false) => {
    const pkt = buildPacket({ ttl: 120, includeServiceEnum });
    if (pkt) sendPacket(pkt);
  };

  try {
    socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    socket.on('error', (err) => {
      ready = false;
      logSuppressed(logger, 'mdns', err, { level: 'debug', detail: 'mDNS UDP socket unavailable (non-fatal)' });
    });
    socket.on('message', (msg) => {
      if (disposed || !ready) return;
      const questions = parseMdnsQueryQuestions(msg);
      if (questions.length === 0) return;
      const instLower = `${sanitizeDnsLabel(instanceNameFor(), 'GrassBag')}.${GRASSBAG_SERVICE_TYPE}`.toLowerCase();
      const hostLower = `${sanitizeDnsLabel(current.hostName, 'grassbag').replace(/\s+/g, '-').toLowerCase()}.local`;
      let matched = false;
      let wantEnum = false;
      for (const q of questions) {
        if (q.name === DNS_SD_ENUM_TYPE) {
          matched = true;
          wantEnum = true;
          break;
        }
        if (q.name === GRASSBAG_SERVICE_TYPE || q.name === instLower || q.name === hostLower) {
          matched = true;
          break;
        }
      }
      if (matched) {
        announce(wantEnum);
      }
    });
    socket.bind(MDNS_PORT, () => {
      if (disposed) {
        try { socket.close(); } catch (err) { ignoreCleanupError(err); }
        return;
      }
      try {
        socket.setMulticastTTL(255);
        socket.setMulticastLoopback(true);
        socket.addMembership(MDNS_ADDR);
        ready = true;
        socket.unref?.();
        announce(true);
        burstTimer = setTimeout(() => {
          if (!disposed) announce(false);
        }, 650);
        burstTimer.unref?.();
      } catch (err) {
        ready = false;
        logSuppressed(logger, 'mdns', err, { level: 'debug', detail: 'mDNS multicast membership unavailable (non-fatal)' });
      }
    });
  } catch (err) {
    ready = false;
    logSuppressed(logger, 'mdns', err, { level: 'debug', detail: 'mDNS advertiser init skipped' });
  }

  return {
    update(patch = {}) {
      if (disposed) return;
      const portChanged = patch.port !== undefined && patch.port !== current.port;
      if (portChanged && ready) {
        // Send goodbye for previous instance port before announcing the new port!
        const bye = buildPacket({ ttl: 0 });
        if (bye) sendPacket(bye);
      }
      current = { ...current, ...patch };
      if (ready && current.port) {
        announce(true);
      }
    },
    announce: () => announce(false),
    dispose() {
      if (disposed) return;
      disposed = true;
      if (burstTimer) {
        clearTimeout(burstTimer);
        burstTimer = null;
      }
      if (ready && socket) {
        const bye = buildPacket({ ttl: 0 });
        if (bye) {
          try { socket.send(bye, 0, bye.length, MDNS_PORT, MDNS_ADDR, () => {}); } catch (err) { ignoreCleanupError(err); }
        }
      }
      ready = false;
      if (socket) {
        const s = socket;
        socket = null;
        try { s.close(); } catch (err) { ignoreCleanupError(err); }
      }
    },
  };
}
