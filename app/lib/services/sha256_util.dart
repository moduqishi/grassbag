import 'dart:typed_data';

/// Pure-Dart FIPS 180-4 streaming SHA-256 implementation (zero external dependencies).
class StreamingSha256 {
  StreamingSha256() {
    reset();
  }

  static const List<int> _k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  final Uint32List _h = Uint32List(8);
  final Uint32List _w = Uint32List(64);
  final Uint8List _block = Uint8List(64);
  int _blockLen = 0;
  int _totalBytes = 0;

  void reset() {
    _h[0] = 0x6a09e667;
    _h[1] = 0xbb67ae85;
    _h[2] = 0x3c6ef372;
    _h[3] = 0xa54ff53a;
    _h[4] = 0x510e527f;
    _h[5] = 0x9b05688c;
    _h[6] = 0x1f83d9ab;
    _h[7] = 0x5be0cd19;
    _blockLen = 0;
    _totalBytes = 0;
  }

  void add(List<int> data, [int start = 0, int? end]) {
    final limit = end ?? data.length;
    var offset = start;
    _totalBytes += (limit - start);
    if (_blockLen > 0) {
      final take = (64 - _blockLen).clamp(0, limit - offset);
      for (var i = 0; i < take; i++) {
        _block[_blockLen + i] = data[offset + i] & 0xff;
      }
      _blockLen += take;
      offset += take;
      if (_blockLen == 64) {
        _processBlock(_block, 0);
        _blockLen = 0;
      }
    }
    while (limit - offset >= 64) {
      _processBlock(data, offset);
      offset += 64;
    }
    while (offset < limit) {
      _block[_blockLen++] = data[offset++] & 0xff;
    }
  }

  String digestHex() {
    final bitLen = _totalBytes * 8;
    _block[_blockLen++] = 0x80;
    if (_blockLen > 56) {
      while (_blockLen < 64) {
        _block[_blockLen++] = 0;
      }
      _processBlock(_block, 0);
      _blockLen = 0;
    }
    while (_blockLen < 56) {
      _block[_blockLen++] = 0;
    }
    final high = (bitLen ~/ 0x100000000) & 0xffffffff;
    final low = bitLen & 0xffffffff;
    _block[56] = (high >> 24) & 0xff;
    _block[57] = (high >> 16) & 0xff;
    _block[58] = (high >> 8) & 0xff;
    _block[59] = high & 0xff;
    _block[60] = (low >> 24) & 0xff;
    _block[61] = (low >> 16) & 0xff;
    _block[62] = (low >> 8) & 0xff;
    _block[63] = low & 0xff;
    _processBlock(_block, 0);

    final buf = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buf.write(_h[i].toRadixString(16).padLeft(8, '0'));
    }
    return buf.toString();
  }

  static int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xffffffff;

  void _processBlock(List<int> src, int offset) {
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      _w[i] = ((src[j] & 0xff) << 24) |
          ((src[j + 1] & 0xff) << 16) |
          ((src[j + 2] & 0xff) << 8) |
          (src[j + 3] & 0xff);
    }
    for (var i = 16; i < 64; i++) {
      final w15 = _w[i - 15];
      final w2 = _w[i - 2];
      final s0 = _rotr(w15, 7) ^ _rotr(w15, 18) ^ (w15 >>> 3);
      final s1 = _rotr(w2, 17) ^ _rotr(w2, 19) ^ (w2 >>> 10);
      _w[i] = (_w[i - 16] + s0 + _w[i - 7] + s1) & 0xffffffff;
    }

    var a = _h[0];
    var b = _h[1];
    var c = _h[2];
    var d = _h[3];
    var e = _h[4];
    var f = _h[5];
    var g = _h[6];
    var h = _h[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final temp1 = (h + s1 + ch + _k[i] + _w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    _h[0] = (_h[0] + a) & 0xffffffff;
    _h[1] = (_h[1] + b) & 0xffffffff;
    _h[2] = (_h[2] + c) & 0xffffffff;
    _h[3] = (_h[3] + d) & 0xffffffff;
    _h[4] = (_h[4] + e) & 0xffffffff;
    _h[5] = (_h[5] + f) & 0xffffffff;
    _h[6] = (_h[6] + g) & 0xffffffff;
    _h[7] = (_h[7] + h) & 0xffffffff;
  }
}

String sha256HexBytes(List<int> bytes) {
  final hasher = StreamingSha256()..add(bytes);
  return hasher.digestHex();
}
