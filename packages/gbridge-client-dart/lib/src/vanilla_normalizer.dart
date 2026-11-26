import 'dart:collection';
import 'dart:convert';

/// Pure-Dart faithful port of `packages/dsh-gbridge/lib/normalizer.js` so GrassBag can
/// connect directly to stock `@deepseek-ai/dsh` (`dsh web`) with ZERO plugins installed
/// and still render full structured turns, thinking steps, tool cards, secret masking,
/// live Dock Stack telemetry, and lazy full tool outputs.
class VanillaDshNormalizer {
  VanillaDshNormalizer({
    this.maxCachedToolOutputs = 400,
    this.maxCacheBytes = 12 * 1024 * 1024,
  });

  static const int _maxSingleToolOutputChars = 512 * 1024;

  final int maxCachedToolOutputs;
  final int maxCacheBytes;
  final LinkedHashMap<String, ({Map<String, dynamic> record, int bytes})> _toolOutputs =
      LinkedHashMap<String, ({Map<String, dynamic> record, int bytes})>();
  int _toolOutputBytes = 0;
  final Map<String, _SessionStreamStat> _turnStats = <String, _SessionStreamStat>{};

  static final RegExp _secretQuickTrigger = RegExp(
    r'(?:sk-|gh[pousr]_|github_pat_|AKIA|AIza|-----BEGIN )',
  );

  static final List<RegExp> _secretPatterns = <RegExp>[
    RegExp(r'\bsk-ant-[A-Za-z0-9_-]{16,}\b'),
    RegExp(r'\bsk-(?!ant-)[A-Za-z0-9_-]{20,}\b'),
    RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}\b'),
    RegExp(r'\bgithub_pat_[A-Za-z0-9_]{22,}\b'),
    RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
    RegExp(r'\bAIza[0-9A-Za-z_-]{30,}\b'),
    RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]{0,16384}?-----END [A-Z ]*PRIVATE KEY-----'),
  ];

  static List<Map<String, dynamic>> detectSecretRanges(String text) {
    if (text.length < 16 || !_secretQuickTrigger.hasMatch(text)) {
      return const <Map<String, dynamic>>[];
    }
    final raw = <({int start, int end, int visiblePrefix})>[];
    for (final re in _secretPatterns) {
      for (final m in re.allMatches(text)) {
        final len = m.end - m.start;
        final visiblePrefix = len - 6 < 0 ? 0 : (len - 6 > 8 ? 8 : len - 6);
        raw.add((start: m.start, end: m.end, visiblePrefix: visiblePrefix));
      }
    }
    if (raw.isEmpty) return const <Map<String, dynamic>>[];
    raw.sort((a, b) {
      final c = a.start.compareTo(b.start);
      return c != 0 ? c : b.end.compareTo(a.end);
    });
    final merged = <({int start, int end, int visiblePrefix})>[raw.first];
    for (var i = 1; i < raw.length; i++) {
      final prev = merged.last;
      final cur = raw[i];
      if (cur.start <= prev.end) {
        if (cur.end > prev.end) {
          merged[merged.length - 1] = (
            start: prev.start,
            end: cur.end,
            visiblePrefix: prev.visiblePrefix,
          );
        }
      } else {
        merged.add(cur);
      }
    }
    return [
      for (final r in merged)
        {'start': r.start, 'end': r.end, 'visiblePrefix': r.visiblePrefix},
    ];
  }

  static String previewLine(Object? text, {int maxChars = 160}) {
    if (text is! String) return '';
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    final nl = trimmed.indexOf('\n');
    final first = (nl >= 0 ? trimmed.substring(0, nl) : trimmed).replaceAll('\r', '');
    return first.length > maxChars ? '${first.substring(0, maxChars - 1)}…' : first;
  }

  static Map<String, dynamic>? _tryParseJsonObject(Object? val) {
    if (val is Map) {
      return Map<String, dynamic>.from(val);
    }
    if (val is! String) return null;
    final trimmed = val.trim();
    if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  static const _phoneKeyLabels = <String, String>{
    'back': '返回键',
    'home': '主屏键',
    'recents': '最近任务',
    'enter': '回车键',
    'notifications': '通知栏',
    'quick_settings': '快捷设置',
  };

  static String _extractToolTarget(
    String tool,
    Object? args,
    Map<String, dynamic>? parsedOut,
  ) {
    final n = tool.toLowerCase();
    final a = args is Map ? args : const <dynamic, dynamic>{};
    if (n.startsWith('phone_')) {
      switch (n) {
        case 'phone_open':
          final app = a['appName'] ??
              a['app'] ??
              parsedOut?['opened'] ??
              parsedOut?['label'] ??
              a['package'] ??
              a['packageName'] ??
              a['url'] ??
              parsedOut?['package'];
          return app is String ? previewLine(app, maxChars: 60) : '';
        case 'phone_tap':
        case 'phone_long_press':
          final lbl = a['label'] ?? a['text'] ?? a['desc'] ?? a['description'] ?? parsedOut?['label'];
          if (lbl is String && lbl.trim().isNotEmpty) return previewLine(lbl, maxChars: 50);
          if (a['nodeId'] != null && a['nodeId'].toString().trim().isNotEmpty) {
            return '元素 ${a['nodeId']}';
          }
          if (a['x'] != null && a['y'] != null) return '(${a['x']}, ${a['y']})';
          return '';
        case 'phone_swipe':
          const dirMap = {'up': '向上滑动', 'down': '向下滑动', 'left': '向左滑动', 'right': '向右滑动'};
          final dir = a['direction']?.toString().toLowerCase() ?? '';
          if (dirMap.containsKey(dir)) return dirMap[dir]!;
          if (a['x1'] != null && a['y1'] != null && a['x2'] != null && a['y2'] != null) {
            return '(${a['x1']},${a['y1']}) → (${a['x2']},${a['y2']})';
          }
          return '滑动屏幕';
        case 'phone_type':
          final txt = a['text'] ?? a['value'] ?? a['input'];
          return (txt is String && txt.trim().isNotEmpty)
              ? '「${previewLine(txt, maxChars: 40)}」'
              : '';
        case 'phone_key':
          final rawKey = (a['action'] ?? a['key'] ?? '').toString();
          return _phoneKeyLabels[rawKey.toLowerCase()] ?? previewLine(rawKey, maxChars: 40);
        case 'phone_intent':
          final kind = a['kind'] ?? a['target'] ?? a['action'] ?? a['uri'] ?? a['url'];
          return kind is String ? previewLine(kind, maxChars: 60) : '';
        case 'phone_wait':
          if (a['ms'] is num) {
            final ms = a['ms'] as num;
            return ms >= 1000 ? '${(ms / 1000).toStringAsFixed(1)}s' : '${ms.round()}ms';
          }
          if (a['seconds'] is num) return '${a['seconds']}s';
          return '等待界面稳定';
        case 'phone_handoff':
          final msg = a['message'] ?? a['reason'] ?? a['prompt'];
          return (msg is String && msg.trim().isNotEmpty)
              ? previewLine(msg, maxChars: 60)
              : '等待人工确认';
        case 'phone_return_app':
          final sum = a['summary'] ?? a['reason'] ?? a['message'];
          return (sum is String && sum.trim().isNotEmpty)
              ? previewLine(sum, maxChars: 60)
              : '回到 GrassBag';
        case 'phone_screen':
          final lbl = parsedOut?['appLabel'] ??
              parsedOut?['appName'] ??
              parsedOut?['package'] ??
              parsedOut?['packageName'];
          return (lbl is String && lbl.trim().isNotEmpty)
              ? previewLine(lbl, maxChars: 50)
              : '读取当前界面';
        case 'phone_screenshot':
          return '截取当前屏幕';
        case 'phone_apps':
          final q = a['query'];
          return (q is String && q.trim().isNotEmpty)
              ? '搜索「${previewLine(q, maxChars: 40)}」'
              : '已安装应用列表';
      }
    }
    final candidate = a['command'] ??
        a['cmd'] ??
        a['file_path'] ??
        a['filePath'] ??
        a['path'] ??
        a['pattern'] ??
        a['glob'] ??
        a['regex'] ??
        a['query'] ??
        a['url'] ??
        a['description'] ??
        a['title'] ??
        a['name'] ??
        a['target'];
    return candidate is String ? previewLine(candidate, maxChars: 100) : '';
  }

  static String _summarizeHumanToolOutput(
    String tool,
    String outStr,
    Map<String, dynamic>? parsedOut,
  ) {
    if (parsedOut == null) return previewLine(outStr, maxChars: 220);
    if (parsedOut['ok'] == false || parsedOut['blocked'] == true || parsedOut['error'] != null) {
      final hint = parsedOut['hint'];
      if (hint is String && hint.trim().isNotEmpty) {
        return previewLine(hint, maxChars: 180);
      }
      final err = parsedOut['error'];
      final errText = err is String
          ? err
          : (err is Map
              ? (err['message'] ?? err['detail'] ?? '执行失败')
              : (parsedOut['message'] ?? parsedOut['reason'] ?? '执行失败'));
      return previewLine(errText.toString(), maxChars: 180);
    }
    final n = tool.toLowerCase();
    if (n.startsWith('phone_')) {
      if (n == 'phone_open') {
        final opened = parsedOut['opened'] ?? parsedOut['label'] ?? parsedOut['appName'];
        if (opened != null && opened.toString().trim().isNotEmpty) {
          return '已打开 ${previewLine(opened.toString(), maxChars: 40)}';
        }
        return parsedOut['ok'] == true ? '已打开应用' : '';
      }
      if (n == 'phone_screenshot') {
        if (parsedOut['width'] != null && parsedOut['height'] != null) {
          return '${parsedOut['width']}×${parsedOut['height']}';
        }
        return parsedOut['ok'] == true ? '截屏完成' : '';
      }
      if (n == 'phone_screen') {
        final app = (parsedOut['appLabel'] ??
                parsedOut['appName'] ??
                parsedOut['package'] ??
                parsedOut['packageName'] ??
                '')
            .toString();
        final elements = parsedOut['elements'];
        final nodes = parsedOut['nodes'];
        final count = elements is List
            ? elements.length
            : (nodes is List
                ? nodes.length
                : (parsedOut['count'] is num
                    ? (parsedOut['count'] as num).round()
                    : (parsedOut['nodeCount'] is num
                        ? (parsedOut['nodeCount'] as num).round()
                        : null)));
        if (app.isNotEmpty && count != null) return '${previewLine(app, maxChars: 32)} · $count 元素';
        if (app.isNotEmpty) return previewLine(app, maxChars: 40);
        if (count != null) return '$count 个元素';
        return parsedOut['ok'] == true ? '已读取界面' : '';
      }
      if (n == 'phone_apps') {
        final apps = parsedOut['apps'];
        final count = apps is List ? apps.length : (parsedOut['count'] is num ? (parsedOut['count'] as num).round() : null);
        return count != null ? '$count 个应用' : (parsedOut['ok'] == true ? '已列出' : '');
      }
      if (n == 'phone_return_app') {
        return parsedOut['ok'] == true ? '已返回应用' : '';
      }
      final msg = parsedOut['message'] ?? parsedOut['summary'] ?? parsedOut['status'];
      if (msg is String && msg.trim().isNotEmpty) return previewLine(msg, maxChars: 60);
      return parsedOut['ok'] == true ? '已完成' : '';
    }
    final msg = parsedOut['summary'] ?? parsedOut['message'];
    if (msg is String && msg.trim().isNotEmpty) return previewLine(msg, maxChars: 160);
    return '';
  }

  static ({String title, String summary, bool hasFullOutput}) summarizeTool(
    Object? name,
    Object? args, [
    Object? output,
    Map<String, dynamic>? preParsedOut,
    bool hasPreParsedOut = false,
  ]) {
    final tool = (name?.toString().isNotEmpty == true) ? name.toString() : 'tool';
    final parsedOut = hasPreParsedOut ? preParsedOut : _tryParseJsonObject(output);
    final hasOutput = output is String ? output.isNotEmpty : output != null;
    final outStr = parsedOut != null
        ? ''
        : output is String
            ? output
            : (hasOutput ? _safeJsonPreview(output, 400) : '');
    final target = _extractToolTarget(tool, args, parsedOut);
    final title = target.isNotEmpty ? '$tool · $target' : tool;
    final summary = _summarizeHumanToolOutput(tool, outStr, parsedOut);
    return (title: title, summary: summary, hasFullOutput: hasOutput);
  }

  static ({String? code, String message})? extractFailureInfo(
    Object? reason, [
    Map<String, dynamic> data = const <String, dynamic>{},
  ]) {
    if (reason is Map) {
      final kind = (reason['kind'] ?? reason['status'] ?? '').toString();
      if (kind == 'error') {
        final err = reason['error'] is Map ? reason['error'] as Map : reason;
        final code = err['code'] is String ? err['code'] as String : null;
        final msg = _formatErrorObject(err);
        return (code: code, message: msg.isNotEmpty ? msg : '执行过程中发生未知错误');
      }
      if (kind == 'aborted') {
        final inner = reason['reason'] is Map ? reason['reason'] as Map : null;
        if (inner != null &&
            inner['kind'] == 'hook' &&
            inner['reason'] == 'deepseek-account/signed-out') {
          return (code: 'ACCOUNT_SIGNED_OUT', message: 'DeepSeek 账号已退出登录，当前回复已中止。');
        }
        if (inner != null && inner['message'] != null) {
          return (
            code: inner['code']?.toString() ?? 'ABORTED',
            message: inner['message'].toString(),
          );
        }
        return null;
      }
      if (kind == 'interrupted') {
        return (code: 'INTERRUPTED', message: 'DSH 进程在本轮回复完成前意外退出。');
      }
    }
    if (reason == 'error') {
      final err = data['error'];
      final code = (err is Map && err['code'] is String)
          ? err['code'] as String
          : (data['code'] is String ? data['code'] as String : null);
      final msg = _formatErrorObject(err ?? data);
      return (code: code, message: msg.isNotEmpty ? msg : '执行过程中发生错误');
    }
    if (data['error'] != null) {
      final err = data['error'];
      final code = (err is Map && err['code'] is String)
          ? err['code'] as String
          : (data['code'] is String ? data['code'] as String : null);
      final msg = _formatErrorObject(err);
      return (code: code, message: msg.isNotEmpty ? msg : err.toString());
    }
    return null;
  }

  void cacheToolOutput(String sessionId, String callId, Map<String, dynamic> record) {
    if (sessionId.isEmpty || callId.isEmpty) return;
    final key = '$sessionId:$callId';
    final prevEntry = _toolOutputs.remove(key);
    if (prevEntry != null) {
      _toolOutputBytes -= prevEntry.bytes;
    }
    final prev = prevEntry?.record;
    final normalized = (prev != null &&
            record['output'] == null &&
            record['status'] == 'running' &&
            (prev['output'] != null || prev['status'] != 'running'))
        ? <String, dynamic>{
            ...prev,
            if (prev['args'] == null && record['args'] != null) 'args': record['args'],
          }
        : Map<String, dynamic>.from(record);
    var bytes = 256;
    final out = normalized['output'];
    if (out is String) {
      if (out.length > _maxSingleToolOutputChars) {
        normalized['output'] =
            '${out.substring(0, _maxSingleToolOutputChars)}\n…[已截断，原始长度 ${out.length} 字符]';
        normalized['truncated'] = true;
      }
      final finalOut = normalized['output'] as String;
      bytes = finalOut.length * 2 < 128 ? 128 : finalOut.length * 2;
    } else if (out != null) {
      var jsonLen = 512;
      try {
        final encoded = jsonEncode(out);
        jsonLen = encoded.length;
        if (jsonLen > _maxSingleToolOutputChars) {
          normalized['output'] =
              '${encoded.substring(0, _maxSingleToolOutputChars)}\n…[已截断，原始长度 $jsonLen 字符]';
          normalized['truncated'] = true;
          jsonLen = (normalized['output'] as String).length;
        }
      } catch (_) {}
      bytes = jsonLen * 2 < 256 ? 256 : jsonLen * 2;
    }
    final args = normalized['args'];
    if (args is String) {
      bytes += args.length * 2;
    } else if (args != null) {
      try {
        bytes += jsonEncode(args).length * 2;
      } catch (_) {
        bytes += 256;
      }
    }
    _toolOutputs[key] = (record: normalized, bytes: bytes);
    _toolOutputBytes += bytes;
    while ((_toolOutputs.length > maxCachedToolOutputs || _toolOutputBytes > maxCacheBytes) &&
        _toolOutputs.length > 1) {
      final oldestKey = _toolOutputs.keys.first;
      final oldest = _toolOutputs.remove(oldestKey);
      if (oldest != null) _toolOutputBytes -= oldest.bytes;
    }
  }

  Map<String, dynamic>? getToolOutput(String sessionId, String callId) {
    final key = '$sessionId:$callId';
    final hit = _toolOutputs.remove(key);
    if (hit == null) return null;
    _toolOutputs[key] = hit;
    return hit.record;
  }

  /// Normalize raw DSH session records/events into GrassBag `NormalizedTurn` JSON maps.
  List<Map<String, dynamic>> normalizeEvents(
    String sessionId,
    List<dynamic> rawEvents, {
    bool incremental = false,
    String? activeTurnId,
  }) {
    final turns = <Map<String, dynamic>>[];
    Map<String, dynamic>? current;
    final toolIndex = <String, Map<String, dynamic>>{};
    final toolStartTimes = <String, int>{};

    void promotePreToolNarration(Map<String, dynamic> turn, int seq) {
      final text = turn['assistantText'] as String? ?? '';
      final trimmed = text.trim();
      if (trimmed.isEmpty) return;
      final steps = turn['steps'] as List<Map<String, dynamic>>;
      steps.add({
        'kind': 'reasoning',
        'id': 'narration-$seq-${steps.length}',
        'text': trimmed,
        'collapsedPreview': previewLine(trimmed),
      });
      turn['assistantText'] = '';
    }

    void restoreFallbackNarration(Map<String, dynamic> turn) {
      if (turn['status'] == 'streaming') return;
      final text = turn['assistantText'] as String? ?? '';
      if (text.trim().isNotEmpty) return;
      final steps = turn['steps'] as List<Map<String, dynamic>>;
      for (var idx = steps.length - 1; idx >= 0; idx--) {
        final s = steps[idx];
        final id = s['id']?.toString() ?? '';
        final stepText = s['text']?.toString() ?? '';
        if (s['kind'] == 'reasoning' && id.startsWith('narration-') && stepText.isNotEmpty) {
          turn['assistantText'] = stepText;
          steps.removeAt(idx);
          return;
        }
      }
    }

    Map<String, dynamic> ensureTurn(String? seedId, int seq) {
      if (current == null) {
        final resolvedId = (incremental && activeTurnId != null && activeTurnId.isNotEmpty)
            ? activeTurnId
            : ((seedId != null && seedId.isNotEmpty) ? seedId : 'turn-${turns.length + 1}');
        current = <String, dynamic>{
          'turnId': resolvedId,
          'seqStart': seq,
          'seqEnd': seq,
          'status': incremental ? 'streaming' : 'completed',
          'steps': <Map<String, dynamic>>[],
          'assistantText': '',
          'deliverables': <dynamic>[],
        };
        turns.add(current!);
      }
      final prevEnd = (current!['seqEnd'] as num?)?.toInt() ?? 0;
      if (seq > prevEnd) current!['seqEnd'] = seq;
      return current!;
    }

    for (var i = 0; i < rawEvents.length; i++) {
      final rawEntry = rawEvents[i];
      if (rawEntry is! Map) continue;
      final entryMap = _asStringMap(rawEntry);
      final ev = (entryMap['type'] == 'event' && entryMap['event'] is Map)
          ? _asStringMap(entryMap['event'] as Map)
          : entryMap;
      if (ev['surfaceOp'] != null && ev['surfaceOp'] != 'append') {
        continue;
      }
      final type = (ev['type'] ?? ev['kind'] ?? '').toString();
      final seq = (ev['seq'] is num) ? (ev['seq'] as num).toInt() : i;
      final rawData = ev['data'] ?? ev['payload'] ?? ev;
      final data = rawData is Map ? _asStringMap(rawData) : ev;

      if (type == 'user/message' ||
          type == 'user_message' ||
          (type == 'message' && data['role'] == 'user')) {
        final msg = data['message'] is Map ? _asStringMap(data['message'] as Map) : data;
        final text = _extractText(msg);
        final contentList = msg['content'] is List ? msg['content'] as List : const <dynamic>[];
        final contentAttachments = <Map<String, dynamic>>[];
        for (final b in contentList) {
          if (b is Map && (b['type'] == 'image' || b['type'] == 'file')) {
            final att = <String, dynamic>{'type': b['type']};
            if (b['attachment'] is Map) {
              att.addAll(_asStringMap(b['attachment'] as Map));
            }
            if (b['name'] != null) att['name'] = b['name'];
            if (b['mediaType'] != null) att['mimeType'] = b['mediaType'];
            if (b['mimeType'] != null) att['mimeType'] = b['mimeType'];
            if (b['data'] is String && (b['data'] as String).isNotEmpty) {
              att['data'] = b['data'];
            }
            if (b['base64'] is String && (b['base64'] as String).isNotEmpty) {
              att['base64'] = b['base64'];
            }
            if (b['url'] is String && (b['url'] as String).isNotEmpty) {
              att['url'] = b['url'];
            }
            if (b['uri'] is String && (b['uri'] as String).isNotEmpty) {
              att['uri'] = b['uri'];
            }
            if (b['image'] is String && (b['image'] as String).isNotEmpty) {
              att['data'] = b['image'];
            }
            if (b['source'] is Map) {
              final src = b['source'] as Map;
              if (src['data'] is String && (src['data'] as String).isNotEmpty) {
                att['data'] = src['data'];
              }
              if (src['media_type'] != null) {
                att['mimeType'] ??= src['media_type'];
              }
            }
            contentAttachments.add(att);
          }
        }
        final rawAtts = msg['attachments'];
        final mergedAttachments = (rawAtts is List && rawAtts.isNotEmpty)
            ? rawAtts
            : contentAttachments;
        if (!_isHumanUserMessage(msg, data, text) && mergedAttachments.isEmpty) {
          continue;
        }
        final canReuse = current != null &&
            current!['userMessage'] == null &&
            (current!['steps'] as List).isEmpty &&
            (current!['assistantText'] as String).isEmpty;
        if (!canReuse) {
          if (current != null && current!['status'] == 'streaming' && !incremental) {
            current!['status'] = 'completed';
          }
          current = null;
        }
        final turn = ensureTurn(
          (ev['turnId'] ?? ev['id'])?.toString() ?? 'turn-$seq',
          seq,
        );
        turn['userMessage'] = {
          'id': (msg['id'] ?? ev['id'] ?? 'msg-$seq').toString(),
          'text': text,
          'attachments': mergedAttachments,
          'references': msg['references'] is List ? msg['references'] : const <dynamic>[],
          'maskedRanges': detectSecretRanges(text),
          'createdAt': (ev['time'] is num)
              ? (ev['time'] as num).toInt()
              : DateTime.now().millisecondsSinceEpoch,
        };
        if (!canReuse && !incremental) {
          turn['status'] = 'completed';
        }
        continue;
      }

      if (type == 'turn/start' || type == 'turn_start') {
        if (current != null && current!['status'] == 'streaming') {
          current!['status'] = 'completed';
          restoreFallbackNarration(current!);
        }
        if (current != null &&
            ((current!['assistantText'] as String).isNotEmpty ||
                (current!['steps'] as List).isNotEmpty ||
                current!['userMessage'] != null)) {
          current = null;
        }
        final seed = data['turnId']?.toString() ??
            (data['turn'] != null ? 'turn-${data['turn']}' : ev['id']?.toString());
        final turn = ensureTurn(seed, seq);
        turn['status'] = 'streaming';
        continue;
      }

      if (type == 'tool/call' || type == 'tool_call') {
        final turn = ensureTurn(ev['turnId']?.toString(), seq);
        promotePreToolNarration(turn, seq);
        final steps = turn['steps'] as List<Map<String, dynamic>>;
        final callId =
            (data['callId'] ?? data['id'] ?? 'call-$seq-${steps.length}').toString();
        Object? parsedArgs = data['arguments'] ?? data['input'] ?? const <String, dynamic>{};
        if (parsedArgs is String) {
          try {
            parsedArgs = jsonDecode(parsedArgs);
          } catch (_) {}
        }
        final sum = summarizeTool(data['name'], parsedArgs);
        if (ev['time'] is num && !toolStartTimes.containsKey(callId)) {
          toolStartTimes[callId] = (ev['time'] as num).toInt();
        }
        if (!toolIndex.containsKey(callId)) {
          final step = <String, dynamic>{
            'kind': 'tool',
            'callId': callId,
            'name': (data['name'] ?? 'tool').toString(),
            'title': sum.title,
            'status': 'running',
            'summary': sum.summary,
            'hasFullOutput': false,
          };
          steps.add(step);
          toolIndex[callId] = step;
        }
        cacheToolOutput(sessionId, callId, {
          'callId': callId,
          'name': (data['name'] ?? 'tool').toString(),
          'args': parsedArgs,
          'output': null,
          'status': 'running',
        });
        continue;
      }

      if (type == 'assistant/message' ||
          type == 'assistant_message' ||
          (type == 'message' && data['role'] == 'assistant')) {
        final turn = ensureTurn(ev['turnId']?.toString(), seq);
        final steps = turn['steps'] as List<Map<String, dynamic>>;
        final msg = data['message'] is Map ? _asStringMap(data['message'] as Map) : data;
        final msgId = (msg['id'] ?? data['messageId'] ?? ev['id'])?.toString().trim();
        if (msgId != null && msgId.isNotEmpty) {
          turn['assistantMessageId'] = msgId;
        }
        final blocks = msg['content'] is List
            ? msg['content'] as List
            : (data['content'] is List ? data['content'] as List : null);
        if (blocks != null) {
          for (final rawB in blocks) {
            if (rawB is! Map) continue;
            final b = _asStringMap(rawB);
            final bType = b['type']?.toString() ?? '';
            if (bType == 'reasoning' || bType == 'thinking') {
              final rText = (b['text'] ?? b['thinking'] ?? '').toString();
              if (rText.isNotEmpty) {
                steps.add({
                  'kind': 'reasoning',
                  'id': (b['id'] ?? 'reason-$seq-${steps.length}').toString(),
                  'text': rText,
                  'collapsedPreview': previewLine(rText),
                });
              }
            } else if (bType == 'tool-call' || bType == 'tool_use' || bType == 'toolCall') {
              promotePreToolNarration(turn, seq);
              final callId =
                  (b['id'] ?? b['callId'] ?? 'call-$seq-${steps.length}').toString();
              Object? bArgs = b['arguments'] ?? b['input'] ?? const <String, dynamic>{};
              if (bArgs is String) {
                try {
                  bArgs = jsonDecode(bArgs);
                } catch (_) {}
              }
              final sum = summarizeTool(b['name'], bArgs);
              if (ev['time'] is num && !toolStartTimes.containsKey(callId)) {
                toolStartTimes[callId] = (ev['time'] as num).toInt();
              }
              if (!toolIndex.containsKey(callId)) {
                final step = <String, dynamic>{
                  'kind': 'tool',
                  'callId': callId,
                  'name': (b['name'] ?? 'tool').toString(),
                  'title': sum.title,
                  'status': 'running',
                  'summary': sum.summary,
                  'hasFullOutput': false,
                };
                steps.add(step);
                toolIndex[callId] = step;
              }
              final existingCached = getToolOutput(sessionId, callId);
              if (existingCached == null ||
                  (existingCached['output'] == null && existingCached['status'] == 'running')) {
                cacheToolOutput(sessionId, callId, {
                  'callId': callId,
                  'name': (b['name'] ?? 'tool').toString(),
                  'args': bArgs,
                  'output': existingCached?['output'],
                  'status': existingCached?['status'] ?? 'running',
                });
              }
            } else if (bType == 'text') {
              final chunk = (b['text'] ?? '').toString();
              if (chunk.isNotEmpty) {
                final curText = turn['assistantText'] as String;
                if (curText.isNotEmpty && !curText.endsWith('\n') && !chunk.startsWith('\n')) {
                  turn['assistantText'] = '$curText\n\n$chunk';
                } else {
                  turn['assistantText'] = '$curText$chunk';
                }
              }
            }
          }
        } else {
          final t = _extractText(msg);
          if (t.isNotEmpty) {
            final curText = turn['assistantText'] as String;
            if (curText.isNotEmpty && !curText.endsWith('\n') && !t.startsWith('\n')) {
              turn['assistantText'] = '$curText\n\n$t';
            } else {
              turn['assistantText'] = '$curText$t';
            }
          }
        }
        final rawUsage = data['usage'] ?? msg['usage'];
        if (rawUsage is Map) {
          _accumulateUsage(turn, _asStringMap(rawUsage));
        }
        continue;
      }

      if (type == 'tool/result' ||
          type == 'tool_result' ||
          (type == 'message' && data['role'] == 'tool')) {
        final turn = ensureTurn(ev['turnId']?.toString(), seq);
        final steps = turn['steps'] as List<Map<String, dynamic>>;
        final msg = data['message'] is Map ? _asStringMap(data['message'] as Map) : data;
        final msgSource = msg['source'] is Map ? msg['source'] as Map : null;
        final callId = (msg['toolCallId'] ??
                msg['callId'] ??
                msgSource?['callId'] ??
                data['callId'] ??
                data['toolCallId'] ??
                msg['id'] ??
                'call-$seq')
            .toString();
        final rawOut = msg['content'] ?? data['output'] ?? data['result'] ?? data['content'] ?? '';
        final output = rawOut is List ? _extractText({'content': rawOut}) : rawOut;
        final parsedOut = _tryParseJsonObject(output);
        final rawErr = data['error'];
        final hasTruthyErr = rawErr != null && rawErr != false && !(rawErr is String && rawErr.trim().isEmpty);
        final isError = hasTruthyErr ||
            msg['isError'] == true ||
            data['isError'] == true ||
            parsedOut?['ok'] == false ||
            parsedOut?['blocked'] == true;
        final prev = getToolOutput(sessionId, callId);
        final existing = toolIndex[callId];
        final toolName = existing?['name']?.toString() ??
            prev?['name']?.toString() ??
            (msg['name'] ?? data['name'] ?? 'tool').toString();
        final effectiveArgs = prev?['args'] ?? data['arguments'] ?? const <String, dynamic>{};
        final sum = summarizeTool(toolName, effectiveArgs, output, parsedOut, true);
        final effectiveHasFull =
            sum.hasFullOutput || (isError && output.toString().trim().isNotEmpty);
        if (existing != null) {
          existing['status'] = isError ? 'error' : 'ok';
          final canUpgradeTitle = sum.title.isNotEmpty &&
              sum.title != toolName &&
              (existing['title'] == null ||
                  existing['title'] == toolName ||
                  (toolName.toLowerCase().startsWith('phone_') && sum.title != existing['title']));
          if (canUpgradeTitle) {
            existing['title'] = sum.title;
          }
          if (sum.summary.isNotEmpty) existing['summary'] = sum.summary;
          existing['hasFullOutput'] = effectiveHasFull;
          final startedAt = toolStartTimes[callId];
          final inferredDur = data['durationMs'] is num
              ? data['durationMs']
              : (ev['time'] is num && startedAt != null && (ev['time'] as num).toInt() >= startedAt
                  ? (ev['time'] as num).toInt() - startedAt
                  : null);
          if (inferredDur is num) existing['durationMs'] = inferredDur;
          if (data['subagentSessionId'] is String) {
            existing['subagentSessionId'] = data['subagentSessionId'];
          }
        } else {
          final startedAt = toolStartTimes[callId];
          final inferredDur = data['durationMs'] is num
              ? data['durationMs']
              : (ev['time'] is num && startedAt != null && (ev['time'] as num).toInt() >= startedAt
                  ? (ev['time'] as num).toInt() - startedAt
                  : null);
          final step = <String, dynamic>{
            'kind': 'tool',
            'callId': callId,
            'name': toolName,
            'title': sum.title,
            'status': isError ? 'error' : 'ok',
            'summary': sum.summary,
            'hasFullOutput': effectiveHasFull,
            if (inferredDur is num) 'durationMs': inferredDur,
          };
          steps.add(step);
          toolIndex[callId] = step;
        }
        cacheToolOutput(sessionId, callId, {
          'callId': callId,
          'name': toolName,
          'args': effectiveArgs,
          'output': (isError && (output == null || output.toString().isEmpty) && data['error'] != null)
              ? _formatErrorObject(data['error'])
              : output,
          if (data['meta'] != null) 'meta': data['meta'],
          'status': isError ? 'error' : 'ok',
        });
        continue;
      }

      if (type == 'error' ||
          type == 'turn/error' ||
          type == 'step/error' ||
          type == 'assistant/error') {
        final turn = ensureTurn(ev['turnId']?.toString(), seq);
        final fail = extractFailureInfo('error', data);
        if (fail != null) {
          turn['status'] = 'error';
          turn['errorMessage'] = fail.message;
          if (fail.code != null) turn['errorCode'] = fail.code;
          (turn['steps'] as List<Map<String, dynamic>>).add({
            'kind': 'notice',
            'level': 'error',
            'text': fail.code != null ? '[${fail.code}] ${fail.message}' : fail.message,
          });
        }
        continue;
      }

      if (type == 'turn/end' || type == 'turn_end') {
        final turn = ensureTurn(data['turnId']?.toString(), seq);
        final rawReason = data['reason'];
        final reason = rawReason is Map
            ? (rawReason['kind'] ?? rawReason['status'])?.toString()
            : (rawReason ?? data['status'])?.toString();
        final fail = extractFailureInfo(rawReason, data);
        final rawTurnErr = data['error'];
        final hasTruthyTurnErr = rawTurnErr != null &&
            rawTurnErr != false &&
            !(rawTurnErr is String && rawTurnErr.trim().isEmpty);
        turn['status'] = (reason == 'cancelled' || (reason == 'aborted' && fail == null))
            ? 'cancelled'
            : (reason == 'error' ||
                    reason == 'interrupted' ||
                    fail != null ||
                    hasTruthyTurnErr)
                ? 'error'
                : 'completed';
        if (fail != null) {
          turn['errorMessage'] = fail.message;
          if (fail.code != null) turn['errorCode'] = fail.code;
          final noticeText =
              fail.code != null ? '[${fail.code}] ${fail.message}' : fail.message;
          final steps = turn['steps'] as List<Map<String, dynamic>>;
          final exists = steps.any(
            (s) => s['kind'] == 'notice' && s['level'] == 'error' && s['text'] == noticeText,
          );
          if (!exists) {
            steps.add({'kind': 'notice', 'level': 'error', 'text': noticeText});
          }
        }
        if (data['usage'] is Map) {
          final u = _asStringMap(data['usage'] as Map);
          final prevUsage = turn['usage'] is Map ? _asStringMap(turn['usage'] as Map) : null;
          final nextDur = u['durationMs'] != null
              ? _numInt(u['durationMs'])
              : (prevUsage?['durationMs'] is num ? (prevUsage!['durationMs'] as num).toInt() : null);
          turn['usage'] = {
            'inputTokens': _numInt(u['uncachedInputTokens'] ?? u['inputTokens'] ?? u['promptTokens']),
            'outputTokens': _numInt(u['outputTokens'] ?? u['completionTokens']),
            if (u['cacheReadTokens'] != null) 'cacheReadTokens': _numInt(u['cacheReadTokens']),
            if (u['cacheWriteTokens'] != null) 'cacheWriteTokens': _numInt(u['cacheWriteTokens']),
            if (nextDur != null) 'durationMs': nextDur,
          };
        }
        if (data['deliverables'] is List) {
          turn['deliverables'] = data['deliverables'];
        }
        restoreFallbackNarration(turn);
        current = null;
        continue;
      }
    }

    for (final t in turns) {
      restoreFallbackNarration(t);
    }

    return turns.where((t) {
      return t['userMessage'] != null ||
          (t['steps'] as List).isNotEmpty ||
          (t['assistantText'] as String).trim().isNotEmpty ||
          (t['errorMessage']?.toString().isNotEmpty == true);
    }).toList(growable: false);
  }

  Map<String, dynamic> observeStreamChunk(String sessionId, Map<String, dynamic> chunk) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var stat = _turnStats[sessionId];
    final ctype = chunk['type']?.toString() ?? '';
    if (stat == null || ctype == 'turn/start' || ctype == 'snapshot') {
      stat = _SessionStreamStat(startedAt: now);
      _turnStats[sessionId] = stat;
    } else if (ctype == 'step/start') {
      stat.activeDecodeMs = 0;
      stat.lastDecodeAt = 0;
      stat.estTokens = 0.0;
      stat.target = null;
      if (stat.phase == 'tool') stat.phase = 'thinking';
    }
    String extractText() {
      if (chunk['texts'] is List) {
        final buf = StringBuffer();
        for (final s in chunk['texts'] as List) {
          if (s != null) buf.write(s.toString());
        }
        return buf.toString();
      }
      return (chunk['text'] ?? chunk['delta'] ?? '').toString();
    }

    double estimateTokens(String text) {
      if (text.isEmpty) return 0.0;
      var cjk = 0;
      var other = 0;
      for (var i = 0; i < text.length; i++) {
        if (text.codeUnitAt(i) >= 0x2E80) {
          cjk += 1;
        } else {
          other += 1;
        }
      }
      return cjk / 1.5 + other / 3.8;
    }

    void recordDecode(String text) {
      final tok = estimateTokens(text);
      if (tok <= 0) return;
      if (stat!.lastDecodeAt > 0) {
        final dt = now - stat.lastDecodeAt;
        if (dt > 0 && dt <= 1500) {
          stat.activeDecodeMs += dt > 600 ? 600 : dt;
        }
      }
      stat.lastDecodeAt = now;
      stat.estTokens += tok;
    }

    final kind = chunk['kind']?.toString() ?? '';
    if (ctype == 'reasoning-delta' || ctype == 'reasoning-chunks' || kind == 'reasoning') {
      if (stat.phase == 'tool') {
        stat.activeDecodeMs = 0;
        stat.lastDecodeAt = 0;
        stat.estTokens = 0.0;
        stat.target = null;
      }
      stat.phase = 'thinking';
      recordDecode(extractText());
    } else if (ctype == 'text-delta' || ctype == 'text-chunks' || kind == 'text') {
      if (stat.phase == 'tool') {
        stat.activeDecodeMs = 0;
        stat.lastDecodeAt = 0;
        stat.estTokens = 0.0;
        stat.target = null;
      }
      stat.phase = 'streaming';
      recordDecode(extractText());
    } else if (ctype == 'tool-call-delta' || ctype == 'tool-call-chunks' || kind == 'tool-call') {
      stat.phase = 'tool';
      stat.lastDecodeAt = 0;
      if (chunk['name'] != null) stat.target = chunk['name'].toString();
    }
    final elapsedMs = (now - stat.startedAt).clamp(1, 1 << 30);
    final tps = (stat.phase != 'tool' && stat.activeDecodeMs >= 200 && stat.estTokens >= 1.0)
        ? ((stat.estTokens * 10000) / stat.activeDecodeMs).round() / 10.0
        : null;
    return {
      'phase': stat.phase,
      if (stat.target != null) 'target': stat.target,
      if (tps != null) 'tps': tps,
      'elapsedMs': elapsedMs,
    };
  }

  void clearSessionStat(String sessionId) {
    _turnStats.remove(sessionId);
  }

  static void _accumulateUsage(Map<String, dynamic> turn, Map<String, dynamic> msgUsage) {
    final prev = turn['usage'] is Map ? _asStringMap(turn['usage'] as Map) : null;
    final stepIn = _numInt(
      msgUsage['uncachedInputTokens'] ?? msgUsage['inputTokens'] ?? msgUsage['promptTokens'],
    );
    final stepOut = _numInt(msgUsage['outputTokens'] ?? msgUsage['completionTokens']);
    final stepCacheRead = _numInt(msgUsage['cacheReadTokens']);
    final stepCacheWrite = _numInt(msgUsage['cacheWriteTokens']);
    final stepDur = _numInt(msgUsage['durationMs']);
    turn['usage'] = {
      'inputTokens': _numInt(prev?['inputTokens']) + stepIn,
      'outputTokens': _numInt(prev?['outputTokens']) + stepOut,
      if (prev?['cacheReadTokens'] != null || msgUsage['cacheReadTokens'] != null)
        'cacheReadTokens': _numInt(prev?['cacheReadTokens']) + stepCacheRead,
      if (prev?['cacheWriteTokens'] != null || msgUsage['cacheWriteTokens'] != null)
        'cacheWriteTokens': _numInt(prev?['cacheWriteTokens']) + stepCacheWrite,
      if (prev?['durationMs'] != null || msgUsage['durationMs'] != null)
        'durationMs': _numInt(prev?['durationMs']) + stepDur,
    };
  }

  static int _numInt(Object? v) => v is num ? v.toInt() : 0;

  static Map<String, dynamic> _asStringMap(Map raw) {
    if (raw is Map<String, dynamic>) return raw;
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }

  static bool _isHumanUserMessage(
    Map<String, dynamic> msg,
    Map<String, dynamic> data,
    String text,
  ) {
    final source = msg['source'] ?? data['source'];
    if (source is Map) {
      final kind = source['kind']?.toString() ?? '';
      return kind == 'user' || kind == 'retry';
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.startsWith('<system-reminder>') ||
        trimmed.startsWith('<openviking-context') ||
        trimmed.startsWith('Time sampled while preparing turn')) {
      return false;
    }
    return true;
  }

  static String _extractText(Object? data) {
    if (data is String) return data;
    if (data is Map) {
      if (data['text'] is String) return data['text'] as String;
      if (data['content'] is String) return data['content'] as String;
      if (data['content'] is List) {
        final buf = StringBuffer();
        for (final b in data['content'] as List) {
          if (b is Map && b['type'] == 'text' && b['text'] is String) {
            buf.write(b['text']);
          }
        }
        return buf.toString();
      }
    }
    return '';
  }

  static String _formatErrorObject(Object? err) {
    if (err == null) return '';
    if (err is String) return err.trim();
    if (err is! Map) return err.toString();
    final parts = <String>[];
    final main = err['message'] ?? err['reason'] ?? err['detail'] ?? err['summary'] ?? err['error'];
    if (main is String && main.trim().isNotEmpty) parts.add(main.trim());
    if (err['reason'] is String &&
        (err['reason'] as String).trim().isNotEmpty &&
        !parts.contains((err['reason'] as String).trim())) {
      parts.add((err['reason'] as String).trim());
    }
    if (err['status'] is num && !parts.any((p) => p.contains('${err['status']}'))) {
      parts.add('HTTP ${err['status']}');
    }
    if (err['cause'] != null) {
      final c = _formatErrorObject(err['cause']);
      if (c.isNotEmpty && !parts.contains(c)) parts.add('原因: $c');
    }
    if (parts.isNotEmpty) return parts.join(' · ');
    return _safeJsonPreview(err, 400);
  }

  static String _safeJsonPreview(Object? val, int max) {
    try {
      final s = jsonEncode(val);
      return s.length > max ? '${s.substring(0, max)}…' : s;
    } catch (_) {
      final s = val.toString();
      return s.length > max ? s.substring(0, max) : s;
    }
  }
}

class _SessionStreamStat {
  _SessionStreamStat({required this.startedAt});
  final int startedAt;
  int activeDecodeMs = 0;
  int lastDecodeAt = 0;
  double estTokens = 0.0;
  String phase = 'thinking';
  String? target;
}
