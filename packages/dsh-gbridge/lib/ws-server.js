import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const MAX_FRAME_BYTES = 8 * 1024 * 1024; // 8 MiB

const OP_CONT = 0x0;
const OP_TEXT = 0x1;
const OP_BINARY = 0x2;
const OP_CLOSE = 0x8;
const OP_PING = 0x9;
const OP_PONG = 0xa;

function buildFrame(opcode, payloadBuf) {
  const payload = Buffer.isBuffer(payloadBuf) ? payloadBuf : Buffer.from(payloadBuf);
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.allocUnsafe(2);
    header[0] = 0x80 | (opcode & 0x0f);
    header[1] = len;
  } else if (len < 65536) {
    header = Buffer.allocUnsafe(4);
    header[0] = 0x80 | (opcode & 0x0f);
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.allocUnsafe(10);
    header[0] = 0x80 | (opcode & 0x0f);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, payload]);
}

/**
 * Zero-dependency RFC 6455 WebSocket connection over a raw Node net.Socket.
 */
export class GbridgeWsConnection extends EventEmitter {
  constructor(socket, head, meta = {}) {
    super();
    this.socket = socket;
    this.meta = meta;
    this.closed = false;
    this._buffer = Buffer.alloc(0);
    this._fragOpcode = null;
    this._fragChunks = [];
    this._fragBytes = 0;

    socket.setNoDelay(true);
    socket.on('data', (chunk) => this._onData(chunk));
    socket.on('error', (err) => {
      if (!this.closed) this.emit('error', err);
      this._markClosed(1006, 'socket error');
    });
    socket.on('close', () => this._markClosed(1006, 'socket closed'));
    socket.on('end', () => this._markClosed(1000, 'eof'));

    if (head && head.length > 0) {
      queueMicrotask(() => this._onData(head));
    }
  }

  _safeWrite(buf) {
    if (this.closed || this.socket.destroyed) return false;
    try {
      return this.socket.write(buf);
    } catch {
      this._markClosed(1006, 'write error');
      return false;
    }
  }

  sendText(text) {
    if (this.closed || this.socket.destroyed) return false;
    return this._safeWrite(buildFrame(OP_TEXT, Buffer.from(text, 'utf8')));
  }

  sendJson(obj) {
    try {
      return this.sendText(JSON.stringify(obj));
    } catch {
      return false;
    }
  }

  sendBinary(buffer) {
    if (this.closed || this.socket.destroyed) return false;
    return this._safeWrite(buildFrame(OP_BINARY, buffer));
  }

  ping(payload = '') {
    if (this.closed || this.socket.destroyed) return false;
    return this._safeWrite(buildFrame(OP_PING, Buffer.from(payload)));
  }

  pong(payload = Buffer.alloc(0)) {
    if (this.closed || this.socket.destroyed) return false;
    return this._safeWrite(buildFrame(OP_PONG, payload));
  }

  close(code = 1000, reason = '') {
    if (this.closed) return;
    let reasonBuf = Buffer.from(String(reason), 'utf8');
    if (reasonBuf.length > 123) reasonBuf = reasonBuf.subarray(0, 123);
    const body = Buffer.allocUnsafe(2 + reasonBuf.length);
    body.writeUInt16BE(code, 0);
    reasonBuf.copy(body, 2);
    try {
      if (!this.socket.destroyed) {
        this.socket.end(buildFrame(OP_CLOSE, body));
        const sock = this.socket;
        const killer = setTimeout(() => {
          try {
            if (!sock.destroyed) sock.destroy();
          } catch {}
        }, 1000);
        killer.unref?.();
      }
    } catch {}
    this._markClosed(code, reason);
  }

  terminate() {
    this._markClosed(1006, 'terminated');
    try { this.socket.destroy(); } catch {}
  }

  _markClosed(code, reason) {
    if (this.closed) return;
    this.closed = true;
    this._buffer = Buffer.alloc(0);
    this._fragChunks = [];
    this.emit('close', code, reason);
  }

  _onData(chunk) {
    if (this.closed) return;
    this._buffer = this._buffer.length === 0 ? chunk : Buffer.concat([this._buffer, chunk]);

    while (this._buffer.length >= 2 && !this.closed) {
      const b0 = this._buffer[0];
      const b1 = this._buffer[1];
      const fin = (b0 & 0x80) !== 0;
      const rsv = b0 & 0x70;
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let payloadLen = b1 & 0x7f;
      let offset = 2;

      if (rsv !== 0) {
        this.close(1002, 'unsupported rsv bits');
        return;
      }
      if (!masked) {
        this.close(1002, 'client frames must be masked');
        return;
      }
      if (payloadLen === 126) {
        if (this._buffer.length < 4) return;
        payloadLen = this._buffer.readUInt16BE(2);
        offset = 4;
      } else if (payloadLen === 127) {
        if (this._buffer.length < 10) return;
        const big = this._buffer.readBigUInt64BE(2);
        if (big > BigInt(MAX_FRAME_BYTES)) {
          this.close(1009, 'frame too large');
          return;
        }
        payloadLen = Number(big);
        offset = 10;
      }
      if (payloadLen > MAX_FRAME_BYTES) {
        this.close(1009, 'frame too large');
        return;
      }
      const frameTotal = offset + 4 + payloadLen;
      if (this._buffer.length < frameTotal) return;

      const maskKey = this._buffer.subarray(offset, offset + 4);
      const maskedData = this._buffer.subarray(offset + 4, frameTotal);
      const payload = Buffer.allocUnsafe(payloadLen);
      for (let i = 0; i < payloadLen; i++) {
        payload[i] = maskedData[i] ^ maskKey[i & 3];
      }
      this._buffer = frameTotal === this._buffer.length
        ? Buffer.alloc(0)
        : this._buffer.subarray(frameTotal);

      this._handleFrame(fin, opcode, payload);
    }
  }

  _handleFrame(fin, opcode, payload) {
    if (opcode >= 0x8) {
      if (!fin || payload.length > 125) {
        this.close(1002, 'invalid control frame');
        return;
      }
      if (opcode === OP_CLOSE) {
        const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1000;
        const reason = payload.length > 2 ? payload.subarray(2).toString('utf8') : '';
        this.close(code, reason);
      } else if (opcode === OP_PING) {
        this.pong(payload);
      } else if (opcode === OP_PONG) {
        this.emit('pong', payload);
      } else {
        this.close(1002, 'unknown control opcode');
      }
      return;
    }

    if (opcode === OP_CONT) {
      if (this._fragOpcode === null) {
        this.close(1002, 'unexpected continuation');
        return;
      }
      this._fragBytes += payload.length;
      if (this._fragBytes > MAX_FRAME_BYTES) {
        this.close(1009, 'message too large');
        return;
      }
      this._fragChunks.push(payload);
      if (fin) {
        const full = Buffer.concat(this._fragChunks);
        const op = this._fragOpcode;
        this._fragOpcode = null;
        this._fragChunks = [];
        this._fragBytes = 0;
        this._deliverData(op, full);
      }
      return;
    }

    if (opcode !== OP_TEXT && opcode !== OP_BINARY) {
      this.close(1002, 'unknown data opcode');
      return;
    }
    if (this._fragOpcode !== null) {
      this.close(1002, 'interleaved data frame');
      return;
    }
    if (!fin) {
      this._fragOpcode = opcode;
      this._fragChunks = [payload];
      this._fragBytes = payload.length;
      return;
    }
    this._deliverData(opcode, payload);
  }

  _deliverData(opcode, buffer) {
    if (opcode === OP_TEXT) {
      this.emit('message', buffer.toString('utf8'), false);
    } else {
      this.emit('message', buffer, true);
    }
  }
}

export function rejectUpgrade(socket, status, reason = 'Forbidden') {
  try {
    if (socket && typeof socket.listenerCount === 'function' && socket.listenerCount('error') === 0) {
      socket.on('error', () => {});
    }
    socket.end(
      `HTTP/1.1 ${status} ${reason}\r\n` +
      'Connection: close\r\n' +
      'Content-Length: 0\r\n' +
      'Cache-Control: no-store\r\n\r\n'
    );
  } catch {
    try { socket.destroy(); } catch {}
  }
}

/**
 * Perform RFC 6455 HTTP/1.1 Upgrade handshake and return a GbridgeWsConnection.
 */
export function upgradeWebSocket(req, socket, head, meta = {}) {
  if (socket && typeof socket.listenerCount === 'function' && socket.listenerCount('error') === 0) {
    socket.on('error', () => {});
  }
  const upgrade = String(req.headers?.upgrade || '').toLowerCase();
  const key = req.headers?.['sec-websocket-key'];
  const version = String(req.headers?.['sec-websocket-version'] || '');
  if (upgrade !== 'websocket' || typeof key !== 'string' || key.length === 0 || version !== '13') {
    rejectUpgrade(socket, 400, 'Bad WebSocket Upgrade');
    return null;
  }
  const accept = createHash('sha1').update(`${key.trim()}${WS_GUID}`).digest('base64');
  try {
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
    );
  } catch {
    try { socket.destroy(); } catch {}
    return null;
  }
  return new GbridgeWsConnection(socket, head, meta);
}
