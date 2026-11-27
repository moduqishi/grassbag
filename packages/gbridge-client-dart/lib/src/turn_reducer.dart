import 'models.dart';

/// Deterministic reducer folding real-time `/gbridge/v1/stream` session events
/// into immutable [NormalizedTurn] lists for smooth 120Hz Flutter rendering.
class TurnStreamReducer {
  TurnStreamReducer([List<NormalizedTurn> initial = const []])
      : _turns = List<NormalizedTurn>.of(initial);

  final List<NormalizedTurn> _turns;
  List<NormalizedTurn>? _cachedTurns;

  // Amortized O(1) StringBuffer accumulators for hot streaming assistant text & reasoning deltas
  // kept alive across read-only `turns` flushes so 1,000+ WS chunks never perform O(L^2) copies!
  StringBuffer? _activeTextBuf;
  int _activeTextTurnIdx = -1;
  int _activeTextMaxSeq = 0;
  bool _activeTextDirty = false;

  StringBuffer? _activeReasonBuf;
  int _activeReasonTurnIdx = -1;
  int _activeReasonStepIdx = -1;
  int _activeReasonMaxSeq = 0;
  bool _activeReasonDirty = false;

  // Monotonic wall-clock start times for live reasoning & tool steps so we can
  // stamp accurate `durationMs` when transitioning to tools/answer/completion.
  final Map<String, int> _reasoningStartedAtMs = <String, int>{};
  final Map<String, int> _toolStartedAtMs = <String, int>{};
  String? _uncommittedReasoningId;

  /// Zero-flush O(1) check for whether the tail streaming turn already has buffered
  /// or committed assistant text or steps (avoids triggering full `turns` flush per WS delta!).
  bool get activeTurnHasOutput {
    if (_turns.isEmpty) return false;
    final lastIdx = _turns.length - 1;
    final last = _turns[lastIdx];
    if (!last.isStreaming) return false;
    if (last.assistantText.isNotEmpty || last.steps.isNotEmpty) return true;
    if (_activeTextBuf != null && _activeTextTurnIdx == lastIdx && _activeTextBuf!.isNotEmpty) {
      return true;
    }
    if (_activeReasonBuf != null && _activeReasonTurnIdx == lastIdx && _activeReasonBuf!.isNotEmpty) {
      return true;
    }
    return false;
  }

  /// Zero-flush O(1) check matching `_turns.isNotEmpty && _turns.last.isStreaming && !activeTurnHasOutput`.
  bool get isActiveTurnEmpty =>
      _turns.isNotEmpty && _turns.last.isStreaming && !activeTurnHasOutput;

  List<NormalizedTurn> get turns {
    _flushBuffers(detach: false);
    return _cachedTurns ??= List.unmodifiable(_turns);
  }

  void _invalidateCache() {
    _cachedTurns = null;
  }

  void _flushTextBuffer({bool detach = true}) {
    final buf = _activeTextBuf;
    final idx = _activeTextTurnIdx;
    final maxSeq = _activeTextMaxSeq;
    final dirty = _activeTextDirty;
    if (detach) {
      _activeTextBuf = null;
      _activeTextTurnIdx = -1;
      _activeTextMaxSeq = 0;
    }
    _activeTextDirty = false;
    if (!dirty || buf == null || idx < 0 || idx >= _turns.length) return;
    final cur = _turns[idx];
    _turns[idx] = cur.copyWith(
      status: 'streaming',
      seqEnd: maxSeq > cur.seqEnd ? maxSeq : cur.seqEnd,
      assistantText: buf.toString(),
    );
    _cachedTurns = null;
  }

  void _flushReasonBuffer({bool detach = true}) {
    final buf = _activeReasonBuf;
    final tIdx = _activeReasonTurnIdx;
    final sIdx = _activeReasonStepIdx;
    final maxSeq = _activeReasonMaxSeq;
    final dirty = _activeReasonDirty;
    if (detach) {
      _activeReasonBuf = null;
      _activeReasonTurnIdx = -1;
      _activeReasonStepIdx = -1;
      _activeReasonMaxSeq = 0;
    }
    _activeReasonDirty = false;
    if (!dirty || buf == null || tIdx < 0 || tIdx >= _turns.length) return;
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

  void _flushBuffers({bool detach = true}) {
    if (_activeTextBuf != null) _flushTextBuffer(detach: detach);
    if (_activeReasonBuf != null) _flushReasonBuffer(detach: detach);
  }

  void _finalizeOpenReasoningSteps(int turnIdx) {
    if (turnIdx < 0 || turnIdx >= _turns.length) return;
    final cur = _turns[turnIdx];
    if (_reasoningStartedAtMs.isEmpty || cur.steps.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    List<NormalizedStep>? updated;
    for (var i = 0; i < cur.steps.length; i++) {
      final s = cur.steps[i];
      if (s is ReasoningStep &&
          s.durationMs == null &&
          !s.id.startsWith('narration-')) {
        final started = _reasoningStartedAtMs.remove(s.id);
        if (started != null) {
          updated ??= List<NormalizedStep>.of(cur.steps);
          final elapsed = (now - started).clamp(1, 3600000);
          updated[i] = s.copyWith(durationMs: elapsed);
        }
      }
    }
    if (updated != null) {
      _turns[turnIdx] = cur.copyWith(steps: List.unmodifiable(updated));
      _cachedTurns = null;
    }
  }

  void _appendAssistantText(int idx, String delta, int eventSeq) {
    if (_activeReasonBuf != null) _flushReasonBuffer(detach: true);
    _finalizeOpenReasoningSteps(idx);
    if (_activeTextBuf != null && _activeTextTurnIdx != idx) {
      _flushTextBuffer(detach: true);
    }
    if (_activeTextBuf == null) {
      final cur = _turns[idx];
      _activeTextBuf = StringBuffer(cur.assistantText);
      _activeTextTurnIdx = idx;
      _activeTextMaxSeq = cur.seqEnd;
    }
    _activeTextBuf!.write(delta);
    _activeTextDirty = true;
    if (eventSeq > _activeTextMaxSeq) _activeTextMaxSeq = eventSeq;
    _cachedTurns = null;
  }

  void _appendReasoningText(int idx, String? explicitId, String delta, int eventSeq) {
    if (_activeTextBuf != null) _flushTextBuffer(detach: true);
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
          _activeReasonDirty = true;
          if (eventSeq > _activeReasonMaxSeq) _activeReasonMaxSeq = eventSeq;
          _cachedTurns = null;
          return;
        }
      }
      _flushReasonBuffer(detach: true);
    } else if (_activeReasonBuf != null) {
      _flushReasonBuffer(detach: true);
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
      _activeReasonDirty = true;
      _cachedTurns = null;
    } else {
      final stepId = (explicitId != null && explicitId.isNotEmpty)
          ? explicitId
          : 'reason-${cur.turnId}-${steps.length}';
      _reasoningStartedAtMs.putIfAbsent(
        stepId,
        () => DateTime.now().millisecondsSinceEpoch,
      );
      _uncommittedReasoningId = stepId;
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
      _activeReasonDirty = false;
      _cachedTurns = null;
    }
  }

  void replaceAll(List<NormalizedTurn> turns) {
    _uncommittedReasoningId = null;
    _activeTextBuf = null;
    _activeTextTurnIdx = -1;
    _activeTextMaxSeq = 0;
    _activeTextDirty = false;
    _activeReasonBuf = null;
    _activeReasonTurnIdx = -1;
    _activeReasonStepIdx = -1;
    _activeReasonMaxSeq = 0;
    _activeReasonDirty = false;
    // Preserve monotonic start timestamps for reasoning/tool steps that are still live
    // across periodic bundle resyncs so duration badges never silently disappear!
    final activeReasoningIds = <String>{};
    final activeToolIds = <String>{};
    for (final turn in turns) {
      if (!turn.isStreaming) continue;
      for (final step in turn.steps) {
        if (step is ReasoningStep &&
            step.durationMs == null &&
            !step.id.startsWith('narration-')) {
          activeReasoningIds.add(step.id);
        } else if (step is ToolStep && step.status == 'running') {
          activeToolIds.add(step.callId);
        }
      }
    }
    _reasoningStartedAtMs.removeWhere((id, _) => !activeReasoningIds.contains(id));
    _toolStartedAtMs.removeWhere((id, _) => !activeToolIds.contains(id));
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
              userMessage: _mergeUserMessages(prev.userMessage, userMsg),
              steps: prev.steps,
              assistantText: prev.assistantText,
              deliverables: prev.deliverables,
              usage: prev.usage,
            );
          } else {
            // Settle any prior unclosed streaming turn so a dropped `turn.end` never leaves
            // two concurrent streaming bubbles on screen!
            for (var i = 0; i < _turns.length; i++) {
              if (_turns[i].status == 'streaming') {
                final settledSteps = _turns[i]
                    .steps
                    .map((s) => s is ToolStep && s.status == 'running' ? s.copyWith(status: 'ok') : s)
                    .toList(growable: false);
                _turns[i] = _turns[i].copyWith(status: 'completed', steps: settledSteps);
              }
            }
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
        _finalizeOpenReasoningSteps(idx);
        final cur = _turns[idx];
        final callId = (data['callId'] ?? data['id'] ?? 'call-$fallbackIdSeq').toString();
        _toolStartedAtMs.putIfAbsent(callId, () => DateTime.now().millisecondsSinceEpoch);
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
        final startedAt = _toolStartedAtMs.remove(callId);
        final explicitDur = (data['durationMs'] as num?)?.toInt();
        final fallbackDur = explicitDur ??
            (startedAt != null
                ? (DateTime.now().millisecondsSinceEpoch - startedAt).clamp(1, 3600000)
                : null);
        final isError = data['isError'] == true || data['status'] == 'error';
        final steps = List<NormalizedStep>.of(cur.steps);
        final existIdx = steps.indexWhere((s) => s is ToolStep && s.callId == callId);
        if (existIdx >= 0) {
          final prev = steps[existIdx] as ToolStep;
          steps[existIdx] = prev.copyWith(
            status: isError ? 'error' : 'ok',
            summary: data['summary']?.toString() ?? prev.summary,
            hasFullOutput: data['hasFullOutput'] == true || prev.hasFullOutput,
            durationMs: fallbackDur ?? prev.durationMs,
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
            durationMs: fallbackDur,
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
          final snapshotNotRunning =
              data['sessionRunning'] == false || data['running'] == false;
          final isAuthoritative = data['authoritative'] == true;
          final parsed = (data['turns'] as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .map((raw) {
                final t = NormalizedTurn.fromJson(raw);
                final prev = prevById[t.turnId];
                if (prev != null) {
                  final enrichedSteps = _preserveStepDurations(prev.steps, t.steps);
                  if (prev.isStreaming) {
                    final snapshotSettled = (snapshotNotRunning || isAuthoritative) &&
                        t.status == 'completed' &&
                        !t.isStreaming &&
                        !enrichedSteps.any((s) => s is ToolStep && s.status == 'running') &&
                        t.assistantText.length >= prev.assistantText.length &&
                        (t.assistantText.isNotEmpty ||
                            enrichedSteps.length >= prev.steps.length);
                    final hasTerminal = t.usage != null ||
                        t.deliverables.isNotEmpty ||
                        (t.errorMessage?.isNotEmpty == true) ||
                        t.status == 'cancelled' ||
                        t.status == 'interrupted' ||
                        t.status == 'error' ||
                        snapshotSettled;
                    final mergedText = (!hasTerminal && prev.assistantText.length > t.assistantText.length)
                        ? prev.assistantText
                        : t.assistantText;
                    final mergedSteps = (!hasTerminal && prev.steps.length > enrichedSteps.length)
                        ? prev.steps
                        : enrichedSteps;
                    final mergedStatus = (!hasTerminal && !t.isStreaming && (mergedText.isNotEmpty || mergedSteps.isNotEmpty))
                        ? 'streaming'
                        : t.status;
                    final mergedUser = _mergeUserMessages(prev.userMessage, t.userMessage);
                    if (prev.status == mergedStatus &&
                        prev.assistantText == mergedText &&
                        prev.assistantMessageId == t.assistantMessageId &&
                        prev.seqStart == t.seqStart &&
                        prev.seqEnd == t.seqEnd &&
                        prev.errorCode == t.errorCode &&
                        _usageEquivalent(prev.usage, t.usage) &&
                        _stepsEquivalent(prev.steps, mergedSteps) &&
                        prev.errorMessage == t.errorMessage &&
                        _deliverablesEquivalent(prev.deliverables, t.deliverables) &&
                        identical(prev.userMessage, mergedUser)) {
                      return prev;
                    }
                    return t.copyWith(
                      stableKey: prev.stableKey,
                      status: mergedStatus,
                      assistantText: mergedText,
                      userMessage: mergedUser,
                      steps: mergedSteps,
                    );
                  }
                  final mergedUser = _mergeUserMessages(prev.userMessage, t.userMessage);
                  if (prev.status == t.status &&
                      prev.assistantText == t.assistantText &&
                      prev.assistantMessageId == t.assistantMessageId &&
                      prev.seqStart == t.seqStart &&
                      prev.seqEnd == t.seqEnd &&
                      prev.errorCode == t.errorCode &&
                      _usageEquivalent(prev.usage, t.usage) &&
                      _stepsEquivalent(prev.steps, enrichedSteps) &&
                      prev.errorMessage == t.errorMessage &&
                      _deliverablesEquivalent(prev.deliverables, t.deliverables) &&
                      identical(prev.userMessage, mergedUser)) {
                    return prev;
                  }
                  return t.copyWith(
                    stableKey: prev.stableKey,
                    userMessage: mergedUser,
                    steps: enrichedSteps,
                  );
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
                ((optUserText.isNotEmpty &&
                        _userTextsMatch(optUserText, lastSnap.userMessage?.text.trim() ?? '')) ||
                    (optUserText.isEmpty && optHasAtt && (lastSnap.userMessage?.attachments.isNotEmpty ?? false)));
            if (!alreadyPresent) {
              parsed.add(pendingOpt);
            } else {
              // Preserve the optimistic turn's stableKey so TurnView & _AssistantBody
              // never unmount/remount or replay typewriter from char 0 mid-stream!
              parsed[parsed.length - 1] = lastSnap.copyWith(
                stableKey: pendingOpt.stableKey,
                userMessage: _mergeUserMessages(pendingOpt.userMessage, lastSnap.userMessage),
              );
            }
          }
          // Preserve older turns previously prepended by `loadOlderTurns()` so live
          // `turn.snapshot` updates never wipe paginated chat history!
          // Skip reconciled optimistic `client-turn-*` shells (seqEnd == 0 / matching stableKey).
          if (_turns.isNotEmpty && parsed.isNotEmpty) {
            final snapIds = <String>{for (final t in parsed) t.turnId};
            final snapStableKeys = <String>{for (final t in parsed) t.stableKey};
            final minSnapSeq = parsed
                .map((t) => t.seqStart)
                .where((s) => s > 0)
                .fold<int>(0x7fffffff, (a, b) => a < b ? a : b);
            final olderPrefix = <NormalizedTurn>[];
            for (final t in _turns) {
              if (snapIds.contains(t.turnId) || snapStableKeys.contains(t.stableKey)) break;
              if (t.turnId.startsWith('client-turn-')) continue;
              if (minSnapSeq > 0 && minSnapSeq < 0x7fffffff && t.seqEnd > 0 && t.seqEnd < minSnapSeq) {
                olderPrefix.add(t);
              }
            }
            if (olderPrefix.isNotEmpty) {
              parsed.insertAll(0, olderPrefix);
            }
          }
          replaceAll(parsed);
          return true;
        }
        if (data['turn'] is Map<String, dynamic>) {
          final snap = NormalizedTurn.fromJson(data['turn'] as Map<String, dynamic>);
          final idx = _turns.indexWhere((t) => t.turnId == snap.turnId);
          if (idx >= 0) {
            final prev = _turns[idx];
            _turns[idx] = snap.copyWith(
              stableKey: prev.stableKey,
              steps: _preserveStepDurations(prev.steps, snap.steps),
              userMessage: _mergeUserMessages(prev.userMessage, snap.userMessage),
              assistantMessageId: snap.assistantMessageId ?? prev.assistantMessageId,
            );
          } else {
            final optIdx = _findOptimisticStreamingTurnIndex();
            if (optIdx >= 0) {
              final prev = _turns[optIdx];
              _turns[optIdx] = snap.copyWith(
                stableKey: prev.stableKey,
                steps: _preserveStepDurations(prev.steps, snap.steps),
                userMessage: _mergeUserMessages(prev.userMessage, snap.userMessage),
                assistantMessageId: snap.assistantMessageId ?? prev.assistantMessageId,
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
        final endTurnId = (data['turnId'] ?? rawData['turnId'])?.toString();
        final rawReasonPre = rawData['reason'] ?? data['reason'] ?? data['status'] ?? 'completed';
        final reasonPre = rawReasonPre is Map<String, dynamic>
            ? (rawReasonPre['kind'] ?? rawReasonPre['status'] ?? 'completed').toString()
            : rawReasonPre.toString();
        final hasErrPayloadPre = reasonPre == 'error' ||
            reasonPre == 'interrupted' ||
            (data['errorMessage']?.toString().isNotEmpty ?? false) ||
            data['error'] != null ||
            rawData['error'] != null;
        if (endTurnId != null && endTurnId.isNotEmpty) {
          final matchedIdx = _turns.indexWhere((t) => t.turnId == endTurnId);
          if (_turns.isNotEmpty && _turns.last.isStreaming && _turns.last.turnId != endTurnId) {
            // Ignore stale completion for an unknown older turn OR an already-cancelled
            // interrupted turn while a newer streaming/interrupt turn is active at the tail!
            if ((matchedIdx < 0 && !_turns.last.turnId.startsWith('client-turn-')) ||
                (matchedIdx >= 0 && matchedIdx < _turns.length - 1 && !_turns[matchedIdx].isStreaming)) {
              return false;
            }
          } else if (matchedIdx < 0 &&
              !hasErrPayloadPre &&
              (_turns.isEmpty || !_turns.last.isStreaming)) {
            // Stale completion for an unknown turn when nothing is streaming -> never spawn a blank phantom turn!
            return false;
          }
        }
        _uncommittedReasoningId = null;
        final idx = _ensureActiveTurnIndex(
          endTurnId,
          eventSeq,
        );
        _finalizeOpenReasoningSteps(idx);
        for (final step in _turns[idx].steps) {
          if (step is ToolStep) {
            _toolStartedAtMs.remove(step.callId);
          }
        }
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
        if ((errMsg == null || errMsg.isEmpty) && reason == 'interrupted') {
          errMsg = '本轮回复已被中断';
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
        final settledToolStatus = nextStatus == 'cancelled'
            ? 'cancelled'
            : (nextStatus == 'error' ? 'error' : 'ok');
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
      final rawType = rawChunk['type']?.toString() ?? '';
      final rawKind = rawChunk['kind']?.toString() ?? '';
      final cType = (rawType.isEmpty || rawType == 'chunk')
          ? (rawKind.isNotEmpty ? rawKind : rawType)
          : rawType;
      final text = _extractChunkText(rawChunk);
      if (cType == 'assistant-stream/abandoned') {
        _flushBuffers();
        final reqTurnId = data['turnId']?.toString();
        var idx = (reqTurnId != null && reqTurnId.isNotEmpty)
            ? _turns.indexWhere((t) => t.turnId == reqTurnId)
            : -1;
        if (idx < 0 && _turns.isNotEmpty && _turns.last.isStreaming) {
          idx = _turns.length - 1;
        }
        if (idx < 0) continue;
        final cur = _turns[idx];
        var nextSteps = cur.steps;
        var droppedReason = false;
        if (cur.steps.isNotEmpty && cur.steps.last is ReasoningStep) {
          final lastReason = cur.steps.last as ReasoningStep;
          if (_reasoningStartedAtMs.containsKey(lastReason.id) || _uncommittedReasoningId == lastReason.id) {
            _reasoningStartedAtMs.remove(lastReason.id);
            if (_uncommittedReasoningId == lastReason.id) _uncommittedReasoningId = null;
            nextSteps = List<NormalizedStep>.unmodifiable(
              cur.steps.sublist(0, cur.steps.length - 1),
            );
            droppedReason = true;
          }
        }
        if (cur.assistantText.isNotEmpty || droppedReason) {
          _turns[idx] = cur.copyWith(
            assistantText: '',
            steps: nextSteps,
          );
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
            // Close any previously unclosed streaming turn (and settle running tools) before starting a new server turn.
            for (var i = 0; i < _turns.length; i++) {
              if (_turns[i].isStreaming && _turns[i].turnId != tid) {
                final settledSteps = _turns[i]
                    .steps
                    .map((s) => s is ToolStep && s.status == 'running' ? s.copyWith(status: 'ok') : s)
                    .toList(growable: false);
                _turns[i] = _turns[i].copyWith(status: 'completed', steps: settledSteps);
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
        _finalizeOpenReasoningSteps(idx);
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
        final resolvedName = name.isEmpty ? 'tool' : name;
        String effId = callId;
        if (effId.isEmpty) {
          if (steps.isNotEmpty && steps.last is ToolStep) {
            final tail = steps.last as ToolStep;
            if (tail.status == 'running' && tail.name == resolvedName) {
              effId = tail.callId;
            }
          }
          if (effId.isEmpty) effId = 'call-$fallbackIdSeq';
        }
        _toolStartedAtMs.putIfAbsent(effId, () => DateTime.now().millisecondsSinceEpoch);
        final existIdx = steps.indexWhere((s) => s is ToolStep && s.callId == effId);
        if (existIdx < 0) {
          steps.add(ToolStep(
            callId: effId,
            name: resolvedName,
            title: resolvedName,
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
          final prev = target[ti] as ToolStep;
          target[ti] = (s.durationMs == null && prev.durationMs != null)
              ? s.copyWith(durationMs: prev.durationMs)
              : s;
        } else {
          target.add(s);
        }
      } else if (s is ReasoningStep) {
        final ri = _findMatchingReasoningIndex(target, s);
        if (ri >= 0) {
          final prev = target[ri] as ReasoningStep;
          final keepId = prev.id.isNotEmpty ? prev.id : s.id;
          final keepDuration = s.durationMs ?? prev.durationMs;
          final keepTranslation = s.translatedText ?? prev.translatedText;
          target[ri] = (keepId != s.id ||
                  keepDuration != s.durationMs ||
                  keepTranslation != s.translatedText)
              ? ReasoningStep(
                  id: keepId,
                  text: s.text,
                  collapsedPreview: s.collapsedPreview,
                  translatedText: keepTranslation,
                  durationMs: keepDuration,
                )
              : s;
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
    // Pass 1: exact or prefix content match across the turn (handles persisted `assistant/message`
    // arriving AFTER `tool-call-delta` already appended a trailing ToolStep).
    if (incTrim.isNotEmpty) {
      for (int i = steps.length - 1; i >= 0; i--) {
        final s = steps[i];
        if (s is ReasoningStep && s.id.startsWith('narration-') == incIsNarration) {
          final curTrim = s.text.trim();
          if (curTrim.isNotEmpty &&
              (curTrim == incTrim || incTrim.startsWith(curTrim) || curTrim.startsWith(incTrim))) {
            return i;
          }
        }
      }
    }
    // Pass 2: fallback only against an empty trailing reasoning placeholder before any tool call.
    for (int i = steps.length - 1; i >= 0; i--) {
      final s = steps[i];
      if (s is ReasoningStep && s.id.startsWith('narration-') == incIsNarration) {
        final curTrim = s.text.trim();
        if (curTrim.isEmpty || incTrim.isEmpty) return i;
        break;
      }
      if (!incIsNarration && s is ToolStep) break;
    }
    return -1;
  }

  static final RegExp _trailingAttachmentTagRe = RegExp(
    r'(?:\s*\[(?:附件|Attachment|附件已上传)\s*[:：][^\]]*\])+\s*$',
    caseSensitive: false,
  );

  static String _stripTrailingAttachmentTags(String s) =>
      s.replaceFirst(_trailingAttachmentTagRe, '').trim();

  static bool _userTextsMatch(String optTrim, String snapTrim) {
    if (optTrim == snapTrim) return true;
    if (optTrim.isEmpty || snapTrim.isEmpty) return false;
    final cleanOpt = _stripTrailingAttachmentTags(optTrim);
    final cleanSnap = _stripTrailingAttachmentTags(snapTrim);
    if (cleanOpt.isEmpty || cleanSnap.isEmpty) return false;
    if (cleanOpt == cleanSnap) return true;
    // Server may prepend `[引用文件: ...]` / `[引用会话: ...]` / `@file:...` / `@session:...` lines
    // or append `\n[附件: ...]` descriptors.
    if (cleanSnap.endsWith(cleanOpt) || cleanOpt.endsWith(cleanSnap)) return true;
    final normOpt = cleanOpt.replaceAll(RegExp(r'\s+'), ' ');
    final normSnap = cleanSnap.replaceAll(RegExp(r'\s+'), ' ');
    return normSnap == normOpt ||
        normSnap.endsWith(normOpt) ||
        normOpt.endsWith(normSnap);
  }

  static bool _shouldClearPromotedNarration(NormalizedTurn cur, NormalizedTurn snap) {
    final promotedSteps = snap.steps
        .whereType<ReasoningStep>()
        .where((s) => s.id.startsWith('narration-') && s.text.trim().isNotEmpty)
        .toList(growable: false);
    if (promotedSteps.isEmpty || snap.assistantText.isNotEmpty) return false;
    final curTrim = cur.assistantText.trim();
    if (curTrim.isEmpty) return true;
    return promotedSteps.any((s) {
      final p = s.text.trim();
      return p == curTrim || p.startsWith(curTrim) || curTrim.startsWith(p);
    });
  }

  void _pruneFinishedToolStartTimes(List<NormalizedStep> steps) {
    if (_toolStartedAtMs.isEmpty) return;
    for (final s in steps) {
      if (s is ToolStep && s.status != 'running') {
        _toolStartedAtMs.remove(s.callId);
      }
    }
  }

  bool _mergeNormalizedTurn(NormalizedTurn snap, int eventSeq) {
    final effSeq = eventSeq > 0 ? eventSeq : snap.seqEnd;
    final idx = _turns.indexWhere((t) => t.turnId == snap.turnId);
    if (idx >= 0) {
      final cur = _turns[idx];
      final promotedNarration = _shouldClearPromotedNarration(cur, snap);
      final mergedSteps = List<NormalizedStep>.of(cur.steps);
      _mergeSteps(mergedSteps, snap.steps);
      _pruneFinishedToolStartTimes(mergedSteps);
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
        userMessage: _mergeUserMessages(cur.userMessage, snap.userMessage),
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
      final canFoldIntoLast = cur.turnId.startsWith('client-turn-') || snap.turnId.isEmpty;
      if (canFoldIntoLast) {
        final promotedNarration = _shouldClearPromotedNarration(cur, snap);
        final mergedSteps = List<NormalizedStep>.of(cur.steps);
        _mergeSteps(mergedSteps, snap.steps);
        _pruneFinishedToolStartTimes(mergedSteps);
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
        final settledMergedSteps = nextStatus == 'streaming'
            ? mergedSteps
            : mergedSteps
                .map((s) => s is ToolStep && s.status == 'running'
                    ? s.copyWith(status: nextStatus == 'error' ? 'error' : 'ok')
                    : s)
                .toList(growable: false);
        _turns[_turns.length - 1] = NormalizedTurn(
          turnId: adoptedTurnId,
          stableKey: cur.stableKey,
          assistantMessageId: snap.assistantMessageId ?? cur.assistantMessageId,
          seqStart: cur.seqStart > 0 ? cur.seqStart : snap.seqStart,
          seqEnd: effSeq > cur.seqEnd ? effSeq : cur.seqEnd,
          status: nextStatus,
          userMessage: _mergeUserMessages(cur.userMessage, snap.userMessage),
          steps: List.unmodifiable(settledMergedSteps),
          assistantText: nextAssistantText,
          deliverables: snap.deliverables.isNotEmpty ? snap.deliverables : cur.deliverables,
          usage: snap.usage ?? cur.usage,
          errorCode: snap.errorCode ?? cur.errorCode,
          errorMessage: snap.errorMessage ?? cur.errorMessage,
        );
        _invalidateCache();
        return true;
      }
      // A distinct new server turn arrived before the prior streaming turn's turn.completed!
      // Settle the prior turn (including any still-running tool spinners) instead of overwriting.
      if (snap.userMessage != null) {
        _finalizeOpenReasoningSteps(_turns.length - 1);
        final settledPrevSteps = _turns[_turns.length - 1]
            .steps
            .map((s) => s is ToolStep && s.status == 'running' ? s.copyWith(status: 'ok') : s)
            .toList(growable: false);
        _turns[_turns.length - 1] = _turns[_turns.length - 1].copyWith(
          status: 'completed',
          steps: List.unmodifiable(settledPrevSteps),
        );
      }
    }
    _pruneFinishedToolStartTimes(snap.steps);
    _turns.add(snap);
    _invalidateCache();
    return true;
  }

  /// Merges local optimistic and server-normalized user messages so server-computed
  /// `maskedRanges` & `references` always enrich optimistic bubbles without dropping
  /// local text, attachments, or timestamps — while never letting a mid-turn steer
  /// `user/message` (with a distinct server ID) overwrite the turn's original prompt!
  static NormalizedUserMessage? _mergeUserMessages(
    NormalizedUserMessage? local,
    NormalizedUserMessage? server,
  ) {
    if (local == null) return server;
    if (server == null) return local;
    final localIsConfirmedServerId = local.id.isNotEmpty &&
        !local.id.startsWith('u-client') &&
        !local.id.startsWith('client-') &&
        !local.id.startsWith('local-') &&
        !local.id.startsWith('opt-') &&
        !local.id.startsWith('u-opt-');
    if (localIsConfirmedServerId &&
        server.id.isNotEmpty &&
        server.id != local.id &&
        local.text.trim() != server.text.trim()) {
      return local;
    }
    final mergedMasks = server.maskedRanges.isNotEmpty
        ? server.maskedRanges
        : local.maskedRanges;
    final mergedRefs = server.references.isNotEmpty
        ? server.references
        : local.references;
    final mergedAtts = _mergeAttachmentLists(local.attachments, server.attachments);
    final mergedText = server.text.isNotEmpty ? server.text : local.text;
    final mergedId = server.id.isNotEmpty ? server.id : local.id;
    final mergedCreatedAt = server.createdAt ?? local.createdAt;
    if (identical(mergedMasks, local.maskedRanges) &&
        identical(mergedRefs, local.references) &&
        identical(mergedAtts, local.attachments) &&
        mergedText == local.text &&
        mergedId == local.id &&
        mergedCreatedAt == local.createdAt) {
      return local;
    }
    return NormalizedUserMessage(
      id: mergedId,
      text: mergedText,
      attachments: mergedAtts,
      references: mergedRefs,
      maskedRanges: mergedMasks,
      createdAt: mergedCreatedAt,
    );
  }

  /// Preserve local live image/file preview bytes when the server echoes back
  /// persisted attachment metadata `{ attachmentId, mediaType, bytes: <size> }`.
  static List<Map<String, dynamic>> _mergeAttachmentLists(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> server,
  ) {
    if (server.isEmpty) return local;
    if (local.isEmpty) return server;
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < server.length; i++) {
      final srv = server[i];
      if (srv['bytes'] is List<int> || srv['previewBytes'] is List<int>) {
        out.add(srv);
        continue;
      }
      final srvId = (srv['attachmentId'] ?? srv['receiptId'] ?? srv['id'] ?? '').toString();
      final srvName = (srv['name'] ?? srv['filename'] ?? '').toString();
      Map<String, dynamic>? match;
      for (final loc in local) {
        final locId = (loc['attachmentId'] ?? loc['receiptId'] ?? loc['id'] ?? '').toString();
        final locName = (loc['name'] ?? loc['filename'] ?? '').toString();
        if (srvId.isNotEmpty && locId == srvId) {
          match = loc;
          break;
        }
        if (srvName.isNotEmpty && locName == srvName) {
          match = loc;
          break;
        }
      }
      if (match == null && i < local.length && server.length == local.length) {
        match = local[i];
      }
      final locBytes = match?['bytes'];
      final locPreview = match?['previewBytes'];
      final locData = match?['data'] ?? match?['base64'];
      if (locBytes is List<int> || locPreview is List<int> || (locData is String && locData.isNotEmpty)) {
        out.add({
          ...srv,
          if (srv['size'] == null && srv['bytes'] is num) 'size': srv['bytes'],
          if (locBytes is List<int>) 'previewBytes': locBytes,
          if (locPreview is List<int>) 'previewBytes': locPreview,
          if (locData is String && locData.isNotEmpty && srv['data'] == null) 'data': locData,
        });
      } else {
        out.add(srv);
      }
    }
    return List.unmodifiable(out);
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
      if (_turns.isNotEmpty && _turns.last.turnId == turnId) {
        return _turns.length - 1;
      }
      final idx = _turns.lastIndexWhere((t) => t.turnId == turnId);
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

  static bool _stepsEquivalent(List<NormalizedStep> a, List<NormalizedStep> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (identical(x, y)) continue;
      if (x.runtimeType != y.runtimeType) return false;
      if (x is ToolStep && y is ToolStep) {
        if (x.callId != y.callId ||
            x.name != y.name ||
            x.title != y.title ||
            x.status != y.status ||
            x.summary != y.summary ||
            x.hasFullOutput != y.hasFullOutput ||
            x.durationMs != y.durationMs ||
            x.subagentSessionId != y.subagentSessionId) {
          return false;
        }
      } else if (x is ReasoningStep && y is ReasoningStep) {
        if (x.id != y.id ||
            x.text.length != y.text.length ||
            x.text != y.text ||
            x.translatedText != y.translatedText ||
            x.durationMs != y.durationMs) {
          return false;
        }
      } else if (x is NoticeStep && y is NoticeStep) {
        if (x.level != y.level || x.text != y.text) return false;
      } else if (x is ActionCardStep && y is ActionCardStep) {
        if (x.id != y.id || x.viewId != y.viewId || !_deepValueEquals(x.sdui, y.sdui)) return false;
      }
    }
    return true;
  }

  static bool _usageEquivalent(TurnUsage? a, TurnUsage? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.inputTokens == b.inputTokens &&
        a.outputTokens == b.outputTokens &&
        a.cacheReadTokens == b.cacheReadTokens &&
        a.cacheWriteTokens == b.cacheWriteTokens &&
        a.cost == b.cost &&
        a.durationMs == b.durationMs;
  }

  static bool _deliverablesEquivalent(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepValueEquals(a[i], b[i])) return false;
    }
    return true;
  }

  static bool _deepValueEquals(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final entry in a.entries) {
        if (!b.containsKey(entry.key) || !_deepValueEquals(entry.value, b[entry.key])) {
          return false;
        }
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepValueEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  static List<NormalizedStep> _preserveStepDurations(
    List<NormalizedStep> prevSteps,
    List<NormalizedStep> nextSteps,
  ) {
    if (prevSteps.isEmpty || nextSteps.isEmpty) return nextSteps;
    List<NormalizedStep>? out;
    for (var i = 0; i < nextSteps.length; i++) {
      final s = nextSteps[i];
      if (s is ReasoningStep) {
        final matchIdx = _findMatchingReasoningIndex(prevSteps, s);
        if (matchIdx >= 0) {
          final prev = prevSteps[matchIdx] as ReasoningStep;
          final keepId = prev.id.isNotEmpty ? prev.id : s.id;
          final keepDuration = s.durationMs ?? prev.durationMs;
          final keepTranslation = s.translatedText ?? prev.translatedText;
          if (keepId != s.id ||
              keepDuration != s.durationMs ||
              keepTranslation != s.translatedText) {
            out ??= List<NormalizedStep>.of(nextSteps);
            out[i] = ReasoningStep(
              id: keepId,
              text: s.text,
              collapsedPreview: s.collapsedPreview,
              translatedText: keepTranslation,
              durationMs: keepDuration,
            );
          }
        }
      } else if (s is ToolStep && s.durationMs == null) {
        final matchIdx = prevSteps.indexWhere((x) => x is ToolStep && x.callId == s.callId);
        if (matchIdx >= 0) {
          final prev = prevSteps[matchIdx] as ToolStep;
          if (prev.durationMs != null) {
            out ??= List<NormalizedStep>.of(nextSteps);
            out[i] = s.copyWith(durationMs: prev.durationMs);
          }
        }
      }
    }
    return out == null ? nextSteps : List.unmodifiable(out);
  }

  static bool _needsPreviewUpdate(String prevText, String prevPreview) {
    // `_previewLine` scans at most the trailing 512 chars in O(1), so always keep the collapsed
    // preview fresh even when long reasoning streams exceed 4096 chars.
    return true;
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
