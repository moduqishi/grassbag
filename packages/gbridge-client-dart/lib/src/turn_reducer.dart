import 'models.dart';

/// Deterministic reducer folding real-time `/gbridge/v1/stream` session events
/// into immutable [NormalizedTurn] lists for smooth 120Hz Flutter rendering.
class TurnStreamReducer {
  TurnStreamReducer([List<NormalizedTurn> initial = const []])
      : _turns = List<NormalizedTurn>.of(initial);

  final List<NormalizedTurn> _turns;
  List<NormalizedTurn>? _cachedTurns;

  // Amortized O(1) StringBuffer accumulators for hot streaming assistant text & reasoning deltas
  // so 1,000+ WS chunks never perform O(L^2) string copies!
  StringBuffer? _activeTextBuf;
  int _activeTextTurnIdx = -1;
  int _activeTextMaxSeq = 0;

  StringBuffer? _activeReasonBuf;
  int _activeReasonTurnIdx = -1;
  int _activeReasonStepIdx = -1;
  int _activeReasonMaxSeq = 0;

  List<NormalizedTurn> get turns {
    _flushBuffers();
    return _cachedTurns ??= List.unmodifiable(_turns);
  }

  void _invalidateCache() {
    _cachedTurns = null;
  }

  void _flushTextBuffer() {
    final buf = _activeTextBuf;
    final idx = _activeTextTurnIdx;
    _activeTextBuf = null;
    _activeTextTurnIdx = -1;
    final maxSeq = _activeTextMaxSeq;
    _activeTextMaxSeq = 0;
    if (buf == null || idx < 0 || idx >= _turns.length) return;
    final cur = _turns[idx];
    _turns[idx] = cur.copyWith(
      status: 'streaming',
      seqEnd: maxSeq > cur.seqEnd ? maxSeq : cur.seqEnd,
      assistantText: buf.toString(),
    );
    _cachedTurns = null;
  }

  void _flushReasonBuffer() {
    final buf = _activeReasonBuf;
    final tIdx = _activeReasonTurnIdx;
    final sIdx = _activeReasonStepIdx;
    _activeReasonBuf = null;
    _activeReasonTurnIdx = -1;
    _activeReasonStepIdx = -1;
    final maxSeq = _activeReasonMaxSeq;
    _activeReasonMaxSeq = 0;
    if (buf == null || tIdx < 0 || tIdx >= _turns.length) return;
    final cur = _turns[tIdx];
    if (sIdx < 0 || sIdx >= cur.steps.length || cur.steps[sIdx] is! ReasoningStep) return;
    final steps = List<NormalizedStep>.of(cur.steps);
    final prev = steps[sIdx] as ReasoningStep;
    final merged = buf.toString();
    final nextPreview = _needsPreviewUpdate(prev.text, prev.collapsedPreview)
        ? _previewLine(merged)
        : prev.collapsedPreview;
    steps[sIdx] = prev.copyWith(
      text: merged,
      collapsedPreview: nextPreview,
    );
    _turns[tIdx] = cur.copyWith(
      status: 'streaming',
      seqEnd: maxSeq > cur.seqEnd ? maxSeq : cur.seqEnd,
      steps: List.unmodifiable(steps),
    );
    _cachedTurns = null;
  }

  void _flushBuffers() {
    if (_activeTextBuf != null) _flushTextBuffer();
    if (_activeReasonBuf != null) _flushReasonBuffer();
  }

  void _appendAssistantText(int idx, String delta, int eventSeq) {
    if (_activeReasonBuf != null) _flushReasonBuffer();
    if (_activeTextBuf != null && _activeTextTurnIdx != idx) {
      _flushTextBuffer();
    }
    if (_activeTextBuf == null) {
      final cur = _turns[idx];
      _activeTextBuf = StringBuffer(cur.assistantText);
      _activeTextTurnIdx = idx;
      _activeTextMaxSeq = cur.seqEnd;
    }
    _activeTextBuf!.write(delta);
    if (eventSeq > _activeTextMaxSeq) _activeTextMaxSeq = eventSeq;
    _cachedTurns = null;
  }

  void _appendReasoningText(int idx, String? explicitId, String delta, int eventSeq) {
    if (_activeTextBuf != null) _flushTextBuffer();
    // Fast path: appending into the currently buffered reasoning step!
    if (_activeReasonBuf != null && _activeReasonTurnIdx == idx) {
      final cur = _turns[idx];
      if (_activeReasonStepIdx >= 0 && _activeReasonStepIdx < cur.steps.length) {
        final step = cur.steps[_activeReasonStepIdx];
        if (step is ReasoningStep &&
            ((explicitId != null && explicitId.isNotEmpty && step.id == explicitId) ||
                ((explicitId == null || explicitId.isEmpty) &&
                    _activeReasonStepIdx == cur.steps.length - 1 &&
                    !step.id.startsWith('narration-')))) {
          _activeReasonBuf!.write(delta);
          if (eventSeq > _activeReasonMaxSeq) _activeReasonMaxSeq = eventSeq;
          _cachedTurns = null;
          return;
        }
      }
      _flushReasonBuffer();
    } else if (_activeReasonBuf != null) {
      _flushReasonBuffer();
    }

    final cur = _turns[idx];
    final steps = List<NormalizedStep>.of(cur.steps);
    int existingStepIdx = -1;
    if (explicitId != null && explicitId.isNotEmpty) {
      existingStepIdx = steps.lastIndexWhere((s) => s is ReasoningStep && s.id == explicitId);
    } else if (steps.isNotEmpty &&
        steps.last is ReasoningStep &&
        !(steps.last as ReasoningStep).id.startsWith('narration-')) {
      existingStepIdx = steps.length - 1;
    }
    if (existingStepIdx >= 0) {
      final prev = steps[existingStepIdx] as ReasoningStep;
      _activeReasonBuf = StringBuffer(prev.text)..write(delta);
      _activeReasonTurnIdx = idx;
      _activeReasonStepIdx = existingStepIdx;
      _activeReasonMaxSeq = eventSeq > cur.seqEnd ? eventSeq : cur.seqEnd;
      _cachedTurns = null;
    } else {
      final stepId = (explicitId != null && explicitId.isNotEmpty)
          ? explicitId
          : 'reason-${cur.turnId}-${steps.length}';
      steps.add(ReasoningStep(
        id: stepId,
        text: delta,
        collapsedPreview: _previewLine(delta),
      ));
      _turns[idx] = cur.copyWith(
        status: 'streaming',
        seqEnd: eventSeq > cur.seqEnd ? eventSeq : cur.seqEnd,
        steps: List.unmodifiable(steps),
      );
      _activeReasonBuf = StringBuffer(delta);
      _activeReasonTurnIdx = idx;
      _activeReasonStepIdx = steps.length - 1;
      _activeReasonMaxSeq = _turns[idx].seqEnd;
      _cachedTurns = null;
    }
  }

  void replaceAll(List<NormalizedTurn> turns) {
    _activeTextBuf = null;
    _activeTextTurnIdx = -1;
    _activeTextMaxSeq = 0;
    _activeReasonBuf = null;
    _activeReasonTurnIdx = -1;
    _activeReasonStepIdx = -1;
    _activeReasonMaxSeq = 0;
    _turns
      ..clear()
      ..addAll(turns);
    _invalidateCache();
  }

  /// Apply a single stream frame belonging to a `session:<id>` channel.
  /// Returns `true` when the turn list changed.
  bool apply(StreamFrame frame) {
    final type = frame.type;
    if (type == null) return false;
    final data = frame.dataMap ?? const <String, dynamic>{};
    // Only use DSH's per-session event seq (`eventSeq` / `raw.seq`) for `seqStart`/`seqEnd`,
    // never StreamHub's global ring sequence (`frame.seq`), so `session/fork(atSeq)` stays exact.
    final rawMap = data['raw'] is Map<String, dynamic> ? data['raw'] as Map<String, dynamic> : null;
    final eventSeq = (data['eventSeq'] as num?)?.toInt() ?? (rawMap?['seq'] as num?)?.toInt() ?? 0;
    final fallbackIdSeq = eventSeq > 0 ? eventSeq : (frame.seq ?? 0);

    switch (type) {
      case 'turn.start':
      case 'session.turn_start':
        _flushBuffers();
        final turnId = (data['turnId'] ?? 'turn-$fallbackIdSeq').toString();
        final existingIdx = _turns.indexWhere((t) => t.turnId == turnId);
        if (existingIdx >= 0) {
          _turns[existingIdx] = _turns[existingIdx].copyWith(
            status: 'streaming',
            seqEnd: eventSeq > _turns[existingIdx].seqEnd ? eventSeq : _turns[existingIdx].seqEnd,
          );
        } else {
          final userMsg = data['userMessage'] is Map<String, dynamic>
              ? NormalizedUserMessage.fromJson(data['userMessage'] as Map<String, dynamic>)
              : null;
          // Reconcile client-optimistic streaming turn instead of creating a duplicate bubble!
          final optIdx = _findOptimisticStreamingTurnIndex();
          if (optIdx >= 0) {
            final prev = _turns[optIdx];
            _turns[optIdx] = NormalizedTurn(
              turnId: turnId,
              stableKey: prev.stableKey,
              assistantMessageId: prev.assistantMessageId,
              seqStart: eventSeq > 0 ? eventSeq : prev.seqStart,
              seqEnd: eventSeq > prev.seqEnd ? eventSeq : prev.seqEnd,
              status: 'streaming',
              userMessage: prev.userMessage ?? userMsg,
              steps: prev.steps,
              assistantText: prev.assistantText,
              deliverables: prev.deliverables,
              usage: prev.usage,
            );
          } else {
            _turns.add(NormalizedTurn(
              turnId: turnId,
              seqStart: eventSeq,
              seqEnd: eventSeq,
              status: 'streaming',
              userMessage: userMsg,
            ));
          }
        }
        _invalidateCache();
        return true;

      case 'text.delta':
      case 'session.text_delta':
        final delta = (data['delta'] ?? data['text'] ?? data['chunk'] ?? '').toString();
        if (delta.isEmpty) return false;
        final idx = _ensureActiveTurnIndex(data['turnId']?.toString(), eventSeq);
        _appendAssistantText(idx, delta, eventSeq);
        return true;

      case 'reasoning.delta':
      case 'thinking.delta':
      case 'session.reasoning_delta':
        final delta = (data['delta'] ?? data['text'] ?? data['chunk'] ?? '').toString();
        if (delta.isEmpty) return false;
        final idx = _ensureActiveTurnIndex(data['turnId']?.toString(), eventSeq);
        _appendReasoningText(idx, data['id']?.toString(), delta, eventSeq);
        return true;

      case 'tool.call':
      case 'session.tool_call':
        _flushBuffers();
        final idx = _ensureActiveTurnIndex(data['turnId']?.toString(), eventSeq);
        final cur = _turns[idx];
        final callId = (data['callId'] ?? data['id'] ?? 'call-$fallbackIdSeq').toString();
        final name = (data['name'] ?? 'tool').toString();
        final title = (data['title'] ?? name).toString();
        final steps = List<NormalizedStep>.of(cur.steps);
        var nextAssistantText = cur.assistantText;
        if (nextAssistantText.trim().isNotEmpty) {
          final narr = nextAssistantText.trim();
          final preview = narr.split('\n').first;
          steps.add(ReasoningStep(
            id: 'narration-$fallbackIdSeq-${steps.length}',
            text: narr,
            collapsedPreview: preview.length > 160 ? '${preview.substring(0, 159)}…' : preview,
          ));
          nextAssistantText = '';
        }
        final existIdx = steps.indexWhere((s) => s is ToolStep && s.callId == callId);
        final toolStep = ToolStep(
          callId: callId,
          name: name,
          title: title,
          status: 'running',
          summary: (data['summary'] ?? '').toString(),
          hasFullOutput: data['hasFullOutput'] == true,
        );
        if (existIdx >= 0) {
          steps[existIdx] = toolStep;
        } else {
          steps.add(toolStep);
        }
        _turns[idx] = cur.copyWith(
          status: 'streaming',
          seqEnd: eventSeq > cur.seqEnd ? eventSeq : cur.seqEnd,
          steps: List.unmodifiable(steps),
          assistantText: nextAssistantText,
        );
        _invalidateCache();
        return true;

      case 'tool.result':
      case 'session.tool_result':
        _flushBuffers();
        final idx = _ensureActiveTurnIndex(data['turnId']?.toString(), eventSeq);
        final cur = _turns[idx];
        final callId = (data['callId'] ?? data['id'] ?? '').toString();
        final isError = data['isError'] == true || data['status'] == 'error';
        final steps = List<NormalizedStep>.of(cur.steps);
        final existIdx = steps.indexWhere((s) => s is ToolStep && s.callId == callId);
        if (existIdx >= 0) {
          final prev = steps[existIdx] as ToolStep;
          steps[existIdx] = prev.copyWith(
            status: isError ? 'error' : 'ok',
            summary: data['summary']?.toString() ?? prev.summary,
            hasFullOutput: data['hasFullOutput'] == true || prev.hasFullOutput,
            durationMs: (data['durationMs'] as num?)?.toInt() ?? prev.durationMs,
            subagentSessionId: data['subagentSessionId']?.toString() ?? prev.subagentSessionId,
          );
        } else {
          final name = (data['name'] ?? 'tool').toString();
          steps.add(ToolStep(
            callId: callId.isEmpty ? 'call-$fallbackIdSeq' : callId,
            name: name,
            title: (data['title'] ?? name).toString(),
            status: isError ? 'error' : 'ok',
            summary: (data['summary'] ?? '').toString(),
            hasFullOutput: data['hasFullOutput'] == true,
            durationMs: (data['durationMs'] as num?)?.toInt(),
            subagentSessionId: data['subagentSessionId']?.toString(),
          ));
        }
        _turns[idx] = cur.copyWith(
          seqEnd: eventSeq > cur.seqEnd ? eventSeq : cur.seqEnd,
          steps: List.unmodifiable(steps),
        );
        _invalidateCache();
        return true;

      case 'action_card':
      case 'session.action_card':
        _flushBuffers();
        final idx = _ensureActiveTurnIndex(data['turnId']?.toString(), eventSeq);
        final cur = _turns[idx];
        final card = ActionCardStep.fromJson(data);
        final steps = List<NormalizedStep>.of(cur.steps);
        final existIdx = steps.indexWhere((s) => s is ActionCardStep && s.id == card.id);
        if (existIdx >= 0) {
          steps[existIdx] = card;
        } else {
          steps.add(card);
        }
        _turns[idx] = cur.copyWith(
          seqEnd: eventSeq > cur.seqEnd ? eventSeq : cur.seqEnd,
          steps: List.unmodifiable(steps),
        );
        _invalidateCache();
        return true;

      case 'notice':
      case 'session.notice':
        _flushBuffers();
        final idx = _ensureActiveTurnIndex(data['turnId']?.toString(), eventSeq);
        final cur = _turns[idx];
        final notice = NoticeStep.fromJson(data);
        final steps = List<NormalizedStep>.of(cur.steps);
        if (!steps.any((s) => s is NoticeStep && s.level == notice.level && s.text == notice.text)) {
          steps.add(notice);
        }
        _turns[idx] = cur.copyWith(
          seqEnd: eventSeq > cur.seqEnd ? eventSeq : cur.seqEnd,
          steps: List.unmodifiable(steps),
        );
        _invalidateCache();
        return true;

      case 'turn.snapshot':
        _flushBuffers();
        if (data['turns'] is List<dynamic>) {
          final prevById = <String, NormalizedTurn>{
            for (final t in _turns) t.turnId: t,
          };
          final pendingOpt = _turns.isNotEmpty &&
                  _turns.last.isStreaming &&
                  _turns.last.turnId.startsWith('client-turn-')
              ? _turns.last
              : null;
          final parsed = (data['turns'] as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .map((raw) {
                final t = NormalizedTurn.fromJson(raw);
                final prev = prevById[t.turnId];
                if (prev != null) {
                  if (prev.status == t.status &&
                      prev.assistantText == t.assistantText &&
                      prev.steps.length == t.steps.length &&
                      prev.errorMessage == t.errorMessage &&
                      prev.deliverables.length == t.deliverables.length &&
                      (prev.userMessage?.text ?? '') == (t.userMessage?.text ?? '')) {
                    return prev;
                  }
                  return t.copyWith(stableKey: prev.stableKey);
                }
                return t;
              })
              .toList();
          if (pendingOpt != null) {
            final optUserText = pendingOpt.userMessage?.text.trim() ?? '';
            final optHasAtt = pendingOpt.userMessage?.attachments.isNotEmpty ?? false;
            final lastSnap = parsed.isNotEmpty ? parsed.last : null;
            final isNewOrLiveSnap =
                lastSnap != null && (!prevById.containsKey(lastSnap.turnId) || lastSnap.isStreaming);
            final alreadyPresent = isNewOrLiveSnap &&
                ((optUserText.isNotEmpty && (lastSnap.userMessage?.text.trim() ?? '') == optUserText) ||
                    (optUserText.isEmpty && optHasAtt && (lastSnap.userMessage?.attachments.isNotEmpty ?? false)));
            if (!alreadyPresent) {
              parsed.add(pendingOpt);
            } else {
              // Preserve the optimistic turn's stableKey so TurnView & _AssistantBody
              // never unmount/remount or replay typewriter from char 0 mid-stream!
              parsed[parsed.length - 1] = lastSnap.copyWith(stableKey: pendingOpt.stableKey);
            }
          }
          replaceAll(parsed);
          return true;
        }
        if (data['turn'] is Map<String, dynamic>) {
          final snap = NormalizedTurn.fromJson(data['turn'] as Map<String, dynamic>);
          final idx = _turns.indexWhere((t) => t.turnId == snap.turnId);
          if (idx >= 0) {
            _turns[idx] = snap.copyWith(
              stableKey: _turns[idx].stableKey,
              userMessage: snap.userMessage ?? _turns[idx].userMessage,
              assistantMessageId: snap.assistantMessageId ?? _turns[idx].assistantMessageId,
            );
          } else {
            final optIdx = _findOptimisticStreamingTurnIndex();
            if (optIdx >= 0) {
              _turns[optIdx] = snap.copyWith(
                stableKey: _turns[optIdx].stableKey,
                userMessage: snap.userMessage ?? _turns[optIdx].userMessage,
                assistantMessageId: snap.assistantMessageId ?? _turns[optIdx].assistantMessageId,
              );
            } else {
              _turns.add(snap);
            }
          }
          _invalidateCache();
          return true;
        }
        return false;

      case 'turn.delta':
        return _applyTurnDelta(data, eventSeq, fallbackIdSeq);

      case 'session.event':
        _flushBuffers();
        final norm = data['normalizedTurn'];
        if (norm is Map<String, dynamic>) {
          final snap = NormalizedTurn.fromJson(norm);
          return _mergeNormalizedTurn(snap, eventSeq);
        }
        return false;

      case 'session.stream_end':
        _flushBuffers();
        var changed = false;
        for (var i = 0; i < _turns.length; i++) {
          final t = _turns[i];
          if (!t.isStreaming) continue;
          final settled = <NormalizedStep>[
            for (final s in t.steps)
              (s is ToolStep && s.status == 'running') ? s.copyWith(status: 'ok') : s,
          ];
          var finalText = t.assistantText;
          if (finalText.trim().isEmpty) {
            for (var j = settled.length - 1; j >= 0; j--) {
              final s = settled[j];
              if (s is ReasoningStep && s.id.startsWith('narration-') && s.text.trim().isNotEmpty) {
                finalText = s.text;
                settled.removeAt(j);
                break;
              }
            }
          }
          _turns[i] = t.copyWith(
            status: 'completed',
            steps: List.unmodifiable(settled),
            assistantText: finalText,
          );
          changed = true;
        }
        if (changed) _invalidateCache();
        return changed;

      case 'turn.end':
      case 'turn.completed':
      case 'session.turn_end':
        _flushBuffers();
        final rawObj = data['raw'] is Map<String, dynamic>
            ? data['raw'] as Map<String, dynamic>
            : data;
        final rawData = rawObj['data'] is Map<String, dynamic>
            ? rawObj['data'] as Map<String, dynamic>
            : data;
        final idx = _ensureActiveTurnIndex(
          (data['turnId'] ?? rawData['turnId'])?.toString(),
          eventSeq,
        );
        final cur = _turns[idx];
        final rawReason = rawData['reason'] ?? data['reason'] ?? data['status'] ?? 'completed';
        final reason = rawReason is Map<String, dynamic>
            ? (rawReason['kind'] ?? rawReason['status'] ?? 'completed').toString()
            : rawReason.toString();
        bool hasTruthyErr(Object? v) =>
            v != null && v != false && !(v is String && v.trim().isEmpty);
        String? errMsg = data['errorMessage']?.toString();
        String? errCode = data['errorCode']?.toString();
        if (errMsg == null || errMsg.isEmpty) {
          if (rawReason is Map<String, dynamic> && rawReason['error'] is Map<String, dynamic>) {
            final re = rawReason['error'] as Map<String, dynamic>;
            errCode ??= re['code']?.toString();
            errMsg = (re['message'] ?? re['detail'] ?? re['error'])?.toString();
          } else if (rawData['error'] is Map<String, dynamic>) {
            final re = rawData['error'] as Map<String, dynamic>;
            errCode ??= re['code']?.toString();
            errMsg = (re['message'] ?? re['detail'] ?? re['error'])?.toString();
          } else if (hasTruthyErr(rawData['error'])) {
            errMsg = rawData['error'].toString();
          } else if (hasTruthyErr(data['error'])) {
            errMsg = data['error'].toString();
          }
        }
        final hasErr = reason == 'error' ||
            reason == 'interrupted' ||
            (errMsg != null && errMsg.isNotEmpty) ||
            hasTruthyErr(data['error']) ||
            hasTruthyErr(rawData['error']);
        final nextStatus = (reason == 'cancelled' || (reason == 'aborted' && !hasErr))
            ? 'cancelled'
            : (hasErr ? 'error' : 'completed');
        // Settle any unfinished running ToolSteps so spinners never freeze after turn completion.
        final settledToolStatus = (nextStatus == 'error' || nextStatus == 'cancelled') ? 'error' : 'ok';
        final nextSteps = <NormalizedStep>[
          for (final s in cur.steps)
            (s is ToolStep && s.status == 'running') ? s.copyWith(status: settledToolStatus) : s,
        ];
        var nextAssistantText = cur.assistantText;
        if (nextStatus != 'streaming' && nextAssistantText.trim().isEmpty) {
          for (var i = nextSteps.length - 1; i >= 0; i--) {
            final s = nextSteps[i];
            if (s is ReasoningStep && s.id.startsWith('narration-') && s.text.trim().isNotEmpty) {
              nextAssistantText = s.text;
              nextSteps.removeAt(i);
              break;
            }
          }
        }
        if (errMsg != null && errMsg.isNotEmpty) {
          final label = (errCode != null && errCode.isNotEmpty) ? '[$errCode] $errMsg' : errMsg;
          final already = nextSteps.any((s) => s is NoticeStep && s.level == 'error' && s.text == label);
          if (!already) {
            nextSteps.add(NoticeStep(level: 'error', text: label));
          }
        }
        final usage = (rawData['usage'] ?? data['usage']) is Map<String, dynamic>
            ? TurnUsage.fromJson((rawData['usage'] ?? data['usage']) as Map<String, dynamic>)
            : cur.usage;
        final deliverables = data['deliverables'] is List<dynamic>
            ? (data['deliverables'] as List<dynamic>)
                .whereType<Map<String, dynamic>>()
                .toList(growable: false)
            : cur.deliverables;
        _turns[idx] = cur.copyWith(
          status: nextStatus,
          seqEnd: eventSeq > cur.seqEnd ? eventSeq : cur.seqEnd,
          steps: List.unmodifiable(nextSteps),
          assistantText: nextAssistantText,
          usage: usage,
          deliverables: deliverables,
          errorCode: errCode ?? cur.errorCode,
          errorMessage: (errMsg != null && errMsg.isNotEmpty) ? errMsg : cur.errorMessage,
        );
        _invalidateCache();
        return true;

      case 'session.stream_error':
        _flushBuffers();
        final msg = (data['message'] ?? data['error'] ?? '流式连接异常').toString();
        final idx = _ensureActiveTurnIndex(data['turnId']?.toString(), eventSeq);
        final cur = _turns[idx];
        final nextSteps = <NormalizedStep>[
          for (final s in cur.steps)
            (s is ToolStep && s.status == 'running') ? s.copyWith(status: 'error') : s,
          NoticeStep(level: 'error', text: msg),
        ];
        _turns[idx] = cur.copyWith(
          status: 'error',
          seqEnd: eventSeq > cur.seqEnd ? eventSeq : cur.seqEnd,
          steps: List.unmodifiable(nextSteps),
          errorMessage: msg,
        );
        _invalidateCache();
        return true;

      default:
        return false;
    }
  }

  static String _extractChunkText(Map<String, dynamic> rawChunk) {
    final direct = rawChunk['text'] ?? rawChunk['delta'] ?? rawChunk['chunk'];
    if (direct is String && direct.isNotEmpty) return direct;
    final texts = rawChunk['texts'];
    if (texts is List && texts.isNotEmpty) {
      return texts.map((e) => e?.toString() ?? '').join();
    }
    return '';
  }

  bool _applyTurnDelta(Map<String, dynamic> data, int eventSeq, int fallbackIdSeq) {
    final chunks = <dynamic>[
      if (data['chunks'] is List<dynamic>) ...(data['chunks'] as List<dynamic>),
      if (data['chunks'] is! List<dynamic> && data['chunk'] != null) data['chunk'],
    ];
    if (chunks.isEmpty) return false;
    var changed = false;
    for (final rawChunk in chunks) {
      if (rawChunk is! Map<String, dynamic>) continue;
      final cType = (rawChunk['type'] ?? rawChunk['kind'] ?? '').toString();
      final text = _extractChunkText(rawChunk);
      if (cType == 'assistant-stream/abandoned') {
        _flushBuffers();
        final idx = _ensureActiveTurnIndex(data['turnId']?.toString(), eventSeq);
        final cur = _turns[idx];
        if (cur.assistantText.isNotEmpty) {
          _turns[idx] = cur.copyWith(assistantText: '');
          _invalidateCache();
          changed = true;
        }
        continue;
      }
      if (cType == 'turn/start') {
        _flushBuffers();
        final tid = rawChunk['turn'] != null
            ? 'turn-${rawChunk['turn']}'
            : (data['turnId']?.toString() ?? 'turn-$fallbackIdSeq');
        final existingIdx = _turns.indexWhere((t) => t.turnId == tid);
        if (existingIdx >= 0) {
          _turns[existingIdx] = _turns[existingIdx].copyWith(
            status: 'streaming',
            seqEnd: eventSeq > _turns[existingIdx].seqEnd ? eventSeq : _turns[existingIdx].seqEnd,
          );
        } else {
          final optIdx = _findOptimisticStreamingTurnIndex();
          if (optIdx >= 0) {
            final prev = _turns[optIdx];
            _turns[optIdx] = NormalizedTurn(
              turnId: tid,
              stableKey: prev.stableKey,
              assistantMessageId: prev.assistantMessageId,
              seqStart: eventSeq > 0 ? eventSeq : prev.seqStart,
              seqEnd: eventSeq > prev.seqEnd ? eventSeq : prev.seqEnd,
              status: 'streaming',
              userMessage: prev.userMessage,
              steps: prev.steps,
              assistantText: prev.assistantText,
              deliverables: prev.deliverables,
              usage: prev.usage,
            );
          } else if (_turns.isNotEmpty &&
              _turns.last.userMessage != null &&
              _turns.last.assistantText.isEmpty &&
              _turns.last.steps.isEmpty) {
            final prev = _turns.last;
            _turns[_turns.length - 1] = NormalizedTurn(
              turnId: tid,
              stableKey: prev.stableKey,
              assistantMessageId: prev.assistantMessageId,
              seqStart: prev.seqStart,
              seqEnd: eventSeq > prev.seqEnd ? eventSeq : prev.seqEnd,
              status: 'streaming',
              userMessage: prev.userMessage,
              steps: prev.steps,
              assistantText: prev.assistantText,
              deliverables: prev.deliverables,
              usage: prev.usage,
            );
          } else {
            // Close any previously unclosed streaming turn before starting a new server turn.
            for (var i = 0; i < _turns.length; i++) {
              if (_turns[i].isStreaming && _turns[i].turnId != tid) {
                _turns[i] = _turns[i].copyWith(status: 'completed');
              }
            }
            _ensureActiveTurnIndex(tid, eventSeq);
          }
        }
        _invalidateCache();
        changed = true;
      } else if (cType.contains('reason') || cType.contains('think')) {
        if (text.isEmpty) continue;
        final idx = _ensureActiveTurnIndex(data['turnId']?.toString(), eventSeq);
        _appendReasoningText(idx, rawChunk['id']?.toString(), text, eventSeq);
        changed = true;
      } else if (cType.contains('text')) {
        if (text.isEmpty) continue;
        final idx = _ensureActiveTurnIndex(data['turnId']?.toString(), eventSeq);
        _appendAssistantText(idx, text, eventSeq);
        changed = true;
      } else if (cType.contains('tool')) {
        _flushBuffers();
        final callId = (rawChunk['callId'] ?? rawChunk['id'] ?? '').toString();
        final name = (rawChunk['name'] ?? '').toString();
        if (callId.isEmpty && name.isEmpty) continue;
        final idx = _ensureActiveTurnIndex(data['turnId']?.toString(), eventSeq);
        final cur = _turns[idx];
        final steps = List<NormalizedStep>.of(cur.steps);
        var nextAssistantText = cur.assistantText;
        if (nextAssistantText.trim().isNotEmpty) {
          final narr = nextAssistantText.trim();
          final preview = narr.split('\n').first;
          steps.add(ReasoningStep(
            id: 'narration-$fallbackIdSeq-${steps.length}',
            text: narr,
            collapsedPreview: preview.length > 160 ? '${preview.substring(0, 159)}…' : preview,
          ));
          nextAssistantText = '';
        }
        final effId = callId.isEmpty ? 'call-$fallbackIdSeq' : callId;
        final existIdx = steps.indexWhere((s) => s is ToolStep && s.callId == effId);
        if (existIdx < 0) {
          steps.add(ToolStep(
            callId: effId,
            name: name.isEmpty ? 'tool' : name,
            title: name.isEmpty ? 'tool' : name,
            status: 'running',
          ));
          _turns[idx] = cur.copyWith(
            status: 'streaming',
            seqEnd: eventSeq > cur.seqEnd ? eventSeq : cur.seqEnd,
            steps: List.unmodifiable(steps),
            assistantText: nextAssistantText,
          );
          _invalidateCache();
          changed = true;
        } else if (nextAssistantText != cur.assistantText) {
          _turns[idx] = cur.copyWith(
            steps: List.unmodifiable(steps),
            assistantText: nextAssistantText,
          );
          _invalidateCache();
          changed = true;
        }
      }
    }
    return changed;
  }

  static void _mergeSteps(List<NormalizedStep> target, List<NormalizedStep> incoming) {
    for (final s in incoming) {
      if (s is ToolStep) {
        final ti = target.indexWhere((x) => x is ToolStep && x.callId == s.callId);
        if (ti >= 0) {
          target[ti] = s;
        } else {
          target.add(s);
        }
      } else if (s is ReasoningStep) {
        final ri = _findMatchingReasoningIndex(target, s);
        if (ri >= 0) {
          target[ri] = s;
        } else {
          target.add(s);
        }
      } else if (s is ActionCardStep) {
        final ai = target.indexWhere((x) => x is ActionCardStep && x.id == s.id);
        if (ai >= 0) {
          target[ai] = s;
        } else {
          target.add(s);
        }
      } else if (s is NoticeStep) {
        if (!target.any((x) => x is NoticeStep && x.level == s.level && x.text == s.text)) {
          target.add(s);
        }
      } else {
        target.add(s);
      }
    }
  }

  static int _findMatchingReasoningIndex(List<NormalizedStep> steps, ReasoningStep incoming) {
    final byId = steps.indexWhere((x) => x is ReasoningStep && x.id == incoming.id);
    if (byId >= 0) return byId;
    final incIsNarration = incoming.id.startsWith('narration-');
    final incTrim = incoming.text.trim();
    for (int i = steps.length - 1; i >= 0; i--) {
      final s = steps[i];
      if (s is ReasoningStep && s.id.startsWith('narration-') == incIsNarration) {
        final curTrim = s.text.trim();
        if (curTrim.isEmpty ||
            incTrim.isEmpty ||
            incTrim.startsWith(curTrim) ||
            curTrim.startsWith(incTrim)) {
          return i;
        }
        // Only coalesce against the latest reasoning step before any intervening non-reasoning step.
        break;
      }
      if (!incIsNarration && s is ToolStep) break;
    }
    return -1;
  }

  bool _mergeNormalizedTurn(NormalizedTurn snap, int eventSeq) {
    final effSeq = eventSeq > 0 ? eventSeq : snap.seqEnd;
    final promotedNarration = snap.assistantText.isEmpty &&
        snap.steps.any((s) => s is ReasoningStep && s.id.startsWith('narration-'));
    final idx = _turns.indexWhere((t) => t.turnId == snap.turnId);
    if (idx >= 0) {
      final cur = _turns[idx];
      final mergedSteps = List<NormalizedStep>.of(cur.steps);
      _mergeSteps(mergedSteps, snap.steps);
      final nextStatus = (snap.status == 'error' || snap.status == 'cancelled')
          ? snap.status
          : (cur.isStreaming ? 'streaming' : snap.status);
      final nextAssistantText = promotedNarration
          ? ''
          : (snap.assistantText.length >= cur.assistantText.length
              ? snap.assistantText
              : cur.assistantText);
      _turns[idx] = cur.copyWith(
        assistantMessageId: snap.assistantMessageId ?? cur.assistantMessageId,
        seqEnd: effSeq > cur.seqEnd ? effSeq : cur.seqEnd,
        status: nextStatus,
        userMessage: cur.userMessage ?? snap.userMessage,
        steps: List.unmodifiable(mergedSteps),
        assistantText: nextAssistantText,
        usage: snap.usage ?? cur.usage,
        deliverables: snap.deliverables.isNotEmpty ? snap.deliverables : cur.deliverables,
        errorCode: snap.errorCode ?? cur.errorCode,
        errorMessage: snap.errorMessage ?? cur.errorMessage,
      );
      _invalidateCache();
      return true;
    }
    if (_turns.isNotEmpty && _turns.last.isStreaming) {
      final cur = _turns.last;
      final mergedSteps = List<NormalizedStep>.of(cur.steps);
      _mergeSteps(mergedSteps, snap.steps);
      final adoptedTurnId =
          cur.turnId.startsWith('client-turn-') && snap.turnId.isNotEmpty
              ? snap.turnId
              : cur.turnId;
      final nextStatus = (snap.status == 'error' || snap.status == 'cancelled')
          ? snap.status
          : 'streaming';
      final nextAssistantText = promotedNarration
          ? ''
          : (snap.assistantText.isNotEmpty && snap.assistantText.length >= cur.assistantText.length
              ? snap.assistantText
              : cur.assistantText);
      _turns[_turns.length - 1] = NormalizedTurn(
        turnId: adoptedTurnId,
        stableKey: cur.stableKey,
        assistantMessageId: snap.assistantMessageId ?? cur.assistantMessageId,
        seqStart: cur.seqStart > 0 ? cur.seqStart : snap.seqStart,
        seqEnd: effSeq > cur.seqEnd ? effSeq : cur.seqEnd,
        status: nextStatus,
        userMessage: cur.userMessage ?? snap.userMessage,
        steps: List.unmodifiable(mergedSteps),
        assistantText: nextAssistantText,
        deliverables: snap.deliverables.isNotEmpty ? snap.deliverables : cur.deliverables,
        usage: snap.usage ?? cur.usage,
        errorCode: snap.errorCode ?? cur.errorCode,
        errorMessage: snap.errorMessage ?? cur.errorMessage,
      );
      _invalidateCache();
      return true;
    }
    _turns.add(snap);
    _invalidateCache();
    return true;
  }

  int _findOptimisticStreamingTurnIndex() {
    if (_turns.isEmpty) return -1;
    final last = _turns.last;
    if (last.isStreaming &&
        (last.turnId.startsWith('client-turn-') ||
            (last.assistantText.isEmpty && last.steps.isEmpty))) {
      return _turns.length - 1;
    }
    return -1;
  }

  int _ensureActiveTurnIndex(String? turnId, int seq) {
    if (turnId != null && turnId.isNotEmpty) {
      final idx = _turns.indexWhere((t) => t.turnId == turnId);
      if (idx >= 0) return idx;
    }
    if (_turns.isNotEmpty && _turns.last.isStreaming) {
      return _turns.length - 1;
    }
    _turns.add(NormalizedTurn(
      turnId: (turnId != null && turnId.isNotEmpty) ? turnId : 'turn-$seq',
      seqStart: seq,
      seqEnd: seq,
      status: 'streaming',
    ));
    return _turns.length - 1;
  }

  static bool _needsPreviewUpdate(String prevText, String prevPreview) {
    if (prevPreview.isEmpty) return true;
    // Refresh collapsed preview whenever a new reasoning line/paragraph arrives so long thinking never looks frozen.
    return prevText.length < 4096 || prevText.endsWith('\n');
  }

  static String _previewLine(String text, {int maxChars = 160}) {
    if (text.isEmpty) return '';
    // O(1) backward scan on ONLY the trailing 512 chars — zero RegExp compilation or full-string split!
    var end = text.length;
    final floor = end > 512 ? end - 512 : 0;
    while (end > floor && text.codeUnitAt(end - 1) <= 32) {
      end--;
    }
    if (end <= floor) {
      final trimmed = text.trim();
      if (trimmed.isEmpty) return '';
      return trimmed.length > maxChars ? '${trimmed.substring(0, maxChars - 1)}…' : trimmed;
    }
    var scanEnd = end;
    while (scanEnd > floor) {
      final nl = text.lastIndexOf('\n', scanEnd - 1);
      final lineStart = (nl < floor) ? floor : nl + 1;
      final candidate = text.substring(lineStart, scanEnd).trim();
      if (candidate.isNotEmpty) {
        return candidate.length > maxChars ? '${candidate.substring(0, maxChars - 1)}…' : candidate;
      }
      if (nl <= floor) break;
      scanEnd = nl;
    }
    final fallback = text.substring(floor, end).trim();
    return fallback.length > maxChars ? '${fallback.substring(0, maxChars - 1)}…' : fallback;
  }
}
