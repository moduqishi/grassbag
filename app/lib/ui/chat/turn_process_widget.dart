import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gbridge_client/gbridge_client.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import '../sdui/sdui_renderer.dart';
import '../web/web_embed.dart';

/// Bounded LRU cache for base64-decoded user image attachments so 42Hz streaming rebuilds
/// never re-decode large payloads or allocate fresh Uint8Lists (which caused blank image flashes).
final Map<String, Uint8List> _decodedAttachmentBytesCache = <String, Uint8List>{};

/// Clears module-level decoded attachment bytes & typewriter reveal caches on host switch
/// so cached images or turn offsets never bleed across hosts.
void clearTurnProcessCaches() {
  _decodedAttachmentBytesCache.clear();
  _AssistantBodyState._revealedProgressByTurn.clear();
}

/// Renders one `NormalizedTurn`: Apple iOS 26 luminous user bubble (with secret redaction
/// & long-press [GlassContextMenu]), `dsh-Go`-grade borderless `StreamRow` + `StreamThread`
/// multi-step timeline, and rich inline-Markdown assistant reply + deliverable cards.
class TurnView extends ConsumerWidget {
  const TurnView({
    super.key,
    required this.turn,
    required this.onOpenTerminal,
    this.animateEntrance = false,
    this.onPrefillPrompt,
    this.onRegenerate,
  });

  final NormalizedTurn turn;
  final VoidCallback onOpenTerminal;
  final bool animateEntrance;
  final ValueChanged<String>? onPrefillPrompt;
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          secretRevealed: s.secretRevealed,
          autoFoldSteps: s.autoFoldSteps,
          isExpanded: s.expandedTurnProcessIds.contains(turn.stableKey) ||
              s.expandedTurnProcessIds.contains(turn.turnId),
          isCollapsed: s.collapsedTurnProcessIds.contains(turn.stableKey) ||
              s.collapsedTurnProcessIds.contains(turn.turnId),
          canTranslateCot: s.connectionPhase == ConnectionPhase.connected,
          glassTier: s.glassTier,
          feedback: s.turnFeedback.isEmpty
              ? null
              : (s.turnFeedback['${s.activeSessionId ?? ''}:${turn.assistantMessageId ?? turn.turnId}'] ??
                  s.turnFeedback['${s.activeSessionId ?? ''}:${turn.turnId}'] ??
                  s.turnFeedback[turn.turnId]),
          isCreatingSession: turn.isStreaming ? s.isCreatingSession : false,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    // Independent per-turn process expansion: open while actively streaming (unless collapsed),
    // or respect autoFoldSteps & explicit per-turn toggle when finished!
    final processOpen = turn.isStreaming
        ? !slice.isCollapsed
        : (slice.autoFoldSteps ? slice.isExpanded : !slice.isCollapsed);
    final effectiveRegenerate = onRegenerate ??
        (turn.userMessage != null
            ? () {
                if (ref.read(appProvider).isStreaming) return;
                final u = turn.userMessage!;
                final prompt = u.text.trim().isNotEmpty ? u.text : '请重新执行上一条请求';
                ctrl.sendPrompt(prompt, includePendingAttachments: false);
              }
            : null);

    Widget buildUserBubble(NormalizedUserMessage msg) {
      return Material(
        type: MaterialType.transparency,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: t.isDark
                  ? [
                      Color.lerp(t.userBubble, Colors.white, 0.08)!,
                      t.userBubble,
                    ]
                  : [
                      Color.lerp(t.userBubble, Colors.white, 0.24)!,
                      t.userBubble,
                    ],
            ),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(22),
              topRight: Radius.circular(22),
              bottomLeft: Radius.circular(22),
              bottomRight: Radius.circular(7),
            ),
            border: Border.all(
              color: t.isDark
                  ? Colors.white.withValues(alpha: 0.09)
                  : Colors.white.withValues(alpha: 0.80),
              width: 0.75,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: t.isDark ? 0.28 : 0.05),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: _UserMessageContent(
            msg: msg,
            revealed: slice.secretRevealed,
            onToggleReveal: ctrl.toggleSecretRevealed,
          ),
        ),
      );
    }

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (turn.userMessage != null)
          RepaintBoundary(
            child: _UserMessageBlock(
              msg: turn.userMessage!,
              revealed: slice.secretRevealed,
              onToggleReveal: ctrl.toggleSecretRevealed,
              bubbleBuilder: buildUserBubble,
              onCopy: () {
                Clipboard.setData(ClipboardData(text: turn.userMessage!.text));
                ctrl.showToast('已复制消息内容');
              },
              onPrefillPrompt: onPrefillPrompt,
            ),
          ),
        if (turn.steps.isNotEmpty) ...[
          const SizedBox(height: 16),
          RepaintBoundary(
            child: _TurnProcessBlock(
              turn: turn,
              tier: slice.glassTier,
              open: processOpen,
              canTranslateCot: slice.canTranslateCot,
              onToggleOpen: () => ctrl.toggleTurnProcessFor(
                turn.stableKey,
                currentlyOpen: processOpen,
              ),
              onToggleStep: ctrl.toggleStepExpanded,
              onToggleTranslate: (stepId, text) => ctrl.translateReasoningStep(stepId, text),
              onOpenTerminal: onOpenTerminal,
              onLoadToolDetail: ctrl.loadToolDetail,
              onSduiAction: (viewId, actionId, payload) =>
                  ctrl.invokeSduiAction(viewId, actionId, payload),
            ),
          ),
        ] else if (turn.isStreaming && turn.assistantText.isEmpty) ...[
          const SizedBox(height: 16),
          _LiveAwaitingResponseRow(
            isCreatingSession: slice.isCreatingSession,
            startedAtMs: turn.userMessage?.createdAt,
          ),
        ] else if (!turn.isStreaming &&
            turn.assistantText.isEmpty &&
            turn.deliverables.isEmpty &&
            !turn.hasError &&
            turn.userMessage != null) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(CupertinoIcons.stop_circle, size: 14, color: t.text3),
              const SizedBox(width: 6),
              Text(
                '已停止生成',
                style: TextStyle(fontSize: 12.5, color: t.text3),
              ),
              if (effectiveRegenerate != null) ...[
                const SizedBox(width: 10),
                GrassBagSpringTap(
                  onTap: effectiveRegenerate,
                  pressedScale: 0.94,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: t.fill1,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.arrow_clockwise, size: 11.5, color: t.primary),
                        const SizedBox(width: 4),
                        Text(
                          '重试',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: t.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
        if (turn.assistantText.isNotEmpty ||
            turn.deliverables.isNotEmpty ||
            (!turn.isStreaming && turn.steps.isNotEmpty && !turn.hasError))
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: _AssistantBody(
              turnId: turn.stableKey,
              text: turn.assistantText,
              isStreaming: turn.isStreaming,
              deliverables: turn.deliverables,
              usage: turn.usage,
              feedback: slice.feedback,
              onCopy: () {
                Clipboard.setData(ClipboardData(text: turn.assistantText));
                ctrl.showToast('已复制回复内容');
              },
              onFork: () => ctrl.forkActiveSession(turnId: turn.turnId),
              onFeedback: (rating) => ctrl.putTurnFeedback(turn.turnId, rating),
              onRegenerate: turn.hasError ? null : effectiveRegenerate,
              onDeliverableTap: (name) {
                final match =
                    turn.deliverables.where((d) => (d['name'] ?? '').toString() == name).firstOrNull;
                showDeliverablePreviewSheet(
                  context,
                  ref,
                  name: name,
                  path: match?['path']?.toString(),
                  subtitle: (match?['note'] ?? '生成产物').toString(),
                  sizeLabel: (match?['size'] ?? '').toString(),
                );
              },
            ),
          ),
        if (turn.hasError) ...[
          const SizedBox(height: 12),
          _TurnErrorCard(
            turn: turn,
            tier: slice.glassTier,
            onCopy: (txt) {
              Clipboard.setData(ClipboardData(text: txt));
              ctrl.showToast('已复制报错详情');
            },
            onRetry: effectiveRegenerate,
          ),
        ],
        const SizedBox(height: 24),
      ],
    );

    // ALWAYS mount `_TurnEntrance` unconditionally so flipping `animateEntrance`
    // from `true -> false` on the 2nd build NEVER unmounts/remounts the turn subtree!
    return _TurnEntrance(animate: animateEntrance, child: body);
  }
}

/// Calm pure-fade entrance for a newly sent live turn (zero vertical jump & zero Frame-2 remount!).
class _TurnEntrance extends StatefulWidget {
  const _TurnEntrance({required this.animate, required this.child});
  final bool animate;
  final Widget child;

  @override
  State<_TurnEntrance> createState() => _TurnEntranceState();
}

class _TurnEntranceState extends State<_TurnEntrance>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;
  Animation<double>? _opacity;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _ctrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 140),
      );
      _opacity = CurvedAnimation(parent: _ctrl!, curve: Curves.easeOut);
      _ctrl!.forward();
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opacity = _opacity;
    if (opacity == null) return widget.child;
    return FadeTransition(
      opacity: opacity,
      child: widget.child,
    );
  }
}

/// Calm, zero-jitter live waiting row shown right below the user's message from Frame 0
/// until the first thinking step, tool call, or assistant character arrives.
/// Mirrors `_TurnProcessBlock`'s exact 34px header geometry so transitioning into steps never jumps!
class _LiveAwaitingResponseRow extends ConsumerStatefulWidget {
  const _LiveAwaitingResponseRow({
    required this.isCreatingSession,
    this.startedAtMs,
  });

  final bool isCreatingSession;
  final int? startedAtMs;

  @override
  ConsumerState<_LiveAwaitingResponseRow> createState() => _LiveAwaitingResponseRowState();
}

class _LiveAwaitingResponseRowState extends ConsumerState<_LiveAwaitingResponseRow> {
  Timer? _timer;
  int _elapsedTenths = 0;
  late final int _originMs;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now().millisecondsSinceEpoch;
    final started = widget.startedAtMs;
    if (started != null && started > 0 && now - started > 0 && now - started < 3600 * 1000) {
      _originMs = started;
      _elapsedTenths = (now - started) ~/ 200;
    } else {
      _originMs = now;
    }
    // 5Hz timer instead of 120Hz vsync Ticker — saves ~95% idle vsync wakeups while waiting.
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      final tenths = (DateTime.now().millisecondsSinceEpoch - _originMs) ~/ 200;
      if (tenths != _elapsedTenths) {
        setState(() => _elapsedTenths = tenths);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _phaseLabel(String? livePhase) {
    if (widget.isCreatingSession) return '正在创建对话并接入工作区…';
    final p = (livePhase ?? '').toLowerCase();
    if (p.contains('reason') || p.contains('think')) return '正在深度思考…';
    if (p.contains('tool')) return '正在准备执行工具…';
    if (p.contains('text') || p.contains('answer')) return '正在组织回复…';
    return '已发送，等待模型响应…';
  }

  @override
  Widget build(BuildContext context) {
    final livePhase = ref.watch(appProvider.select((s) => s.sessionTelemetry.livePhase));
    final t = GrassBagTokens.of(context);
    final sec = (_elapsedTenths * 0.2).toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Center(
              child: _BreathingStatusDot(color: t.primary),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _phaseLabel(livePhase),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: t.text2,
              ),
            ),
          ),
          if (_elapsedTenths >= 2)
            Text(
              '${sec}s',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: t.text3,
              ),
            ),
        ],
      ),
    );
  }
}

class _UserMessageBlock extends StatefulWidget {
  const _UserMessageBlock({
    required this.msg,
    required this.revealed,
    required this.onToggleReveal,
    required this.bubbleBuilder,
    required this.onCopy,
    this.onPrefillPrompt,
  });

  final NormalizedUserMessage msg;
  final bool revealed;
  final VoidCallback onToggleReveal;
  final Widget Function(NormalizedUserMessage) bubbleBuilder;
  final VoidCallback onCopy;
  final ValueChanged<String>? onPrefillPrompt;

  @override
  State<_UserMessageBlock> createState() => _UserMessageBlockState();
}

class _UserMessageBlockState extends State<_UserMessageBlock> {
  bool _hovered = false;

  String? _formatTime(int? ms) {
    if (ms == null || ms <= 0) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final timeStr = _formatTime(widget.msg.createdAt);
    final isDesktop = kIsWeb ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Always wrap user bubble in SelectionArea so BOTH mobile and desktop users can
              // highlight & copy partial text without long-press context menu hijacking selection!
              SelectionArea(child: widget.bubbleBuilder(widget.msg)),
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (timeStr != null)
                      Text(
                        timeStr,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: t.text3.withValues(alpha: 0.72),
                        ),
                      ),
                    IgnorePointer(
                      ignoring: isDesktop && !_hovered,
                      child: () {
                        final iconColor = isDesktop ? t.text3 : t.text3.withValues(alpha: 0.78);
                        final row = Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (timeStr != null) const SizedBox(width: 4),
                            Tooltip(
                              message: '复制消息',
                              child: GrassBagSpringTap(
                                onTap: widget.onCopy,
                                pressedScale: 0.9,
                                child: SizedBox(
                                  width: 36,
                                  height: 32,
                                  child: Center(
                                    child: Icon(CupertinoIcons.doc_on_doc, size: 13.5, color: iconColor),
                                  ),
                                ),
                              ),
                            ),
                            if (widget.onPrefillPrompt != null)
                              Tooltip(
                                message: '编辑重发',
                                child: GrassBagSpringTap(
                                  onTap: () => widget.onPrefillPrompt!(widget.msg.text),
                                  pressedScale: 0.9,
                                  child: SizedBox(
                                    width: 36,
                                    height: 32,
                                    child: Center(
                                      child: Icon(CupertinoIcons.pencil, size: 13.5, color: iconColor),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                        // Avoid permanent offscreen OpacityLayer saveLayer on every mobile user bubble!
                        if (!isDesktop) return row;
                        return AnimatedOpacity(
                          opacity: _hovered ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 140),
                          child: row,
                        );
                      }(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UserMessageContent extends StatelessWidget {
  const _UserMessageContent({
    required this.msg,
    required this.revealed,
    required this.onToggleReveal,
  });

  final NormalizedUserMessage msg;
  final bool revealed;
  final VoidCallback onToggleReveal;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final hasAttachments = msg.attachments.isNotEmpty;
    Widget buildTextWidget() {
      if (msg.maskedRanges.isEmpty) {
        return Text(
          msg.text,
          style: TextStyle(fontSize: 14.5, height: 1.55, letterSpacing: -0.1, color: t.text),
        );
      }

      final spans = <InlineSpan>[];
      var cursor = 0;
      for (final range in msg.maskedRanges) {
        final start = range.start.clamp(0, msg.text.length);
        final end = range.end.clamp(start, msg.text.length);
        if (start > cursor) {
          spans.add(TextSpan(text: msg.text.substring(cursor, start)));
        }
        final rawSecret = msg.text.substring(start, end);
        final masked = revealed
            ? rawSecret
            : '${rawSecret.substring(0, range.visiblePrefix.clamp(0, rawSecret.length))}••••••••';
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: GrassBagSpringTap(
              onTap: onToggleReveal,
              pressedScale: 0.94,
              haptic: true,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                decoration: BoxDecoration(
                  color: t.isDark
                      ? Colors.black.withValues(alpha: 0.28)
                      : Colors.white.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: t.primary.withValues(alpha: 0.24),
                    width: 0.6,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        masked,
                        softWrap: true,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: t.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Icon(
                      revealed ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                      size: 13,
                      color: t.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        cursor = end;
      }
      if (cursor < msg.text.length) {
        spans.add(TextSpan(text: msg.text.substring(cursor)));
      }
      return Text.rich(
        TextSpan(
          style: TextStyle(fontSize: 14.5, height: 1.55, letterSpacing: -0.1, color: t.text),
          children: spans,
        ),
      );
    }

    if (!hasAttachments) return buildTextWidget();

    Uint8List? decodeAttBytes(Map<String, dynamic> att) {
      final rawBytes = att['bytes'];
      if (rawBytes is Uint8List && rawBytes.isNotEmpty) return rawBytes;
      final b64 = (att['data'] ?? att['base64'])?.toString().trim() ?? '';
      if (b64.isEmpty) return null;
      final comma = b64.indexOf(',');
      final payload = (b64.startsWith('data:') && comma > 0) ? b64.substring(comma + 1) : b64;
      final cacheKey =
          '${payload.length}:${payload.hashCode}:${payload.substring(0, math.min(24, payload.length))}';
      final cached = _decodedAttachmentBytesCache[cacheKey];
      if (cached != null) return cached;
      try {
        final decoded = base64Decode(payload);
        if (decoded.isEmpty) return null;
        if (_decodedAttachmentBytesCache.length >= 48) {
          _decodedAttachmentBytesCache.remove(_decodedAttachmentBytesCache.keys.first);
        }
        _decodedAttachmentBytesCache[cacheKey] = decoded;
        return decoded;
      } catch (_) {
        return null;
      }
    }

    final thumbCachePx = (76 * MediaQuery.devicePixelRatioOf(context)).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final att in msg.attachments)
              Builder(
                builder: (ctx) {
                  final name = (att['name'] ?? att['filename'] ?? '附件').toString();
                  final isImg = att['mimeType']?.toString().startsWith('image/') == true ||
                      att['type']?.toString() == 'image';
                  final imgBytes = isImg ? decodeAttBytes(att) : null;
                  final imgUrl = isImg
                      ? (att['url'] ?? att['previewUrl'] ?? att['src'])?.toString().trim()
                      : null;
                  if (imgBytes != null ||
                      (imgUrl != null &&
                          (imgUrl.startsWith('http://') || imgUrl.startsWith('https://')))) {
                    return GestureDetector(
                      onTap: () => showImagePreviewDialog(
                        ctx,
                        bytes: imgBytes,
                        url: imgUrl,
                        title: name,
                      ),
                      child: Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: t.sepStrong, width: 0.7),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: imgBytes != null
                            ? Image.memory(
                                imgBytes,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                                cacheWidth: thumbCachePx,
                                errorBuilder: (_, __, ___) => Center(
                                  child: Icon(CupertinoIcons.photo_fill, size: 20, color: t.primary),
                                ),
                              )
                            : Image.network(
                                imgUrl!,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                                cacheWidth: thumbCachePx,
                                errorBuilder: (_, __, ___) => Center(
                                  child: Icon(CupertinoIcons.photo_fill, size: 20, color: t.primary),
                                ),
                              ),
                      ),
                    );
                  }
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: t.isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.white.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: t.sep, width: 0.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isImg ? CupertinoIcons.photo_fill : CupertinoIcons.doc_fill,
                          size: 12,
                          color: t.primary,
                        ),
                        const SizedBox(width: 5),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 160),
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: t.text2),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
        if (msg.text.isNotEmpty) ...[
          const SizedBox(height: 8),
          buildTextWidget(),
        ],
      ],
    );
  }
}

/// Tiny isolated consumer for live phase + rounded t/s so speed ticks NEVER rebuild the entire TurnView!
class _LiveProcessSummaryText extends ConsumerWidget {
  const _LiveProcessSummaryText({
    required this.runningToolName,
    required this.hasAssistantText,
    required this.hasReasoning,
  });

  final String? runningToolName;
  final bool hasAssistantText;
  final bool hasReasoning;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(
      appProvider.select(
        (s) => (
          phase: s.sessionTelemetry.livePhase,
          tpsRounded: s.sessionTelemetry.liveTps != null && s.sessionTelemetry.liveTps! > 1.0
              ? s.sessionTelemetry.liveTps!.round()
              : null,
        ),
      ),
    );
    final t = GrassBagTokens.of(context);
    final p = (live.phase ?? '').toLowerCase();
    final speed = live.tpsRounded != null ? ' · ${live.tpsRounded} t/s' : '';
    final summaryText = runningToolName != null
        ? '正在执行 $runningToolName…$speed'
        : (p.contains('text') || hasAssistantText)
            ? '正在生成回复$speed'
            : (p.contains('reason') || p.contains('think') || hasReasoning)
                ? '正在思考…$speed'
                : '正在思考与执行步骤…$speed';
    return Text(
      summaryText,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: t.text2,
      ),
    );
  }
}

/// Borderless `dsh-Go` TurnProcess summary + `1px` vertical StreamThread rail (`x = 12px`).
class _TurnProcessBlock extends StatelessWidget {
  const _TurnProcessBlock({
    required this.turn,
    required this.tier,
    required this.open,
    required this.canTranslateCot,
    required this.onToggleOpen,
    required this.onToggleStep,
    required this.onToggleTranslate,
    required this.onOpenTerminal,
    required this.onLoadToolDetail,
    required this.onSduiAction,
  });

  final NormalizedTurn turn;
  final GrassBagGlassTier tier;
  final bool open;
  final bool canTranslateCot;
  final VoidCallback onToggleOpen;
  final ValueChanged<String> onToggleStep;
  final void Function(String stepId, String text) onToggleTranslate;
  final VoidCallback onOpenTerminal;
  final Future<Map<String, dynamic>> Function(String callId, {bool forceRefresh}) onLoadToolDetail;
  final FutureOr<String?> Function(String viewId, String actionId, Map<String, dynamic>? payload)
      onSduiAction;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    var toolCount = 0;
    var reasonCount = 0;
    var errTools = 0;
    ToolStep? runningTool;
    for (final s in turn.steps) {
      if (s is ToolStep) {
        toolCount++;
        if (s.status == 'running') runningTool = s;
        if (s.status == 'error') errTools++;
      } else if (s is ReasoningStep) {
        reasonCount++;
      }
    }
    final durSec = turn.usage?.durationMs != null
        ? '${(turn.usage!.durationMs! / 1000).toStringAsFixed(1)}s'
        : null;
    final settledSummaryText = () {
      final bits = <String>[];
      if (durSec != null) {
        bits.add('耗时 $durSec');
      } else if (reasonCount > 0) {
        bits.add('已思考');
      }
      if (toolCount > 0) bits.add('$toolCount 项操作');
      if (errTools > 0) bits.add('$errTools 项异常');
      if (bits.isEmpty) {
        return turn.hasError ? '执行遇到错误' : '执行过程 (${turn.steps.length})';
      }
      return bits.join(' · ');
    }();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagSpringTap(
          onTap: onToggleOpen,
          pressedScale: 0.985,
          haptic: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(
                    child: turn.isStreaming
                        ? _BreathingStatusDot(color: t.primary)
                        : Icon(
                            errTools > 0 || turn.hasError
                                ? CupertinoIcons.exclamationmark_circle_fill
                                : CupertinoIcons.sparkles,
                            size: 15.5,
                            color: errTools > 0 || turn.hasError ? t.err : t.primary,
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: turn.isStreaming
                      ? _LiveProcessSummaryText(
                          runningToolName: runningTool?.name,
                          hasAssistantText: turn.assistantText.isNotEmpty,
                          hasReasoning: reasonCount > 0,
                        )
                      : Text(
                          settledSummaryText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: t.text2,
                          ),
                        ),
                ),
                AnimatedRotation(
                  turns: open ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    CupertinoIcons.chevron_down,
                    size: 13.5,
                    color: t.text3,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Zero layout-lag AnimatedSize while actively streaming (prevents rubber-band twitching
        // as thinking & tool steps grow!), crisp 180ms animation on user tap once settled.
        AnimatedSize(
          duration: turn.isStreaming ? Duration.zero : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          clipBehavior: Clip.hardEdge,
          child: open
              ? CustomPaint(
                  painter: _StreamThreadRailPainter(color: t.sepStrong),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 26, top: 4, bottom: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final step in turn.steps)
                          if (step is ReasoningStep)
                            _ThinkingStepRow(
                              key: ValueKey('reason-${step.id}'),
                              step: step,
                              canTranslate: canTranslateCot && !turn.isStreaming,
                              isStreaming: turn.isStreaming,
                              onToggleExpand: () => onToggleStep(step.id),
                              onToggleTranslate: () => onToggleTranslate(step.id, step.text),
                            )
                          else if (step is ToolStep)
                            _ToolStepRow(
                              key: ValueKey('tool-${step.callId}'),
                              step: step,
                              isStreaming: turn.isStreaming,
                              onToggleExpand: () => onToggleStep(step.callId),
                              onOpenTerminal: onOpenTerminal,
                              onLoadToolDetail: onLoadToolDetail,
                            )
                          else if (step is ActionCardStep)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: SduiNodeRenderer(
                                node: step.sdui,
                                tier: tier,
                                onAction: (actionId, payload) =>
                                    onSduiAction(step.viewId ?? step.id, actionId, payload),
                              ),
                            )
                          else if (step is NoticeStep && step.level != 'error')
                            Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                              decoration: BoxDecoration(
                                color: step.level == 'warn' ? t.warnSoft : t.fill1,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                step.text,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: step.level == 'warn' ? t.warn : t.text2,
                                ),
                              ),
                            ),
                      ],
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Zero-layout, RepaintBoundary-isolated 120Hz breathing dot (NEVER dirties parent TurnView!).
class _BreathingStatusDot extends StatefulWidget {
  const _BreathingStatusDot({required this.color});
  final Color color;

  @override
  State<_BreathingStatusDot> createState() => _BreathingStatusDotState();
}

class _BreathingStatusDotState extends State<_BreathingStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CustomPaint(
          painter: _BreathingDotPainter(animation: _ctrl, color: widget.color),
        ),
      ),
    );
  }
}

class _BreathingDotPainter extends CustomPainter {
  _BreathingDotPainter({required this.animation, required this.color})
      : super(repaint: animation);

  final Animation<double> animation;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final v = Curves.easeInOut.transform(animation.value);
    final center = Offset(size.width * 0.5, size.height * 0.5);
    canvas.drawCircle(
      center,
      5.0 + 4.0 * v,
      Paint()..color = color.withValues(alpha: 0.28 * (1.0 - v) + 0.08),
    );
    canvas.drawCircle(center, 3.75, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _BreathingDotPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.animation != animation;
}

class _StreamThreadRailPainter extends CustomPainter {
  const _StreamThreadRailPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(12, 4), Offset(12, size.height - 4), paint);
  }

  @override
  bool shouldRepaint(covariant _StreamThreadRailPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _ThinkingStepRow extends ConsumerWidget {
  const _ThinkingStepRow({
    super.key,
    required this.step,
    required this.canTranslate,
    required this.isStreaming,
    required this.onToggleExpand,
    required this.onToggleTranslate,
  });

  final ReasoningStep step;
  final bool canTranslate;
  final bool isStreaming;
  final VoidCallback onToggleExpand;
  final VoidCallback onToggleTranslate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stepSlice = ref.watch(
      appProvider.select(
        (s) => (
          expanded: s.expandedStepIds.contains(step.id),
          translated: s.translatedStepIds.contains(step.id),
          translating: s.translatingStepIds.contains(step.id),
          translatedTextOverride: s.stepTranslations[step.id],
        ),
      ),
    );
    final expanded = stepSlice.expanded;
    final translated = stepSlice.translated;
    final translating = stepSlice.translating;
    final translatedTextOverride = stepSlice.translatedTextOverride;
    final t = GrassBagTokens.of(context);
    final effectiveTranslation = (translatedTextOverride?.isNotEmpty == true)
        ? translatedTextOverride
        : step.translatedText;
    final bodyText =
        (translated && effectiveTranslation != null && effectiveTranslation.isNotEmpty)
            ? effectiveTranslation
            : step.text;
    final showTranslateBtn =
        step.text.trim().isNotEmpty && (canTranslate || effectiveTranslation != null);
    final dur = step.durationMs != null
        ? '${(step.durationMs! / 1000).toStringAsFixed(1)}s'
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagSpringTap(
          onTap: onToggleExpand,
          pressedScale: 0.985,
          haptic: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: Icon(CupertinoIcons.lightbulb, size: 14, color: t.text3),
                ),
                const SizedBox(width: 6),
                Text(
                  dur != null ? '思考 $dur' : '思考',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: t.text2,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Container(
                    width: 3,
                    height: 3,
                    decoration: BoxDecoration(color: t.text3, shape: BoxShape.circle),
                  ),
                ),
                Expanded(
                  child: Text(
                    step.collapsedPreview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: t.text3),
                  ),
                ),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    CupertinoIcons.chevron_down,
                    size: 12,
                    color: t.text3,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: isStreaming ? Duration.zero : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded
              ? Container(
                  margin: const EdgeInsets.only(left: 28, top: 2, bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.fill1,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: t.sep, width: 0.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: SelectionArea(
                          key: ValueKey('${step.id}-$translated'),
                          child: Text(
                            bodyText,
                            style: TextStyle(fontSize: 12.5, height: 1.6, color: t.text2),
                          ),
                        ),
                      ),
                      if (showTranslateBtn) ...[
                        const SizedBox(height: 8),
                        GrassBagSpringTap(
                          onTap: translating ? () {} : onToggleTranslate,
                          pressedScale: 0.94,
                          haptic: true,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (translating)
                                CupertinoActivityIndicator(radius: 6, color: t.primary)
                              else
                                Icon(CupertinoIcons.globe, size: 13, color: t.primary),
                              const SizedBox(width: 5),
                              Text(
                                translating
                                    ? '正在翻译…'
                                    : (translated ? '查看原文' : '翻译思考过程'),
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: t.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _ToolStepRow extends ConsumerStatefulWidget {
  const _ToolStepRow({
    super.key,
    required this.step,
    required this.isStreaming,
    required this.onToggleExpand,
    required this.onOpenTerminal,
    required this.onLoadToolDetail,
  });

  final ToolStep step;
  final bool isStreaming;
  final VoidCallback onToggleExpand;
  final VoidCallback onOpenTerminal;
  final Future<Map<String, dynamic>> Function(String callId, {bool forceRefresh}) onLoadToolDetail;

  @override
  ConsumerState<_ToolStepRow> createState() => _ToolStepRowState();
}

class _ToolStepRowState extends ConsumerState<_ToolStepRow> {
  Map<String, dynamic>? _detail;
  bool _loading = false;
  bool _loadedOnce = false;
  bool _pendingForceReload = false;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    if (ref.read(appProvider).expandedStepIds.contains(widget.step.callId)) {
      _ensureLoaded();
    }
  }

  @override
  void didUpdateWidget(covariant _ToolStepRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final expanded = ref.read(appProvider).expandedStepIds.contains(widget.step.callId);
    if (oldWidget.step.callId != widget.step.callId) {
      _detail = null;
      _loading = false;
      _loadedOnce = false;
      _pendingForceReload = false;
      _copied = false;
      if (expanded) {
        _ensureLoaded();
      }
      return;
    }
    final statusChanged = oldWidget.step.status != widget.step.status;
    final settledFromStream = oldWidget.isStreaming && !widget.isStreaming;
    if (expanded && (!_loadedOnce || statusChanged || settledFromStream)) {
      _ensureLoaded(forceRefresh: statusChanged || settledFromStream);
    }
  }

  Future<void> _ensureLoaded({bool forceRefresh = false}) async {
    if (_loading) {
      if (forceRefresh) _pendingForceReload = true;
      return;
    }
    setState(() => _loading = true);
    final callId = widget.step.callId;
    final res = await widget.onLoadToolDetail(callId, forceRefresh: forceRefresh);
    if (!mounted || widget.step.callId != callId) return;
    final shouldReload = _pendingForceReload;
    _pendingForceReload = false;
    setState(() {
      _detail = res;
      _loading = false;
      _loadedOnce = true;
    });
    if (shouldReload) {
      _ensureLoaded(forceRefresh: true);
    }
  }

  void _openFullOutputSheet(
    BuildContext context, {
    required bool isCmd,
    required bool isErr,
    required String commandOrTitle,
    required String fullOut,
  }) {
    if (isCmd) {
      showCommandOutputSheet(
        context,
        command: commandOrTitle,
        failed: isErr,
        outputText: fullOut,
        onOpenTerminal: widget.onOpenTerminal,
      );
      return;
    }
    showGrassBagSheet<void>(
      context,
      title: widget.step.title,
      subtitle: isErr ? '执行失败 · 完整输出' : '执行完成 · 完整输出',
      bodyBuilder: (ctx) {
        final st = GrassBagTokens.of(ctx);
        final tier = ProviderScope.containerOf(ctx, listen: false).read(appProvider).glassTier;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              constraints: const BoxConstraints(maxHeight: 400),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: st.codeBg,
                borderRadius: BorderRadius.circular(14),
                border: isErr
                    ? Border.all(color: st.err.withValues(alpha: 0.45), width: 0.8)
                    : Border.all(color: Colors.white.withValues(alpha: 0.08), width: 0.6),
              ),
              child: SingleChildScrollView(
                child: SelectionArea(
                  child: Text(
                    fullOut,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      height: 1.5,
                      color: isErr ? const Color(0xFFFCA5A5) : st.codeFg,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            GrassBagSecondaryGlassButton(
              label: '复制完整输出',
              icon: CupertinoIcons.doc_on_doc,
              height: 38,
              tier: tier,
              insideGlass: true,
              onTap: () {
                Clipboard.setData(ClipboardData(text: fullOut));
                Navigator.of(ctx).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final expanded = ref.watch(
      appProvider.select((s) => s.expandedStepIds.contains(widget.step.callId)),
    );
    if (expanded && !_loadedOnce && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_loadedOnce && !_loading) {
          _ensureLoaded();
        }
      });
    }
    final t = GrassBagTokens.of(context);
    final step = widget.step;
    final n = step.name.toLowerCase();
    final isWrite = n == 'write' || n == 'write_file' || n == 'create_file' || n == 'create';
    final isEdit = isWrite ||
        n == 'edit' ||
        n == 'edit_file' ||
        n == 'patch' ||
        n == 'apply_patch' ||
        n == 'replace' ||
        n.contains('edit') ||
        n.contains('write');
    final isCmd = n == 'cmd' ||
        n == 'bash' ||
        n == 'shell' ||
        n == 'exec' ||
        n == 'run' ||
        n == 'terminal' ||
        n == 'command' ||
        n.contains('bash') ||
        n.contains('shell') ||
        n.contains('exec');
    final isWeb = n.contains('web') || n.contains('fetch') || n.contains('http');
    final isSubagent = n.contains('subagent') || n.contains('agent') || n.contains('delegate');
    final isErr = step.status == 'error';
    final isRunning = widget.isStreaming && step.status == 'running';

    final icon = isEdit
        ? CupertinoIcons.pencil
        : isCmd
            ? CupertinoIcons.chevron_left_slash_chevron_right
            : isWeb
                ? CupertinoIcons.globe
                : isSubagent
                    ? CupertinoIcons.arrow_branch
                    : CupertinoIcons.search;
    final verb = isWrite
        ? '写入'
        : (isEdit
            ? '编辑'
            : (isCmd
                ? '执行'
                : (isWeb ? '联网' : (isSubagent ? '委派' : '查阅'))));
    final prefix = '${step.name} · ';
    final displayTitle = step.title.startsWith(prefix) && step.title.length > prefix.length
        ? step.title.substring(prefix.length)
        : step.title;

    final argsMap = _detail?['args'] is Map ? _detail!['args'] as Map : const {};
    final argsText = (_detail?['argsText']?.toString() ?? '').trim();
    final outputText = (_detail?['outputText']?.toString() ?? '').trim();
    final effectiveOutput = outputText.isNotEmpty
        ? outputText
        : (step.summary.isNotEmpty
            ? step.summary
            : (isRunning ? '正在执行中…' : '（该操作无额外输出）'));
    final cmdText = (argsMap['command'] ?? argsMap['cmd'])?.toString().trim() ?? '';
    final filePath = (argsMap['file_path'] ?? argsMap['path'])?.toString().trim() ?? '';
    final durLabel = step.durationMs != null
        ? (step.durationMs! < 1000
            ? '${step.durationMs}ms'
            : '${(step.durationMs! / 1000).toStringAsFixed(1)}s')
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagSpringTap(
          pressedScale: 0.985,
          haptic: true,
          onTap: () {
            widget.onToggleExpand();
            if (!expanded) {
              _ensureLoaded();
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: Center(
                        child: isRunning
                            ? _BreathingStatusDot(color: t.primary)
                            : Icon(
                                icon,
                                size: 14,
                                color: isErr ? t.err : (isEdit ? t.primary : t.text3),
                              ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      verb,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: isErr ? t.err : t.text2,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Container(
                        width: 3,
                        height: 3,
                        decoration: BoxDecoration(color: t.text3, shape: BoxShape.circle),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: (isEdit || isCmd) ? 'monospace' : null,
                          fontSize: 12.5,
                          color: isErr ? t.err : t.text,
                        ),
                      ),
                    ),
                    if (durLabel != null && !isErr) ...[
                      const SizedBox(width: 6),
                      Text(
                        durLabel,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: t.text3,
                        ),
                      ),
                    ] else if (step.summary.isNotEmpty && !isErr && !expanded) ...[
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 100),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: isCmd ? t.okSoft : t.fill1,
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            step.summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: isEdit ? 'monospace' : null,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              fontFeatures: const [FontFeature.tabularFigures()],
                              color: isCmd ? t.ok : t.text2,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (isErr) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: t.errSoft,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          '失败',
                          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: t.err),
                        ),
                      ),
                    ],
                    const SizedBox(width: 5),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        CupertinoIcons.chevron_down,
                        size: 12,
                        color: t.text3,
                      ),
                    ),
                  ],
                ),
                if (isErr && !expanded && step.summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 28, top: 4),
                    child: Text(
                      step.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.38, color: t.err),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Inline expandable tool parameters + real execution output panel
        AnimatedSize(
          duration: widget.isStreaming ? Duration.zero : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded
              ? Container(
                  margin: const EdgeInsets.only(left: 28, top: 2, bottom: 8),
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: t.codeBg,
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(
                      color: isErr
                          ? t.err.withValues(alpha: 0.45)
                          : Colors.white.withValues(alpha: 0.09),
                      width: 0.65,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_loading && _detail == null)
                        Row(
                          children: [
                            CupertinoActivityIndicator(radius: 7, color: t.primaryHi),
                            const SizedBox(width: 7),
                            const Text(
                              '正在加载操作参数与输出…',
                              style: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8)),
                            ),
                          ],
                        )
                      else ...[
                        if (cmdText.isNotEmpty) ...[
                          SelectionArea(
                            child: Text(
                              '\$ $cmdText',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.8,
                                fontWeight: FontWeight.w600,
                                height: 1.45,
                                color: Color(0xFF7DD3FC),
                              ),
                            ),
                          ),
                          const SizedBox(height: 7),
                        ] else if (argsText.isNotEmpty) ...[
                          Text(
                            '调用参数 (${step.name})',
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                          const SizedBox(height: 4),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 110),
                            child: SingleChildScrollView(
                              child: SelectionArea(
                                child: Text(
                                  argsText,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    height: 1.42,
                                    color: Color(0xFF93C5FD),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        Text(
                          isErr ? '错误输出' : '执行结果',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: isErr ? const Color(0xFFFCA5A5) : const Color(0xFF94A3B8),
                          ),
                        ),
                        const SizedBox(height: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 220),
                          child: SingleChildScrollView(
                            child: SelectionArea(
                              child: Text(
                                effectiveOutput,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11.5,
                                  height: 1.48,
                                  color: isErr ? const Color(0xFFFCA5A5) : const Color(0xFFD5DCE4),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          runSpacing: 6,
                          children: [
                            GrassBagSpringTap(
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: effectiveOutput));
                                setState(() => _copied = true);
                                Future<void>.delayed(const Duration(milliseconds: 1400), () {
                                  if (mounted) setState(() => _copied = false);
                                });
                              },
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _copied ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
                                    size: 12,
                                    color: _copied ? const Color(0xFF34D399) : const Color(0xFF94A3B8),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _copied ? '已复制' : '复制输出',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: _copied
                                          ? const Color(0xFF34D399)
                                          : const Color(0xFFCBD5E1),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (effectiveOutput.length > 260)
                              GrassBagSpringTap(
                                onTap: () => _openFullOutputSheet(
                                  context,
                                  isCmd: isCmd,
                                  isErr: isErr,
                                  commandOrTitle: cmdText.isNotEmpty ? cmdText : displayTitle,
                                  fullOut: effectiveOutput,
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(CupertinoIcons.arrow_up_left_arrow_down_right,
                                        size: 11.5, color: Color(0xFF60A5FA)),
                                    SizedBox(width: 4),
                                    Text(
                                      '全屏查看',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF60A5FA),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (isEdit && !isErr)
                              GrassBagSpringTap(
                                onTap: () => showDiffSheet(
                                  context,
                                  filePath.isNotEmpty ? filePath : displayTitle,
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(CupertinoIcons.doc_text_search,
                                        size: 12, color: Color(0xFF60A5FA)),
                                    SizedBox(width: 4),
                                    Text(
                                      '查看 Diff',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF60A5FA),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (isCmd)
                              GrassBagSpringTap(
                                onTap: widget.onOpenTerminal,
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(CupertinoIcons.chevron_left_slash_chevron_right,
                                        size: 11.5, color: Color(0xFF94A3B8)),
                                    SizedBox(width: 4),
                                    Text(
                                      '打开终端',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: Color(0xFFCBD5E1),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Unmistakable, always-visible Turn Error Banner Card matching `@deepseek-ai/dsh-client-ui-chat`'s
/// `turn-error` display — never hidden inside collapsed steps, always selectable & copyable!
class _TurnErrorCard extends StatelessWidget {
  const _TurnErrorCard({
    required this.turn,
    required this.tier,
    required this.onCopy,
    this.onRetry,
  });

  final NormalizedTurn turn;
  final GrassBagGlassTier tier;
  final ValueChanged<String> onCopy;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final noticeErrors = turn.steps
        .whereType<NoticeStep>()
        .where((s) => s.level == 'error' && s.text.trim().isNotEmpty)
        .map((s) => s.text.trim())
        .toList(growable: false);
    final rawDetail = (turn.errorMessage != null && turn.errorMessage!.trim().isNotEmpty)
        ? turn.errorMessage!.trim()
        : (noticeErrors.isNotEmpty ? noticeErrors.join('\n') : '本轮请求未能完成，请查看报错日志或重试。');
    final code = turn.errorCode?.trim();
    final copyPayload = (code != null && code.isNotEmpty && !rawDetail.contains(code))
        ? '[$code] $rawDetail'
        : rawDetail;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: t.errSoft,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: t.err.withValues(alpha: t.isDark ? 0.38 : 0.25),
            width: 0.8,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 16, color: t.err),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  code != null && code.isNotEmpty ? '执行失败 · $code' : '执行失败',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: t.err,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectionArea(
            child: Text(
              rawDetail,
              style: TextStyle(
                fontFamily: rawDetail.contains('Error') || rawDetail.contains('HTTP')
                    ? 'monospace'
                    : null,
                fontSize: 12.5,
                height: 1.48,
                color: t.isDark ? t.text : Color.lerp(t.err, t.text, 0.35)!,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              GrassBagSecondaryGlassButton(
                label: '复制报错',
                icon: CupertinoIcons.doc_on_doc,
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                tier: tier,
                insideGlass: true,
                destructive: true,
                onTap: () => onCopy(copyPayload),
              ),
              if (onRetry != null)
                GrassBagPrimaryGlassButton(
                  label: '重新发送',
                  icon: CupertinoIcons.arrow_clockwise,
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 13),
                  tier: tier,
                  insideGlass: true,
                  color: t.err,
                  foregroundColor: t.err.computeLuminance() > 0.48
                      ? const Color(0xFF1A0A0A)
                      : Colors.white,
                  onTap: onRetry!,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AssistantBody extends StatefulWidget {
  const _AssistantBody({
    required this.turnId,
    required this.text,
    required this.isStreaming,
    required this.deliverables,
    this.usage,
    this.feedback,
    required this.onCopy,
    required this.onFork,
    required this.onFeedback,
    this.onRegenerate,
    required this.onDeliverableTap,
  });

  final String turnId;
  final String text;
  final bool isStreaming;
  final List<Map<String, dynamic>> deliverables;
  final TurnUsage? usage;
  final String? feedback;
  final VoidCallback onCopy;
  final VoidCallback onFork;
  final ValueChanged<String> onFeedback;
  final VoidCallback? onRegenerate;
  final ValueChanged<String> onDeliverableTap;

  @override
  State<_AssistantBody> createState() => _AssistantBodyState();
}

enum _MdBlockKind { code, math, heading, hr, table, quote, bullet, image, paragraph }

class _RawMdBlock {
  const _RawMdBlock({
    required this.kind,
    required this.raw,
    this.lang = '',
    this.level = 0,
    this.marker = '',
    this.indent = 0.0,
    this.body = '',
    this.imageUrl = '',
    this.taskChecked,
    this.tableLines = const [],
  });

  final _MdBlockKind kind;
  final String raw;
  final String lang;
  final int level;
  final String marker;
  final double indent;
  final String body;
  final String imageUrl;
  final bool? taskChecked;
  final List<String> tableLines;
}

class _CachedMdBlock {
  const _CachedMdBlock({
    required this.kind,
    required this.raw,
    required this.hasCursor,
    required this.widget,
    required this.recognizers,
  });

  final _MdBlockKind kind;
  final String raw;
  final bool hasCursor;
  final Widget widget;
  final List<TapGestureRecognizer> recognizers;

  void dispose() {
    for (final r in recognizers) {
      r.dispose();
    }
  }
}

class _AssistantBodyState extends State<_AssistantBody>
    with SingleTickerProviderStateMixin {
  static final RegExp _openFenceRe = RegExp(r'^(`{3,}|~{3,})(.*)$');
  static final RegExp _headingPattern = RegExp(r'^(#{1,6})\s+(.+)$');
  static final RegExp _hrPattern = RegExp(r'^([-*_])(?:\s*\1){2,}$');
  static final RegExp _tableSepPattern = RegExp(r'^\|?[\s:]*-+[\s:]*(?:\|[\s:]*-+[\s:]*)*\|?$');
  static final RegExp _bulletPattern = RegExp(r'^([-*+•]|\d+\.)\s+(.+)$');
  static final RegExp _taskPrefixPattern = RegExp(r'^\[([ xX])\]\s+(.*)$');
  static final RegExp _standaloneImageRe = RegExp(r'^!\[([^\]]*)\]\((https?://[^\s)]+)\)$');
  static final Map<String, int> _revealedProgressByTurn = <String, int>{};

  bool _copied = false;
  Widget? _cachedRichBody;
  bool? _cachedStreaming;
  bool? _cachedDark;
  GrassBagAccent? _cachedAccent;
  Color? _cachedTextColor;
  Color? _cachedPrimaryColor;
  Color? _cachedCardSolidColor;
  Color? _cachedCodeBgColor;
  Color? _cachedSepColor;
  final List<_CachedMdBlock> _settledCachedBlocks = [];
  final List<_CachedMdBlock> _tailCachedBlocks = [];
  final Set<int> _streamedBlockIndices = <int>{};
  Widget? _settledColumnCache;
  final List<TapGestureRecognizer> _fallbackRecognizers = [];
  final List<TapGestureRecognizer> _pendingDisposeRecognizers = [];
  bool _pendingDisposeScheduled = false;
  int _settledLen = 0;
  String _settledHeadAnchor = '';
  String _settledTailAnchor = '';
  int _cachedSettledLen = -1;
  String? _cachedTailText;
  int _lastPrefixScanLen = 0;

  static const int _anchorSampleLen = 24;

  bool _matchesSettledAnchor(String source) {
    if (_settledLen == 0) return true;
    if (source.length < _settledLen) return false;
    if (_settledHeadAnchor.isNotEmpty && !source.startsWith(_settledHeadAnchor)) {
      return false;
    }
    if (_settledTailAnchor.isNotEmpty) {
      final tailStart = _settledLen - _settledTailAnchor.length;
      if (tailStart < 0 || !source.startsWith(_settledTailAnchor, tailStart)) {
        return false;
      }
    }
    return true;
  }

  static bool _fastStartsWithPrev(String next, String prev) {
    if (prev.isEmpty) return true;
    final pLen = prev.length;
    if (next.length < pLen) return false;
    if (pLen <= 64) return next.startsWith(prev);
    // O(1) prefix/mid/tail check avoids O(N) string scan on every streaming chunk!
    final sample = 24;
    if (!next.startsWith(prev.substring(0, sample))) return false;
    final mid = pLen >> 1;
    if (!next.startsWith(prev.substring(mid, mid + sample), mid)) return false;
    final tailStart = pLen - sample;
    return next.startsWith(prev.substring(tailStart), tailStart);
  }

  static void _rememberRevealed(String turnId, int len) {
    if (_revealedProgressByTurn.length > 64 && !_revealedProgressByTurn.containsKey(turnId)) {
      _revealedProgressByTurn.remove(_revealedProgressByTurn.keys.first);
    }
    _revealedProgressByTurn[turnId] = len;
  }

  void _deferDisposeRecognizers(Iterable<TapGestureRecognizer> list) {
    _pendingDisposeRecognizers.addAll(list);
    if (_pendingDisposeScheduled || _pendingDisposeRecognizers.isEmpty) return;
    _pendingDisposeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingDisposeScheduled = false;
      for (final r in _pendingDisposeRecognizers) {
        r.dispose();
      }
      _pendingDisposeRecognizers.clear();
    });
  }

  void _disposeAllCachedBlocks({bool immediate = false}) {
    for (final b in _settledCachedBlocks) {
      if (immediate) {
        b.dispose();
      } else {
        _deferDisposeRecognizers(b.recognizers);
      }
    }
    _settledCachedBlocks.clear();
    for (final b in _tailCachedBlocks) {
      if (immediate) {
        b.dispose();
      } else {
        _deferDisposeRecognizers(b.recognizers);
      }
    }
    _tailCachedBlocks.clear();
    _settledColumnCache = null;
    if (immediate) {
      for (final r in _fallbackRecognizers) {
        r.dispose();
      }
      for (final r in _pendingDisposeRecognizers) {
        r.dispose();
      }
      _pendingDisposeRecognizers.clear();
    } else {
      _deferDisposeRecognizers(_fallbackRecognizers);
    }
    _fallbackRecognizers.clear();
    _settledLen = 0;
    _settledHeadAnchor = '';
    _settledTailAnchor = '';
    _cachedSettledLen = -1;
    _cachedTailText = null;
    _lastPrefixScanLen = 0;
  }

  static int _safeInitialReveal(String text) {
    if (text.isEmpty) return 0;
    if (text.length >= 2) {
      final cu = text.codeUnitAt(0);
      if (cu >= 0xD800 && cu <= 0xDBFF) return 2;
    }
    return 1;
  }

  // Smooth 60/120Hz adaptive typewriter engine (eliminates lumpy chunk pops & vertical jitter)
  late int _revealedLen;
  double _charBudget = 0.0;
  Ticker? _typeTicker;
  Duration? _lastTickElapsed;

  @override
  void initState() {
    super.initState();
    // Completed historical turns mount at 100% immediately (zero replay!).
    // Streaming turns restore prior progress if remounted after scrolling out & back,
    // and reveal at least 1 character on Frame 0 so the assistant block never collapses to 0px -> 50px.
    if (widget.isStreaming) {
      final prev = _revealedProgressByTurn[widget.turnId] ?? 0;
      _revealedLen = prev > 0
          ? prev.clamp(0, widget.text.length)
          : _safeInitialReveal(widget.text);
    } else {
      _revealedLen = widget.text.length;
    }
    if (widget.isStreaming && _revealedLen < widget.text.length) {
      _startTypeTicker();
    }
  }

  @override
  void didUpdateWidget(covariant _AssistantBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final targetLen = widget.text.length;
    if (oldWidget.turnId != widget.turnId) {
      _disposeAllCachedBlocks();
      _streamedBlockIndices.clear();
      if (widget.isStreaming) {
        final prev = _revealedProgressByTurn[widget.turnId] ?? 0;
        _revealedLen = prev > 0
            ? prev.clamp(0, targetLen)
            : _safeInitialReveal(widget.text);
      } else {
        _revealedLen = targetLen;
      }
      _charBudget = 0.0;
    } else if (targetLen == 0) {
      // Narration promoted to step / cleared -> purge stale progress so the final reply types cleanly!
      _disposeAllCachedBlocks();
      _streamedBlockIndices.clear();
      _revealedLen = 0;
      _charBudget = 0.0;
      _revealedProgressByTurn.remove(widget.turnId);
    } else if (oldWidget.text != widget.text) {
      final isPureAppend = oldWidget.text.isNotEmpty &&
          targetLen >= oldWidget.text.length &&
          _fastStartsWithPrev(widget.text, oldWidget.text);
      if (!isPureAppend &&
          (targetLen < _revealedLen ||
              (oldWidget.text.isNotEmpty &&
                  _revealedLen > 0 &&
                  !_fastStartsWithPrev(
                    widget.text,
                    oldWidget.text.substring(0, _revealedLen.clamp(0, oldWidget.text.length)),
                  )))) {
        // If text shrank or replaced completely (e.g. narration promoted to step), snap cleanly.
        _disposeAllCachedBlocks();
        _revealedLen = targetLen;
        _charBudget = 0.0;
        _rememberRevealed(widget.turnId, _revealedLen);
      } else if (widget.isStreaming && _revealedLen == 0 && targetLen > 0) {
        // First token arrived while streaming -> reveal 1 char immediately so Frame 0 never collapses!
        _revealedLen = _safeInitialReveal(widget.text);
      }
    } else if (widget.isStreaming && _revealedLen == 0 && targetLen > 0) {
      _revealedLen = _safeInitialReveal(widget.text);
    }
    if (!widget.isStreaming && !oldWidget.isStreaming) {
      // Static completed turn update -> show immediately.
      _revealedLen = targetLen;
      _revealedProgressByTurn.remove(widget.turnId);
      _stopTypeTicker();
    } else if (_revealedLen < targetLen) {
      _startTypeTicker();
    } else if (!widget.isStreaming && _revealedLen >= targetLen) {
      _revealedProgressByTurn.remove(widget.turnId);
      _stopTypeTicker();
    }
  }

  @override
  void dispose() {
    if (widget.isStreaming && _revealedLen > 0 && widget.text.isNotEmpty) {
      _rememberRevealed(widget.turnId, _revealedLen);
    } else if (widget.text.isEmpty) {
      _revealedProgressByTurn.remove(widget.turnId);
    }
    _typeTicker?.dispose();
    _disposeAllCachedBlocks(immediate: true);
    super.dispose();
  }

  void _startTypeTicker() {
    _typeTicker ??= createTicker(_onTypeTick);
    if (!_typeTicker!.isActive) {
      _lastTickElapsed = null;
      _typeTicker!.start();
    }
  }

  void _stopTypeTicker() {
    if (_typeTicker != null && _typeTicker!.isActive) {
      _typeTicker!.stop();
    }
    _lastTickElapsed = null;
    _charBudget = 0.0;
  }

  void _onTypeTick(Duration elapsed) {
    if (!mounted) {
      _stopTypeTicker();
      return;
    }
    final prev = _lastTickElapsed;
    _lastTickElapsed = elapsed;
    final dtSec = prev == null
        ? 0.016
        : ((elapsed - prev).inMicroseconds / 1000000.0).clamp(0.004, 0.05);

    final targetLen = widget.text.length;
    final lag = targetLen - _revealedLen;
    if (lag <= 0) {
      _stopTypeTicker();
      return;
    }

    // Smooth adaptive catch-up: crisp readable cadence at low lag, effortless acceleration
    // for 300+ tok/s models, and rapid <120ms finish when streaming ends.
    final charsPerSec = widget.isStreaming
        ? (48.0 + lag * 6.5).clamp(48.0, 1200.0)
        : (240.0 + lag * 16.0).clamp(240.0, 3200.0);
    _charBudget += charsPerSec * dtSec;
    final step = _charBudget.floor();
    if (step <= 0) return;
    _charBudget -= step;

    var nextLen = (_revealedLen + step).clamp(0, targetLen);
    // Never split a UTF-16 surrogate pair (emoji / rare CJK) mid-character!
    if (nextLen > 0 && nextLen < targetLen) {
      final cu = widget.text.codeUnitAt(nextLen - 1);
      if (cu >= 0xD800 && cu <= 0xDBFF) {
        nextLen++;
      }
    }
    if (nextLen != _revealedLen) {
      _rememberRevealed(widget.turnId, nextLen);
      setState(() {
        _revealedLen = nextLen;
      });
    }
    if (_revealedLen >= targetLen && !widget.isStreaming) {
      _revealedProgressByTurn.remove(widget.turnId);
      _stopTypeTicker();
    }
  }

  static bool _isClosingFence(String trimmedLine, String fenceChar, int fenceLen) {
    if (trimmedLine.length < fenceLen) return false;
    var count = 0;
    while (count < trimmedLine.length && trimmedLine[count] == fenceChar) {
      count++;
    }
    if (count < fenceLen) return false;
    return trimmedLine.substring(count).trim().isEmpty;
  }

  /// Stabilize dangling unclosed inline syntax at the streaming tail (`**`, `` ` ``)
  /// so half-typed tokens never flicker raw syntax markers back and forth.
  /// Starts scanning from [settledOffset] (guaranteed outside open fences) using indexOf
  /// so 60/120Hz typewriter frames are O(tail) with ZERO full-message `split('\n')` allocations!
  static String _stabilizeStreamingText(String raw, [int settledOffset = 0]) {
    if (raw.isEmpty) return raw;
    String? openChar;
    var openLen = 0;
    var pos = settledOffset.clamp(0, raw.length);
    final rawLen = raw.length;
    while (pos < rawLen) {
      final nl = raw.indexOf('\n', pos);
      final end = nl < 0 ? rawLen : nl;
      final t = raw.substring(pos, end).trimLeft();
      if (openChar == null) {
        final m = _openFenceRe.firstMatch(t);
        if (m != null) {
          final f = m.group(1)!;
          final info = m.group(2) ?? '';
          if (!(f[0] == '`' && info.contains('`'))) {
            openChar = f[0];
            openLen = f.length;
          }
        }
      } else if (_isClosingFence(t, openChar, openLen)) {
        openChar = null;
        openLen = 0;
      }
      if (nl < 0) break;
      pos = nl + 1;
    }
    if (openChar != null) return raw;
    // Stabilize trailing unclosed delimiters (`***`, `**`, `~~`, `` `` ``, `` ` ``, half-closed `**word*`) on the last line
    final lastNl = raw.lastIndexOf('\n');
    final tail = lastNl >= 0 ? raw.substring(lastNl + 1) : raw;
    if (tail.endsWith('``') && !tail.endsWith('```')) {
      return raw.substring(0, raw.length - 2);
    }
    final backticks = '`'.allMatches(tail).length;
    if (backticks.isOdd && tail.endsWith('`')) {
      return raw.substring(0, raw.length - 1);
    }
    if (tail.endsWith('***')) {
      return raw.substring(0, raw.length - 3);
    }
    if (tail.endsWith('**')) {
      final boldCount = '**'.allMatches(tail).length;
      if (boldCount.isOdd) return raw.substring(0, raw.length - 2);
    } else if (tail.endsWith('*') && tail.length >= 2 && tail[tail.length - 2] != ' ') {
      // Prevent `**bold*` (first char of closing `**`) from flashing italic before the second `*` arrives.
      final withoutLast = tail.substring(0, tail.length - 1);
      final boldCount = '**'.allMatches(withoutLast).length;
      if (boldCount.isOdd) return raw.substring(0, raw.length - 1);
    }
    if (tail.endsWith('~~')) {
      final strikeCount = '~~'.allMatches(tail).length;
      if (strikeCount.isOdd) return raw.substring(0, raw.length - 2);
    }
    return raw;
  }

  void _handleCopy() {
    widget.onCopy();
    if (!_copied) {
      setState(() => _copied = true);
      Future<void>.delayed(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _copied = false);
      });
    }
  }

  static bool _isWordChar(int cu) =>
      (cu >= 0x30 && cu <= 0x39) ||
      (cu >= 0x41 && cu <= 0x5A) ||
      (cu >= 0x61 && cu <= 0x7A) ||
      cu == 0x5F;

  static bool _isAsciiDigit(int cu) => cu >= 0x30 && cu <= 0x39;

  static final RegExp _currencyProseRe = RegExp(r'^\d[\d,.]*(?:\s+[a-zA-Z\u4e00-\u9fff])');
  static final RegExp _mathOperatorRe = RegExp(r'[\\^_=+*/<>\{\}\[\]\(\)]');

  static bool _looksLikeCurrencyNotMath(String body, bool afterIsDigitOrWord) {
    if (afterIsDigitOrWord) return true;
    // Reject obvious monetary prose like `$5 to $10` or `$19.99 per month` when no LaTeX/math ops exist.
    if (_currencyProseRe.hasMatch(body) && !_mathOperatorRe.hasMatch(body)) {
      return true;
    }
    return false;
  }

  static TapGestureRecognizer _makeUrlRecognizer(
    String url,
    BuildContext? previewContext,
  ) {
    return TapGestureRecognizer()
      ..onTap = () {
        if (!openUrlInNewTab(url)) {
          if (GrassBagNativeBridge.instance.isAndroidNative) {
            GrassBagNativeBridge.instance.openExternalUrl(url);
          } else {
            Clipboard.setData(ClipboardData(text: url));
            if (previewContext != null && previewContext.mounted) {
              ProviderScope.containerOf(previewContext, listen: false)
                  .read(appProvider.notifier)
                  .showToast('已复制链接');
            }
          }
        }
      };
  }

  /// Parses inline `**bold**` / `__bold__`, `***bold italic***`, `*italic*` / `_italic_` (with flanking rules),
  /// `~~strike~~`, `$math$` / `$$math$$` (currency-safe & protected from `_` italic mangling!),
  /// `![alt](url)`, `[**rich** label](url)` (balanced parens + recursive inline formatting!),
  /// bare `https://...` autolinks, selection-friendly `` `code` `` & zero-jitter cursor.
  /// Find closing delimiter [delim] starting at [start], skipping backslash escapes and
  /// inline code spans (`` `...` ``) so `**use `a**b` here**` and `$\$5 + x$` parse cleanly!
  static int _findClosingDelim(
    String input,
    int start,
    String delim, {
    bool allowNewline = true,
  }) {
    final len = input.length;
    final dLen = delim.length;
    if (start > len - dLen) return -1;
    // O(1) native indexOf pre-check: immediately bail when streaming partial `*`/`**`/`$` has no closer!
    final firstHit = input.indexOf(delim, start);
    if (firstHit < 0) return -1;
    final delimFirstCu = delim.codeUnitAt(0);
    var scan = start;
    while (scan <= len - dLen) {
      final cu = input.codeUnitAt(scan);
      if (!allowNewline && cu == 0x0A /* '\n' */) return -1;
      if (cu == 0x5C /* '\\' */ && scan + 1 < len) {
        scan += 2;
        continue;
      }
      if (cu == 0x60 /* '`' */) {
        var tickEnd = scan;
        while (tickEnd < len && input.codeUnitAt(tickEnd) == 0x60) {
          tickEnd++;
        }
        final tickLen = tickEnd - scan;
        final closeCode = _findExactBacktickClose(input, tickEnd, tickLen);
        if (closeCode >= 0) {
          scan = closeCode + tickLen;
          continue;
        }
        scan = tickEnd;
        continue;
      }
      if (cu == delimFirstCu && (dLen == 1 || input.startsWith(delim, scan))) {
        return scan;
      }
      scan++;
    }
    return -1;
  }

  /// Find an exact run of [tickLen] backticks (not preceded or followed by another backtick).
  static int _findExactBacktickClose(String input, int start, int tickLen) {
    final len = input.length;
    var scan = start;
    while (scan < len) {
      final hit = input.indexOf('`', scan);
      if (hit < 0) return -1;
      var end = hit + 1;
      while (end < len && input.codeUnitAt(end) == 0x60) {
        end++;
      }
      if (end - hit == tickLen) return hit;
      scan = end;
    }
    return -1;
  }

  static List<InlineSpan> _buildMarkdownSpans(
    String input,
    GrassBagTokens t,
    List<TapGestureRecognizer> outRecognizers, {
    bool showCursor = false,
    int depth = 0,
    BuildContext? previewContext,
    TapGestureRecognizer? linkRecognizer,
  }) {
    final spans = <InlineSpan>[];
    final buf = StringBuffer();
    final len = input.length;

    void flushBuf() {
      if (buf.isNotEmpty) {
        spans.add(TextSpan(text: buf.toString(), recognizer: linkRecognizer));
        buf.clear();
      }
    }

    var i = 0;
    while (i < len) {
      final ch = input[i];

      // Escaped markdown punctuation
      if (ch == r'\' && i + 1 < len && r'\`*_{}[]()#+-.!~|$'.contains(input[i + 1])) {
        buf.write(input[i + 1]);
        i += 2;
        continue;
      }

      // Inline/display LaTeX math `$...$` or `$$...$$` — currency-safe & escape/backtick-aware!
      if (ch == r'$') {
        final isDouble = i + 1 < len && input[i + 1] == r'$';
        final prevBlocked = !isDouble && i > 0 && _isWordChar(input.codeUnitAt(i - 1));
        final delim = isDouble ? r'$$' : r'$';
        final start = i + delim.length;
        if (!prevBlocked &&
            start < len &&
            (isDouble || (input[start] != ' ' && input[start] != '\t' && input[start] != r'$'))) {
          final closeIdx = _findClosingDelim(input, start, delim, allowNewline: false);
          if (closeIdx > start && (isDouble || (input[closeIdx - 1] != ' ' && input[closeIdx - 1] != '\t'))) {
            final afterIdx = closeIdx + delim.length;
            final afterIsDigitOrWord = !isDouble &&
                afterIdx < len &&
                (_isAsciiDigit(input.codeUnitAt(afterIdx)) || _isWordChar(input.codeUnitAt(afterIdx)));
            final mathBody = input.substring(start, closeIdx).trim();
            if (mathBody.isNotEmpty &&
                !mathBody.contains('\n') &&
                !mathBody.contains('`') &&
                (isDouble || !_looksLikeCurrencyNotMath(mathBody, afterIsDigitOrWord))) {
              flushBuf();
              spans.add(
                TextSpan(
                  text: ' $mathBody ',
                  recognizer: linkRecognizer,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13.2,
                    fontStyle: FontStyle.italic,
                    color: t.isDark ? t.primaryHi : t.primary,
                    backgroundColor: t.fill1,
                  ),
                ),
              );
              i = closeIdx + delim.length;
              continue;
            }
          }
        }
      }

      // Inline code span `` `code` `` rendered as pure TextSpan (exact backtick-run matching!).
      if (ch == '`') {
        var tickEnd = i;
        while (tickEnd < len && input[tickEnd] == '`') {
          tickEnd++;
        }
        final tickLen = tickEnd - i;
        final closeIdx = _findExactBacktickClose(input, tickEnd, tickLen);
        if (closeIdx > tickEnd) {
          flushBuf();
          final code = input.substring(tickEnd, closeIdx).trim();
          spans.add(
            TextSpan(
              text: '\u00A0$code\u00A0',
              recognizer: linkRecognizer,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.none,
                color: t.text,
                backgroundColor: t.isDark
                    ? Color.lerp(t.cardSolid, Colors.white, 0.11)
                    : t.fill2,
              ),
            ),
          );
          i = closeIdx + tickLen;
          continue;
        }
      }

      // Inline Markdown image `![alt](https://...)` -> tappable preview link
      if (linkRecognizer == null && ch == '!' && i + 1 < len && input[i + 1] == '[') {
        final closeBracket = input.indexOf(']', i + 2);
        if (closeBracket > i + 1 && closeBracket + 1 < len && input[closeBracket + 1] == '(') {
          final closeParen = input.indexOf(')', closeBracket + 2);
          if (closeParen > closeBracket + 2) {
            final alt = input.substring(i + 2, closeBracket).trim();
            final imgUrl = input.substring(closeBracket + 2, closeParen).trim();
            if (imgUrl.startsWith('http://') || imgUrl.startsWith('https://')) {
              flushBuf();
              final recognizer = TapGestureRecognizer()
                ..onTap = () {
                  if (previewContext != null && previewContext.mounted) {
                    showImagePreviewDialog(
                      previewContext,
                      url: imgUrl,
                      title: alt.isEmpty ? '图片预览' : alt,
                    );
                  } else if (!openUrlInNewTab(imgUrl) &&
                      GrassBagNativeBridge.instance.isAndroidNative) {
                    GrassBagNativeBridge.instance.openExternalUrl(imgUrl);
                  }
                };
              outRecognizers.add(recognizer);
              spans.add(
                TextSpan(
                  text: '[图片: ${alt.isEmpty ? imgUrl : alt}]',
                  style: TextStyle(
                    color: t.isDark ? t.primaryHi : t.primary,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.underline,
                  ),
                  recognizer: recognizer,
                ),
              );
              i = closeParen + 1;
              continue;
            }
          }
        }
      }

      // Link `[label](https://...)` with balanced parentheses & recursive inline styling in label
      if (linkRecognizer == null && ch == '[') {
        final closeBracket = input.indexOf(']', i + 1);
        if (closeBracket > i + 1 && closeBracket + 1 < len && input[closeBracket + 1] == '(') {
          var urlEnd = closeBracket + 2;
          var parenDepth = 0;
          var validEnd = -1;
          while (urlEnd < len) {
            final c = input[urlEnd];
            if (c == '(') {
              parenDepth++;
            } else if (c == ')') {
              if (parenDepth == 0) {
                validEnd = urlEnd;
                break;
              }
              parenDepth--;
            } else if (c == ' ' || c == '\n' || c == '\t') {
              break;
            }
            urlEnd++;
          }
          if (validEnd > closeBracket + 2) {
            final linkLabel = input.substring(i + 1, closeBracket);
            final linkUrl = input.substring(closeBracket + 2, validEnd);
            if (linkUrl.startsWith('http://') || linkUrl.startsWith('https://')) {
              flushBuf();
              final recognizer = _makeUrlRecognizer(linkUrl, previewContext);
              outRecognizers.add(recognizer);
              final labelChildren = depth < 4
                  ? _buildMarkdownSpans(
                      linkLabel,
                      t,
                      outRecognizers,
                      depth: depth + 1,
                      previewContext: previewContext,
                      linkRecognizer: recognizer,
                    )
                  : <InlineSpan>[TextSpan(text: linkLabel, recognizer: recognizer)];
              spans.add(
                TextSpan(
                  style: TextStyle(
                    color: t.isDark ? t.primaryHi : t.primary,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.underline,
                    decorationColor: (t.isDark ? t.primaryHi : t.primary).withValues(alpha: 0.45),
                  ),
                  children: labelChildren,
                ),
              );
              i = validEnd + 1;
              continue;
            }
          }
        }
      }

      // Bare URL autolink `https://...` / `http://...`
      if (linkRecognizer == null &&
          ch == 'h' &&
          (i == 0 || !_isWordChar(input.codeUnitAt(i - 1))) &&
          (input.startsWith('https://', i) || input.startsWith('http://', i))) {
        var end = i;
        while (end < len) {
          final c = input[end];
          final cu = input.codeUnitAt(end);
          if (c == ' ' ||
              c == '\n' ||
              c == '\t' ||
              c == '<' ||
              c == '>' ||
              c == '"' ||
              c == "'" ||
              cu >= 0x3000) {
            break;
          }
          end++;
        }
        var url = input.substring(i, end);
        // Strip trailing sentence punctuation while keeping balanced `(...)` in Wikipedia-like URLs
        while (url.isNotEmpty) {
          final last = url[url.length - 1];
          if ('.,;:!?'.contains(last)) {
            url = url.substring(0, url.length - 1);
          } else if (last == ')' && '('.allMatches(url).length < ')'.allMatches(url).length) {
            url = url.substring(0, url.length - 1);
          } else if (last == ']' && '['.allMatches(url).length < ']'.allMatches(url).length) {
            url = url.substring(0, url.length - 1);
          } else {
            break;
          }
        }
        if (url.length > 10) {
          flushBuf();
          final recognizer = _makeUrlRecognizer(url, previewContext);
          outRecognizers.add(recognizer);
          spans.add(
            TextSpan(
              text: url,
              style: TextStyle(
                color: t.isDark ? t.primaryHi : t.primary,
                decoration: TextDecoration.underline,
                decorationColor: (t.isDark ? t.primaryHi : t.primary).withValues(alpha: 0.45),
              ),
              recognizer: recognizer,
            ),
          );
          i += url.length;
          continue;
        }
      }

      // Bold+Italic `***...***` (must be matched before `**...**`!)
      if (depth < 4 && ch == '*' && i + 2 < len && input[i + 1] == '*' && input[i + 2] == '*') {
        final closeIdx = _findClosingDelim(input, i + 3, '***');
        if (closeIdx > i + 3 && input[i + 3] != ' ') {
          flushBuf();
          final inner = input.substring(i + 3, closeIdx);
          spans.add(
            TextSpan(
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontStyle: FontStyle.italic,
                color: linkRecognizer == null ? t.text : null,
              ),
              children: _buildMarkdownSpans(
                inner,
                t,
                outRecognizers,
                depth: depth + 1,
                previewContext: previewContext,
                linkRecognizer: linkRecognizer,
              ),
            ),
          );
          i = closeIdx + 3;
          continue;
        }
      }

      // Bold `**...**` or `__...__` (supports recursive nested inline spans & inline code!)
      if (depth < 4 &&
          ((ch == '*' && i + 1 < len && input[i + 1] == '*') ||
              (ch == '_' &&
                  i + 1 < len &&
                  input[i + 1] == '_' &&
                  (i == 0 || !_isWordChar(input.codeUnitAt(i - 1)))))) {
        final delim = ch == '*' ? '**' : '__';
        final closeIdx = _findClosingDelim(input, i + 2, delim);
        if (closeIdx > i + 2 && input[i + 2] != ' ') {
          flushBuf();
          final inner = input.substring(i + 2, closeIdx);
          spans.add(
            TextSpan(
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: linkRecognizer == null ? t.text : null,
              ),
              children: _buildMarkdownSpans(
                inner,
                t,
                outRecognizers,
                depth: depth + 1,
                previewContext: previewContext,
                linkRecognizer: linkRecognizer,
              ),
            ),
          );
          i = closeIdx + 2;
          continue;
        }
      }

      // Strikethrough `~~...~~`
      if (depth < 4 && ch == '~' && i + 1 < len && input[i + 1] == '~') {
        final closeIdx = _findClosingDelim(input, i + 2, '~~');
        if (closeIdx > i + 2 && input[i + 2] != ' ') {
          flushBuf();
          final inner = input.substring(i + 2, closeIdx);
          spans.add(
            TextSpan(
              style: TextStyle(
                decoration: TextDecoration.lineThrough,
                color: linkRecognizer == null ? t.text3 : null,
              ),
              children: _buildMarkdownSpans(
                inner,
                t,
                outRecognizers,
                depth: depth + 1,
                previewContext: previewContext,
                linkRecognizer: linkRecognizer,
              ),
            ),
          );
          i = closeIdx + 2;
          continue;
        }
      }

      // Italic `*...*` or `_..._` — skips escaped chars, inline code & multi-char `**`/`__` runs
      // so nested `*italic **bold** italic*` renders cleanly!
      if (depth < 4 && (ch == '*' || ch == '_')) {
        final prevIsWord = i > 0 && _isWordChar(input.codeUnitAt(i - 1));
        final nextIsSame = i + 1 < len && input[i + 1] == ch;
        final nextIsSpace = i + 1 >= len || input[i + 1] == ' ' || input[i + 1] == '\n';
        final canOpen = !nextIsSame && !nextIsSpace && (ch == '*' || !prevIsWord);
        if (canOpen) {
          var closeIdx = -1;
          var scan = i + 1;
          while (scan < len) {
            final sc = input[scan];
            if (sc == '\\' && scan + 1 < len) {
              scan += 2;
              continue;
            }
            if (sc == '`') {
              var tickEnd = scan;
              while (tickEnd < len && input[tickEnd] == '`') {
                tickEnd++;
              }
              final tickLen = tickEnd - scan;
              final closeCode = _findExactBacktickClose(input, tickEnd, tickLen);
              scan = closeCode >= 0 ? closeCode + tickLen : tickEnd;
              continue;
            }
            if (sc == ch) {
              // Skip any multi-character run (`**` / `***` / `__`) intact!
              var runEnd = scan + 1;
              while (runEnd < len && input[runEnd] == ch) {
                runEnd++;
              }
              if (runEnd - scan > 1) {
                scan = runEnd;
                continue;
              }
              final beforeSpace = input[scan - 1] == ' ' || input[scan - 1] == '\n';
              final afterIsWord = scan + 1 < len && _isWordChar(input.codeUnitAt(scan + 1));
              if (!beforeSpace && (ch == '*' || !afterIsWord)) {
                closeIdx = scan;
                break;
              }
            }
            scan++;
          }
          if (closeIdx > i + 1) {
            flushBuf();
            final inner = input.substring(i + 1, closeIdx);
            spans.add(
              TextSpan(
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: linkRecognizer == null ? t.text : null,
                ),
                children: _buildMarkdownSpans(
                  inner,
                  t,
                  outRecognizers,
                  depth: depth + 1,
                  previewContext: previewContext,
                  linkRecognizer: linkRecognizer,
                ),
              ),
            );
            i = closeIdx + 1;
            continue;
          }
        }
      }

      buf.write(ch);
      i++;
    }
    flushBuf();
    if (showCursor) {
      // Pure text-metric cursor glyph (identical baseline & line height — ZERO vertical twitch!)
      spans.add(
        TextSpan(
          text: ' ▍',
          style: TextStyle(
            color: t.primary.withValues(alpha: 0.78),
            fontWeight: FontWeight.w400,
          ),
        ),
      );
    }
    return spans;
  }

  static List<String> _splitTableRow(String r) {
    var s = r.trim();
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|') && !s.endsWith(r'\|')) s = s.substring(0, s.length - 1);
    final cells = <String>[];
    final buf = StringBuffer();
    var inCode = false;
    for (int k = 0; k < s.length; k++) {
      final ch = s[k];
      if (ch == r'\' && k + 1 < s.length && s[k + 1] == '|') {
        buf.write('|');
        k++;
        continue;
      }
      if (ch == '`') inCode = !inCode;
      if (ch == '|' && !inCode) {
        cells.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    cells.add(buf.toString().trim());
    return cells;
  }

  static TextAlign _parseTableAlign(String spec) {
    final s = spec.trim();
    final left = s.startsWith(':');
    final right = s.endsWith(':');
    if (left && right) return TextAlign.center;
    if (right) return TextAlign.right;
    return TextAlign.left;
  }

  /// Fast single-pass linear block splitter enabling O(1) incremental prefix caching during streaming.
  static List<_RawMdBlock> _splitMarkdownBlocks(String sourceText) {
    final out = <_RawMdBlock>[];
    final lines = sourceText.split('\n');
    final paraBuf = <String>[];
    var i = 0;

    void flushParagraph() {
      if (paraBuf.isEmpty) return;
      final joined = paraBuf.join('\n').trimRight();
      paraBuf.clear();
      if (joined.isEmpty) return;
      out.add(_RawMdBlock(kind: _MdBlockKind.paragraph, raw: joined, body: joined));
    }

    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trimLeft();

      // Fenced code block (` ```lang ` or ` ~~~lang `, matching exact char & length >= 3;
      // CommonMark forbids backticks in a backtick fence's info string so ```` ```foo``` ```` stays inline!)
      final openFence = _openFenceRe.firstMatch(trimmed);
      if (openFence != null &&
          !(openFence.group(1)![0] == '`' && (openFence.group(2) ?? '').contains('`'))) {
        flushParagraph();
        final startIdx = i;
        final fenceStr = openFence.group(1)!;
        final fenceChar = fenceStr[0];
        final fenceLen = fenceStr.length;
        final lang = (openFence.group(2) ?? '').trim();
        final codeLines = <String>[];
        i++;
        while (i < lines.length && !_isClosingFence(lines[i].trimLeft(), fenceChar, fenceLen)) {
          codeLines.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++;
        final codeBody = codeLines.join('\n');
        out.add(
          _RawMdBlock(
            kind: _MdBlockKind.code,
            raw: lines.sublist(startIdx, i).join('\n'),
            lang: lang,
            body: codeBody,
          ),
        );
        continue;
      }

      // Display LaTeX math block (`$$ ... $$` single-line or multi-line)
      if (trimmed.startsWith(r'$$')) {
        final rest = trimmed.substring(2).trim();
        if (rest.endsWith(r'$$') && rest.length > 2) {
          flushParagraph();
          final formula = rest.substring(0, rest.length - 2).trim();
          out.add(_RawMdBlock(kind: _MdBlockKind.math, raw: line, body: formula));
          i++;
          continue;
        }
        if (rest.isEmpty) {
          flushParagraph();
          final startIdx = i;
          final mathLines = <String>[];
          i++;
          while (i < lines.length && lines[i].trim() != r'$$') {
            mathLines.add(lines[i]);
            i++;
          }
          if (i < lines.length) i++;
          out.add(
            _RawMdBlock(
              kind: _MdBlockKind.math,
              raw: lines.sublist(startIdx, i).join('\n'),
              body: mathLines.join('\n').trim(),
            ),
          );
          continue;
        }
      }

      // Headings (# through ######)
      final headingMatch = _headingPattern.firstMatch(trimmed);
      if (headingMatch != null) {
        flushParagraph();
        out.add(
          _RawMdBlock(
            kind: _MdBlockKind.heading,
            raw: line,
            level: headingMatch.group(1)!.length,
            body: headingMatch.group(2)!,
          ),
        );
        i++;
        continue;
      }

      // Horizontal rule (`---`, `----`, `- - -`, `***`, `___`)
      if (_hrPattern.hasMatch(trimmed.trim())) {
        flushParagraph();
        out.add(_RawMdBlock(kind: _MdBlockKind.hr, raw: trimmed));
        i++;
        continue;
      }

      // Standalone Markdown Image `![alt](https://...)`
      final imgMatch = _standaloneImageRe.firstMatch(trimmed.trim());
      if (imgMatch != null) {
        flushParagraph();
        out.add(
          _RawMdBlock(
            kind: _MdBlockKind.image,
            raw: line,
            body: imgMatch.group(1) ?? '',
            imageUrl: imgMatch.group(2) ?? '',
          ),
        );
        i++;
        continue;
      }

      // Markdown GFM table (supports both `| a | b |` AND leading-pipe-less `a | b`!)
      if (trimmed.contains('|') &&
          i + 1 < lines.length &&
          lines[i + 1].contains('|') &&
          _tableSepPattern.hasMatch(lines[i + 1].trim())) {
        flushParagraph();
        final tableStartIdx = i;
        i += 2;
        while (i < lines.length) {
          final rowTrim = lines[i].trim();
          if (rowTrim.isEmpty || !rowTrim.contains('|') || rowTrim == '|') break;
          i++;
        }
        final tLines = lines.sublist(tableStartIdx, i);
        out.add(
          _RawMdBlock(
            kind: _MdBlockKind.table,
            raw: tLines.join('\n'),
            tableLines: tLines,
          ),
        );
        continue;
      }

      // Cohesive multi-line Blockquote (supports `> ...` AND bare `>`)
      if (trimmed == '>' || trimmed.startsWith('>')) {
        flushParagraph();
        final quoteLines = <String>[];
        while (i < lines.length) {
          final qt = lines[i].trimLeft();
          if (qt == '>') {
            quoteLines.add('');
            i++;
          } else if (qt.startsWith('> ')) {
            quoteLines.add(qt.substring(2));
            i++;
          } else if (qt.startsWith('>')) {
            quoteLines.add(qt.substring(1));
            i++;
          } else {
            break;
          }
        }
        final qBody = quoteLines.join('\n');
        out.add(_RawMdBlock(kind: _MdBlockKind.quote, raw: qBody, body: qBody));
        continue;
      }

      // Bullet, numbered list, or task-checkbox item (`- [x]`, `- [ ]`)
      final bulletMatch = _bulletPattern.firstMatch(trimmed);
      if (bulletMatch != null) {
        flushParagraph();
        final leadingSpaces = line.length - trimmed.length;
        final indent = (leadingSpaces ~/ 2).clamp(0, 4) * 14.0;
        var itemBody = bulletMatch.group(2)!;
        bool? taskChecked;
        final taskMatch = _taskPrefixPattern.firstMatch(itemBody);
        if (taskMatch != null) {
          taskChecked = taskMatch.group(1)!.toLowerCase() == 'x';
          itemBody = taskMatch.group(2)!;
        }
        out.add(
          _RawMdBlock(
            kind: _MdBlockKind.bullet,
            raw: line,
            marker: bulletMatch.group(1)!,
            indent: indent,
            body: itemBody,
            taskChecked: taskChecked,
          ),
        );
        i++;
        continue;
      }

      if (trimmed.isEmpty) {
        flushParagraph();
      } else {
        paraBuf.add(line);
      }
      i++;
    }
    flushParagraph();
    return out;
  }

  Widget _buildSingleBlockWidget(
    int idx,
    _RawMdBlock blk,
    GrassBagTokens t,
    List<TapGestureRecognizer> recognizers, {
    required bool showCursor,
    bool isStreamingBlock = false,
  }) {
    final key = ValueKey('md-blk-$idx');
    switch (blk.kind) {
      case _MdBlockKind.code:
        if (isStreamingBlock) {
          _streamedBlockIndices.add(idx);
        }
        return RepaintBoundary(
          key: key,
          child: _FencedCodeBlock(
            lang: blk.lang,
            code: blk.body,
            isStreaming: isStreamingBlock,
            initiallyExpanded: isStreamingBlock || _streamedBlockIndices.contains(idx),
          ),
        );
      case _MdBlockKind.math:
        return Padding(
          key: key,
          padding: const EdgeInsets.only(top: 4, bottom: 10),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: t.fill1,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.sep, width: 0.6),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                blk.body,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13.5,
                  height: 1.55,
                  fontStyle: FontStyle.italic,
                  color: t.isDark ? t.primaryHi : t.primary,
                ),
              ),
            ),
          ),
        );
      case _MdBlockKind.heading:
        final fontSize = switch (blk.level) {
          1 => 18.5,
          2 => 16.5,
          3 => 15.5,
          _ => 14.5,
        };
        return Padding(
          key: key,
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          child: Text.rich(
            TextSpan(
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.25,
                color: t.text,
              ),
              children: _buildMarkdownSpans(
                blk.body,
                t,
                recognizers,
                previewContext: context,
              ),
            ),
          ),
        );
      case _MdBlockKind.hr:
        return Padding(
          key: key,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Divider(height: 0.6, color: t.sep),
        );
      case _MdBlockKind.image:
        return Padding(
          key: key,
          padding: const EdgeInsets.only(top: 4, bottom: 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: () => showImagePreviewDialog(
                context,
                url: blk.imageUrl,
                title: blk.body.isEmpty ? '图片预览' : blk.body,
              ),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 360, maxHeight: 260),
                decoration: BoxDecoration(
                  color: t.fill1,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: t.sep, width: 0.7),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Flexible(
                      child: Image.network(
                        blk.imageUrl,
                        cacheWidth: 720,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        loadingBuilder: (ctx, child, progress) {
                          if (progress == null) return child;
                          return Container(
                            width: 240,
                            height: 140,
                            alignment: Alignment.center,
                            color: t.fill1,
                            child: CupertinoActivityIndicator(radius: 9, color: t.text3),
                          );
                        },
                        errorBuilder: (_, __, ___) => Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(CupertinoIcons.photo, size: 16, color: t.text3),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  blk.body.isEmpty ? blk.imageUrl : blk.body,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12.5, color: t.text2),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (blk.body.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Text(
                          blk.body,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: t.text3),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      case _MdBlockKind.table:
        final headers = _splitTableRow(blk.tableLines[0].trimLeft());
        final sepCells = _splitTableRow(blk.tableLines[1].trim());
        final alignments = [
          for (int ci = 0; ci < headers.length; ci++)
            ci < sepCells.length ? _parseTableAlign(sepCells[ci]) : TextAlign.left,
        ];
        final rows = <List<String>>[
          for (int ri = 2; ri < blk.tableLines.length; ri++)
            _splitTableRow(blk.tableLines[ri].trim()),
        ];
        return RepaintBoundary(
          key: key,
          child: _MarkdownTableCard(
            headers: headers,
            alignments: alignments,
            rows: rows,
            rawMarkdown: blk.raw,
            spanBuilder: (cellText, tokens, cellRecognizers) => _buildMarkdownSpans(
              cellText,
              tokens,
              cellRecognizers,
              previewContext: context,
            ),
          ),
        );
      case _MdBlockKind.quote:
        return Padding(
          key: key,
          padding: const EdgeInsets.only(bottom: 9),
          child: ClipRSuperellipse(
            borderRadius: BorderRadius.circular(12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: t.fill1,
                border: Border(
                  left: BorderSide(color: t.primary, width: 3.5),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(11, 8, 12, 8),
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 14, height: 1.58, color: t.text2),
                    children: _buildMarkdownSpans(
                      blk.body,
                      t,
                      recognizers,
                      previewContext: context,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      case _MdBlockKind.bullet:
        return Padding(
          key: key,
          padding: EdgeInsets.only(left: 4 + blk.indent, bottom: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 22),
                child: Padding(
                  padding: const EdgeInsets.only(right: 4, top: 2),
                  child: blk.taskChecked != null
                      ? Icon(
                          blk.taskChecked!
                              ? CupertinoIcons.checkmark_square_fill
                              : CupertinoIcons.square,
                          size: 15,
                          color: blk.taskChecked! ? t.ok : t.text3,
                        )
                      : Text(
                          blk.marker == '-' || blk.marker == '*' || blk.marker == '+'
                              ? '•'
                              : blk.marker,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: t.primary,
                          ),
                        ),
                ),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.65,
                      decoration: blk.taskChecked == true ? TextDecoration.lineThrough : null,
                      color: blk.taskChecked == true ? t.text3 : t.text,
                    ),
                    children: _buildMarkdownSpans(
                      blk.body,
                      t,
                      recognizers,
                      showCursor: showCursor,
                      previewContext: context,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      case _MdBlockKind.paragraph:
        return Padding(
          key: key,
          padding: const EdgeInsets.only(bottom: 8),
          child: Text.rich(
            TextSpan(
              style: TextStyle(
                fontSize: 15,
                height: 1.72,
                letterSpacing: -0.1,
                decoration: TextDecoration.none,
                color: t.text,
              ),
              children: _buildMarkdownSpans(
                blk.body,
                t,
                recognizers,
                showCursor: showCursor,
                previewContext: context,
              ),
            ),
          ),
        );
    }
  }

  /// Finds the latest safe blank-line boundary outside any open code/math fence within the
  /// revealed tail `[settledLen .. revealedLen)`, settles completed blocks ONCE into an isolated
  /// `RepaintBoundary` (`_settledColumnCache`), and keeps ONLY the final active block mutable!
  void _advanceSettledPrefix(String fullSource, int revealedLen, GrassBagTokens t) {
    final tailLen = revealedLen - _settledLen;
    if (tailLen < 160) return;
    if (revealedLen < _lastPrefixScanLen + 64) return;
    _lastPrefixScanLen = revealedLen;

    // Leave at least 48 chars as mutable tail so the latest active block stays live.
    final maxCut = revealedLen - 48;
    if (maxCut <= _settledLen) return;

    final startPos = _settledLen;
    String? openChar;
    var openLen = 0;
    var inMathBlock = false;
    var pos = startPos;
    var lastSafeCut = -1;
    while (pos < maxCut) {
      final nl = fullSource.indexOf('\n', pos);
      if (nl < 0 || nl >= maxCut) break;
      final line = fullSource.substring(pos, nl);
      final trimmed = line.trimLeft();
      if (openChar == null && !inMathBlock) {
        final m = _openFenceRe.firstMatch(trimmed);
        if (m != null && !(m.group(1)![0] == '`' && (m.group(2) ?? '').contains('`'))) {
          final f = m.group(1)!;
          openChar = f[0];
          openLen = f.length;
        } else if (trimmed == r'$$') {
          inMathBlock = true;
        } else if (trimmed.isEmpty && nl + 1 < revealedLen) {
          // A blank line outside open fences guarantees clean block flush before nl + 1.
          lastSafeCut = nl + 1;
        }
      } else if (inMathBlock) {
        if (trimmed == r'$$') inMathBlock = false;
      } else if (_isClosingFence(trimmed, openChar!, openLen)) {
        openChar = null;
        openLen = 0;
      }
      pos = nl + 1;
    }
    if (lastSafeCut > startPos) {
      final deltaSlice = fullSource.substring(startPos, lastSafeCut);
      final deltaBlocks = _splitMarkdownBlocks(deltaSlice);
      if (deltaBlocks.isEmpty) return;

      // Remember any code block that was actively streamed in the tail before it moves to settled!
      final baseIdx = _settledCachedBlocks.length;
      for (var i = 0; i < deltaBlocks.length; i++) {
        final blk = deltaBlocks[i];
        final absIdx = baseIdx + i;
        final recs = <TapGestureRecognizer>[];
        final w = _buildSingleBlockWidget(
          absIdx,
          blk,
          t,
          recs,
          showCursor: false,
          isStreamingBlock: false,
        );
        _settledCachedBlocks.add(
          _CachedMdBlock(
            kind: blk.kind,
            raw: blk.raw,
            hasCursor: false,
            widget: w,
            recognizers: recs,
          ),
        );
      }

      _settledLen = lastSafeCut;
      _settledHeadAnchor = fullSource.substring(
        0,
        math.min(_anchorSampleLen, fullSource.length),
      );
      final tailAnchorStart = math.max(0, lastSafeCut - _anchorSampleLen);
      _settledTailAnchor = fullSource.substring(tailAnchorStart, lastSafeCut);

      _settledColumnCache = RepaintBoundary(
        key: const ValueKey('md-settled-blocks'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [for (final b in _settledCachedBlocks) b.widget],
        ),
      );
      // Clear cached tail blocks since their indices shifted into settled!
      for (final b in _tailCachedBlocks) {
        _deferDisposeRecognizers(b.recognizers);
      }
      _tailCachedBlocks.clear();
    }
  }

  /// Renders rich block Markdown in true O(tail) time per 120Hz typewriter frame:
  /// settled prefix blocks live in their own `RepaintBoundary` (`_settledColumnCache`) and are
  /// NEVER repainted or re-sliced; ONLY the active streaming tail is parsed & painted!
  Widget _buildRichMarkdownBody(
    String tailText,
    GrassBagTokens t, {
    required bool showCursor,
  }) {
    final tailBlocks = tailText.isEmpty ? const <_RawMdBlock>[] : _splitMarkdownBlocks(tailText);

    if (_settledCachedBlocks.isEmpty && tailBlocks.isEmpty) {
      for (final b in _tailCachedBlocks) {
        _deferDisposeRecognizers(b.recognizers);
      }
      _tailCachedBlocks.clear();
      return Text.rich(
        TextSpan(
          style: TextStyle(fontSize: 15, height: 1.72, color: t.text),
          children: _buildMarkdownSpans(
            tailText,
            t,
            _fallbackRecognizers,
            showCursor: showCursor,
            previewContext: context,
          ),
        ),
      );
    }

    if (_fallbackRecognizers.isNotEmpty) {
      _deferDisposeRecognizers(_fallbackRecognizers);
      _fallbackRecognizers.clear();
    }

    // Defer-dispose any excess tail blocks if tail shrank
    while (_tailCachedBlocks.length > tailBlocks.length) {
      _deferDisposeRecognizers(_tailCachedBlocks.removeLast().recognizers);
    }

    final baseIdx = _settledCachedBlocks.length;
    for (var ti = 0; ti < tailBlocks.length; ti++) {
      final blk = tailBlocks[ti];
      final absIdx = baseIdx + ti;
      final isLast = ti == tailBlocks.length - 1;
      final isStreamingCode = showCursor && isLast && blk.kind == _MdBlockKind.code;
      final wantsCursor = showCursor &&
          isLast &&
          (blk.kind == _MdBlockKind.paragraph || blk.kind == _MdBlockKind.bullet);
      final cacheFlag = wantsCursor || isStreamingCode;

      if (ti < _tailCachedBlocks.length) {
        final existing = _tailCachedBlocks[ti];
        if (existing.kind == blk.kind &&
            existing.raw == blk.raw &&
            existing.hasCursor == cacheFlag) {
          continue; // O(1) cache hit! Preserves Widget identity, tables, code blocks & links!
        }
        _deferDisposeRecognizers(existing.recognizers);
        final recs = <TapGestureRecognizer>[];
        final w = _buildSingleBlockWidget(
          absIdx,
          blk,
          t,
          recs,
          showCursor: wantsCursor,
          isStreamingBlock: isStreamingCode,
        );
        _tailCachedBlocks[ti] = _CachedMdBlock(
          kind: blk.kind,
          raw: blk.raw,
          hasCursor: cacheFlag,
          widget: w,
          recognizers: recs,
        );
      } else {
        final recs = <TapGestureRecognizer>[];
        final w = _buildSingleBlockWidget(
          absIdx,
          blk,
          t,
          recs,
          showCursor: wantsCursor,
          isStreamingBlock: isStreamingCode,
        );
        _tailCachedBlocks.add(
          _CachedMdBlock(
            kind: blk.kind,
            raw: blk.raw,
            hasCursor: cacheFlag,
            widget: w,
            recognizers: recs,
          ),
        );
      }
    }

    final tailWidget = _tailCachedBlocks.isEmpty
        ? null
        : RepaintBoundary(
            key: const ValueKey('md-active-tail'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [for (final b in _tailCachedBlocks) b.widget],
            ),
          );

    if (_settledColumnCache == null) {
      return tailWidget ?? const SizedBox.shrink();
    }
    if (tailWidget == null) {
      return _settledColumnCache!;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [_settledColumnCache!, tailWidget],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final isTyping = widget.isStreaming || _revealedLen < widget.text.length;
    final visibleLen = _revealedLen.clamp(0, widget.text.length);

    final themeChanged = _cachedDark != t.isDark ||
        _cachedAccent != t.accent ||
        _cachedTextColor != t.text ||
        _cachedPrimaryColor != t.primary ||
        _cachedCardSolidColor != t.cardSolid ||
        _cachedCodeBgColor != t.codeBg ||
        _cachedSepColor != t.sep;
    if (themeChanged ||
        (_settledLen > 0 && (visibleLen < _settledLen || !_matchesSettledAnchor(widget.text)))) {
      _disposeAllCachedBlocks();
    }

    // Incrementally settle completed prefix blocks into their own RepaintBoundary
    // BEFORE slicing the mutable tail — O(delta) work, ZERO full-message copy or O(N) startsWith!
    if (visibleLen - _settledLen >= 160) {
      _advanceSettledPrefix(widget.text, visibleLen, t);
    }

    final rawTail = _settledLen == 0 && visibleLen >= widget.text.length
        ? widget.text
        : widget.text.substring(_settledLen, visibleLen);
    // _settledLen always ends at a blank line outside open code/math fences -> offset 0 is exact!
    final displayTail = isTyping ? _stabilizeStreamingText(rawTail, 0) : rawTail;

    if (_cachedRichBody == null ||
        _cachedSettledLen != _settledLen ||
        _cachedTailText != displayTail ||
        _cachedStreaming != isTyping ||
        themeChanged) {
      _cachedRichBody = _buildRichMarkdownBody(displayTail, t, showCursor: isTyping);
      _cachedSettledLen = _settledLen;
      _cachedTailText = displayTail;
      _cachedStreaming = isTyping;
      _cachedDark = t.isDark;
      _cachedAccent = t.accent;
      _cachedTextColor = t.text;
      _cachedPrimaryColor = t.primary;
      _cachedCardSolidColor = t.cardSolid;
      _cachedCodeBgColor = t.codeBg;
      _cachedSepColor = t.sep;
    }
    final richBody = _cachedRichBody!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pure SelectionArea (no GlassContextMenu gesture hijack!) so users can freely
        // select & copy any snippet on both mobile long-press and desktop mouse drag.
        // Keep mounted whenever typing with non-empty source text so Frame 0 never collapses
        // if the first character is temporarily stripped syntax (e.g. leading `**`).
        if (_settledLen > 0 || displayTail.isNotEmpty || (isTyping && widget.text.isNotEmpty))
          SelectionArea(child: richBody),
        for (final item in widget.deliverables) ...[
          const SizedBox(height: 14),
          GrassBagSpringTap(
            pressedScale: 0.975,
            haptic: true,
            onTap: () => widget.onDeliverableTap((item['name'] ?? '附件').toString()),
            child: GrassBagCard(
              borderRadius: 22,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
              child: Row(
                children: [
                  GrassBagSquircleIcon(
                    icon: CupertinoIcons.doc_text_fill,
                    color: t.ok,
                    size: 38,
                    iconSize: 18,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (item['name'] ?? '产物').toString(),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                            color: t.text,
                          ),
                        ),
                        const SizedBox(height: 1.5),
                        Text(
                          '${item['note'] ?? '生成产物'} · ${item['size'] ?? ''}',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: t.text3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: t.primarySoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '预览',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: t.primary,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(CupertinoIcons.chevron_right, size: 11.5, color: t.primary),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        // Quiet minimalist one-tap action strip below completed replies (wait until typewriter settles!)
        if (!isTyping)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (widget.text.isNotEmpty)
                  _QuietReplyAction(
                    icon: _copied ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
                    label: _copied ? '已复制' : '复制',
                    active: _copied,
                    onTap: _handleCopy,
                  ),
                _QuietReplyAction(
                  icon: CupertinoIcons.arrow_branch,
                  label: '分叉',
                  onTap: widget.onFork,
                ),
                if (widget.onRegenerate != null)
                  Consumer(
                    builder: (_, ref, __) {
                      final streaming = ref.watch(appProvider.select((s) => s.isStreaming));
                      if (streaming) return const SizedBox.shrink();
                      return _QuietReplyAction(
                        icon: CupertinoIcons.arrow_clockwise,
                        label: '重新生成',
                        onTap: widget.onRegenerate!,
                      );
                    },
                  ),
                _QuietReplyAction(
                  icon: widget.feedback == 'up'
                      ? CupertinoIcons.hand_thumbsup_fill
                      : CupertinoIcons.hand_thumbsup,
                  label: '赞',
                  active: widget.feedback == 'up',
                  onTap: () => widget.onFeedback('up'),
                ),
                _QuietReplyAction(
                  icon: widget.feedback == 'down'
                      ? CupertinoIcons.hand_thumbsdown_fill
                      : CupertinoIcons.hand_thumbsdown,
                  label: '踩',
                  active: widget.feedback == 'down',
                  onTap: () => widget.onFeedback('down'),
                ),
                if (widget.usage != null &&
                    (widget.usage!.inputTokens > 0 ||
                        widget.usage!.outputTokens > 0 ||
                        (widget.usage!.cacheReadTokens ?? 0) > 0))
                  _TurnUsageMicroBadge(usage: widget.usage!),
              ],
            ),
          ),
      ],
    );
  }
}

class _TableScrollMetrics {
  const _TableScrollMetrics({
    this.offset = 0.0,
    this.maxExtent = 0.0,
    this.viewport = 0.0,
  });

  final double offset;
  final double maxExtent;
  final double viewport;
}

class _MarkdownTableCard extends StatefulWidget {
  const _MarkdownTableCard({
    required this.headers,
    required this.alignments,
    required this.rows,
    required this.rawMarkdown,
    required this.spanBuilder,
  });

  final List<String> headers;
  final List<TextAlign> alignments;
  final List<List<String>> rows;
  final String rawMarkdown;
  final List<InlineSpan> Function(
    String text,
    GrassBagTokens t,
    List<TapGestureRecognizer> outRecognizers,
  ) spanBuilder;

  @override
  State<_MarkdownTableCard> createState() => _MarkdownTableCardState();
}

class _CachedTableCell {
  const _CachedTableCell({
    required this.text,
    required this.spans,
    required this.recognizers,
  });

  final String text;
  final List<InlineSpan> spans;
  final List<TapGestureRecognizer> recognizers;
}

class _MarkdownTableCardState extends State<_MarkdownTableCard> {
  final ScrollController _hCtrl = ScrollController();
  final ValueNotifier<_TableScrollMetrics> _metricsNotifier =
      ValueNotifier<_TableScrollMetrics>(const _TableScrollMetrics());
  final ValueNotifier<bool> _draggingThumb = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _hoveringTrack = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _copied = ValueNotifier<bool>(false);
  final List<_CachedTableCell> _headerCache = [];
  final List<List<_CachedTableCell>> _rowCache = [];
  bool? _cachedDark;
  Color? _cachedTextColor;
  Color? _cachedPrimaryColor;
  final List<TapGestureRecognizer> _pendingDisposeRecognizers = [];
  bool _pendingDisposeScheduled = false;
  bool _metricsSyncScheduled = false;
  double _dragStartLocalX = 0;
  double _dragStartOffset = 0;

  void _deferDisposeCellRecognizers(Iterable<TapGestureRecognizer> list) {
    _pendingDisposeRecognizers.addAll(list);
    if (_pendingDisposeScheduled || _pendingDisposeRecognizers.isEmpty) return;
    _pendingDisposeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingDisposeScheduled = false;
      for (final r in _pendingDisposeRecognizers) {
        r.dispose();
      }
      _pendingDisposeRecognizers.clear();
    });
  }

  void _clearCellCache({bool immediate = false}) {
    for (final c in _headerCache) {
      if (immediate) {
        for (final r in c.recognizers) {
          r.dispose();
        }
      } else {
        _deferDisposeCellRecognizers(c.recognizers);
      }
    }
    _headerCache.clear();
    for (final row in _rowCache) {
      for (final c in row) {
        if (immediate) {
          for (final r in c.recognizers) {
            r.dispose();
          }
        } else {
          _deferDisposeCellRecognizers(c.recognizers);
        }
      }
    }
    _rowCache.clear();
    if (immediate) {
      for (final r in _pendingDisposeRecognizers) {
        r.dispose();
      }
      _pendingDisposeRecognizers.clear();
    }
  }

  void _scheduleMetricsSync() {
    if (_metricsSyncScheduled) return;
    _metricsSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsSyncScheduled = false;
      _syncFromController();
    });
  }

  @override
  void initState() {
    super.initState();
    _hCtrl.addListener(_syncFromController);
    _scheduleMetricsSync();
  }

  @override
  void didUpdateWidget(covariant _MarkdownTableCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleMetricsSync();
  }

  @override
  void dispose() {
    _hCtrl.removeListener(_syncFromController);
    _hCtrl.dispose();
    _metricsNotifier.dispose();
    _draggingThumb.dispose();
    _hoveringTrack.dispose();
    _copied.dispose();
    _clearCellCache(immediate: true);
    super.dispose();
  }

  void _syncFromController() {
    if (!mounted || !_hCtrl.hasClients) return;
    final pos = _hCtrl.position;
    if (!pos.hasContentDimensions || !pos.hasViewportDimension) return;
    _applyMetrics(pos.pixels, pos.maxScrollExtent, pos.viewportDimension);
  }

  void _applyMetrics(double offset, double maxExtent, double viewport) {
    final nextOffset = offset.clamp(0.0, maxExtent < 0 ? 0.0 : maxExtent);
    final nextMax = maxExtent < 0 ? 0.0 : maxExtent;
    final nextVp = viewport < 0 ? 0.0 : viewport;
    final cur = _metricsNotifier.value;
    if ((nextOffset - cur.offset).abs() > 0.5 ||
        (nextMax - cur.maxExtent).abs() > 0.5 ||
        (nextVp - cur.viewport).abs() > 0.5) {
      // Pure ValueNotifier update -> ZERO Table rebuilds & ZERO IntrinsicColumnWidth re-layout during scroll!
      _metricsNotifier.value = _TableScrollMetrics(
        offset: nextOffset,
        maxExtent: nextMax,
        viewport: nextVp,
      );
    }
  }

  void _nudgeBy(double delta) {
    final maxExt = _metricsNotifier.value.maxExtent;
    if (!_hCtrl.hasClients || maxExt <= 0) return;
    final target = (_hCtrl.offset + delta).clamp(0.0, maxExt);
    _hCtrl.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    final maxExt = _metricsNotifier.value.maxExtent;
    if (event is! PointerScrollEvent || !_hCtrl.hasClients || maxExt <= 0) return;
    final dx = event.scrollDelta.dx;
    final dy = event.scrollDelta.dy;
    double delta = 0;
    if (dx.abs() > 0.1) {
      delta = dx;
    } else if (HardwareKeyboard.instance.isShiftPressed && dy.abs() > 0.1) {
      delta = dy;
    }
    if (delta == 0) return;
    final target = (_hCtrl.offset + delta).clamp(0.0, maxExt);
    if ((target - _hCtrl.offset).abs() > 0.1) {
      _hCtrl.jumpTo(target);
    }
  }

  void _copyMarkdown() {
    Clipboard.setData(ClipboardData(text: widget.rawMarkdown));
    _copied.value = true;
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) _copied.value = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final cardBg = t.isDark ? t.cardSolid : Colors.white.withValues(alpha: 0.92);
    final headerBg = t.isDark
        ? Color.lerp(t.cardSolid, Colors.white, 0.075)!
        : t.bgGrouped;
    final stripeBg = t.isDark
        ? Colors.white.withValues(alpha: 0.025)
        : t.text.withValues(alpha: 0.025);

    // Incremental per-cell inline Markdown span cache: completed rows in a growing streaming table
    // hit O(1) string equality with ZERO re-parsing or TapGestureRecognizer churn!
    if (_cachedDark != t.isDark ||
        _cachedTextColor != t.text ||
        _cachedPrimaryColor != t.primary) {
      _clearCellCache();
      _cachedDark = t.isDark;
      _cachedTextColor = t.text;
      _cachedPrimaryColor = t.primary;
    }

    final colCount = widget.headers.length;
    while (_headerCache.length > colCount) {
      _deferDisposeCellRecognizers(_headerCache.removeLast().recognizers);
    }
    final headerSpans = List<List<InlineSpan>>.generate(colCount, (ci) {
      final text = widget.headers[ci];
      if (ci < _headerCache.length && _headerCache[ci].text == text) {
        return _headerCache[ci].spans;
      }
      final recs = <TapGestureRecognizer>[];
      final spans = widget.spanBuilder(text, t, recs);
      final cell = _CachedTableCell(text: text, spans: spans, recognizers: recs);
      if (ci < _headerCache.length) {
        _deferDisposeCellRecognizers(_headerCache[ci].recognizers);
        _headerCache[ci] = cell;
      } else {
        _headerCache.add(cell);
      }
      return spans;
    }, growable: false);

    final rowCount = widget.rows.length;
    while (_rowCache.length > rowCount) {
      for (final c in _rowCache.removeLast()) {
        _deferDisposeCellRecognizers(c.recognizers);
      }
    }
    final rowSpans = List<List<List<InlineSpan>>>.generate(rowCount, (ri) {
      if (ri >= _rowCache.length) {
        _rowCache.add(<_CachedTableCell>[]);
      }
      final cachedRow = _rowCache[ri];
      while (cachedRow.length > colCount) {
        _deferDisposeCellRecognizers(cachedRow.removeLast().recognizers);
      }
      final srcRow = widget.rows[ri];
      return List<List<InlineSpan>>.generate(colCount, (ci) {
        final text = ci < srcRow.length ? srcRow[ci] : '';
        if (ci < cachedRow.length && cachedRow[ci].text == text) {
          return cachedRow[ci].spans;
        }
        final recs = <TapGestureRecognizer>[];
        final spans = widget.spanBuilder(text, t, recs);
        final cell = _CachedTableCell(text: text, spans: spans, recognizers: recs);
        if (ci < cachedRow.length) {
          _deferDisposeCellRecognizers(cachedRow[ci].recognizers);
          cachedRow[ci] = cell;
        } else {
          cachedRow.add(cell);
        }
        return spans;
      }, growable: false);
    }, growable: false);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxCardW = constraints.maxWidth.isFinite ? constraints.maxWidth : 640.0;
        final cellMaxW = maxCardW >= 620 ? 300.0 : (maxCardW >= 420 ? 235.0 : 195.0);

        final tableContent = Listener(
          onPointerSignal: _handlePointerSignal,
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (n) {
              if (n.metrics.axis == Axis.horizontal) {
                _scheduleMetricsSync();
              }
              return false;
            },
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                scrollbars: false,
                dragDevices: const {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.trackpad,
                  PointerDeviceKind.stylus,
                },
              ),
              child: SingleChildScrollView(
                controller: _hCtrl,
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                child: Table(
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  border: TableBorder(
                    horizontalInside: BorderSide(color: t.sep, width: 0.5),
                    verticalInside: BorderSide(
                      color: t.sep.withValues(alpha: t.sep.a * 0.65),
                      width: 0.5,
                    ),
                  ),
                  children: [
                    TableRow(
                      decoration: BoxDecoration(color: headerBg),
                      children: [
                        for (int ci = 0; ci < widget.headers.length; ci++)
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              minWidth: 56,
                              maxWidth: cellMaxW,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 13,
                                vertical: 9.5,
                              ),
                              child: Text.rich(
                                TextSpan(
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    height: 1.38,
                                    color: t.text,
                                  ),
                                  children: headerSpans[ci],
                                ),
                                textAlign: ci < widget.alignments.length
                                    ? widget.alignments[ci]
                                    : TextAlign.left,
                              ),
                            ),
                          ),
                      ],
                    ),
                    for (int ri = 0; ri < widget.rows.length; ri++)
                      TableRow(
                        decoration: ri.isOdd ? BoxDecoration(color: stripeBg) : null,
                        children: [
                          for (int ci = 0; ci < widget.headers.length; ci++)
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                minWidth: 56,
                                maxWidth: cellMaxW,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 13,
                                  vertical: 8.5,
                                ),
                                child: Text.rich(
                                  TextSpan(
                                    style: TextStyle(
                                      fontSize: 13,
                                      height: 1.48,
                                      color: t.text2,
                                    ),
                                    children: rowSpans[ri][ci],
                                  ),
                                  textAlign: ci < widget.alignments.length
                                      ? widget.alignments[ci]
                                      : TextAlign.left,
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        );

        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(top: 4, bottom: 12),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: t.isDark ? Colors.white.withValues(alpha: 0.11) : t.sep,
                width: 0.75,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: ValueListenableBuilder<_TableScrollMetrics>(
              valueListenable: _metricsNotifier,
              child: tableContent,
              builder: (context, m, staticTable) {
                final canScroll = m.maxExtent > 1.0;
                final canScrollLeft = canScroll && m.offset > 2.0;
                final canScrollRight = canScroll && m.offset < m.maxExtent - 2.0;

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Stack(
                      children: [
                        staticTable!,
                        if (canScrollLeft)
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            width: 22,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                    colors: [
                                      cardBg.withValues(alpha: 0.92),
                                      cardBg.withValues(alpha: 0.0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (canScrollRight)
                          Positioned(
                            right: 0,
                            top: 0,
                            bottom: 0,
                            width: 26,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.centerRight,
                                    end: Alignment.centerLeft,
                                    colors: [
                                      cardBg.withValues(alpha: 0.94),
                                      cardBg.withValues(alpha: 0.0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    SelectionContainer.disabled(
                      child: Container(
                        width: canScroll ? maxCardW : null,
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: headerBg.withValues(alpha: 0.72),
                          border: Border(top: BorderSide(color: t.sep, width: 0.5)),
                        ),
                        child: Row(
                          mainAxisSize: canScroll ? MainAxisSize.max : MainAxisSize.min,
                          children: [
                            if (canScroll) ...[
                              _TableNudgeButton(
                                icon: CupertinoIcons.chevron_left,
                                enabled: canScrollLeft,
                                onTap: () =>
                                    _nudgeBy(-(m.viewport > 0 ? m.viewport * 0.65 : 180.0)),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: ListenableBuilder(
                                  listenable: Listenable.merge([_draggingThumb, _hoveringTrack]),
                                  builder: (_, __) {
                                    final dragging = _draggingThumb.value;
                                    final hovering = _hoveringTrack.value;
                                    return MouseRegion(
                                      cursor: dragging
                                          ? SystemMouseCursors.grabbing
                                          : SystemMouseCursors.grab,
                                      onEnter: (_) => _hoveringTrack.value = true,
                                      onExit: (_) => _hoveringTrack.value = false,
                                      child: LayoutBuilder(
                                        builder: (ctx, trackBox) {
                                          final trackW = trackBox.maxWidth;
                                          final totalW = m.viewport + m.maxExtent;
                                          final thumbW = (totalW > 0 && trackW > 34.0)
                                              ? (trackW * (m.viewport / totalW)).clamp(34.0, trackW)
                                              : trackW;
                                          final avail = (trackW - thumbW).clamp(0.0, trackW);
                                          final thumbLeft = m.maxExtent > 0
                                              ? avail * (m.offset / m.maxExtent).clamp(0.0, 1.0)
                                              : 0.0;

                                          return GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTapDown: (d) {
                                              if (!_hCtrl.hasClients || avail <= 0) return;
                                              final ratio =
                                                  ((d.localPosition.dx - thumbW / 2) / avail)
                                                      .clamp(0.0, 1.0);
                                              _hCtrl.animateTo(
                                                ratio * m.maxExtent,
                                                duration: const Duration(milliseconds: 180),
                                                curve: Curves.easeOutCubic,
                                              );
                                            },
                                            onHorizontalDragStart: (d) {
                                              if (!_hCtrl.hasClients) return;
                                              _draggingThumb.value = true;
                                              _dragStartLocalX = d.localPosition.dx;
                                              _dragStartOffset = _hCtrl.offset;
                                            },
                                            onHorizontalDragUpdate: (d) {
                                              if (!_hCtrl.hasClients || avail <= 0) return;
                                              final dx = d.localPosition.dx - _dragStartLocalX;
                                              final next =
                                                  (_dragStartOffset + (dx / avail) * m.maxExtent)
                                                      .clamp(0.0, m.maxExtent);
                                              _hCtrl.jumpTo(next);
                                            },
                                            onHorizontalDragEnd: (_) {
                                              if (mounted) _draggingThumb.value = false;
                                            },
                                            onHorizontalDragCancel: () {
                                              if (mounted) _draggingThumb.value = false;
                                            },
                                            child: SizedBox(
                                              height: 26,
                                              child: Stack(
                                                alignment: Alignment.centerLeft,
                                                children: [
                                                  Container(
                                                    height: 6,
                                                    decoration: BoxDecoration(
                                                      color: t.isDark
                                                          ? Colors.white.withValues(alpha: 0.08)
                                                          : Colors.black.withValues(alpha: 0.07),
                                                      borderRadius: BorderRadius.circular(999),
                                                    ),
                                                  ),
                                                  Positioned(
                                                    left: thumbLeft,
                                                    child: AnimatedContainer(
                                                      duration: const Duration(milliseconds: 100),
                                                      width: thumbW,
                                                      height: (dragging || hovering) ? 7.5 : 6.0,
                                                      decoration: BoxDecoration(
                                                        color: dragging
                                                            ? t.primary
                                                            : (hovering
                                                                ? t.text2.withValues(alpha: 0.65)
                                                                : t.text3.withValues(alpha: 0.55)),
                                                        borderRadius: BorderRadius.circular(999),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 4),
                              _TableNudgeButton(
                                icon: CupertinoIcons.chevron_right,
                                enabled: canScrollRight,
                                onTap: () =>
                                    _nudgeBy(m.viewport > 0 ? m.viewport * 0.65 : 180.0),
                              ),
                              Container(
                                width: 0.5,
                                height: 14,
                                margin: const EdgeInsets.symmetric(horizontal: 6),
                                color: t.sep,
                              ),
                            ],
                            ValueListenableBuilder<bool>(
                              valueListenable: _copied,
                              builder: (_, copied, __) => GrassBagSpringTap(
                                onTap: _copyMarkdown,
                                pressedScale: 0.92,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        copied
                                            ? CupertinoIcons.checkmark
                                            : CupertinoIcons.doc_on_doc,
                                        size: 11.5,
                                        color: copied ? t.ok : t.text3,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        copied ? '已复制' : '复制表格',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w500,
                                          color: copied ? t.ok : t.text3,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _TableNudgeButton extends StatelessWidget {
  const _TableNudgeButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: SizedBox(
        width: 22,
        height: 24,
        child: Center(
          child: Icon(
            icon,
            size: 12.5,
            color: enabled ? t.text2 : t.text3.withValues(alpha: 0.30),
          ),
        ),
      ),
    );
  }
}

class _FencedCodeBlock extends StatefulWidget {
  const _FencedCodeBlock({
    required this.lang,
    required this.code,
    this.isStreaming = false,
    this.initiallyExpanded = false,
  });
  final String lang;
  final String code;
  final bool isStreaming;
  final bool initiallyExpanded;

  @override
  State<_FencedCodeBlock> createState() => _FencedCodeBlockState();
}

class _FencedCodeBlockState extends State<_FencedCodeBlock> {
  static const int _collapseThreshold = 40;
  static const int _collapsedPreviewLines = 24;

  final ScrollController _hCtrl = ScrollController();
  bool _copied = false;
  bool _softWrap = false;
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    // Keep live-streamed code blocks expanded so finishing a 40+ line code block NEVER
    // violently collapses and jumps scrollback by ~300px! Historical long blocks still collapse.
    _expanded = widget.isStreaming || widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(covariant _FencedCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.isStreaming || widget.initiallyExpanded) && !_expanded) {
      _expanded = true;
    }
  }

  @override
  void dispose() {
    _hCtrl.dispose();
    super.dispose();
  }

  static int _countLines(String s) {
    var count = 1;
    final len = s.length;
    for (var i = 0; i < len; i++) {
      if (s.codeUnitAt(i) == 0x0A /* '\n' */) count++;
    }
    return count;
  }

  static String _takeFirstLines(String s, int maxLines) {
    var seen = 0;
    var pos = 0;
    while (seen < maxLines) {
      final nl = s.indexOf('\n', pos);
      if (nl < 0) return s;
      seen++;
      if (seen == maxLines) return s.substring(0, nl);
      pos = nl + 1;
    }
    return s;
  }

  Widget _buildCodeText(String displayText, bool isDiff) {
    if (isDiff) {
      final displayLines = displayText.split('\n');
      return Text.rich(
        TextSpan(
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.5,
            color: Color(0xFFE2E8F0),
          ),
          children: [
            for (int li = 0; li < displayLines.length; li++)
              TextSpan(
                text: li == displayLines.length - 1 ? displayLines[li] : '${displayLines[li]}\n',
                style: displayLines[li].startsWith('+')
                    ? const TextStyle(color: Color(0xFF6EE7B7))
                    : (displayLines[li].startsWith('-')
                        ? const TextStyle(color: Color(0xFFFCA5A5))
                        : null),
              ),
          ],
        ),
        softWrap: _softWrap,
      );
    }
    return Text(
      displayText,
      softWrap: _softWrap,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        height: 1.52,
        color: Color(0xFFE2E8F0),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final isDiff = widget.lang.toLowerCase() == 'diff';
    // Fast codeUnitAt line count — skips .split('\n') + .join('\n') allocations on every 120Hz tick!
    final lineCount = _countLines(widget.code);
    // Never abruptly auto-collapse a code block mid-stream at line 41 (causes sudden ~300px scroll jump)!
    final isLong = !widget.isStreaming && lineCount > _collapseThreshold;
    final displayText =
        (isLong && !_expanded) ? _takeFirstLines(widget.code, _collapsedPreviewLines) : widget.code;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: t.codeBg,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.10), width: 0.65),
          ),
        ),
        child: ClipRSuperellipse(
          borderRadius: BorderRadius.circular(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectionContainer.disabled(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  color: t.codeBar,
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.lang.isEmpty ? 'code' : widget.lang,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ),
                      if (lineCount > 10) ...[
                        const SizedBox(width: 6),
                        Text(
                          '$lineCount 行',
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontFeatures: [FontFeature.tabularFigures()],
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                      const Spacer(),
                      if (isLong) ...[
                        GrassBagSpringTap(
                          onTap: () => setState(() => _expanded = !_expanded),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: Text(
                              _expanded ? '收起' : '展开',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF94A3B8),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      GrassBagSpringTap(
                        onTap: () => setState(() => _softWrap = !_softWrap),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          child: Text(
                            _softWrap ? '单行' : '换行',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: _softWrap ? t.primaryHi : const Color(0xFF94A3B8),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GrassBagSpringTap(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: widget.code));
                          setState(() => _copied = true);
                          Future<void>.delayed(const Duration(milliseconds: 1400), () {
                            if (mounted) setState(() => _copied = false);
                          });
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _copied ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
                              size: 12,
                              color: _copied ? const Color(0xFF34D399) : const Color(0xFFCBD5E1),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _copied ? '已复制' : '复制',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: _copied ? const Color(0xFF34D399) : const Color(0xFFCBD5E1),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_softWrap)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: _buildCodeText(displayText, isDiff),
                )
              else
                CupertinoScrollbar(
                  controller: _hCtrl,
                  thumbVisibility: false,
                  child: SingleChildScrollView(
                    controller: _hCtrl,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(12),
                    child: _buildCodeText(displayText, isDiff),
                  ),
                ),
              if (isLong && !_expanded)
                SelectionContainer.disabled(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _expanded = true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: t.codeBar.withValues(alpha: 0.72),
                        border: Border(
                          top: BorderSide(color: Colors.white.withValues(alpha: 0.08), width: 0.6),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '展开剩余 ${lineCount - _collapsedPreviewLines} 行（共 $lineCount 行）',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TurnUsageMicroBadge extends StatelessWidget {
  const _TurnUsageMicroBadge({required this.usage});
  final TurnUsage usage;

  static String _fmtTok(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 10000) return '${(n / 1000).toStringAsFixed(1)}K';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(2)}K';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final cacheRead = usage.cacheReadTokens ?? 0;
    final totalIn = usage.inputTokens + cacheRead + (usage.cacheWriteTokens ?? 0);
    final hitPct = totalIn > 0 && cacheRead > 0
        ? ((cacheRead / totalIn) * 100).toStringAsFixed(0)
        : null;
    final parts = <String>[
      if (usage.inputTokens > 0) '↑${_fmtTok(usage.inputTokens)}',
      if (usage.outputTokens > 0) '↓${_fmtTok(usage.outputTokens)}',
      if (hitPct != null) '缓存 $hitPct%',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5),
      decoration: BoxDecoration(
        color: t.fill1.withValues(alpha: t.isDark ? 0.06 : 0.05),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        parts.join(' · '),
        style: TextStyle(
          fontSize: 11,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: t.text3,
        ),
      ),
    );
  }
}

class _QuietReplyAction extends StatelessWidget {
  const _QuietReplyAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final fg = active ? t.ok : t.text3;
    return GrassBagSpringTap(
      onTap: onTap,
      pressedScale: 0.92,
      haptic: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
        decoration: BoxDecoration(
          color: active ? t.okSoft : t.fill1.withValues(alpha: t.isDark ? 0.08 : 0.06),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12.5, color: fg),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
