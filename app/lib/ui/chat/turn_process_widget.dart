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
import '../detail/session_detail_page.dart';
import '../sdui/sdui_renderer.dart';
import '../web/deepseek_signin_page.dart';
import '../web/web_embed.dart';

/// Byte-budgeted true LRU cache (max 24 MiB / 48 items) for base64-decoded user image
/// attachments so 42Hz streaming rebuilds never re-decode large payloads or OOM on photos.
final Map<String, Uint8List> _decodedAttachmentBytesCache = <String, Uint8List>{};
int _decodedAttachmentCacheBytes = 0;
const int _kMaxAttachmentCacheEntries = 48;
const int _kMaxAttachmentCacheBytes = 24 * 1024 * 1024;
const int _kAsyncDecodeThresholdChars = 64 * 1024;

Uint8List _decodeBase64Payload(String payload) {
  try {
    return base64Decode(payload);
  } catch (_) {
    return Uint8List(0);
  }
}

Uint8List? _getCachedAttachmentBytes(String key) {
  final hit = _decodedAttachmentBytesCache.remove(key);
  if (hit == null) return null;
  _decodedAttachmentBytesCache[key] = hit; // refresh LRU recency
  return hit;
}

void _putCachedAttachmentBytes(String key, Uint8List bytes) {
  final prev = _decodedAttachmentBytesCache.remove(key);
  if (prev != null) _decodedAttachmentCacheBytes -= prev.lengthInBytes;
  _decodedAttachmentBytesCache[key] = bytes;
  _decodedAttachmentCacheBytes += bytes.lengthInBytes;
  while ((_decodedAttachmentBytesCache.length > _kMaxAttachmentCacheEntries ||
          _decodedAttachmentCacheBytes > _kMaxAttachmentCacheBytes) &&
      _decodedAttachmentBytesCache.length > 1) {
    final oldestKey = _decodedAttachmentBytesCache.keys.first;
    final oldest = _decodedAttachmentBytesCache.remove(oldestKey);
    if (oldest != null) _decodedAttachmentCacheBytes -= oldest.lengthInBytes;
  }
}

/// Clears module-level decoded attachment bytes & typewriter reveal caches on host switch
/// so cached images or turn offsets never bleed across hosts.
void clearTurnProcessCaches() {
  _decodedAttachmentBytesCache.clear();
  _decodedAttachmentCacheBytes = 0;
  _AssistantBodyState._revealedProgressByTurn.clear();
  _ToolStepRowState._kDetailCache.clear();
}

/// Decodes large (>64 KB) base64 image attachments off the UI thread via `compute`
/// so opening history or streaming turns with pasted photos never drops a frame.
class _AsyncAttachmentThumb extends StatefulWidget {
  const _AsyncAttachmentThumb({
    required this.cacheKey,
    required this.payload,
    required this.title,
    required this.thumbCachePx,
  });

  final String cacheKey;
  final String payload;
  final String title;
  final int thumbCachePx;

  @override
  State<_AsyncAttachmentThumb> createState() => _AsyncAttachmentThumbState();
}

class _AsyncAttachmentThumbState extends State<_AsyncAttachmentThumb> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _AsyncAttachmentThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  void _load() {
    final hit = _getCachedAttachmentBytes(widget.cacheKey);
    if (hit != null) {
      _bytes = hit;
      return;
    }
    final key = widget.cacheKey;
    compute(_decodeBase64Payload, widget.payload).then((decoded) {
      if (decoded.isNotEmpty) {
        _putCachedAttachmentBytes(key, decoded);
      }
      if (!mounted || widget.cacheKey != key) return;
      setState(() {
        if (decoded.isEmpty) {
          _failed = true;
        } else {
          _bytes = decoded;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final bytes = _bytes;
    return GestureDetector(
      onTap: bytes != null
          ? () => showImagePreviewDialog(
                context,
                bytes: bytes,
                title: widget.title,
              )
          : null,
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: t.fill1,
          border: Border.all(color: t.sepStrong, width: 0.7),
        ),
        clipBehavior: Clip.antiAlias,
        child: bytes != null
            ? Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: widget.thumbCachePx,
                errorBuilder: (_, __, ___) => Center(
                  child: Icon(CupertinoIcons.photo_fill, size: 20, color: t.primary),
                ),
              )
            : Center(
                child: _failed
                    ? Icon(CupertinoIcons.photo_fill, size: 20, color: t.text3)
                    : GrassBagActivityIndicator(radius: 8, color: t.text3),
              ),
      ),
    );
  }
}

Map<String, dynamic>? _tryParseJsonMap(String raw) {
  final trimmed = raw.trim();
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {}
  return null;
}

String _humanizeToolName(String name) {
  final n = name.toLowerCase().trim();
  switch (n) {
    case 'phone_open':
      return '打开应用';
    case 'phone_tap':
      return '点击屏幕';
    case 'phone_long_press':
      return '长按元素';
    case 'phone_swipe':
      return '滑动屏幕';
    case 'phone_type':
      return '输入文本';
    case 'phone_screen':
      return '读取当前屏幕';
    case 'phone_screenshot':
      return '截取当前屏幕';
    case 'phone_apps':
      return '获取应用列表';
    case 'phone_key':
      return '模拟系统按键';
    case 'phone_intent':
      return '执行快捷动作';
    case 'phone_wait':
      return '等待界面响应';
    case 'phone_handoff':
      return '等待人工接管';
    case 'phone_return_app':
      return '返回 GrassBag';
    case 'todo_write':
    case 'todowrite':
      return '更新待办清单';
    case 'read':
    case 'read_file':
      return '读取文件';
    case 'write':
    case 'write_file':
    case 'create_file':
      return '写入文件';
    case 'edit':
    case 'edit_file':
    case 'apply_patch':
      return '编辑文件';
    case 'bash':
    case 'shell':
    case 'cmd':
    case 'exec':
    case 'terminal':
      return '执行终端命令';
    case 'grep':
    case 'search':
    case 'ripgrep':
      return '检索代码';
    case 'glob':
    case 'find':
    case 'find_files':
      return '查找文件';
    case 'ls':
    case 'list_dir':
    case 'list_directory':
    case 'listdir':
      return '浏览目录';
    case 'delete':
    case 'delete_file':
    case 'remove_file':
    case 'rm':
      return '删除文件';
    case 'subagent':
    case 'task':
    case 'delegate':
    case 'spawn_subagent':
      return '委派子代理';
    case 'ask_user':
    case 'user_questions':
      return '向你确认';
    case 'web_search':
      return '联网搜索';
    case 'web_fetch':
    case 'fetch_url':
      return '抓取网页';
    default:
      if (n.startsWith('phone_')) return '操控手机';
      if (n.startsWith('mcp__') || n.startsWith('mcp.')) {
        final parts = name.split(RegExp(r'__|[:./]')).where((p) => p.isNotEmpty).toList();
        return parts.length >= 2 ? 'MCP · ${parts.last}' : 'MCP 工具';
      }
      return name;
  }
}

String _humanizeToolDisplayTitle(ToolStep step) {
  final prefix = '${step.name} · ';
  final stripped = step.title.startsWith(prefix) && step.title.length > prefix.length
      ? step.title.substring(prefix.length).trim()
      : step.title.trim();
  final n = step.name.toLowerCase().trim();
  if (stripped.isNotEmpty && stripped.toLowerCase() != n) {
    return stripped;
  }
  final parsed = _tryParseJsonMap(step.summary);
  if (parsed != null) {
    final opened = (parsed['opened'] ?? parsed['label'] ?? parsed['appLabel'] ?? parsed['appName'] ?? '')
        .toString()
        .trim();
    if (opened.isNotEmpty) return opened;
    final pkg = (parsed['package'] ?? parsed['packageName'] ?? '').toString().trim();
    if (pkg.isNotEmpty) return pkg;
  }
  switch (n) {
    case 'phone_open':
      return '目标应用';
    case 'phone_screen':
      return '当前界面';
    case 'phone_screenshot':
      return '当前屏幕';
    case 'phone_apps':
      return '已安装应用';
    case 'phone_return_app':
      return '回到 GrassBag';
    case 'phone_tap':
      return '屏幕元素';
    case 'phone_long_press':
      return '目标元素';
    case 'phone_swipe':
      return '屏幕滑动';
    case 'phone_type':
      return '文本输入';
    case 'phone_key':
      return '系统按键';
    case 'phone_wait':
      return '界面稳定';
    case 'phone_handoff':
      return '人工确认';
    case 'todo_write':
    case 'todowrite':
      return '任务进度';
    default:
      return stripped.isNotEmpty ? stripped : _humanizeToolName(step.name);
  }
}

String _humanizeSummaryPill(ToolStep step) {
  final raw = step.summary.trim();
  if (raw.isEmpty) return '';
  final looksJson = raw.startsWith('{') || raw.startsWith('[');
  if (!looksJson) return raw;
  final parsed = _tryParseJsonMap(raw);
  if (parsed == null) return '';
  if (parsed['ok'] == false || parsed['error'] != null) {
    final err = parsed['error'] ?? parsed['message'] ?? '失败';
    return err.toString().trim();
  }
  final n = step.name.toLowerCase().trim();
  if (n == 'phone_open') {
    final opened = (parsed['opened'] ?? parsed['label'] ?? '').toString().trim();
    return opened.isNotEmpty ? '已打开 $opened' : '已打开';
  }
  if (n == 'phone_screenshot') {
    if (parsed['width'] != null && parsed['height'] != null) {
      return '${parsed['width']}×${parsed['height']}';
    }
    return parsed['ok'] == true ? '截屏完成' : '';
  }
  if (n == 'phone_screen') {
    final nodes = parsed['nodes'];
    if (nodes is List) return '${nodes.length} 元素';
    return parsed['ok'] == true ? '已读取' : '';
  }
  if (n == 'phone_apps') {
    final apps = parsed['apps'];
    if (apps is List) return '${apps.length} 个应用';
    return parsed['ok'] == true ? '已列出' : '';
  }
  if (n == 'phone_return_app') {
    return parsed['ok'] == true ? '已返回' : '';
  }
  final msg = (parsed['summary'] ?? parsed['message'] ?? '').toString().trim();
  if (msg.isNotEmpty) return msg;
  if (n.startsWith('phone_') && parsed['ok'] == true) return '已完成';
  return '';
}

String _prettyFormatJsonIfApplicable(String raw) {
  final trimmed = raw.trim();
  if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
      (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(trimmed));
    } catch (_) {}
  }
  return raw;
}

bool _isMostlyChinese(String text) {
  var cjk = 0;
  var letters = 0;
  var sampled = 0;
  for (final rune in text.runes) {
    if (rune >= 0x4E00 && rune <= 0x9FFF) {
      cjk++;
      letters++;
    } else if ((rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A)) {
      letters++;
    }
    if (++sampled >= 400 && letters >= 40) break;
  }
  return letters > 0 && (cjk / letters) >= 0.30;
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
    this.onEditTurn,
    this.onRegenerate,
    this.onOpenModelSettings,
    this.onOpenHostSettings,
  });

  final NormalizedTurn turn;
  final VoidCallback onOpenTerminal;
  final bool animateEntrance;
  final ValueChanged<String>? onPrefillPrompt;
  final ValueChanged<NormalizedTurn>? onEditTurn;
  final VoidCallback? onRegenerate;
  final VoidCallback? onOpenModelSettings;
  final VoidCallback? onOpenHostSettings;

  static List<String> _extractModifiedFiles(List<NormalizedStep> steps) {
    final out = <String>[];
    final seen = <String>{};
    for (final s in steps) {
      if (s is! ToolStep || s.status == 'error' || s.status == 'cancelled') continue;
      final n = s.name.toLowerCase();
      final isEdit = n.contains('edit') ||
          n.contains('write') ||
          n.contains('patch') ||
          n.contains('create') ||
          n.contains('replace');
      if (!isEdit) continue;
      final prefix = '${s.name} · ';
      final candidate = s.title.startsWith(prefix)
          ? s.title.substring(prefix.length).trim()
          : s.title.trim();
      if (candidate.isEmpty || candidate.contains(' ') && !candidate.contains('/')) continue;
      if (seen.add(candidate)) out.add(candidate);
    }
    return out;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slice = ref.watch(
      appProvider.select(
        (s) => (
          activeHostId: s.activeHostId,
          sessionRenderGen: s.sessionRenderGen,
          autoFoldSteps: s.autoFoldSteps,
          isExpanded: s.expandedTurnProcessIds.contains(turn.stableKey) ||
              s.expandedTurnProcessIds.contains(turn.turnId),
          isCollapsed: s.collapsedTurnProcessIds.contains(turn.stableKey) ||
              s.collapsedTurnProcessIds.contains(turn.turnId),
          canTranslateCot: s.connectionPhase == ConnectionPhase.connected,
          glassTier: s.glassTier,
          feedback: s.turnFeedback.isEmpty || s.activeSessionId == null
              ? null
              : (s.turnFeedback['${s.activeHostId}:${s.activeSessionId}:${turn.assistantMessageId ?? turn.turnId}'] ??
                  s.turnFeedback['${s.activeHostId}:${s.activeSessionId}:${turn.turnId}'] ??
                  s.turnFeedback['${s.activeSessionId}:${turn.assistantMessageId ?? turn.turnId}'] ??
                  s.turnFeedback['${s.activeSessionId}:${turn.turnId}']),
          isCreatingSession: turn.isStreaming ? s.isCreatingSession : false,
          sendStage: turn.isStreaming ? s.sendStage : SendStage.idle,
          uploadDoneCount: turn.isStreaming ? s.uploadDoneCount : 0,
          uploadTotalCount: turn.isStreaming ? s.uploadTotalCount : 0,
          streamStalled: turn.isStreaming ? s.streamStalled : false,
        ),
      ),
    );
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    // Smooth iOS 26 / Claude-style lifecycle with hysteresis: stay open while actively reasoning
    // or executing tools, and wait until the answer clearly establishes (>= 60 chars or paragraph
    // break) before auto-folding so short pre-tool narrations never flap the accordion!
    // Never auto-fold cancelled turns so users can still inspect partial thinking/steps.
    final hasLiveRunningTool = turn.steps.any((s) => s is ToolStep && s.status == 'running');
    final answerEstablished =
        turn.assistantText.length >= 60 || turn.assistantText.contains('\n\n');
    final isCancelledTurn = turn.status == 'cancelled' || turn.status == 'interrupted';
    final processOpen = turn.isStreaming
        ? (answerEstablished && !hasLiveRunningTool && slice.autoFoldSteps
            ? slice.isExpanded
            : !slice.isCollapsed)
        : (isCancelledTurn
            ? !slice.isCollapsed
            : (slice.autoFoldSteps ? slice.isExpanded : !slice.isCollapsed));
    final effectiveRegenerate = onRegenerate ??
        (turn.userMessage != null
            ? () {
                final turns = ref.read(appProvider).turns;
                final isEarlierTurn = turns.length > 1 &&
                    turns.last.turnId != turn.turnId &&
                    turns.last.stableKey != turn.stableKey;
                unawaited(
                  ctrl.regenerateOrRetryTurn(
                    turn,
                    forkBefore: isEarlierTurn && !turn.hasError,
                  ),
                );
              }
            : null);
    final effectiveEditTurn = turn.userMessage != null && turn.userMessage!.text.trim().isNotEmpty
        ? () {
            if (onEditTurn != null) {
              onEditTurn!(turn);
            } else {
              onPrefillPrompt?.call(turn.userMessage!.text);
            }
          }
        : null;

    final visibleProcessSteps = turn.steps
        .where((s) => !(s is NoticeStep && s.level == 'error'))
        .toList(growable: false);
    final completedToolCount = visibleProcessSteps.whereType<ToolStep>().length;
    final modifiedFiles = turn.isStreaming
        ? const <String>[]
        : _extractModifiedFiles(visibleProcessSteps);
    final isExplicitlyCancelled = !turn.isStreaming &&
        (turn.status == 'cancelled' || turn.status == 'interrupted') &&
        !turn.hasError;
    final isEmptyStoppedTurn = !turn.isStreaming &&
        !turn.hasError &&
        turn.assistantText.isEmpty &&
        turn.deliverables.isEmpty &&
        visibleProcessSteps.isEmpty &&
        turn.userMessage != null;
    final showCancelledRow = (isExplicitlyCancelled &&
            turn.assistantText.isEmpty &&
            turn.deliverables.isEmpty &&
            turn.userMessage != null) ||
        isEmptyStoppedTurn;
    final showCancelledPartialBadge = isExplicitlyCancelled &&
        (turn.assistantText.isNotEmpty || turn.deliverables.isNotEmpty);

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (turn.userMessage != null)
          RepaintBoundary(
            child: _UserMessageBlock(
              msg: turn.userMessage!,
              onCopy: () {
                Clipboard.setData(ClipboardData(text: turn.userMessage!.text));
              },
              onPrefillPrompt: effectiveEditTurn != null ? (_) => effectiveEditTurn() : onPrefillPrompt,
            ),
          ),
        if (visibleProcessSteps.isNotEmpty) ...[
          const SizedBox(height: 16),
          RepaintBoundary(
            child: _TurnProcessBlock(
              turn: turn,
              visibleSteps: visibleProcessSteps,
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
            sendStage: slice.sendStage,
            uploadDone: slice.uploadDoneCount,
            uploadTotal: slice.uploadTotalCount,
            startedAtMs: turn.userMessage?.createdAt,
          ),
        ],
        if (turn.isStreaming && slice.streamStalled) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: GrassBagSpringTap(
              pressedScale: 0.95,
              haptic: true,
              onTap: () => unawaited(ctrl.syncStalledStream()),
              child: GrassBagFresnelGlassSurface(
                isPill: true,
                innerWell: true,
                tintColor: t.warnSoft,
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.arrow_2_circlepath, size: 12.5, color: t.warn),
                    const SizedBox(width: 5),
                    Text(
                      '响应较慢 · 点击同步状态',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: t.warn,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        if (showCancelledRow) ...[
          const SizedBox(height: 12),
          Consumer(
            builder: (_, ref, __) {
              final streaming = ref.watch(appProvider.select((s) => s.isStreaming));
              return Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.stop_circle, size: 14, color: t.text3),
                      const SizedBox(width: 6),
                      Text(
                        '已停止生成',
                        style: TextStyle(fontSize: 12.5, color: t.text3),
                      ),
                    ],
                  ),
                  if (effectiveRegenerate != null)
                    GrassBagSpringTap(
                      enabled: !streaming,
                      onTap: effectiveRegenerate,
                      pressedScale: 0.94,
                      child: GrassBagFresnelGlassSurface(
                        isPill: true,
                        innerWell: true,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.arrow_clockwise,
                              size: 11.5,
                              color: streaming ? t.text3.withValues(alpha: 0.45) : t.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '重试',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: streaming ? t.text3.withValues(alpha: 0.45) : t.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (effectiveEditTurn != null)
                    GrassBagSpringTap(
                      enabled: !streaming,
                      onTap: effectiveEditTurn,
                      pressedScale: 0.94,
                      child: GrassBagFresnelGlassSurface(
                        isPill: true,
                        innerWell: true,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.pencil,
                              size: 11.5,
                              color: streaming ? t.text3.withValues(alpha: 0.45) : t.text2,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '编辑修改',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: streaming ? t.text3.withValues(alpha: 0.45) : t.text2,
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
        ],
        if (turn.assistantText.isNotEmpty ||
            turn.deliverables.isNotEmpty ||
            (!turn.isStreaming &&
                visibleProcessSteps.isNotEmpty &&
                !turn.hasError &&
                turn.status != 'cancelled' &&
                turn.status != 'interrupted'))
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: RepaintBoundary(
              child: _AssistantBody(
                turnId: '${slice.activeHostId}:${turn.stableKey}',
                text: turn.assistantText,
                isStreaming: turn.isStreaming,
                deliverables: turn.deliverables,
                modifiedFiles: modifiedFiles,
                completedToolCount: completedToolCount,
                cancelledPartial: showCancelledPartialBadge,
                usage: turn.usage,
                feedback: slice.feedback,
                onCopy: () {
                  Clipboard.setData(ClipboardData(text: turn.assistantText));
                },
                onFork: () => ctrl.forkActiveSession(turnId: turn.turnId),
                onFeedback: (rating) => ctrl.putTurnFeedback(turn.turnId, rating),
                onRegenerate: turn.hasError ? null : effectiveRegenerate,
                onContinue: showCancelledPartialBadge
                    ? () => unawaited(ctrl.continueTurn(turn))
                    : null,
                onDeliverableTap: (item) {
                  final name = (item['name'] ?? '附件').toString();
                  showDeliverablePreviewSheet(
                    context,
                    ref,
                    name: name,
                    path: item['path']?.toString(),
                    subtitle: (item['note'] ?? '生成产物').toString(),
                    sizeLabel: (item['size'] ?? '').toString(),
                  );
                },
              ),
            ),
          ),
        if (turn.hasError) ...[
          const SizedBox(height: 12),
          _TurnErrorCard(
            turn: turn,
            tier: slice.glassTier,
            onCopy: (txt) {
              Clipboard.setData(ClipboardData(text: txt));
            },
            onRetry: effectiveRegenerate,
            onEdit: effectiveEditTurn,
            onOpenModel: () => showModelSheet(
              context,
              ref,
              onOpenModelSettings: onOpenModelSettings,
            ),
            onOpenHost: onOpenHostSettings ??
                () => showHostQuickSheet(
                      context,
                      ref,
                      onOpenHostSettings: onOpenHostSettings,
                    ),
            onSignIn: () => launchDeepSeekSignInFlow(context, ref),
            onCompact: () => unawaited(ctrl.compactContext()),
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
    this.sendStage = SendStage.idle,
    this.uploadDone = 0,
    this.uploadTotal = 0,
    this.startedAtMs,
  });

  final bool isCreatingSession;
  final SendStage sendStage;
  final int uploadDone;
  final int uploadTotal;
  final int? startedAtMs;

  @override
  ConsumerState<_LiveAwaitingResponseRow> createState() => _LiveAwaitingResponseRowState();
}

class _LiveAwaitingResponseRowState extends ConsumerState<_LiveAwaitingResponseRow> {
  Timer? _timer;
  late final ValueNotifier<int> _elapsedTenthsNotifier;
  late final int _originMs;

  void _syncTimer() {
    final active = WidgetsBinding.instance is WidgetsFlutterBinding &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (active) {
      _timer ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!mounted) return;
        final tenths = (DateTime.now().millisecondsSinceEpoch - _originMs) ~/ 100;
        if (tenths != _elapsedTenthsNotifier.value) {
          _elapsedTenthsNotifier.value = tenths;
        }
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now().millisecondsSinceEpoch;
    final started = widget.startedAtMs;
    if (started != null && started > 0 && now - started > 0 && now - started < 3600 * 1000) {
      _originMs = started;
      _elapsedTenthsNotifier = ValueNotifier<int>((now - started) ~/ 100);
    } else {
      _originMs = now;
      _elapsedTenthsNotifier = ValueNotifier<int>(0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _elapsedTenthsNotifier.dispose();
    super.dispose();
  }

  String _phaseLabel(String? livePhase) {
    if (widget.isCreatingSession || widget.sendStage == SendStage.creatingSession) {
      return '正在创建对话并接入工作区…';
    }
    if (widget.sendStage == SendStage.uploadingAttachments) {
      if (widget.uploadTotal > 1) {
        return '正在上传附件 (${widget.uploadDone}/${widget.uploadTotal})…';
      }
      return '正在上传附件…';
    }
    if (widget.sendStage == SendStage.sending) {
      return '正在发送消息…';
    }
    final p = (livePhase ?? '').toLowerCase();
    if (p.contains('reason') || p.contains('think')) return '正在深度思考…';
    if (p.contains('tool')) return '正在准备执行工具…';
    if (p.contains('stream') || p.contains('text') || p.contains('answer')) return '正在组织回复…';
    return '已发送，等待模型响应…';
  }

  @override
  Widget build(BuildContext context) {
    final livePhase = ref.watch(appProvider.select((s) => s.sessionTelemetry.livePhase));
    final t = GrassBagTokens.of(context);
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
            child: GrassBagShimmerText(
              _phaseLabel(livePhase),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: t.text2,
              ),
            ),
          ),
          ValueListenableBuilder<int>(
            valueListenable: _elapsedTenthsNotifier,
            builder: (_, tenths, __) {
              if (tenths < 3) return const SizedBox.shrink();
              return Text(
                '${(tenths * 0.1).toStringAsFixed(1)}s',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: t.text3,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _UserMessageBlock extends StatefulWidget {
  const _UserMessageBlock({
    required this.msg,
    required this.onCopy,
    this.onPrefillPrompt,
  });

  final NormalizedUserMessage msg;
  final VoidCallback onCopy;
  final ValueChanged<String>? onPrefillPrompt;

  @override
  State<_UserMessageBlock> createState() => _UserMessageBlockState();
}

class _UserMessageBlockState extends State<_UserMessageBlock> {
  bool _hovered = false;
  bool _actionsFocused = false;
  bool _copied = false;
  bool _secretRevealed = false;
  bool _longExpanded = false;

  String? _formatTime(int? ms) {
    if (ms == null || ms <= 0) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    final diffDays = today.difference(msgDay).inDays;
    if (diffDays == 0) return '$hh:$mm';
    if (diffDays == 1) return '昨天 $hh:$mm';
    if (dt.year == now.year) return '${dt.month}月${dt.day}日 $hh:$mm';
    return '${dt.year}/${dt.month}/${dt.day} $hh:$mm';
  }

  void _handleCopy() {
    widget.onCopy();
    if (!_copied) {
      setState(() => _copied = true);
      Future<void>.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _copied = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final timeStr = _formatTime(widget.msg.createdAt);
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);

    final ambientTier = resolveAmbientGlassTier(context);
    final isSolid = ambientTier == GrassBagGlassTier.solid;
    const bubbleRadius = BorderRadius.only(
      topLeft: Radius.circular(22),
      topRight: Radius.circular(22),
      bottomLeft: Radius.circular(22),
      bottomRight: Radius.circular(7),
    );
    final bubbleBox = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: t.isDark
              ? [
                  Color.lerp(t.userBubble, Colors.white, 0.10)!
                      .withValues(alpha: isSolid ? 1.0 : 0.88),
                  t.userBubble.withValues(alpha: isSolid ? 1.0 : 0.80),
                ]
              : [
                  Color.lerp(t.userBubble, Colors.white, 0.28)!
                      .withValues(alpha: isSolid ? 1.0 : 0.90),
                  t.userBubble.withValues(alpha: isSolid ? 1.0 : 0.80),
                ],
        ),
        borderRadius: bubbleRadius,
        border: isSolid
            ? Border.all(
                color: t.isDark
                    ? Colors.white.withValues(alpha: 0.10)
                    : t.sep,
                width: 0.75,
              )
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: t.isDark ? 0.28 : 0.065),
            blurRadius: 15,
            offset: const Offset(0, 4.5),
          ),
        ],
      ),
      child: _UserMessageContent(
        msg: widget.msg,
        revealed: _secretRevealed,
        onToggleReveal: () => setState(() => _secretRevealed = !_secretRevealed),
        longExpanded: _longExpanded,
        onToggleLongExpand: () => setState(() => _longExpanded = !_longExpanded),
      ),
    );
    final bubble = Material(
      type: MaterialType.transparency,
      child: isSolid
          ? bubbleBox
          : CustomPaint(
              foregroundPainter: GrassBagFresnelRimPainter(
                isDark: t.isDark,
                customBorderRadius: bubbleRadius,
                accent: t.primaryHi,
                frosted: ambientTier == GrassBagGlassTier.frosted,
                strokeWidth: 0.95,
              ),
              child: bubbleBox,
            ),
    );

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
              SelectionArea(
                contextMenuBuilder: buildGrassBagSelectableContextMenu,
                child: bubble,
              ),
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
                    Focus(
                      canRequestFocus: false,
                      onFocusChange: (focused) {
                        if (_actionsFocused != focused) {
                          setState(() => _actionsFocused = focused);
                        }
                      },
                      child: () {
                        final iconColor = isDesktop ? t.text3 : t.text3.withValues(alpha: 0.78);
                        final row = Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (timeStr != null) const SizedBox(width: 4),
                            if (widget.msg.text.isNotEmpty)
                              Tooltip(
                                message: _copied ? '已复制' : '复制消息',
                                child: FocusableActionDetector(
                                  shortcuts: const {
                                    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                                    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
                                  },
                                  actions: {
                                    ActivateIntent: CallbackAction<ActivateIntent>(
                                      onInvoke: (_) {
                                        _handleCopy();
                                        return null;
                                      },
                                    ),
                                  },
                                  child: GrassBagSpringTap(
                                    onTap: _handleCopy,
                                    pressedScale: 0.9,
                                    haptic: true,
                                    child: SizedBox(
                                      width: 36,
                                      height: 32,
                                      child: Center(
                                        child: Icon(
                                          _copied
                                              ? CupertinoIcons.checkmark
                                              : CupertinoIcons.doc_on_doc,
                                          size: 13.5,
                                          color: _copied ? t.ok : iconColor,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (widget.onPrefillPrompt != null && widget.msg.text.trim().isNotEmpty)
                              Consumer(
                                builder: (_, ref, __) {
                                  final streaming =
                                      ref.watch(appProvider.select((s) => s.isStreaming));
                                  return Tooltip(
                                    message: streaming ? '生成中暂不可编辑重发' : '编辑重发',
                                    child: FocusableActionDetector(
                                      enabled: !streaming,
                                      shortcuts: const {
                                        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                                        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
                                      },
                                      actions: {
                                        ActivateIntent: CallbackAction<ActivateIntent>(
                                          onInvoke: (_) {
                                            if (!streaming) {
                                              widget.onPrefillPrompt!(widget.msg.text);
                                            }
                                            return null;
                                          },
                                        ),
                                      },
                                      child: GrassBagSpringTap(
                                        enabled: !streaming,
                                        onTap: () {
                                          if (!streaming) {
                                            widget.onPrefillPrompt!(widget.msg.text);
                                          }
                                        },
                                        pressedScale: 0.9,
                                        haptic: true,
                                        child: SizedBox(
                                          width: 36,
                                          height: 32,
                                          child: Center(
                                            child: Icon(
                                              CupertinoIcons.pencil,
                                              size: 13.5,
                                              color: streaming
                                                  ? iconColor.withValues(alpha: 0.35)
                                                  : iconColor,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        );
                        if (!isDesktop) return row;
                        return AnimatedOpacity(
                          opacity: (_hovered || _copied || _actionsFocused) ? 1.0 : 0.0,
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
    required this.longExpanded,
    required this.onToggleLongExpand,
  });

  final NormalizedUserMessage msg;
  final bool revealed;
  final VoidCallback onToggleReveal;
  final bool longExpanded;
  final VoidCallback onToggleLongExpand;

  static int _countLines(String s) {
    var count = 1;
    for (var i = 0; i < s.length; i++) {
      if (s.codeUnitAt(i) == 0x0A) count++;
    }
    return count;
  }

  static String _formatBytes(num? raw) {
    if (raw == null || raw <= 0) return '';
    final b = raw.toDouble();
    if (b < 1024) return '${b.round()} B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static IconData _fileIconFor(String name, String mime) {
    final lower = name.toLowerCase();
    if (mime.startsWith('image/')) return CupertinoIcons.photo_fill;
    if (lower.endsWith('.pdf')) return CupertinoIcons.doc_richtext;
    if (lower.endsWith('.zip') || lower.endsWith('.tar') || lower.endsWith('.gz')) {
      return CupertinoIcons.archivebox_fill;
    }
    if (lower.endsWith('.dart') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.js') ||
        lower.endsWith('.py') ||
        lower.endsWith('.json') ||
        lower.endsWith('.yaml') ||
        lower.endsWith('.yml') ||
        lower.endsWith('.md')) {
      return CupertinoIcons.doc_text_fill;
    }
    return CupertinoIcons.doc_fill;
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final hasAttachments = msg.attachments.isNotEmpty;
    final hasReferences = msg.references.isNotEmpty;
    final lineCount = _countLines(msg.text);
    final isLongMessage = lineCount > 10 || msg.text.length > 620;
    final expandLabel = longExpanded
        ? '收起内容'
        : (lineCount > 7 ? '展开全部（共 $lineCount 行）' : '展开全部（共 ${msg.text.length} 字）');

    Widget buildExpandToggle() {
      return SelectionContainer.disabled(
        child: GrassBagSpringTap(
          onTap: onToggleLongExpand,
          pressedScale: 0.95,
          enablePointerGlow: false,
          haptic: true,
          child: GrassBagFresnelGlassSurface(
            isPill: true,
            innerWell: true,
            interactive: true,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  expandLabel,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: t.primary,
                  ),
                ),
                const SizedBox(width: 3),
                Icon(
                  longExpanded ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down,
                  size: 11,
                  color: t.primary,
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget buildTextWidget() {
      if (msg.maskedRanges.isEmpty) {
        if (!isLongMessage) {
          return Text(
            msg.text,
            style: TextStyle(fontSize: 14.5, height: 1.55, letterSpacing: -0.1, color: t.text),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topLeft,
              child: Text(
                msg.text,
                maxLines: longExpanded ? null : 7,
                overflow: longExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14.5, height: 1.55, letterSpacing: -0.1, color: t.text),
              ),
            ),
            const SizedBox(height: 6),
            buildExpandToggle(),
          ],
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: GrassBagSpringTap(
                onTap: onToggleReveal,
                pressedScale: 0.94,
                enablePointerGlow: false,
                haptic: true,
                child: GrassBagFresnelGlassSurface(
                  borderRadius: 8,
                  innerWell: true,
                  interactive: true,
                  tintColor: t.primarySoft,
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
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
          ),
        );
        cursor = end;
      }
      if (cursor < msg.text.length) {
        spans.add(TextSpan(text: msg.text.substring(cursor)));
      }
      final richText = Text.rich(
        TextSpan(
          style: TextStyle(fontSize: 14.5, height: 1.55, letterSpacing: -0.1, color: t.text),
          children: spans,
        ),
      );
      if (!isLongMessage) return richText;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topLeft,
            child: longExpanded
                ? richText
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 168),
                    child: ClipRect(
                      child: ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (bounds) => const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.white, Colors.white, Colors.transparent],
                          stops: [0.0, 0.72, 1.0],
                        ).createShader(bounds),
                        child: SingleChildScrollView(
                          physics: const NeverScrollableScrollPhysics(),
                          child: richText,
                        ),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 6),
          buildExpandToggle(),
        ],
      );
    }

    if (!hasAttachments && !hasReferences) return buildTextWidget();

    ({Uint8List? bytes, String? payload, String? cacheKey}) resolveAttImage(
      Map<String, dynamic> att,
    ) {
      final rawBytes = att['bytes'];
      if (rawBytes is Uint8List && rawBytes.isNotEmpty) {
        return (bytes: rawBytes, payload: null, cacheKey: null);
      }
      final b64 = (att['data'] ?? att['base64'])?.toString().trim() ?? '';
      if (b64.isEmpty) return (bytes: null, payload: null, cacheKey: null);
      final comma = b64.indexOf(',');
      final payload = (b64.startsWith('data:') && comma > 0) ? b64.substring(comma + 1) : b64;
      final payloadLen = payload.length;
      final midStart = payloadLen > 48 ? (payloadLen ~/ 2) - 12 : 0;
      final tailStart = payloadLen > 24 ? payloadLen - 24 : 0;
      final cacheKey =
          '$payloadLen:${payload.substring(0, math.min(24, payloadLen))}:${payload.substring(midStart, math.min(midStart + 24, payloadLen))}:${payload.substring(tailStart)}';
      final cached = _getCachedAttachmentBytes(cacheKey);
      if (cached != null) {
        return (bytes: cached, payload: null, cacheKey: cacheKey);
      }
      if (payloadLen <= _kAsyncDecodeThresholdChars) {
        final decoded = _decodeBase64Payload(payload);
        if (decoded.isEmpty) return (bytes: null, payload: null, cacheKey: null);
        _putCachedAttachmentBytes(cacheKey, decoded);
        return (bytes: decoded, payload: null, cacheKey: cacheKey);
      }
      return (bytes: null, payload: payload, cacheKey: cacheKey);
    }

    final thumbCachePx = (76 * MediaQuery.devicePixelRatioOf(context)).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasAttachments)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final att in msg.attachments)
                Builder(
                  builder: (ctx) {
                    final name = (att['name'] ?? att['filename'] ?? '附件').toString();
                    final mime = att['mimeType']?.toString() ?? '';
                    final sizeStr = _formatBytes(att['size'] as num?);
                    final isImg = mime.startsWith('image/') || att['type']?.toString() == 'image';
                    final resolved = isImg
                        ? resolveAttImage(att)
                        : (bytes: null, payload: null, cacheKey: null);
                    final imgBytes = resolved.bytes;
                    final imgPayload = resolved.payload;
                    final imgCacheKey = resolved.cacheKey;
                    final imgUrl = isImg
                        ? (att['url'] ?? att['previewUrl'] ?? att['src'] ?? att['uri'])
                            ?.toString()
                            .trim()
                        : null;
                    if (imgPayload != null && imgCacheKey != null) {
                      return _AsyncAttachmentThumb(
                        cacheKey: imgCacheKey,
                        payload: imgPayload,
                        title: name,
                        thumbCachePx: thumbCachePx,
                      );
                    }
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
                    final attPath = (att['path'] ?? att['workspacePath'])?.toString().trim() ?? '';
                    final chip = Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5),
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
                          Icon(_fileIconFor(name, mime), size: 12.5, color: t.primary),
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
                          if (sizeStr.isNotEmpty) ...[
                            const SizedBox(width: 5),
                            Text(
                              sizeStr,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontFeatures: const [FontFeature.tabularFigures()],
                                color: t.text3,
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                    if (attPath.isNotEmpty) {
                      return GrassBagSpringTap(
                        onTap: () => showWorkspaceFilePreviewSheet(ctx, path: attPath, title: name),
                        pressedScale: 0.95,
                        child: chip,
                      );
                    }
                    return chip;
                  },
                ),
            ],
          ),
        if (hasReferences) ...[
          if (hasAttachments) const SizedBox(height: 6),
          SelectionContainer.disabled(
            child: Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final refItem in msg.references)
                  () {
                    final kind = (refItem['kind'] ?? refItem['type'] ?? 'file').toString();
                    final path = (refItem['path'] ?? refItem['value'] ?? refItem['id'] ?? '').toString().trim();
                    final label = (refItem['label'] ?? refItem['name'] ?? path).toString().trim();
                    if (label.isEmpty) return const SizedBox.shrink();
                    final isSession = kind == 'session';
                    final baseLabel = !isSession && label.contains('/')
                        ? (label.split('/').where((s) => s.isNotEmpty).lastOrNull ?? label)
                        : label;
                    final pill = Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 3.5),
                      decoration: BoxDecoration(
                        color: t.isDark
                            ? t.primary.withValues(alpha: 0.16)
                            : Colors.white.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: t.primary.withValues(alpha: 0.28),
                          width: 0.6,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isSession ? CupertinoIcons.chat_bubble_text : CupertinoIcons.at,
                            size: 11,
                            color: t.primary,
                          ),
                          const SizedBox(width: 4),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 180),
                            child: Text(
                              baseLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: isSession ? null : 'monospace',
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: t.isDark ? t.primaryHi : t.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                    if (!isSession && path.isNotEmpty) {
                      return GrassBagSpringTap(
                        onTap: () => showWorkspaceFilePreviewSheet(context, path: path, title: baseLabel),
                        pressedScale: 0.95,
                        child: pill,
                      );
                    }
                    return pill;
                  }(),
              ],
            ),
          ),
        ],
        if (msg.text.isNotEmpty) ...[
          const SizedBox(height: 8),
          buildTextWidget(),
        ],
      ],
    );
  }
}

/// Tiny isolated live tabular elapsed timer (`0.4s`, `12s`) that pauses off-route & in tests.
class _LiveElapsedClock extends StatefulWidget {
  const _LiveElapsedClock({
    this.startedAtMs,
    this.style,
    this.minTenths = 3,
  });

  final int? startedAtMs;
  final TextStyle? style;
  final int minTenths;

  @override
  State<_LiveElapsedClock> createState() => _LiveElapsedClockState();
}

class _LiveElapsedClockState extends State<_LiveElapsedClock> {
  Timer? _timer;
  int _elapsedTenths = 0;
  late final int _originMs;

  void _syncTimer() {
    final active = WidgetsBinding.instance is WidgetsFlutterBinding &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (active) {
      _timer ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        final tenths = (DateTime.now().millisecondsSinceEpoch - _originMs) ~/ 100;
        if (tenths != _elapsedTenths) {
          setState(() => _elapsedTenths = tenths);
        }
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now().millisecondsSinceEpoch;
    final started = widget.startedAtMs;
    if (started != null && started > 0 && now - started >= 0 && now - started < 3600 * 1000) {
      _originMs = started;
      _elapsedTenths = (now - started) ~/ 100;
    } else {
      _originMs = now;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_elapsedTenths < widget.minTenths) return const SizedBox.shrink();
    final t = GrassBagTokens.of(context);
    final label = _elapsedTenths >= 100
        ? '${_elapsedTenths ~/ 10}s'
        : '${(_elapsedTenths * 0.1).toStringAsFixed(1)}s';
    return Text(
      label,
      style: widget.style ??
          TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: t.text3,
          ),
    );
  }
}

/// Tiny isolated consumer for live phase + concrete tool target + rounded t/s so speed ticks
/// NEVER rebuild the entire TurnView!
class _LiveProcessSummaryText extends ConsumerWidget {
  const _LiveProcessSummaryText({
    required this.runningTool,
    required this.runningToolCount,
    required this.hasAssistantText,
    required this.hasReasoning,
  });

  final ToolStep? runningTool;
  final int runningToolCount;
  final bool hasAssistantText;
  final bool hasReasoning;

  static String _shortTargetFor(ToolStep tool) {
    final raw = _humanizeToolDisplayTitle(tool).trim();
    final humanName = _humanizeToolName(tool.name).trim();
    if (raw.isEmpty || raw == humanName || raw.toLowerCase() == tool.name.toLowerCase()) {
      return '';
    }
    if (raw.contains('/')) {
      final segs = raw.split('/').where((s) => s.isNotEmpty).toList();
      if (segs.isNotEmpty) {
        final tail = segs.last;
        return tail.length > 26 ? '${tail.substring(0, 25)}…' : tail;
      }
    }
    return raw.length > 26 ? '${raw.substring(0, 25)}…' : raw;
  }

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
    final isToolPhase = runningTool != null || p.contains('tool');
    // Never show bogus frozen LLM decode t/s while executing a shell/file tool!
    final speed = (!isToolPhase && live.tpsRounded != null) ? ' · ${live.tpsRounded} t/s' : '';
    final String summaryText;
    if (runningTool != null) {
      final verb = _humanizeToolName(runningTool!.name);
      final target = _shortTargetFor(runningTool!);
      if (runningToolCount > 1) {
        summaryText = target.isNotEmpty
            ? '正在并行执行 $runningToolCount 项操作 · $target'
            : '正在并行执行 $runningToolCount 项操作…';
      } else {
        summaryText = target.isNotEmpty ? '正在$verb $target' : '正在$verb…';
      }
    } else if (p.contains('stream') || p.contains('text') || p.contains('answer') || hasAssistantText) {
      summaryText = '正在生成回复$speed';
    } else if (p.contains('reason') || p.contains('think') || hasReasoning) {
      summaryText = '正在深度思考…$speed';
    } else {
      summaryText = '正在思考与执行步骤…$speed';
    }
    return GrassBagShimmerText(
      summaryText,
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
    required this.visibleSteps,
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
  final List<NormalizedStep> visibleSteps;
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
    var cancelledTools = 0;
    var runningToolCount = 0;
    ToolStep? runningTool;
    for (final s in visibleSteps) {
      if (s is ToolStep) {
        toolCount++;
        if (s.status == 'running') {
          runningTool = s;
          runningToolCount++;
        }
        if (s.status == 'error') errTools++;
        if (s.status == 'cancelled') cancelledTools++;
      } else if (s is ReasoningStep) {
        reasonCount++;
      }
    }
    final isCancelledTurn = !turn.isStreaming &&
        (turn.status == 'cancelled' || turn.status == 'interrupted') &&
        !turn.hasError;
    final durSec = turn.usage?.durationMs != null
        ? '${(turn.usage!.durationMs! / 1000).toStringAsFixed(1)}s'
        : null;
    final settledSummaryText = () {
      final bits = <String>[];
      if (isCancelledTurn) {
        bits.add('已停止');
      }
      if (durSec != null) {
        bits.add('耗时 $durSec');
      } else if (reasonCount > 0 && !isCancelledTurn) {
        bits.add('已思考');
      } else if (reasonCount > 0 && toolCount == 0) {
        bits.add('思考已中断');
      }
      if (toolCount > 0) bits.add('$toolCount 项操作');
      if (errTools > 0) bits.add('$errTools 项异常');
      if (cancelledTools > 0 && errTools == 0 && !isCancelledTurn) bits.add('已中断');
      if (bits.isEmpty) {
        return turn.hasError ? '执行遇到错误' : '执行过程 (${visibleSteps.length})';
      }
      return bits.join(' · ');
    }();

    // Only the very last non-narration ReasoningStep is actively thinking when no tool is
    // running and answer text hasn't started yet — prevents stacked pulsing boxes on multi-step turns!
    final lastVisibleStep = visibleSteps.isNotEmpty ? visibleSteps.last : null;

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
                                : (isCancelledTurn
                                    ? CupertinoIcons.stop_circle
                                    : CupertinoIcons.sparkles),
                            size: 15.5,
                            color: errTools > 0 || turn.hasError
                                ? t.err
                                : (isCancelledTurn ? t.text3 : t.primary),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: turn.isStreaming
                      ? _LiveProcessSummaryText(
                          runningTool: runningTool,
                          runningToolCount: runningToolCount,
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
                if (turn.isStreaming) ...[
                  const SizedBox(width: 6),
                  _LiveElapsedClock(startedAtMs: turn.userMessage?.createdAt),
                  const SizedBox(width: 6),
                ],
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
        // Explicit toggle-only disclosure: glides smoothly open on live first step mount without
        // fighting inner thinking/tool resizes once settled open.
        _SmoothDisclosure(
          expanded: open,
          animateOnMount: turn.isStreaming,
          builder: () => CustomPaint(
            painter: _StreamThreadRailPainter(color: t.sepStrong),
            child: Padding(
              padding: const EdgeInsets.only(left: 26, top: 4, bottom: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final step in visibleSteps)
                    if (step is ReasoningStep)
                      _ThinkingStepRow(
                        key: ValueKey('reason-${step.id}'),
                        step: step,
                        canTranslate: canTranslateCot && !turn.isStreaming,
                        isStreaming: turn.isStreaming,
                        isActivelyThinking: turn.isStreaming &&
                            runningTool == null &&
                            turn.assistantText.isEmpty &&
                            identical(step, lastVisibleStep) &&
                            !step.id.startsWith('narration-'),
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
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: GrassBagFresnelGlassSurface(
                          borderRadius: 13,
                          innerWell: true,
                          tintColor: step.level == 'warn' ? t.warnSoft : null,
                          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                          child: Text(
                            step.text,
                            style: TextStyle(
                              fontSize: 12,
                              color: step.level == 'warn' ? t.warn : t.text2,
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Toggle-only smooth disclosure (`SizeTransition` + `FadeTransition`).
/// Unlike `AnimatedSize`, once settled open (`controller.isCompleted`) it renders the
/// child directly with zero implicit size-change re-animations, completely eliminating
/// nested rubber-band jitter when streaming or toggling inner thinking/tool rows.
class _SmoothDisclosure extends StatefulWidget {
  const _SmoothDisclosure({
    required this.expanded,
    required this.builder,
    this.animateOnMount = false,
  });

  final bool expanded;
  final Widget Function() builder;
  final bool animateOnMount;

  @override
  State<_SmoothDisclosure> createState() => _SmoothDisclosureState();
}

class _SmoothDisclosureState extends State<_SmoothDisclosure>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _sizeAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    final startCollapsed = widget.animateOnMount && widget.expanded;
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 170),
      value: startCollapsed ? 0.0 : (widget.expanded ? 1.0 : 0.0),
    )..addStatusListener(_onStatus);
    _sizeAnim = CurvedAnimation(
      parent: _ctrl,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _fadeAnim = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.10, 1.0, curve: Curves.easeOut),
      reverseCurve: const Interval(0.0, 0.72, curve: Curves.easeIn),
    );
    if (startCollapsed) {
      _ctrl.forward();
    }
  }

  void _onStatus(AnimationStatus status) {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _SmoothDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;
    if (widget.expanded) {
      _ctrl.forward();
    } else {
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.removeStatusListener(_onStatus);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.expanded && _ctrl.isDismissed) {
      return const SizedBox.shrink();
    }
    final child = widget.builder();
    final settledOpen = widget.expanded && _ctrl.isCompleted;
    // Keep wrapper topology 100% constant between animating and settled-open so Stateful
    // children (scroll positions, copied states, expanded subtrees) NEVER unmount/remount!
    return ClipRect(
      clipBehavior: settledOpen ? Clip.none : Clip.hardEdge,
      child: FadeTransition(
        opacity: _fadeAnim,
        child: SizeTransition(
          sizeFactor: _sizeAnim,
          axisAlignment: -1.0,
          child: child,
        ),
      ),
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
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shouldRun = WidgetsBinding.instance is WidgetsFlutterBinding &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        !MediaQuery.disableAnimationsOf(context);
    if (shouldRun && !_running) {
      _running = true;
      _ctrl.repeat(reverse: true);
    } else if (!shouldRun && _running) {
      _running = false;
      _ctrl.stop();
    }
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
  final Paint _haloPaint = Paint();
  final Paint _corePaint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final v = Curves.easeInOut.transform(animation.value);
    final dim = math.min(size.width, size.height);
    final scale = (dim / 20.0).clamp(0.55, 1.25);
    final center = Offset(size.width * 0.5, size.height * 0.5);
    _haloPaint.color = color.withValues(alpha: 0.28 * (1.0 - v) + 0.08);
    _corePaint.color = color;
    canvas.drawCircle(center, (5.0 + 4.0 * v) * scale, _haloPaint);
    canvas.drawCircle(center, 3.75 * scale, _corePaint);
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

class _ThinkingStepRow extends ConsumerStatefulWidget {
  const _ThinkingStepRow({
    super.key,
    required this.step,
    required this.canTranslate,
    required this.isStreaming,
    this.isActivelyThinking = false,
    required this.onToggleExpand,
    required this.onToggleTranslate,
  });

  final ReasoningStep step;
  final bool canTranslate;
  final bool isStreaming;
  final bool isActivelyThinking;
  final VoidCallback onToggleExpand;
  final VoidCallback onToggleTranslate;

  @override
  ConsumerState<_ThinkingStepRow> createState() => _ThinkingStepRowState();
}

class _ThinkingStepRowState extends ConsumerState<_ThinkingStepRow> {
  final ScrollController _thinkScrollCtrl = ScrollController();
  bool _userScrolledUp = false;
  bool _scrollScheduled = false;
  int _lastLiveTextLen = 0;
  String? _cachedZhStepId;
  int _cachedZhTextLen = -1;
  bool _cachedMostlyZh = false;

  bool _isStepMostlyChinese(ReasoningStep step) {
    if (_cachedZhStepId == step.id && _cachedZhTextLen == step.text.length) {
      return _cachedMostlyZh;
    }
    _cachedZhStepId = step.id;
    _cachedZhTextLen = step.text.length;
    _cachedMostlyZh = _isMostlyChinese(step.text);
    return _cachedMostlyZh;
  }

  @override
  void didUpdateWidget(covariant _ThinkingStepRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step.id != widget.step.id) {
      _userScrolledUp = false;
      _lastLiveTextLen = 0;
    }
  }

  @override
  void dispose() {
    _thinkScrollCtrl.dispose();
    super.dispose();
  }

  void _openFullscreenThinking(BuildContext context, String text, bool isNarration) {
    showGrassBagSheet<void>(
      context,
      title: isNarration ? '完整说明' : '完整思考过程',
      subtitle: '可长按选取或一键复制',
      icon: isNarration ? CupertinoIcons.text_quote : CupertinoIcons.lightbulb_fill,
      expandable: true,
      bodyBuilder: (ctx) {
        final st = GrassBagTokens.of(ctx);
        final tier = ProviderScope.containerOf(ctx, listen: false).read(appProvider).glassTier;
        final metrics = GrassBagSheetMetrics.maybeOf(ctx);
        final maxH = (metrics != null && metrics.expanded)
            ? math.max(360.0, metrics.maxBodyHeight - 96.0)
            : 380.0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GrassBagFresnelGlassSurface(
              borderRadius: 16,
              innerWell: true,
              padding: const EdgeInsets.all(14),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxH),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: SelectionArea(
                    contextMenuBuilder: buildGrassBagSelectableContextMenu,
                    child: Text(
                      text,
                      style: TextStyle(fontSize: 13, height: 1.62, color: st.text2),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            GrassBagSecondaryGlassButton(
              label: '复制全部内容',
              icon: CupertinoIcons.doc_on_doc,
              height: 40,
              tier: tier,
              insideGlass: true,
              onTap: () {
                Clipboard.setData(ClipboardData(text: text));
                HapticFeedback.selectionClick();
                ProviderScope.containerOf(ctx, listen: false)
                    .read(appProvider.notifier)
                    .showToast('已复制全部内容', tone: ToastTone.ok);
                Navigator.of(ctx).pop();
              },
            ),
          ],
        );
      },
    );
  }

  bool _copied = false;

  void _handleCopyThinking(String text) {
    Clipboard.setData(ClipboardData(text: text));
    if (!_copied) {
      setState(() => _copied = true);
      Future<void>.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _copied = false);
      });
    }
  }

  void _maybeAutoFollowLive(bool isLive, bool showBody, int textLen) {
    if (!isLive || !showBody) {
      _lastLiveTextLen = textLen;
      return;
    }
    if (textLen > _lastLiveTextLen && !_userScrolledUp) {
      _lastLiveTextLen = textLen;
      if (!_scrollScheduled) {
        _scrollScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollScheduled = false;
          if (!mounted || !_thinkScrollCtrl.hasClients || _userScrolledUp) return;
          final max = _thinkScrollCtrl.position.maxScrollExtent;
          if (max > 0 && (max - _thinkScrollCtrl.offset) > 2.0) {
            _thinkScrollCtrl.jumpTo(max);
          }
        });
      }
    } else {
      _lastLiveTextLen = textLen;
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
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
    final isNarration = step.id.startsWith('narration-');
    final isLiveThinking = widget.isActivelyThinking && !isNarration && step.durationMs == null;
    // Show a sleek auto-scrolling 4-line live reasoning viewport ONLY while this exact step
    // is actively thinking — prevents multiple stacked live boxes across multi-step agent turns!
    final showLiveViewport = isLiveThinking && !expanded && bodyText.trim().isNotEmpty;
    final dur = step.durationMs != null
        ? (step.durationMs! < 1000
            ? '${step.durationMs}ms'
            : '${(step.durationMs! / 1000).toStringAsFixed(1)}s')
        : null;
    _maybeAutoFollowLive(isLiveThinking, expanded || showLiveViewport, bodyText.length);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagSpringTap(
          onTap: widget.onToggleExpand,
          pressedScale: 0.985,
          haptic: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: Center(
                    child: isLiveThinking
                        ? _BreathingStatusDot(color: t.primary)
                        : Icon(
                            isNarration ? CupertinoIcons.text_quote : CupertinoIcons.lightbulb,
                            size: 14,
                            color: t.text3,
                          ),
                  ),
                ),
                const SizedBox(width: 6),
                if (isLiveThinking) ...[
                  Text(
                    '思考中',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: t.primary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  _LiveElapsedClock(
                    minTenths: 5,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: t.text3,
                    ),
                  ),
                ] else
                  Text(
                    isNarration
                        ? '说明'
                        : (dur != null ? '思考 $dur' : '思考'),
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
        _SmoothDisclosure(
          expanded: expanded || showLiveViewport,
          animateOnMount: isLiveThinking,
          builder: () {
            final showTranslateBtn = expanded &&
                step.text.isNotEmpty &&
                (effectiveTranslation != null || (widget.canTranslate && !_isStepMostlyChinese(step)));
            // When collapsed & actively streaming thinking, slice ONLY the trailing ~800 chars
            // so TextPainter doesn't re-layout 10,000+ chars on every 42ms token flush!
            String viewportText = bodyText;
            if (showLiveViewport && bodyText.length > 820) {
              var cut = bodyText.length - 800;
              final nl = bodyText.indexOf('\n', cut);
              if (nl >= 0 && nl < bodyText.length - 120) {
                cut = nl + 1;
              }
              viewportText = '…${bodyText.substring(cut)}';
            }
            final rawTextWidget = Text(
              viewportText,
              key: ValueKey('${step.id}-$translated'),
              style: TextStyle(
                fontSize: showLiveViewport ? 12.0 : 12.5,
                height: 1.58,
                color: showLiveViewport ? t.text3 : t.text2,
              ),
            );
            final textNode = showLiveViewport
                ? rawTextWidget
                : SelectionArea(
                    contextMenuBuilder: buildGrassBagSelectableContextMenu,
                    key: ValueKey('${step.id}-$translated'),
                    child: rawTextWidget,
                  );
            final scrollViewport = NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollUpdateNotification && n.dragDetails != null) {
                  final atBottom = (n.metrics.maxScrollExtent - n.metrics.pixels) <= 18.0;
                  _userScrolledUp = !atBottom;
                }
                return false;
              },
              child: SingleChildScrollView(
                controller: _thinkScrollCtrl,
                physics: const BouncingScrollPhysics(),
                child: isLiveThinking
                    ? textNode
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: textNode,
                      ),
              ),
            );
            final thinkTier = resolveAmbientGlassTier(context);
            final thinkSolid = thinkTier == GrassBagGlassTier.solid;
            final thinkBox = AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.all(showLiveViewport ? 10 : 12),
              decoration: ShapeDecoration(
                color: thinkSolid ? t.fill1 : null,
                gradient: thinkSolid
                    ? null
                    : LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: showLiveViewport
                            ? [
                                t.primary.withValues(alpha: t.isDark ? 0.13 : 0.08),
                                (t.isDark ? Colors.white : Colors.white)
                                    .withValues(alpha: t.isDark ? 0.04 : 0.50),
                              ]
                            : (t.isDark
                                ? [
                                    Colors.white.withValues(alpha: 0.085),
                                    Colors.white.withValues(alpha: 0.03),
                                  ]
                                : [
                                    Colors.white.withValues(alpha: 0.68),
                                    Colors.white.withValues(alpha: 0.42),
                                  ]),
                      ),
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(15),
                  side: thinkSolid
                      ? BorderSide(
                          color: showLiveViewport
                              ? t.primary.withValues(alpha: 0.22)
                              : t.sep,
                          width: 0.6,
                        )
                      : BorderSide.none,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    constraints: BoxConstraints(maxHeight: showLiveViewport ? 96 : 280),
                    child: showLiveViewport
                        ? RepaintBoundary(
                            child: ShaderMask(
                              blendMode: BlendMode.dstIn,
                              shaderCallback: (rect) => const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                stops: [0.0, 0.16, 0.86, 1.0],
                                colors: [
                                  Colors.transparent,
                                  Colors.black,
                                  Colors.black,
                                  Colors.transparent,
                                ],
                              ).createShader(rect),
                              child: scrollViewport,
                            ),
                          )
                        : scrollViewport,
                  ),
                  if (expanded) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (showTranslateBtn) ...[
                          GrassBagSpringTap(
                            enabled: !translating,
                            onTap: translating ? () {} : widget.onToggleTranslate,
                            pressedScale: 0.94,
                            haptic: true,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (translating)
                                    GrassBagActivityIndicator(radius: 6, color: t.primary)
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
                          ),
                          const SizedBox(width: 6),
                        ],
                        if (bodyText.trim().isNotEmpty)
                          GrassBagSpringTap(
                            onTap: () => _handleCopyThinking(bodyText),
                            pressedScale: 0.94,
                            haptic: true,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _copied ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
                                    size: 12.5,
                                    color: _copied ? t.ok : t.text3,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _copied ? '已复制' : '复制',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: _copied ? t.ok : t.text3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (bodyText.length > 240 || '\n'.allMatches(bodyText).length >= 8) ...[
                          const SizedBox(width: 6),
                          GrassBagSpringTap(
                            onTap: () => _openFullscreenThinking(context, bodyText, isNarration),
                            pressedScale: 0.94,
                            haptic: true,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    CupertinoIcons.arrow_up_left_arrow_down_right,
                                    size: 11.5,
                                    color: t.primary,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '全屏查看',
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
                ],
              ),
            );
            return Padding(
              padding: const EdgeInsets.only(left: 28, top: 2, bottom: 8),
              child: thinkSolid
                  ? thinkBox
                  : CustomPaint(
                      foregroundPainter: GrassBagFresnelRimPainter(
                        isDark: t.isDark,
                        borderRadius: 15,
                        accent: showLiveViewport ? t.primary : null,
                        innerWell: true,
                        frosted: thinkTier == GrassBagGlassTier.frosted,
                        paintTopSheen: false,
                        strokeWidth: 0.78,
                      ),
                      child: thinkBox,
                    ),
            );
          },
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
  /// Synchronous LRU cache scoped by `(hostId, sessionRenderGen, callId)` so re-mounted or
  /// re-expanded tool cards render full output immediately on frame 0 without cross-host/session bleed.
  static final Map<String, Map<String, dynamic>> _kDetailCache = {};

  Map<String, dynamic>? _detail;
  String _loadedCacheKey = '';
  bool _loading = false;
  bool _loadedOnce = false;
  bool _initialFetchAttempted = false;
  bool _pendingForceReload = false;
  bool _copied = false;
  Timer? _livePollTimer;

  void _syncLivePollTimer(bool expanded, bool isRunning) {
    final shouldPoll = expanded &&
        isRunning &&
        WidgetsBinding.instance is WidgetsFlutterBinding &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (shouldPoll) {
      _livePollTimer ??= Timer.periodic(const Duration(milliseconds: 1500), (_) {
        if (!mounted || widget.step.status != 'running' || !widget.isStreaming) {
          _livePollTimer?.cancel();
          _livePollTimer = null;
          return;
        }
        if (!_loading) {
          _ensureLoaded(forceRefresh: true);
        }
      });
    } else {
      _livePollTimer?.cancel();
      _livePollTimer = null;
    }
  }

  @override
  void dispose() {
    _livePollTimer?.cancel();
    super.dispose();
  }

  // Memoized display labels & JSON summary so streaming flushes run 0 repeated jsonDecodes!
  String? _memoName;
  String? _memoTitle;
  String? _memoSummary;
  String _memoDisplayTitle = '';
  String _memoSummaryPill = '';
  String? _memoFormattedSummaryRaw;
  String _memoFormattedSummary = '';
  Map<String, dynamic>? _memoDiffDetail;
  bool? _memoDiffIsDark;
  ({int added, int removed, String unified})? _memoSynthDiff;
  TextSpan? _memoDiffSpan;

  ({({int added, int removed, String unified})? diff, TextSpan? span}) _resolveMemoizedDiff(
    bool isEdit,
    Map argsMap,
    bool isDark,
  ) {
    if (!isEdit) return (diff: null, span: null);
    if (identical(_memoDiffDetail, _detail) &&
        _memoDiffDetail != null &&
        _memoDiffIsDark == isDark) {
      return (diff: _memoSynthDiff, span: _memoDiffSpan);
    }
    _memoDiffDetail = _detail;
    _memoDiffIsDark = isDark;
    _memoSynthDiff = _synthesizeInlineDiffFromArgs(argsMap);
    _memoDiffSpan = _memoSynthDiff != null
        ? _highlightDiffSpan(_memoSynthDiff!.unified, isDark: isDark)
        : null;
    return (diff: _memoSynthDiff, span: _memoDiffSpan);
  }

  String _formattedSummaryFor(String raw) {
    if (_memoFormattedSummaryRaw == raw) return _memoFormattedSummary;
    _memoFormattedSummaryRaw = raw;
    _memoFormattedSummary = _prettyFormatJsonIfApplicable(raw);
    return _memoFormattedSummary;
  }

  void _syncMemoizedLabels(ToolStep step) {
    if (_memoName == step.name && _memoTitle == step.title && _memoSummary == step.summary) {
      return;
    }
    _memoName = step.name;
    _memoTitle = step.title;
    _memoSummary = step.summary;
    _memoDisplayTitle = _humanizeToolDisplayTitle(step);
    _memoSummaryPill = _humanizeSummaryPill(step);
  }

  String _currentCacheKey() {
    final s = ref.read(appProvider);
    return '${s.activeHostId}:${s.sessionRenderGen}:${widget.step.callId}';
  }

  void _primeFromCache() {
    final key = _currentCacheKey();
    _loadedCacheKey = key;
    final cached = _kDetailCache[key];
    if (cached != null) {
      _detail = cached;
      _loadedOnce = widget.step.status != 'running';
      _initialFetchAttempted = _loadedOnce;
    }
  }

  @override
  void initState() {
    super.initState();
    _primeFromCache();
    if (ref.read(appProvider).expandedStepIds.contains(widget.step.callId) && !_loadedOnce) {
      _ensureLoaded();
    }
  }

  @override
  void didUpdateWidget(covariant _ToolStepRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final expanded = ref.read(appProvider).expandedStepIds.contains(widget.step.callId);
    final nextKey = _currentCacheKey();
    if (oldWidget.step.callId != widget.step.callId || nextKey != _loadedCacheKey) {
      _detail = null;
      _loading = false;
      _loadedOnce = false;
      _initialFetchAttempted = false;
      _pendingForceReload = false;
      _copied = false;
      _primeFromCache();
      if (expanded && !_loadedOnce) {
        _ensureLoaded();
      }
      return;
    }
    final statusChanged = oldWidget.step.status != widget.step.status;
    final settledFromStream = oldWidget.isStreaming && !widget.isStreaming;
    final runningMetaChanged = widget.step.status == 'running' &&
        (oldWidget.step.title != widget.step.title || oldWidget.step.summary != widget.step.summary);
    if (expanded &&
        ((!_loadedOnce && !_initialFetchAttempted) ||
            statusChanged ||
            settledFromStream ||
            runningMetaChanged)) {
      _ensureLoaded(forceRefresh: statusChanged || settledFromStream || runningMetaChanged);
    }
  }

  Future<void> _ensureLoaded({bool forceRefresh = false}) async {
    if (_loading) {
      if (forceRefresh) _pendingForceReload = true;
      return;
    }
    _initialFetchAttempted = true;
    setState(() => _loading = true);
    final callId = widget.step.callId;
    final cacheKey = _currentCacheKey();
    final res = await widget.onLoadToolDetail(callId, forceRefresh: forceRefresh);
    if (!mounted || widget.step.callId != callId || _currentCacheKey() != cacheKey) return;
    if (res.isNotEmpty) {
      _kDetailCache.remove(cacheKey);
      _kDetailCache[cacheKey] = res;
      if (_kDetailCache.length > 128) {
        _kDetailCache.remove(_kDetailCache.keys.first);
      }
    }
    final shouldReload = _pendingForceReload;
    _pendingForceReload = false;
    setState(() {
      if (res.isNotEmpty || _detail == null) {
        _detail = res;
      }
      _loading = false;
      // Never lock `_loadedOnce = true` on an empty 404 while the tool is still running!
      _loadedOnce = widget.step.status != 'running' || res.isNotEmpty;
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
      icon: isErr ? CupertinoIcons.exclamationmark_triangle_fill : CupertinoIcons.doc_plaintext,
      iconColor: isErr ? GrassBagTokens.of(context).err : null,
      expandable: true,
      bodyBuilder: (ctx) {
        final st = GrassBagTokens.of(ctx);
        final tier = ProviderScope.containerOf(ctx, listen: false).read(appProvider).glassTier;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CustomPaint(
              foregroundPainter: tier == GrassBagGlassTier.solid
                  ? null
                  : GrassBagFresnelRimPainter(
                      isDark: st.isDark,
                      borderRadius: 16,
                      accent: isErr ? st.err : (st.isDark ? st.primaryHi : null),
                      innerWell: true,
                      frosted: tier == GrassBagGlassTier.frosted,
                      paintTopSheen: false,
                      strokeWidth: 0.8,
                    ),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 420),
                width: double.infinity,
                padding: const EdgeInsets.all(13),
                decoration: ShapeDecoration(
                  color: st.codeBg,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: tier == GrassBagGlassTier.solid
                        ? BorderSide(
                            color: isErr
                                ? st.err.withValues(alpha: 0.45)
                                : (st.isDark ? Colors.white.withValues(alpha: 0.11) : st.sep),
                            width: 0.75,
                          )
                        : BorderSide.none,
                  ),
                ),
                child: SingleChildScrollView(
                  child: SelectionArea(
                    contextMenuBuilder: buildGrassBagSelectableContextMenu,
                    child: Text(
                      fullOut,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.8,
                        height: 1.52,
                        color: isErr
                            ? (st.isDark ? const Color(0xFFFCA5A5) : st.err)
                            : st.codeFg,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            GrassBagSecondaryGlassButton(
              label: '复制完整输出',
              icon: CupertinoIcons.doc_on_doc,
              height: 40,
              tier: tier,
              insideGlass: true,
              onTap: () {
                Clipboard.setData(ClipboardData(text: fullOut));
                HapticFeedback.selectionClick();
                ProviderScope.containerOf(ctx, listen: false)
                    .read(appProvider.notifier)
                    .showToast('已复制完整输出', tone: ToastTone.ok);
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
    if (expanded && !_loadedOnce && !_initialFetchAttempted && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_loadedOnce && !_initialFetchAttempted && !_loading) {
          _ensureLoaded();
        }
      });
    }
    final t = GrassBagTokens.of(context);
    final step = widget.step;
    final n = step.name.toLowerCase();
    final isTodo = n.contains('todo');
    final isWrite = !isTodo &&
        (n == 'write' || n == 'write_file' || n == 'create_file' || n == 'create');
    final isEdit = !isTodo &&
        (isWrite ||
            n == 'edit' ||
            n == 'edit_file' ||
            n == 'patch' ||
            n == 'apply_patch' ||
            n == 'replace' ||
            n.contains('edit') ||
            n.contains('write'));
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
    final isPhone = n.startsWith('phone_');
    final isErr = step.status == 'error';
    final isCancelled = step.status == 'cancelled';
    final isRunning = widget.isStreaming && step.status == 'running';
    _syncLivePollTimer(expanded, isRunning);

    final IconData icon;
    final String verb;
    if (isPhone) {
      switch (n) {
        case 'phone_tap':
          icon = CupertinoIcons.hand_point_right_fill;
          verb = '点按';
          break;
        case 'phone_long_press':
          icon = CupertinoIcons.hand_draw_fill;
          verb = '长按';
          break;
        case 'phone_swipe':
          icon = CupertinoIcons.arrow_up_arrow_down;
          verb = '滑动';
          break;
        case 'phone_type':
          icon = CupertinoIcons.keyboard;
          verb = '输入';
          break;
        case 'phone_open':
          icon = CupertinoIcons.app_badge;
          verb = '打开';
          break;
        case 'phone_screen':
          icon = CupertinoIcons.viewfinder;
          verb = '识屏';
          break;
        case 'phone_screenshot':
          icon = CupertinoIcons.camera_viewfinder;
          verb = '截屏';
          break;
        case 'phone_apps':
          icon = CupertinoIcons.square_grid_2x2;
          verb = '应用';
          break;
        case 'phone_key':
          icon = CupertinoIcons.return_icon;
          verb = '按键';
          break;
        case 'phone_intent':
          icon = CupertinoIcons.bolt_fill;
          verb = '快捷';
          break;
        case 'phone_wait':
          icon = CupertinoIcons.clock;
          verb = '等待';
          break;
        case 'phone_handoff':
          icon = CupertinoIcons.person_crop_circle_badge_checkmark;
          verb = '接管';
          break;
        case 'phone_return_app':
          icon = CupertinoIcons.arrow_uturn_left_circle;
          verb = '返回';
          break;
        default:
          icon = CupertinoIcons.device_phone_portrait;
          verb = '操控';
          break;
      }
    } else if (isTodo) {
      icon = CupertinoIcons.checkmark_circle;
      verb = '待办';
    } else {
      final isRead = n == 'read' || n == 'read_file' || n.contains('read_file');
      final isDir = n == 'ls' || n == 'list_dir' || n == 'list_directory' || n == 'listdir';
      final isDel = n == 'delete' || n == 'delete_file' || n == 'remove_file' || n == 'rm';
      final isMcp = n.startsWith('mcp__') || n.startsWith('mcp.');
      icon = isDel
          ? CupertinoIcons.trash
          : isEdit
              ? CupertinoIcons.pencil
              : isCmd
                  ? CupertinoIcons.chevron_left_slash_chevron_right
                  : isWeb
                      ? CupertinoIcons.globe
                      : isSubagent
                          ? CupertinoIcons.arrow_branch
                          : isRead
                              ? CupertinoIcons.doc_text
                              : isDir
                                  ? CupertinoIcons.folder
                                  : isMcp
                                      ? CupertinoIcons.cube_box
                                      : CupertinoIcons.search;
      verb = isDel
          ? '删除'
          : isWrite
              ? '写入'
              : (isEdit
                  ? '编辑'
                  : (isCmd
                      ? '执行'
                      : (isWeb
                          ? '联网'
                          : (isSubagent
                              ? '委派'
                              : (isRead
                                  ? '读取'
                                  : (isDir ? '目录' : (isMcp ? 'MCP' : '检索')))))));
    }
    _syncMemoizedLabels(step);
    final rawDisplayTitle = _memoDisplayTitle;
    // Middle-shorten deep file paths so the actual filename is ALWAYS visible instead of ellipsis!
    final displayTitle = () {
      if (rawDisplayTitle.length > 34 && rawDisplayTitle.contains('/')) {
        final segs = rawDisplayTitle.split('/').where((s) => s.isNotEmpty).toList();
        if (segs.length >= 3) {
          final tail2 = '${segs[segs.length - 2]}/${segs.last}';
          if (tail2.length < rawDisplayTitle.length - 3) {
            return '…/$tail2';
          }
        }
      }
      return rawDisplayTitle;
    }();
    final isFileTool = isEdit ||
        isWrite ||
        n == 'read' ||
        n == 'read_file' ||
        n.contains('read_file');
    final summaryPill = _memoSummaryPill;
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
                                color: isErr
                                    ? t.err
                                    : ((isEdit || isPhone) ? t.primary : t.text3),
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
                    ...() {
                      final isRedundantTitle = displayTitle.trim().isEmpty ||
                          displayTitle.trim() == _humanizeToolName(step.name).trim() ||
                          displayTitle.trim().toLowerCase() == step.name.trim().toLowerCase();
                      final shownTitle = isRedundantTitle
                          ? (isRunning ? '准备参数…' : _humanizeToolName(step.name))
                          : displayTitle;
                      return [
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
                            shownTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: (!isRedundantTitle && (isEdit || isCmd)) ? 'monospace' : null,
                              fontSize: 12.5,
                              color: isErr
                                  ? t.err
                                  : (isRedundantTitle && isRunning ? t.text3 : t.text),
                            ),
                          ),
                        ),
                      ];
                    }(),
                    if (isRunning) ...[
                      const SizedBox(width: 6),
                      _LiveElapsedClock(
                        minTenths: 5,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: t.primary,
                        ),
                      ),
                    ] else if (durLabel != null && !isErr && !isCancelled) ...[
                      const SizedBox(width: 6),
                      Text(
                        durLabel,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: t.text3,
                        ),
                      ),
                    ],
                    if (summaryPill.isNotEmpty && !isErr && !isCancelled && !expanded) ...[
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 112),
                        child: () {
                          final isPositiveCmd = isCmd &&
                              (summaryPill.toLowerCase().contains('exit 0') ||
                                  summaryPill.toLowerCase() == 'ok' ||
                                  summaryPill.contains('通过'));
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: isPositiveCmd ? t.okSoft : t.fill1,
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              summaryPill,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: isEdit ? 'monospace' : null,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                fontFeatures: const [FontFeature.tabularFigures()],
                                color: isPositiveCmd ? t.ok : t.text2,
                              ),
                            ),
                          );
                        }(),
                      ),
                    ],
                    if (isCancelled) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: t.fill2,
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                            color: t.isDark ? Colors.white.withValues(alpha: 0.12) : t.sep,
                            width: 0.6,
                          ),
                        ),
                        child: Text(
                          '已中断',
                          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: t.text3),
                        ),
                      ),
                    ] else if (isErr) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: t.errSoft,
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                            color: t.err.withValues(alpha: t.isDark ? 0.36 : 0.26),
                            width: 0.65,
                          ),
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
                      _memoSummaryPill.isNotEmpty ? _memoSummaryPill : step.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.38, color: t.err),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Inline expandable tool parameters + real execution output panel (formatted lazily ONLY when expanded!)
        _SmoothDisclosure(
          expanded: expanded,
          builder: () {
            final argsMap = _detail?['args'] is Map ? _detail!['args'] as Map : const {};
            final rawArgs = (_detail?['argsText']?.toString() ?? '').trim();
            final rawOut = (_detail?['outputText']?.toString() ?? '').trim();
            // loadToolDetail() already pretty-prints JSON; memoize fallback summary formatting.
            final argsText = rawArgs;
            final outputText = rawOut;
            final effectiveOutput = outputText.isNotEmpty
                ? outputText
                : (step.summary.isNotEmpty
                    ? _formattedSummaryFor(step.summary)
                    : (isRunning ? '正在执行中…' : (isCancelled ? '已中断该操作' : '（该操作无额外输出）')));
            final cmdText = (argsMap['command'] ?? argsMap['cmd'])?.toString().trim() ?? '';
            final filePath = (argsMap['file_path'] ??
                    argsMap['filePath'] ??
                    argsMap['path'] ??
                    argsMap['target_file'] ??
                    argsMap['filename'])
                ?.toString()
                .trim() ??
                '';
            final resolvedFilePath = filePath.isNotEmpty
                ? filePath
                : (isFileTool && rawDisplayTitle.isNotEmpty && !rawDisplayTitle.contains(' ')
                    ? rawDisplayTitle
                    : '');
            // Synthesize real inline colored diff directly from edit/write/patch args (memoized by _detail identity!)
            final resolvedDiff = _resolveMemoizedDiff(isEdit, argsMap, t.isDark);
            final synthDiff = resolvedDiff.diff;
            final synthDiffSpan = resolvedDiff.span;
            final synthDiffRecord = (synthDiff != null && resolvedFilePath.isNotEmpty)
                ? WorkspaceDiffRecord(
                    path: resolvedFilePath,
                    summary: '+${synthDiff.added} -${synthDiff.removed}',
                    added: synthDiff.added,
                    removed: synthDiff.removed,
                    unifiedDiff: synthDiff.unified,
                  )
                : null;
            final mutedInk = t.isDark ? const Color(0xFF94A3B8) : t.text3;
            final linkSky = t.isDark ? const Color(0xFF7DD3FC) : t.primary;
            final linkBlue = t.isDark ? const Color(0xFF60A5FA) : t.primary;
            final linkViolet = t.isDark ? const Color(0xFFC4B5FD) : t.dusk;
            final okInk = t.isDark ? const Color(0xFF34D399) : t.ok;
            final errInk = t.isDark ? const Color(0xFFFCA5A5) : t.err;
            final subtleActionInk = t.isDark ? const Color(0xFFCBD5E1) : t.text2;
            final toolTier = resolveAmbientGlassTier(context);
            final toolSolid = toolTier == GrassBagGlassTier.solid;
            final toolBox = Container(
              padding: const EdgeInsets.all(11),
              decoration: ShapeDecoration(
                color: t.codeBg,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: toolSolid
                      ? BorderSide(
                          color: isErr
                              ? t.err.withValues(alpha: 0.45)
                              : (t.isDark ? Colors.white.withValues(alpha: 0.10) : t.sep),
                          width: 0.65,
                        )
                      : BorderSide.none,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_loading && _detail == null)
                    Row(
                      children: [
                        GrassBagActivityIndicator(
                            radius: 7, color: t.isDark ? t.primaryHi : t.primary),
                        const SizedBox(width: 7),
                        Text(
                          '正在加载操作参数与输出…',
                          style: TextStyle(fontSize: 11.5, color: mutedInk),
                        ),
                      ],
                    )
                  else ...[
                    if (cmdText.isNotEmpty) ...[
                      SelectionArea(
                        contextMenuBuilder: buildGrassBagSelectableContextMenu,
                        child: Text(
                          '\$ $cmdText',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.8,
                            fontWeight: FontWeight.w600,
                            height: 1.45,
                            color: linkSky,
                          ),
                        ),
                      ),
                      const SizedBox(height: 7),
                    ] else if (synthDiff != null) ...[
                      Row(
                        children: [
                          Text(
                            '改动预览',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: mutedInk,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (synthDiff.added > 0)
                            Text(
                              '+${synthDiff.added}',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: okInk,
                              ),
                            ),
                          if (synthDiff.added > 0 && synthDiff.removed > 0) const SizedBox(width: 5),
                          if (synthDiff.removed > 0)
                            Text(
                              '-${synthDiff.removed}',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: errInk,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 170),
                        child: SingleChildScrollView(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SelectionArea(
                              contextMenuBuilder: buildGrassBagSelectableContextMenu,
                              child: Text.rich(
                                synthDiffSpan ??
                                    _highlightDiffSpan(synthDiff.unified, isDark: t.isDark),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ] else if (argsText.isNotEmpty) ...[
                      Text(
                        '调用参数 (${step.name})',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: mutedInk,
                        ),
                      ),
                      const SizedBox(height: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 110),
                        child: SingleChildScrollView(
                          child: SelectionArea(
                            contextMenuBuilder: buildGrassBagSelectableContextMenu,
                            child: Text(
                              argsText,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                height: 1.42,
                                color: t.isDark ? const Color(0xFF93C5FD) : const Color(0xFF1B56B5),
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
                        color: isErr ? errInk : mutedInk,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(
                        child: SelectionArea(
                          contextMenuBuilder: buildGrassBagSelectableContextMenu,
                          child: Text(
                            effectiveOutput,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              height: 1.48,
                              color: isErr ? errInk : t.codeFg,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 4,
                      runSpacing: 2,
                      children: [
                        GrassBagSpringTap(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: effectiveOutput));
                            setState(() => _copied = true);
                            Future<void>.delayed(const Duration(milliseconds: 1400), () {
                              if (mounted) setState(() => _copied = false);
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _copied ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
                                  size: 12,
                                  color: _copied ? okInk : mutedInk,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _copied ? '已复制' : '复制输出',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w500,
                                    color: _copied ? okInk : subtleActionInk,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (!_loading &&
                            _initialFetchAttempted &&
                            (_detail == null || _detail!.isEmpty))
                          GrassBagSpringTap(
                            onTap: () => _ensureLoaded(forceRefresh: true),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(CupertinoIcons.refresh, size: 11.5, color: linkBlue),
                                  const SizedBox(width: 4),
                                  Text(
                                    '重试加载',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: linkBlue,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (effectiveOutput.length > 260 ||
                            '\n'.allMatches(effectiveOutput).length >= 10)
                          GrassBagSpringTap(
                            onTap: () => _openFullOutputSheet(
                              context,
                              isCmd: isCmd,
                              isErr: isErr,
                              commandOrTitle: cmdText.isNotEmpty ? cmdText : rawDisplayTitle,
                              fullOut: effectiveOutput,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(CupertinoIcons.arrow_up_left_arrow_down_right,
                                      size: 11.5, color: linkBlue),
                                  const SizedBox(width: 4),
                                  Text(
                                    '全屏查看',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: linkBlue,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (resolvedFilePath.isNotEmpty && !isErr)
                          GrassBagSpringTap(
                            onTap: () => showWorkspaceFilePreviewSheet(
                              context,
                              path: resolvedFilePath,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(CupertinoIcons.doc_text, size: 12, color: linkSky),
                                  const SizedBox(width: 4),
                                  Text(
                                    '查看文件',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: linkSky,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (isEdit && !isErr)
                          GrassBagSpringTap(
                            onTap: () => showDiffSheet(
                              context,
                              resolvedFilePath.isNotEmpty ? resolvedFilePath : rawDisplayTitle,
                              record: synthDiffRecord,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(CupertinoIcons.doc_text_search, size: 12, color: linkBlue),
                                  const SizedBox(width: 4),
                                  Text(
                                    '查看 Diff',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: linkBlue,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (step.subagentSessionId != null && step.subagentSessionId!.isNotEmpty)
                          GrassBagSpringTap(
                            onTap: () =>
                                ref.read(appProvider.notifier).selectSession(step.subagentSessionId!),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(CupertinoIcons.arrow_branch, size: 12, color: linkViolet),
                                  const SizedBox(width: 4),
                                  Text(
                                    '查看子代理',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: linkViolet,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (isCmd)
                          GrassBagSpringTap(
                            onTap: widget.onOpenTerminal,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(CupertinoIcons.chevron_left_slash_chevron_right,
                                      size: 11.5, color: mutedInk),
                                  const SizedBox(width: 4),
                                  Text(
                                    '打开终端',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w500,
                                      color: subtleActionInk,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            );
            return Padding(
              padding: const EdgeInsets.only(left: 28, top: 2, bottom: 8),
              child: toolSolid
                  ? toolBox
                  : CustomPaint(
                      foregroundPainter: GrassBagFresnelRimPainter(
                        isDark: t.isDark,
                        borderRadius: 14,
                        accent: isErr ? t.err : (t.isDark ? t.primaryHi : null),
                        innerWell: true,
                        frosted: toolTier == GrassBagGlassTier.frosted,
                        paintTopSheen: false,
                        strokeWidth: 0.8,
                      ),
                      child: toolBox,
                    ),
            );
          },
        ),
      ],
    );
  }
}

/// Unmistakable, always-visible Turn Error Banner Card matching `@deepseek-ai/dsh-client-ui-chat`'s
/// `turn-error` display — never hidden inside collapsed steps, always selectable & copyable!
class _TurnErrorCard extends StatefulWidget {
  const _TurnErrorCard({
    required this.turn,
    required this.tier,
    required this.onCopy,
    this.onRetry,
    this.onEdit,
    this.onOpenModel,
    this.onOpenHost,
    this.onSignIn,
    this.onCompact,
  });

  final NormalizedTurn turn;
  final GrassBagGlassTier tier;
  final ValueChanged<String> onCopy;
  final VoidCallback? onRetry;
  final VoidCallback? onEdit;
  final VoidCallback? onOpenModel;
  final VoidCallback? onOpenHost;
  final VoidCallback? onSignIn;
  final VoidCallback? onCompact;

  @override
  State<_TurnErrorCard> createState() => _TurnErrorCardState();
}

class _TurnErrorCardState extends State<_TurnErrorCard> {
  bool _showTechDetail = false;
  bool _copied = false;

  void _handleCopy(String payload) {
    widget.onCopy(payload);
    if (!_copied) {
      setState(() => _copied = true);
      Future<void>.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _copied = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final turn = widget.turn;
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
    final classified = GrassBagController.classifyReadableError(rawDetail, code: code);
    final showCompactRawInDefault = _isMostlyChinese(rawDetail);
    final primaryBody = showCompactRawInDefault ? rawDetail : classified.guidance;
    final hasInspectableDetail = copyPayload.isNotEmpty &&
        (copyPayload != primaryBody || (code != null && code.isNotEmpty));

    final isSolid = widget.tier == GrassBagGlassTier.solid;
    final errBody = Container(
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: isSolid ? t.errSoft : null,
        gradient: isSolid
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.lerp(
                    t.errSoft,
                    Colors.white.withValues(alpha: t.errSoft.a),
                    t.isDark ? 0.08 : 0.24,
                  )!,
                  t.errSoft,
                ],
              ),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(20),
          side: isSolid
              ? BorderSide(
                  color: t.err.withValues(alpha: t.isDark ? 0.38 : 0.25),
                  width: 0.8,
                )
              : BorderSide.none,
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
                  classified.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: t.err,
                  ),
                ),
              ),
              if (hasInspectableDetail)
                GrassBagSpringTap(
                  onTap: () => setState(() => _showTechDetail = !_showTechDetail),
                  pressedScale: 0.94,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _showTechDetail ? '收起详情' : '技术详情',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: t.err.withValues(alpha: 0.85),
                          ),
                        ),
                        const SizedBox(width: 3),
                        AnimatedRotation(
                          turns: _showTechDetail ? 0.5 : 0.0,
                          duration: const Duration(milliseconds: 180),
                          child: Icon(
                            CupertinoIcons.chevron_down,
                            size: 11,
                            color: t.err.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          SelectionArea(
            contextMenuBuilder: buildGrassBagSelectableContextMenu,
            child: Text(
              primaryBody,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.48,
                color: t.isDark ? t.text : Color.lerp(t.err, t.text, 0.42)!,
              ),
            ),
          ),
          _SmoothDisclosure(
            expanded: _showTechDetail && hasInspectableDetail,
            builder: () => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 240),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: t.isDark
                      ? Colors.black.withValues(alpha: 0.22)
                      : Colors.white.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: t.err.withValues(alpha: 0.20),
                    width: 0.6,
                  ),
                ),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: SelectionArea(
                    contextMenuBuilder: buildGrassBagSelectableContextMenu,
                    child: Text(
                      copyPayload,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        height: 1.45,
                        color: t.isDark ? t.text2 : Color.lerp(t.err, t.text, 0.30)!,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Consumer(
            builder: (_, ref, __) {
              final streaming = ref.watch(appProvider.select((s) => s.isStreaming));
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (widget.onRetry != null)
                    GrassBagPrimaryGlassButton(
                      label: '重新发送',
                      icon: CupertinoIcons.arrow_clockwise,
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 13),
                      tier: widget.tier,
                      insideGlass: true,
                      enabled: !streaming,
                      color: t.isDark ? const Color(0xFFD94444) : t.err,
                      foregroundColor: Colors.white,
                      onTap: widget.onRetry!,
                    ),
                  if (widget.onEdit != null)
                    GrassBagSecondaryGlassButton(
                      label: '编辑修改',
                      icon: CupertinoIcons.pencil,
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tier: widget.tier,
                      insideGlass: true,
                      enabled: !streaming,
                      onTap: widget.onEdit!,
                    ),
                  if (classified.actionKind == 'signin' && widget.onSignIn != null)
                    GrassBagSecondaryGlassButton(
                      label: '重新登录 DeepSeek',
                      icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tier: widget.tier,
                      insideGlass: true,
                      onTap: widget.onSignIn!,
                    ),
                  if (classified.actionKind == 'host' && widget.onOpenHost != null)
                    GrassBagSecondaryGlassButton(
                      label: '检查主机',
                      icon: CupertinoIcons.antenna_radiowaves_left_right,
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tier: widget.tier,
                      insideGlass: true,
                      onTap: widget.onOpenHost!,
                    ),
                  if (classified.actionKind == 'model' && widget.onOpenModel != null)
                    GrassBagSecondaryGlassButton(
                      label: '切换模型 / 密钥',
                      icon: CupertinoIcons.sparkles,
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tier: widget.tier,
                      insideGlass: true,
                      onTap: widget.onOpenModel!,
                    ),
                  if (classified.actionKind == 'compact' && widget.onCompact != null)
                    GrassBagSecondaryGlassButton(
                      label: '精简上下文',
                      icon: CupertinoIcons.arrow_down_right_arrow_up_left,
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tier: widget.tier,
                      insideGlass: true,
                      enabled: !streaming,
                      onTap: streaming ? null : widget.onCompact!,
                    ),
                  GrassBagSecondaryGlassButton(
                    label: _copied ? '已复制' : '复制报错',
                    icon: _copied ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tier: widget.tier,
                    insideGlass: true,
                    onTap: () => _handleCopy(copyPayload),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
    if (isSolid) return errBody;
    return CustomPaint(
      foregroundPainter: GrassBagFresnelRimPainter(
        isDark: t.isDark,
        borderRadius: 20,
        accent: t.err,
        innerWell: true,
        frosted: widget.tier == GrassBagGlassTier.frosted,
        paintTopSheen: false,
        strokeWidth: 0.85,
      ),
      child: errBody,
    );
  }
}

class _AssistantBody extends StatefulWidget {
  const _AssistantBody({
    required this.turnId,
    required this.text,
    required this.isStreaming,
    required this.deliverables,
    this.modifiedFiles = const [],
    this.completedToolCount = 0,
    this.cancelledPartial = false,
    this.usage,
    this.feedback,
    required this.onCopy,
    required this.onFork,
    required this.onFeedback,
    this.onRegenerate,
    this.onContinue,
    required this.onDeliverableTap,
  });

  final String turnId;
  final String text;
  final bool isStreaming;
  final List<Map<String, dynamic>> deliverables;
  final List<String> modifiedFiles;
  final int completedToolCount;
  final bool cancelledPartial;
  final TurnUsage? usage;
  final String? feedback;
  final VoidCallback onCopy;
  final VoidCallback onFork;
  final ValueChanged<String> onFeedback;
  final VoidCallback? onRegenerate;
  final VoidCallback? onContinue;
  final ValueChanged<Map<String, dynamic>> onDeliverableTap;

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
  // Matches a table separator row mid-stream once at least one `-` cell exists (even with trailing `| ` or `| :`),
  // preventing the table card from violently flickering back to raw pipe text on every column!
  static final RegExp _streamingTableSepPartialRe =
      RegExp(r'^\|?[\s:]*-+[\s:]*(?:\|[\s:\-]*)*$');
  static final RegExp _bulletPattern = RegExp(r'^([-*+•]|\d+[.)])\s+(.+)$');
  static final RegExp _taskPrefixPattern = RegExp(r'^\[([ xX])\]\s+(.*)$');
  static final RegExp _standaloneImageRe =
      RegExp(r'^!\[([^\]]*)\]\((https?://(?:[^\s()]|\([^\s()]*\))+)\)$');
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
  GrassBagGlassTier? _cachedGlassTier;
  final List<_CachedMdBlock> _settledCachedBlocks = [];
  final List<_CachedMdBlock> _tailCachedBlocks = [];
  final Set<int> _streamedBlockIndices = <int>{};
  final List<TapGestureRecognizer> _fallbackRecognizers = [];
  final List<TapGestureRecognizer> _pendingDisposeRecognizers = [];
  bool _pendingDisposeScheduled = false;
  int _settledLen = 0;
  String _settledHeadAnchor = '';
  String _settledTailAnchor = '';
  int _cachedSettledLen = -1;
  int _cachedVisibleLen = -1;
  String? _cachedSourceText;
  String? _cachedTailText;
  int _lastPrefixScanLen = 0;
  bool _animateActionStripEntrance = false;

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
    _cachedVisibleLen = -1;
    _cachedSourceText = null;
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
  Duration? _lastEmitElapsed;
  Ticker? _typeTicker;
  Duration? _lastTickElapsed;

  @override
  void initState() {
    super.initState();
    // Completed historical turns mount at 100% immediately (zero replay!).
    // Streaming turns restore prior progress if remounted after scrolling out & back,
    // and reveal at least 1 character on Frame 0 so the assistant block never collapses to 0px -> 50px.
    if (widget.isStreaming) {
      _animateActionStripEntrance = true;
      final prev = _revealedProgressByTurn[widget.turnId] ?? 0;
      if (prev > 0) {
        _revealedLen = prev.clamp(0, widget.text.length);
      } else if (widget.text.length > 64) {
        // Switching back to an already-populated live stream: snap to the live frontier
        // so users don't watch hundreds of already-generated chars replay from char 1!
        _revealedLen = widget.text.length;
        _rememberRevealed(widget.turnId, _revealedLen);
      } else {
        _revealedLen = _safeInitialReveal(widget.text);
      }
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
        if (prev > 0) {
          _revealedLen = prev.clamp(0, targetLen);
        } else if (targetLen > 64) {
          _revealedLen = targetLen;
          _rememberRevealed(widget.turnId, _revealedLen);
        } else {
          _revealedLen = _safeInitialReveal(widget.text);
        }
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
    final stillRevealingCompletedTail = !widget.isStreaming &&
        !oldWidget.isStreaming &&
        (_typeTicker?.isActive == true) &&
        _revealedLen < targetLen &&
        (oldWidget.text == widget.text || _fastStartsWithPrev(widget.text, oldWidget.text));
    if (!widget.isStreaming && !oldWidget.isStreaming && !stillRevealingCompletedTail) {
      // Static completed turn update -> show immediately (without snapping an active
      // post-turn typewriter catch-up tail during session reconcile!).
      _revealedLen = targetLen;
      _revealedProgressByTurn.remove(widget.turnId);
      _stopTypeTicker();
    } else if (oldWidget.isStreaming && !widget.isStreaming && widget.cancelledPartial) {
      // User tapped Stop -> halt typewriter INSTANTLY instead of drifting another ~300ms!
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
    _lastEmitElapsed = null;
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

    // Adaptive setState pacing: 60Hz (16ms) for prose, 25Hz (40ms) when streaming a large
    // unsettled code block / table tail (>400 chars) so 120Hz phones avoid redundant full-tail re-layout.
    final unsettledLen = _revealedLen - _settledLen;
    final minEmitUs = widget.isStreaming
        ? (unsettledLen > 400 ? 40000 : 15500)
        : 15500;
    if (_lastEmitElapsed != null &&
        (elapsed - _lastEmitElapsed!).inMicroseconds < minEmitUs &&
        _revealedLen + step < targetLen) {
      return;
    }
    _lastEmitElapsed = elapsed;
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

  static final RegExp _incompleteLinkTailRe = RegExp(r'(!?)\[([^\]\n]+)\]\([^)\n]*$');
  static final RegExp _incompleteBlockStarterRe = RegExp(
    r'^(?:#{1,6}\s*|-{1,2}|>{1}\s*\[![A-Za-z]*|[-*+]\s+\[[ xX]?\]?)$',
  );

  /// Stabilize dangling unclosed block & inline syntax at the streaming tail
  /// (`**`, `` ` ``, `~~`, `[label](url`, GFM table separators, partial closing code/math fences)
  /// so tokens render styled smoothly with ZERO raw-syntax flash or card flicker.
  static String _stabilizeStreamingText(String raw, [int settledOffset = 0]) {
    if (raw.isEmpty) return raw;
    String? openChar;
    var openLen = 0;
    var inMathBlock = false;
    var mathBlockCloser = r'$$';
    var pos = settledOffset.clamp(0, raw.length);
    final rawLen = raw.length;
    var lastLineStart = pos;
    while (pos < rawLen) {
      final nl = raw.indexOf('\n', pos);
      final end = nl < 0 ? rawLen : nl;
      lastLineStart = pos;
      final rawLine = raw.substring(pos, end);
      final t = rawLine.trimLeft();
      final exactTrim = rawLine.trim();
      if (openChar == null && !inMathBlock) {
        final m = _openFenceRe.firstMatch(t);
        if (m != null) {
          final f = m.group(1)!;
          final info = m.group(2) ?? '';
          if (!(f[0] == '`' && info.contains('`'))) {
            openChar = f[0];
            openLen = f.length;
          }
        } else if (exactTrim.startsWith(r'$$') && !exactTrim.substring(2).contains(r'$$')) {
          inMathBlock = true;
          mathBlockCloser = r'$$';
        } else if (exactTrim.startsWith(r'\[') && !exactTrim.substring(2).contains(r'\]')) {
          inMathBlock = true;
          mathBlockCloser = r'\]';
        }
      } else if (inMathBlock) {
        if (exactTrim.contains(mathBlockCloser)) {
          inMathBlock = false;
        }
      } else if (_isClosingFence(t, openChar!, openLen)) {
        openChar = null;
        openLen = 0;
      }
      if (nl < 0) break;
      pos = nl + 1;
    }

    // 1. Inside an open fenced code block: strip a half-typed closing fence (`\n`` `)
    //    so literal backticks never flash on the last line of the code card!
    if (openChar != null) {
      final lastLine = raw.substring(lastLineStart);
      final lt = lastLine.trimLeft();
      if (lastLineStart > settledOffset &&
          lt.isNotEmpty &&
          lt.length < openLen &&
          lt.split('').every((c) => c == openChar)) {
        return raw.substring(0, lastLineStart > 0 ? lastLineStart - 1 : 0);
      }
      return raw;
    }

    // 2. Inside an open display math block: strip trailing single `$` or `\` partial closer.
    if (inMathBlock) {
      final lastLine = raw.substring(lastLineStart).trim();
      if ((mathBlockCloser == r'$$' && lastLine == r'$') ||
          (mathBlockCloser == r'\]' && lastLine == r'\')) {
        return raw.substring(0, lastLineStart > 0 ? lastLineStart - 1 : 0);
      }
      return raw;
    }

    // 3. Stabilize prose / table tail on the last line.
    final lastNl = raw.lastIndexOf('\n');
    final prefix = lastNl >= 0 ? raw.substring(0, lastNl + 1) : '';
    var tail = lastNl >= 0 ? raw.substring(lastNl + 1) : raw;
    final tailTrim = tail.trim();

    // 3a. GFM table streaming protection:
    //     - If the previous line looks like a table header/row (`contains('|')`):
    //       * Bare `|` at the start of a new row -> hold until first cell chars arrive (no stray `|` paragraph).
    //       * Partial separator row (`| --- | ` / `| --- | :`) -> normalize to clean closed separator so
    //         `_tableSepPattern` stays matched continuously and never flips back to raw pipe text!
    if (lastNl > 0) {
      final prevNl = raw.lastIndexOf('\n', lastNl - 1);
      final prevLine = raw.substring(prevNl + 1, lastNl).trim();
      if (prevLine.contains('|')) {
        if (tailTrim == '|' || tailTrim == '| -' || tailTrim == '| :' || tailTrim == '| :-') {
          return raw.substring(0, lastNl);
        }
        if (_streamingTableSepPartialRe.hasMatch(tailTrim) &&
            !_tableSepPattern.hasMatch(tailTrim)) {
          // Close trailing partial cell (`| ` or `| :`) cleanly so table card never unmounts!
          final cleaned = tailTrim.replaceFirst(RegExp(r'\|[\s:]*$'), '|');
          if (_tableSepPattern.hasMatch(cleaned)) {
            return '$prefix$cleaned';
          }
          return raw.substring(0, lastNl);
        }
      }
    }

    // 3b. Hold bare line-start block tokens (`#`, `## `, `--`, `> [!`, `- [x]`) until content arrives.
    if (tailTrim.isNotEmpty && _incompleteBlockStarterRe.hasMatch(tailTrim)) {
      return lastNl >= 0 ? raw.substring(0, lastNl) : '';
    }

    // 3c. Sanitize incomplete `[label](https://...` or `![alt](https://...` at the end of the tail
    //     so bare-URL autolink never hijacks half-streamed links and collapses lines when `)` arrives!
    final linkMatch = _incompleteLinkTailRe.firstMatch(tail);
    if (linkMatch != null) {
      final isImg = linkMatch.group(1) == '!';
      final label = linkMatch.group(2) ?? '';
      tail = '${tail.substring(0, linkMatch.start)}${isImg ? '' : label}';
    }

    // 3d. Single-pass escape- and backtick-aware scanner over the active paragraph so
    //     code spans like `` `a**b` ``, multi-line bold `**a\nb`, `***`, and inline math
    //     `$x+y` / `\(x+y` stabilize smoothly with zero raw-syntax flash!
    var paraStart = settledOffset.clamp(0, prefix.length);
    final blankBreak = prefix.lastIndexOf('\n\n');
    if (blankBreak >= paraStart) {
      paraStart = blankBreak + 2;
    }
    final activePara = '${prefix.substring(paraStart)}$tail';
    int openTickLen = 0;
    int openTickStart = -1;
    bool openBold = false;
    int openBoldStart = -1;
    bool openStrike = false;
    int openStrikeStart = -1;
    bool openDollarMath = false;
    int openDollarStart = -1;
    bool openParenMath = false;
    int openParenStart = -1;

    var i = 0;
    final pLen = activePara.length;
    while (i < pLen) {
      final ch = activePara[i];
      if (openTickLen > 0) {
        if (ch == '`') {
          var end = i;
          while (end < pLen && activePara[end] == '`') {
            end++;
          }
          if (end - i == openTickLen) {
            openTickLen = 0;
            openTickStart = -1;
          }
          i = end;
          continue;
        }
        i++;
        continue;
      }
      if (ch == r'\' && i + 1 < pLen) {
        final nextCh = activePara[i + 1];
        if (!openParenMath && nextCh == '(') {
          openParenMath = true;
          openParenStart = i;
          i += 2;
          continue;
        }
        if (openParenMath && nextCh == ')') {
          openParenMath = false;
          openParenStart = -1;
          i += 2;
          continue;
        }
        i += 2;
        continue;
      }
      if (openParenMath) {
        i++;
        continue;
      }
      if (ch == '`') {
        var end = i;
        while (end < pLen && activePara[end] == '`') {
          end++;
        }
        openTickLen = end - i;
        openTickStart = i;
        i = end;
        continue;
      }
      if (ch == r'$') {
        final isDouble = i + 1 < pLen && activePara[i + 1] == r'$';
        if (isDouble) {
          i += 2;
          continue;
        }
        if (!openDollarMath) {
          final prevWord = i > 0 && _isWordChar(activePara.codeUnitAt(i - 1));
          final nextSpace = i + 1 < pLen && (activePara[i + 1] == ' ' || activePara[i + 1] == '\t' || activePara[i + 1] == '\n');
          if (!prevWord && !nextSpace) {
            openDollarMath = true;
            openDollarStart = i;
          }
        } else {
          final prevSpace = i > 0 && (activePara[i - 1] == ' ' || activePara[i - 1] == '\t');
          if (!prevSpace) {
            openDollarMath = false;
            openDollarStart = -1;
          }
        }
        i++;
        continue;
      }
      if (openDollarMath) {
        if (ch == '\n') {
          openDollarMath = false;
          openDollarStart = -1;
        }
        i++;
        continue;
      }
      if (ch == '*' && i + 1 < pLen && activePara[i + 1] == '*') {
        // Skip `***` if it's a bare trailing triple-asterisk opener
        if (i + 2 < pLen && activePara[i + 2] == '*' && i + 3 == pLen) {
          return '${prefix.substring(0, paraStart)}${activePara.substring(0, i)}';
        }
        if (openBold) {
          openBold = false;
          openBoldStart = -1;
        } else {
          openBold = true;
          openBoldStart = i;
        }
        i += 2;
        continue;
      }
      if (ch == '~' && i + 1 < pLen && activePara[i + 1] == '~') {
        if (openStrike) {
          openStrike = false;
          openStrikeStart = -1;
        } else {
          openStrike = true;
          openStrikeStart = i;
        }
        i += 2;
        continue;
      }
      i++;
    }

    final basePrefix = prefix.substring(0, paraStart);
    if (openTickLen > 0) {
      if (openTickStart + openTickLen == pLen) {
        return '$basePrefix${activePara.substring(0, openTickStart)}';
      }
      return '$basePrefix$activePara${'`' * openTickLen}';
    }
    if (openParenMath) {
      final body = activePara.substring(openParenStart + 2);
      if (body.trim().isEmpty || body == r'\') {
        return '$basePrefix${activePara.substring(0, openParenStart)}';
      }
      if (activePara.endsWith(r'\')) {
        return '$basePrefix${activePara.substring(0, pLen - 1)}\\)';
      }
      return '$basePrefix$activePara\\)';
    }
    if (openDollarMath) {
      final body = activePara.substring(openDollarStart + 1);
      if (body.isEmpty) {
        return '$basePrefix${activePara.substring(0, openDollarStart)}';
      }
      if (!body.endsWith(' ') && !body.endsWith('\t') && !_looksLikeCurrencyNotMath(body, false)) {
        return '$basePrefix$activePara\$';
      }
    }
    if (openBold) {
      if (openBoldStart + 2 == pLen) {
        return '$basePrefix${activePara.substring(0, openBoldStart)}';
      }
      if (activePara.endsWith('*') && pLen >= openBoldStart + 3 && activePara[pLen - 2] != ' ') {
        return '$basePrefix$activePara*';
      }
      if (openBoldStart + 2 < pLen && activePara[openBoldStart + 2] != ' ') {
        return '$basePrefix$activePara**';
      }
    }
    if (openStrike) {
      if (openStrikeStart + 2 == pLen) {
        return '$basePrefix${activePara.substring(0, openStrikeStart)}';
      }
      if (activePara.endsWith('~') && pLen >= openStrikeStart + 3 && activePara[pLen - 2] != ' ') {
        return '$basePrefix$activePara~';
      }
      if (openStrikeStart + 2 < pLen && activePara[openStrikeStart + 2] != ' ') {
        return '$basePrefix$activePara~~';
      }
    }
    return '$prefix$tail';
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

  static final RegExp _unicodeWordRe = RegExp(r'[\p{L}\p{N}_]', unicode: true);
  static final RegExp _htmlBrTagRe = RegExp(r'<br\s*/?>', caseSensitive: false);
  static final RegExp _linkTitleSuffixRe = RegExp(r'''\s+(?:"[^"]*"|'[^']*')\s*$''');

  static bool _isWordChar(int cu) {
    if ((cu >= 0x30 && cu <= 0x39) ||
        (cu >= 0x41 && cu <= 0x5A) ||
        (cu >= 0x61 && cu <= 0x7A) ||
        cu == 0x5F) {
      return true;
    }
    if (cu < 0x80) return false;
    return _unicodeWordRe.hasMatch(String.fromCharCode(cu));
  }

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

  /// Find balanced `]` matching `[` at [startIdx] (hoisted static helper to avoid per-char closures).
  static int _findBalancedBracketClose(String input, int startIdx) {
    final len = input.length;
    var scan = startIdx;
    var bDepth = 0;
    while (scan < len) {
      final c = input[scan];
      if (c == r'\' && scan + 1 < len) {
        scan += 2;
        continue;
      }
      if (c == '`') {
        var te = scan;
        while (te < len && input[te] == '`') {
          te++;
        }
        final cc = _findExactBacktickClose(input, te, te - scan);
        scan = cc >= 0 ? cc + (te - scan) : te;
        continue;
      }
      if (c == '[') {
        bDepth++;
      } else if (c == ']') {
        if (bDepth == 0) return scan;
        bDepth--;
      } else if (c == '\n') {
        return -1;
      }
      scan++;
    }
    return -1;
  }

  /// Find balanced `)` matching `(` at [startIdx], supporting optional `"title"` / `'title'`.
  static int _findBalancedParenClose(String input, int startIdx) {
    final len = input.length;
    var scan = startIdx;
    var pDepth = 0;
    String? quote;
    while (scan < len) {
      final c = input[scan];
      if (quote != null) {
        if (c == r'\' && scan + 1 < len) {
          scan += 2;
          continue;
        }
        if (c == quote) {
          quote = null;
        } else if (c == '\n') {
          return -1;
        }
        scan++;
        continue;
      }
      if (c == '(') {
        pDepth++;
      } else if (c == ')') {
        if (pDepth == 0) return scan;
        pDepth--;
      } else if (c == '\n') {
        return -1;
      } else if (c == ' ' || c == '\t') {
        var nextNonWs = scan + 1;
        while (nextNonWs < len && (input[nextNonWs] == ' ' || input[nextNonWs] == '\t')) {
          nextNonWs++;
        }
        if (nextNonWs < len && (input[nextNonWs] == '"' || input[nextNonWs] == "'")) {
          quote = input[nextNonWs];
          scan = nextNonWs + 1;
          continue;
        }
        if (nextNonWs < len && input[nextNonWs] == ')') {
          scan = nextNonWs;
          continue;
        }
        return -1;
      }
      scan++;
    }
    return -1;
  }

  static (String decoded, int consumed)? _tryDecodeHtmlEntity(String input, int i) {
    const table = <String, String>{
      '&amp;': '&',
      '&lt;': '<',
      '&gt;': '>',
      '&quot;': '"',
      '&#39;': "'",
      '&apos;': "'",
      '&nbsp;': ' ',
    };
    for (final entry in table.entries) {
      if (input.startsWith(entry.key, i)) {
        return (entry.value, entry.key.length);
      }
    }
    return null;
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

      // DeepSeek inline/display LaTeX `\(...\)` and `\[...\]` BEFORE generic backslash unescaping!
      if (ch == r'\' && i + 1 < len && (input[i + 1] == '(' || input[i + 1] == '[')) {
        final isBracket = input[i + 1] == '[';
        final closeToken = isBracket ? r'\]' : r'\)';
        final closeIdx = _findClosingDelim(input, i + 2, closeToken, allowNewline: isBracket);
        if (closeIdx > i + 2) {
          final mathBody = input.substring(i + 2, closeIdx).trim();
          if (mathBody.isNotEmpty) {
            flushBuf();
            spans.add(
              TextSpan(
                text: _formatReadableLatex(mathBody),
                recognizer: linkRecognizer,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13.4,
                  fontStyle: FontStyle.italic,
                  color: t.isDark ? t.primaryHi : t.primary,
                  backgroundColor: t.fill1,
                ),
              ),
            );
            i = closeIdx + 2;
            continue;
          }
        }
      }

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
                  text: _formatReadableLatex(mathBody),
                  recognizer: linkRecognizer,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13.4,
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

      // Inline code span `` `code` `` rendered as pure TextSpan WITHOUT invisible NBSP (\u00A0)
      // so copying commands, flags, or paths pastes cleanly into shells & IDEs!
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
          final isLinkCode = linkRecognizer != null;
          final linkCodeColor = t.isDark ? t.primaryHi : t.primary;
          spans.add(
            TextSpan(
              text: code,
              recognizer: linkRecognizer,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.1,
                decoration: isLinkCode ? TextDecoration.underline : TextDecoration.none,
                decorationColor: isLinkCode
                    ? linkCodeColor.withValues(alpha: 0.48)
                    : null,
                color: isLinkCode ? linkCodeColor : t.text,
                backgroundColor: isLinkCode
                    ? t.primarySoft
                    : (t.isDark
                        ? Color.lerp(t.cardSolid, Colors.white, 0.11)
                        : t.fill2),
              ),
            ),
          );
          i = closeIdx + tickLen;
          continue;
        }
        // Unmatched multi-backtick run: emit entire run literally instead of re-scanning!
        buf.write(input.substring(i, tickEnd));
        i = tickEnd;
        continue;
      }

      // Common HTML entities outside inline code spans (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#39;`, `&nbsp;`)
      if (ch == '&') {
        final ent = _tryDecodeHtmlEntity(input, i);
        if (ent != null) {
          buf.write(ent.$1);
          i += ent.$2;
          continue;
        }
      }

      // Inline Markdown image `![alt](https://...)` -> tappable preview link (balanced brackets & parens!)
      if (linkRecognizer == null && ch == '!' && i + 1 < len && input[i + 1] == '[') {
        final closeBracket = _findBalancedBracketClose(input, i + 2);
        if (closeBracket > i + 1 && closeBracket + 1 < len && input[closeBracket + 1] == '(') {
          final closeParen = _findBalancedParenClose(input, closeBracket + 2);
          if (closeParen > closeBracket + 2) {
            final alt = input.substring(i + 2, closeBracket).trim();
            final imgUrl = input
                .substring(closeBracket + 2, closeParen)
                .replaceFirst(_linkTitleSuffixRe, '')
                .trim();
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

      // Link `[label](url)` — supports `https://`, `file://`, and relative workspace file paths!
      if (linkRecognizer == null && ch == '[') {
        final closeBracket = _findBalancedBracketClose(input, i + 1);
        if (closeBracket > i + 1 && closeBracket + 1 < len && input[closeBracket + 1] == '(') {
          final validEnd = _findBalancedParenClose(input, closeBracket + 2);
          if (validEnd > closeBracket + 2) {
            final linkLabel = input.substring(i + 1, closeBracket);
            final linkUrl = input
                .substring(closeBracket + 2, validEnd)
                .replaceFirst(_linkTitleSuffixRe, '')
                .trim();
            final isWebUrl = linkUrl.startsWith('http://') || linkUrl.startsWith('https://');
            final isFileLink = linkUrl.startsWith('file://') ||
                (!linkUrl.contains('://') &&
                    !linkUrl.startsWith('#') &&
                    !linkUrl.startsWith('mailto:') &&
                    (linkUrl.contains('/') ||
                        RegExp(r'\.[a-zA-Z0-9]{1,8}(?:#L\d+(?:-L?\d+)?)?$').hasMatch(linkUrl)));
            if (isWebUrl || isFileLink) {
              flushBuf();
              final TapGestureRecognizer recognizer;
              if (isWebUrl) {
                recognizer = _makeUrlRecognizer(linkUrl, previewContext);
              } else {
                var cleanPath = linkUrl;
                if (linkUrl.startsWith('file://')) {
                  final raw = linkUrl.substring(7);
                  try {
                    cleanPath = Uri.decodeFull(raw);
                  } catch (_) {
                    cleanPath = raw;
                  }
                }
                final hashIdx = cleanPath.indexOf('#');
                if (hashIdx > 0) cleanPath = cleanPath.substring(0, hashIdx);
                recognizer = TapGestureRecognizer()
                  ..onTap = () {
                    if (previewContext != null && previewContext.mounted) {
                      showWorkspaceFilePreviewSheet(
                        previewContext,
                        path: cleanPath,
                        title: linkLabel.trim().isNotEmpty ? linkLabel.trim() : null,
                      );
                    }
                  };
              }
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
        var closeIdx = _findClosingDelim(input, i + 2, delim);
        if (ch == '_' &&
            closeIdx > i + 2 &&
            closeIdx + 2 < len &&
            _isWordChar(input.codeUnitAt(closeIdx + 2))) {
          closeIdx = -1;
        }
        // Handle `**bold *italic***`: when closing `**` is immediately followed by `*`,
        // check if the interior contains an unmatched single `*` so `*italic*` closes first!
        if (ch == '*' &&
            closeIdx > i + 2 &&
            closeIdx + 2 < len &&
            input[closeIdx + 2] == '*') {
          final candidateInner = input.substring(i + 2, closeIdx);
          var singleStarCount = 0;
          for (var s = 0; s < candidateInner.length; s++) {
            if (candidateInner[s] == '*') {
              if ((s == 0 || candidateInner[s - 1] != '*') &&
                  (s + 1 >= candidateInner.length || candidateInner[s + 1] != '*')) {
                singleStarCount++;
              }
            }
          }
          if (singleStarCount.isOdd) {
            closeIdx += 1;
          }
        }
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
      // Non-copyable, Word-Joiner-anchored breathing capsule caret (NEVER orphans onto a blank
      // line, NEVER copies into clipboard when selecting text mid-stream, and matches line height!).
      spans.add(const TextSpan(text: '\u2060'));
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: SelectionContainer.disabled(
            child: _LiveStreamingCaret(color: t.primary),
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
    var openTickLen = 0;
    var k = 0;
    while (k < s.length) {
      final ch = s[k];
      if (openTickLen == 0 && ch == r'\' && k + 1 < s.length) {
        final next = s[k + 1];
        if (next == '|') {
          buf.write('|');
          k += 2;
          continue;
        }
        if (next == '`') {
          buf.write(r'\`');
          k += 2;
          continue;
        }
      }
      if (ch == '`') {
        var end = k;
        while (end < s.length && s[end] == '`') {
          end++;
        }
        final runLen = end - k;
        if (openTickLen > 0) {
          if (runLen == openTickLen) openTickLen = 0;
        } else if (_findExactBacktickClose(s, end, runLen) >= 0) {
          // Only enter inline code span when a matching closing backtick run exists in this row,
          // so a lone unclosed backtick never swallows the remaining columns!
          openTickLen = runLen;
        }
        buf.write(s.substring(k, end));
        k = end;
        continue;
      }
      if (ch == '|' && openTickLen == 0) {
        cells.add(buf.toString().trim());
        buf.clear();
        k++;
      } else {
        buf.write(ch);
        k++;
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

      // Display LaTeX math block (`$$ ... $$` or DeepSeek `\[ ... \]`, single-line or multi-line).
      // CRITICAL: If a closer appears mid-line with trailing prose (e.g. `$$E=mc^2$$ 是质能方程`),
      // leave the line to inline paragraph parsing so we NEVER swallow the rest of the message!
      if (trimmed.startsWith(r'$$') || trimmed.startsWith(r'\[')) {
        final isBracketMath = trimmed.startsWith(r'\[');
        final closer = isBracketMath ? r'\]' : r'$$';
        final rest = trimmed.substring(2).trim();
        final closerIdxInRest = rest.indexOf(closer);
        if (closerIdxInRest >= 0) {
          // Single-line display math ONLY when the closer is cleanly at the very end!
          if (closerIdxInRest == rest.length - closer.length && rest.length > closer.length) {
            flushParagraph();
            final formula = rest.substring(0, closerIdxInRest).trim();
            out.add(_RawMdBlock(kind: _MdBlockKind.math, raw: line, body: formula));
            i++;
            continue;
          }
          // Otherwise fall through to paragraph inline math parsing!
        } else {
          // Multi-line display math: `$$\nexpr\n$$` or `$$expr\n...$$` (even with trailing `。` / prose)
          flushParagraph();
          final startIdx = i;
          final mathLines = <String>[if (rest.isNotEmpty) rest];
          var trailingAfterCloser = '';
          i++;
          while (i < lines.length) {
            final curTrim = lines[i].trim();
            final closerPos = curTrim.indexOf(closer);
            if (closerPos >= 0) {
              final beforeCloser = curTrim.substring(0, closerPos).trim();
              if (beforeCloser.isNotEmpty) mathLines.add(beforeCloser);
              trailingAfterCloser = curTrim.substring(closerPos + closer.length).trim();
              i++;
              break;
            }
            mathLines.add(lines[i]);
            i++;
          }
          out.add(
            _RawMdBlock(
              kind: _MdBlockKind.math,
              raw: lines.sublist(startIdx, i).join('\n'),
              body: mathLines.join('\n').trim(),
            ),
          );
          if (trailingAfterCloser.isNotEmpty) {
            paraBuf.add(trailingAfterCloser);
          }
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

      // Bullet, numbered list, or task-checkbox item (`- [x]`, `- [ ]`, `1.`, `1)`)
      final bulletMatch = _bulletPattern.firstMatch(trimmed);
      if (bulletMatch != null) {
        flushParagraph();
        var leadingCols = 0;
        for (var ci = 0; ci < line.length - trimmed.length; ci++) {
          leadingCols += line.codeUnitAt(ci) == 0x09 /* '\t' */ ? 2 : 1;
        }
        final indent = (leadingCols ~/ 2).clamp(0, 4) * 14.0;
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
    int quoteDepth = 0,
  }) {
    final key = ValueKey('md-blk-$idx');
    switch (blk.kind) {
      case _MdBlockKind.code:
        if (isStreamingBlock || widget.isStreaming) {
          _streamedBlockIndices.add(idx);
        }
        return _FencedCodeBlock(
          key: key,
          lang: blk.lang,
          code: blk.body,
          isStreaming: isStreamingBlock,
          initiallyExpanded: isStreamingBlock || _streamedBlockIndices.contains(idx),
        );
      case _MdBlockKind.math:
        return _DisplayMathCard(
          key: key,
          rawLatex: blk.body,
          isStreaming: isStreamingBlock,
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
                showCursor: showCursor,
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
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        loadingBuilder: (ctx, child, progress) {
                          if (progress == null) return child;
                          return Container(
                            width: 240,
                            height: 140,
                            alignment: Alignment.center,
                            color: t.fill1,
                            child: GrassBagActivityIndicator(radius: 9, color: t.text3),
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
        return _MarkdownTableCard(
          key: key,
          headers: headers,
          alignments: alignments,
          rows: rows,
          rawMarkdown: blk.raw,
          isStreaming: isStreamingBlock,
          spanBuilder: (cellText, tokens, cellRecognizers) => _buildMarkdownSpans(
            cellText.replaceAll(_htmlBrTagRe, '\n'),
            tokens,
            cellRecognizers,
            previewContext: context,
          ),
        );
      case _MdBlockKind.quote:
        final calloutMatch = _mdCalloutRe.firstMatch(blk.body.trimLeft());
        final String? calloutKind = calloutMatch?.group(1)?.toUpperCase();
        final effectiveQuoteBody = calloutMatch != null
            ? blk.body.trimLeft().substring(calloutMatch.end).trim()
            : blk.body;
        final Color accentColor;
        final Color bgColor;
        final IconData? calloutIcon;
        final String? calloutLabel;
        switch (calloutKind) {
          case 'NOTE':
            accentColor = t.primary;
            bgColor = t.primarySoft;
            calloutIcon = CupertinoIcons.info_circle_fill;
            calloutLabel = '备注';
            break;
          case 'TIP':
            accentColor = t.ok;
            bgColor = t.okSoft;
            calloutIcon = CupertinoIcons.lightbulb_fill;
            calloutLabel = '提示';
            break;
          case 'IMPORTANT':
            accentColor = const Color(0xFF8B5CF6);
            bgColor = const Color(0xFF8B5CF6).withValues(alpha: t.isDark ? 0.16 : 0.10);
            calloutIcon = CupertinoIcons.exclamationmark_circle_fill;
            calloutLabel = '重要';
            break;
          case 'WARNING':
            accentColor = t.warn;
            bgColor = t.warnSoft;
            calloutIcon = CupertinoIcons.exclamationmark_triangle_fill;
            calloutLabel = '注意';
            break;
          case 'CAUTION':
            accentColor = t.err;
            bgColor = t.errSoft;
            calloutIcon = CupertinoIcons.xmark_octagon_fill;
            calloutLabel = '警告';
            break;
          default:
            accentColor = t.primary;
            bgColor = t.fill1;
            calloutIcon = null;
            calloutLabel = null;
        }
        final nestedBlocks = quoteDepth < 3
            ? _splitMarkdownBlocks(effectiveQuoteBody)
            : const <_RawMdBlock>[];
        final hasRichNested = quoteDepth < 3 &&
            (nestedBlocks.length > 1 ||
                (nestedBlocks.length == 1 && nestedBlocks.first.kind != _MdBlockKind.paragraph));
        final quoteTier = resolveAmbientGlassTier(context);
        final quoteBox = ClipRSuperellipse(
          borderRadius: BorderRadius.circular(13),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: quoteTier == GrassBagGlassTier.solid ? bgColor : null,
              gradient: quoteTier == GrassBagGlassTier.solid
                  ? null
                  : LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.lerp(
                          bgColor,
                          Colors.white.withValues(alpha: bgColor.a),
                          t.isDark ? 0.08 : 0.24,
                        )!,
                        bgColor,
                      ],
                    ),
              border: Border(
                left: BorderSide(color: accentColor, width: 3.5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(11, 8, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (calloutLabel != null && calloutIcon != null) ...[
                    Row(
                      children: [
                        Icon(calloutIcon, size: 13.5, color: accentColor),
                        const SizedBox(width: 5),
                        Text(
                          calloutLabel,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: accentColor,
                          ),
                        ),
                      ],
                    ),
                    if (effectiveQuoteBody.isNotEmpty) const SizedBox(height: 5),
                  ],
                  if (effectiveQuoteBody.isNotEmpty)
                    hasRichNested
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var ni = 0; ni < nestedBlocks.length; ni++)
                                _buildSingleBlockWidget(
                                  -((idx + 1) * 1000 + ni + 1),
                                  nestedBlocks[ni],
                                  t,
                                  recognizers,
                                  showCursor: showCursor && ni == nestedBlocks.length - 1,
                                  isStreamingBlock:
                                      isStreamingBlock && ni == nestedBlocks.length - 1,
                                  quoteDepth: quoteDepth + 1,
                                ),
                            ],
                          )
                        : Text.rich(
                            TextSpan(
                              style: TextStyle(fontSize: 14, height: 1.58, color: t.text2),
                              children: _buildMarkdownSpans(
                                effectiveQuoteBody,
                                t,
                                recognizers,
                                showCursor: showCursor,
                                previewContext: context,
                              ),
                            ),
                          ),
                ],
              ),
            ),
          ),
        );
        return Padding(
          key: key,
          padding: const EdgeInsets.only(bottom: 9),
          child: quoteTier == GrassBagGlassTier.solid
              ? quoteBox
              : CustomPaint(
                  foregroundPainter: GrassBagFresnelRimPainter(
                    isDark: t.isDark,
                    borderRadius: 13,
                    accent: accentColor,
                    innerWell: true,
                    frosted: quoteTier == GrassBagGlassTier.frosted,
                    paintTopSheen: false,
                    strokeWidth: 0.7,
                  ),
                  child: quoteBox,
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
                  padding: EdgeInsets.only(right: 4, top: blk.taskChecked != null ? 4.5 : 2),
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
    var mathBlockCloser = r'$$';
    var pos = startPos;
    var lastSafeCut = -1;
    while (pos < maxCut) {
      final nl = fullSource.indexOf('\n', pos);
      if (nl < 0 || nl >= maxCut) break;
      final line = fullSource.substring(pos, nl);
      final trimmed = line.trimLeft();
      final exactTrim = line.trim();
      if (openChar == null && !inMathBlock) {
        final m = _openFenceRe.firstMatch(trimmed);
        if (m != null && !(m.group(1)![0] == '`' && (m.group(2) ?? '').contains('`'))) {
          final f = m.group(1)!;
          openChar = f[0];
          openLen = f.length;
        } else if (exactTrim.startsWith(r'$$')) {
          // Mirror `_splitMarkdownBlocks`: only enter multi-line math when NO closer appears on this line!
          final rest = exactTrim.substring(2);
          if (!rest.contains(r'$$')) {
            inMathBlock = true;
            mathBlockCloser = r'$$';
          }
        } else if (exactTrim.startsWith(r'\[')) {
          final rest = exactTrim.substring(2);
          if (!rest.contains(r'\]')) {
            inMathBlock = true;
            mathBlockCloser = r'\]';
          }
        } else if (exactTrim.isEmpty && nl + 1 < revealedLen) {
          // A blank line outside open fences guarantees clean block flush before nl + 1.
          lastSafeCut = nl + 1;
        } else if (tailLen > 600 &&
            pos > startPos &&
            !trimmed.contains('|') &&
            !trimmed.startsWith('>') &&
            (_bulletPattern.hasMatch(trimmed) || _headingPattern.hasMatch(trimmed)) &&
            !line.startsWith(' ') &&
            !line.startsWith('\t')) {
          // Also settle long tight bullet lists / heading chains so 50-item lists stay O(tail)!
          lastSafeCut = pos;
        }
      } else if (inMathBlock) {
        if (exactTrim.contains(mathBlockCloser)) {
          inMathBlock = false;
        }
      } else if (_isClosingFence(trimmed, openChar as String, openLen)) {
        openChar = null;
        openLen = 0;
      }
      pos = nl + 1;
    }
    if (lastSafeCut > startPos) {
      final deltaSlice = fullSource.substring(startPos, lastSafeCut);
      final deltaBlocks = _splitMarkdownBlocks(deltaSlice);
      if (deltaBlocks.isEmpty) return;

      // Wrap each settled block in its own keyed RepaintBoundary so moving from tail -> settled
      // inside ONE flat Column preserves Element identity (zero SelectionArea wipe or code collapse!).
      final baseIdx = _settledCachedBlocks.length;
      for (var i = 0; i < deltaBlocks.length; i++) {
        final blk = deltaBlocks[i];
        final absIdx = baseIdx + i;
        final recs = <TapGestureRecognizer>[];
        final w = RepaintBoundary(
          key: ValueKey('md-blk-$absIdx'),
          child: _buildSingleBlockWidget(
            absIdx,
            blk,
            t,
            recs,
            showCursor: false,
            isStreamingBlock: false,
          ),
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
      final isStreamingRichBlock = showCursor &&
          isLast &&
          (blk.kind == _MdBlockKind.code ||
              blk.kind == _MdBlockKind.math ||
              blk.kind == _MdBlockKind.table);
      final wantsCursor = showCursor &&
          isLast &&
          (blk.kind == _MdBlockKind.paragraph ||
              blk.kind == _MdBlockKind.bullet ||
              blk.kind == _MdBlockKind.heading ||
              blk.kind == _MdBlockKind.quote);
      final cacheFlag = wantsCursor || isStreamingRichBlock;

      if (ti < _tailCachedBlocks.length) {
        final existing = _tailCachedBlocks[ti];
        if (existing.kind == blk.kind &&
            existing.raw == blk.raw &&
            existing.hasCursor == cacheFlag) {
          continue; // O(1) cache hit! Preserves Widget identity, tables, code blocks & links!
        }
        _deferDisposeRecognizers(existing.recognizers);
        final recs = <TapGestureRecognizer>[];
        final w = RepaintBoundary(
          key: ValueKey('md-blk-$absIdx'),
          child: _buildSingleBlockWidget(
            absIdx,
            blk,
            t,
            recs,
            showCursor: wantsCursor,
            isStreamingBlock: isStreamingRichBlock,
          ),
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
        final w = RepaintBoundary(
          key: ValueKey('md-blk-$absIdx'),
          child: _buildSingleBlockWidget(
            absIdx,
            blk,
            t,
            recs,
            showCursor: wantsCursor,
            isStreamingBlock: isStreamingRichBlock,
          ),
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

    // Flatten settled + tail blocks into ONE single parent Column with stable `md-blk-$absIdx`
    // keys so settling a prefix NEVER unmounts/remounts code blocks or wipes user text selection!
    if (_settledCachedBlocks.isEmpty && _tailCachedBlocks.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final b in _settledCachedBlocks) b.widget,
        for (final b in _tailCachedBlocks) b.widget,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final isTyping = widget.isStreaming || _revealedLen < widget.text.length;
    final visibleLen = _revealedLen.clamp(0, widget.text.length);

    final glassTier = resolveAmbientGlassTier(context);
    final themeChanged = _cachedDark != t.isDark ||
        _cachedAccent != t.accent ||
        _cachedTextColor != t.text ||
        _cachedPrimaryColor != t.primary ||
        _cachedCardSolidColor != t.cardSolid ||
        _cachedCodeBgColor != t.codeBg ||
        _cachedSepColor != t.sep ||
        _cachedGlassTier != glassTier;
    if (themeChanged ||
        (_settledLen > 0 && (visibleLen < _settledLen || !_matchesSettledAnchor(widget.text)))) {
      _disposeAllCachedBlocks();
    }

    // O(1) fast-path short-circuit: skip substring(), prefix scan, and _stabilizeStreamingText()
    // whenever neither visible frontier, source string, streaming state, nor theme changed!
    final canReuseCachedBody = !themeChanged &&
        _cachedRichBody != null &&
        _cachedVisibleLen == visibleLen &&
        _cachedSettledLen == _settledLen &&
        _cachedStreaming == isTyping &&
        identical(_cachedSourceText, widget.text);

    late final String displayTail;
    if (canReuseCachedBody) {
      displayTail = _cachedTailText ?? '';
    } else {
      // Incrementally settle completed prefix blocks into their own RepaintBoundary
      // BEFORE slicing the mutable tail — O(delta) work, ZERO full-message copy or O(N) startsWith!
      if (visibleLen - _settledLen >= 160) {
        _advanceSettledPrefix(widget.text, visibleLen, t);
      }

      final rawTail = _settledLen == 0 && visibleLen >= widget.text.length
          ? widget.text
          : widget.text.substring(_settledLen, visibleLen);
      // _settledLen always ends at a blank line outside open code/math fences -> offset 0 is exact!
      displayTail = isTyping ? _stabilizeStreamingText(rawTail, 0) : rawTail;

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
        _cachedGlassTier = glassTier;
      }
      _cachedVisibleLen = visibleLen;
      _cachedSourceText = widget.text;
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
          SelectionArea(contextMenuBuilder: buildGrassBagSelectableContextMenu, child: richBody)
        else if (!isTyping &&
            widget.text.isEmpty &&
            widget.deliverables.isEmpty &&
            widget.completedToolCount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Icon(CupertinoIcons.checkmark_circle_fill, size: 14, color: t.ok),
                const SizedBox(width: 6),
                Text(
                  '已完成 ${widget.completedToolCount} 项操作',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: t.text2),
                ),
              ],
            ),
          ),
        for (final item in widget.deliverables) ...[
          const SizedBox(height: 14),
          GrassBagSpringTap(
            pressedScale: 0.975,
            enablePointerGlow: false,
            haptic: true,
            onTap: () => widget.onDeliverableTap(item),
            child: GrassBagCard(
              borderRadius: 22,
              interactive: true,
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
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                            color: t.text,
                          ),
                        ),
                        const SizedBox(height: 1.5),
                        Text(
                          () {
                            final note = (item['note'] ?? '生成产物').toString().trim();
                            final size = (item['size'] ?? '').toString().trim();
                            return size.isEmpty ? note : '$note · $size';
                          }(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: t.text3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GrassBagFresnelGlassSurface(
                    isPill: true,
                    innerWell: true,
                    tintColor: t.primarySoft,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
        // Quiet minimalist bottom chrome (modified files + one-tap action pills) smoothly revealed
        // with SizeTransition + FadeTransition so completion NEVER causes a 1-frame layout pop!
        if (!isTyping)
          _ReplyActionStripReveal(
            animate: _animateActionStripEntrance,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.modifiedFiles.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  SelectionContainer.disabled(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(CupertinoIcons.pencil_outline, size: 12.5, color: t.text3),
                            const SizedBox(width: 4),
                            Text(
                              '已修改 ${widget.modifiedFiles.length} 个文件',
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: t.text3),
                            ),
                          ],
                        ),
                        for (final path in widget.modifiedFiles.take(5))
                          GrassBagSpringTap(
                            pressedScale: 0.95,
                            enablePointerGlow: false,
                            haptic: true,
                            onTap: () => showDiffSheet(context, path),
                            child: GrassBagFresnelGlassSurface(
                              borderRadius: 10,
                              innerWell: true,
                              interactive: true,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(CupertinoIcons.doc_text, size: 11.5, color: t.primary),
                                  const SizedBox(width: 4),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 150),
                                    child: Text(
                                      path.contains('/')
                                          ? (path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path)
                                          : path,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: t.text2,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 2,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (widget.text.isNotEmpty)
                        _QuietReplyAction(
                          icon: _copied ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
                          label: _copied ? '已复制' : '复制',
                          showLabel: _copied,
                          active: _copied,
                          onTap: _handleCopy,
                        ),
                      Consumer(
                        builder: (_, ref, __) {
                          final streaming = ref.watch(appProvider.select((s) => s.isStreaming));
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.cancelledPartial && widget.onContinue != null)
                                _QuietReplyAction(
                                  icon: CupertinoIcons.play_arrow_solid,
                                  label: '继续',
                                  showLabel: true,
                                  enabled: !streaming,
                                  onTap: widget.onContinue!,
                                ),
                              _QuietReplyAction(
                                icon: CupertinoIcons.arrow_branch,
                                label: '分叉对话',
                                enabled: !streaming,
                                onTap: widget.onFork,
                              ),
                              if (widget.onRegenerate != null)
                                _QuietReplyAction(
                                  icon: CupertinoIcons.arrow_clockwise,
                                  label: '重新生成',
                                  enabled: !streaming,
                                  onTap: widget.onRegenerate!,
                                ),
                            ],
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
                        warnActive: true,
                        onTap: () => widget.onFeedback('down'),
                      ),
                      if (widget.cancelledPartial)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: GrassBagFresnelGlassSurface(
                            isPill: true,
                            innerWell: true,
                            padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(CupertinoIcons.stop_circle, size: 11.5, color: t.text3),
                                const SizedBox(width: 4),
                                Text(
                                  '已停止生成',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: t.text3),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (widget.usage != null &&
                          (widget.usage!.inputTokens > 0 ||
                              widget.usage!.outputTokens > 0 ||
                              (widget.usage!.cacheReadTokens ?? 0) > 0))
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: _TurnUsageMicroBadge(
                            usage: widget.usage!,
                            toolCount: widget.completedToolCount,
                          ),
                        ),
                    ],
                  ),
                ),
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
    super.key,
    required this.headers,
    required this.alignments,
    required this.rows,
    required this.rawMarkdown,
    required this.spanBuilder,
    this.isStreaming = false,
  });

  final List<String> headers;
  final List<TextAlign> alignments;
  final List<List<String>> rows;
  final String rawMarkdown;
  final bool isStreaming;
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

  static final RegExp _cellMarkdownStripRe = RegExp(r'[*_`~\[\]]');
  static final RegExp _cellUrlStripRe = RegExp(r'\(https?://[^)]+\)');

  int _cachedWidthRowCount = -1;
  int _cachedWidthColCount = -1;
  double _cachedWidthCardW = -1;
  double _cachedTextScale = -1;
  String _cachedHeadersSig = '';
  String _cachedWidthSig = '';
  List<double>? _cachedRawWidths;
  Map<int, TableColumnWidth>? _cachedColWidths;

  @override
  void initState() {
    super.initState();
    _hCtrl.addListener(_syncFromController);
    _scheduleMetricsSync();
  }

  @override
  void didUpdateWidget(covariant _MarkdownTableCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isStreaming && !widget.isStreaming) {
      // Recompute final settled column widths cleanly once streaming finishes so any
      // cell that shrank or settled after streaming doesn't retain stale max widths.
      _cachedRawWidths = null;
      _cachedColWidths = null;
    }
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
      GestureBinding.instance.pointerSignalResolver.register(event, (PointerSignalEvent _) {
        if (!mounted || !_hCtrl.hasClients) return;
        final liveMax = _hCtrl.position.maxScrollExtent;
        final liveTarget = (_hCtrl.offset + delta).clamp(0.0, liveMax);
        if ((liveTarget - _hCtrl.offset).abs() > 0.1) {
          _hCtrl.jumpTo(liveTarget);
        }
      });
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
    final isSolid = resolveAmbientGlassTier(context) == GrassBagGlassTier.solid;
    final cardBg = isSolid
        ? t.cardSolid
        : (t.isDark
            ? t.cardSolid.withValues(alpha: 0.78)
            : Colors.white.withValues(alpha: 0.76));
    final headerBg = isSolid
        ? (t.isDark ? Color.lerp(t.cardSolid, Colors.white, 0.075)! : t.bgGrouped)
        : (t.isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0x0B0F2840));
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
        final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(0.85, 2.2);
        final cellMaxW = (maxCardW >= 620 ? 300.0 : (maxCardW >= 420 ? 235.0 : 195.0)) *
            math.min(textScale, 1.35);

        // Precompute fixed column widths incrementally during streaming:
        // when headers, colCount, card width, and textScale are unchanged and rows grow monotonically,
        // only measure the new/last row instead of rescanning rows 0..31 on every character!
        final sampleLimit = widget.rows.length < 32 ? widget.rows.length : 32;
        final headersSig = widget.headers.join('|');
        final lastRowSig = sampleLimit > 0 ? widget.rows[sampleLimit - 1].join('|') : '';
        final widthSig = '$headersSig#$lastRowSig';
        Map<int, TableColumnWidth> colWidths;
        if (_cachedColWidths != null &&
            _cachedWidthColCount == colCount &&
            _cachedWidthRowCount == sampleLimit &&
            (_cachedWidthCardW - maxCardW).abs() < 1.0 &&
            (_cachedTextScale - textScale).abs() < 0.01 &&
            _cachedWidthSig == widthSig) {
          colWidths = _cachedColWidths!;
        } else {
          double estimatedCellWidth(String raw, {bool isHeader = false}) {
            final stripped = raw
                .replaceAll(_cellMarkdownStripRe, '')
                .replaceAll(_cellUrlStripRe, '');
            double units = 0;
            for (final rune in stripped.runes) {
              units += (rune > 0x2E80) ? 1.85 : 0.96;
            }
            final px = units * (isHeader ? 8.2 : 7.8) * textScale + 30.0;
            return px.clamp(68.0, cellMaxW);
          }

          final canIncremental = _cachedRawWidths != null &&
              _cachedRawWidths!.length == colCount &&
              _cachedWidthColCount == colCount &&
              _cachedHeadersSig == headersSig &&
              (_cachedWidthCardW - maxCardW).abs() < 1.0 &&
              (_cachedTextScale - textScale).abs() < 0.01 &&
              sampleLimit >= _cachedWidthRowCount &&
              _cachedWidthRowCount >= 0;

          final List<double> rawWidths;
          if (canIncremental) {
            rawWidths = _cachedRawWidths!;
            final startRow = math.max(0, _cachedWidthRowCount - 1);
            for (int ri = startRow; ri < sampleLimit; ri++) {
              final row = widget.rows[ri];
              final len = math.min(colCount, row.length);
              for (int ci = 0; ci < len; ci++) {
                final cw = estimatedCellWidth(row[ci]);
                if (cw > rawWidths[ci]) rawWidths[ci] = cw;
              }
            }
          } else {
            rawWidths = List<double>.filled(colCount, 68.0);
            for (int ci = 0; ci < colCount; ci++) {
              double w = estimatedCellWidth(widget.headers[ci], isHeader: true);
              for (int ri = 0; ri < sampleLimit; ri++) {
                final row = widget.rows[ri];
                if (ci < row.length) {
                  final cw = estimatedCellWidth(row[ci]);
                  if (cw > w) w = cw;
                }
              }
              rawWidths[ci] = w;
            }
            _cachedRawWidths = rawWidths;
          }

          double totalW = 0;
          for (int ci = 0; ci < colCount; ci++) {
            totalW += rawWidths[ci];
          }
          colWidths = <int, TableColumnWidth>{};
          // If total table width is narrower than card width, gently stretch columns
          // proportionally so compact tables fill the card cleanly.
          if (totalW > 0 && totalW < maxCardW - 2 && colCount > 0) {
            final scale = ((maxCardW - 2) / totalW).clamp(1.0, 1.85);
            for (int ci = 0; ci < colCount; ci++) {
              colWidths[ci] = FixedColumnWidth((rawWidths[ci] * scale).clamp(68.0, cellMaxW));
            }
          } else {
            for (int ci = 0; ci < colCount; ci++) {
              colWidths[ci] = FixedColumnWidth(rawWidths[ci]);
            }
          }
          _cachedColWidths = colWidths;
          _cachedWidthColCount = colCount;
          _cachedWidthRowCount = sampleLimit;
          _cachedWidthCardW = maxCardW;
          _cachedTextScale = textScale;
          _cachedHeadersSig = headersSig;
          _cachedWidthSig = widthSig;
        }

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
                  columnWidths: colWidths,
                  defaultColumnWidth: FixedColumnWidth(cellMaxW),
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

        final double tableTotalW = colWidths.values.fold<double>(
          0.0,
          (acc, w) => acc + (w is FixedColumnWidth ? w.value : cellMaxW),
        );
        final tableTier = resolveAmbientGlassTier(context);
        final tableSolid = tableTier == GrassBagGlassTier.solid;
        final tableCard = DecoratedBox(
          decoration: ShapeDecoration(
            color: cardBg,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(16),
              side: tableSolid
                  ? BorderSide(
                      color: t.isDark ? Colors.white.withValues(alpha: 0.11) : t.sep,
                      width: 0.75,
                    )
                  : BorderSide.none,
            ),
          ),
          child: ClipRSuperellipse(
            borderRadius: BorderRadius.circular(16),
            child: ValueListenableBuilder<_TableScrollMetrics>(
              valueListenable: _metricsNotifier,
              child: tableContent,
              builder: (context, m, staticTable) {
                final canScroll = m.maxExtent > 1.0;
                final canScrollLeft = canScroll && m.offset > 2.0;
                final canScrollRight = canScroll && m.offset < m.maxExtent - 2.0;

                final edgeFadeBg = isSolid ? t.cardSolid : cardBg.withValues(alpha: 0.94);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Constant-depth Stack (never wraps/unwraps ShaderMask around staticTable)
                    // so horizontal scroll metrics sync NEVER unmounts the Table or wipes selection!
                    Stack(
                      children: [
                        staticTable!,
                        if (canScrollLeft)
                          Positioned(
                            top: 0,
                            bottom: 0,
                            left: 0,
                            width: 18,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                    colors: [edgeFadeBg, edgeFadeBg.withValues(alpha: 0.0)],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (canScrollRight)
                          Positioned(
                            top: 0,
                            bottom: 0,
                            right: 0,
                            width: 22,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.centerRight,
                                    end: Alignment.centerLeft,
                                    colors: [edgeFadeBg, edgeFadeBg.withValues(alpha: 0.0)],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    SelectionContainer.disabled(
                      child: Container(
                        width: canScroll
                            ? maxCardW
                            : math.min(
                                m.viewport > 1.0 ? m.viewport : tableTotalW,
                                maxCardW,
                              ),
                        height: 34,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: headerBg.withValues(alpha: headerBg.a * 0.72),
                          border: Border(top: BorderSide(color: t.sep, width: 0.5)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.max,
                          mainAxisAlignment:
                              canScroll ? MainAxisAlignment.start : MainAxisAlignment.end,
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
                            if (widget.isStreaming) ...[
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: _BreathingStatusDot(color: t.primary),
                              ),
                              const SizedBox(width: 6),
                            ],
                            ValueListenableBuilder<bool>(
                              valueListenable: _copied,
                              builder: (_, copied, __) => GrassBagSpringTap(
                                onTap: _copyMarkdown,
                                pressedScale: 0.92,
                                enablePointerGlow: false,
                                haptic: true,
                                child: GrassBagFresnelGlassSurface(
                                  isPill: true,
                                  innerWell: true,
                                  interactive: true,
                                  tintColor: copied ? t.okSoft : null,
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
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
                                      const SizedBox(width: 3.5),
                                      Text(
                                        copied ? '已复制' : '复制表格',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
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

        return Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: tableSolid
                ? tableCard
                : CustomPaint(
                    foregroundPainter: GrassBagFresnelRimPainter(
                      isDark: t.isDark,
                      borderRadius: 16,
                      innerWell: true,
                      frosted: tableTier == GrassBagGlassTier.frosted,
                      paintTopSheen: false,
                      strokeWidth: 0.8,
                    ),
                    child: tableCard,
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
        width: 34,
        height: 32,
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

final RegExp _mdCalloutRe = RegExp(
  r'^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\s+|$)',
  caseSensitive: false,
);
final RegExp _latexEnvRe = RegExp(r'\\(?:begin|end)\{(?:aligned|align\*?|gather\*?|equation\*?|cases|split)\}');
final RegExp _latexLineBreakRe = RegExp(r'\\\\(?:\[[^\]]*\])?');
final RegExp _latexBbRe = RegExp(r'\\mathbb\{([RNZQC])\}');
final RegExp _latexSymbolRe = RegExp(r'\\[a-zA-Z]+|\\[,;!]');
final RegExp _latexSupBracedRe = RegExp(r'\^\{([0-9+\-ni=()]+)\}');
final RegExp _latexSubBracedRe = RegExp(r'_\{([0-9+\-ijknx=()]+)\}');
final RegExp _latexSupSingleRe = RegExp(r'\^([0-9+\-ni])');
final RegExp _latexSubSingleRe = RegExp(r'_([0-9+\-ijknx])');

const Map<String, String> _latexBbMap = <String, String>{
  'R': 'ℝ',
  'N': 'ℕ',
  'Z': 'ℤ',
  'Q': 'ℚ',
  'C': 'ℂ',
};

const Map<String, String> _latexSymbolMap = <String, String>{
  r'\alpha': 'α',
  r'\beta': 'β',
  r'\gamma': 'γ',
  r'\delta': 'δ',
  r'\epsilon': 'ε',
  r'\varepsilon': 'ε',
  r'\theta': 'θ',
  r'\lambda': 'λ',
  r'\mu': 'μ',
  r'\nu': 'ν',
  r'\xi': 'ξ',
  r'\pi': 'π',
  r'\rho': 'ρ',
  r'\sigma': 'σ',
  r'\tau': 'τ',
  r'\phi': 'φ',
  r'\varphi': 'φ',
  r'\chi': 'χ',
  r'\psi': 'ψ',
  r'\omega': 'ω',
  r'\Gamma': 'Γ',
  r'\Delta': 'Δ',
  r'\Theta': 'Θ',
  r'\Lambda': 'Λ',
  r'\Pi': 'Π',
  r'\Sigma': 'Σ',
  r'\Phi': 'Φ',
  r'\Psi': 'Ψ',
  r'\Omega': 'Ω',
  r'\infty': '∞',
  r'\pm': '±',
  r'\mp': '∓',
  r'\times': '×',
  r'\div': '÷',
  r'\cdot': '·',
  r'\dots': '…',
  r'\cdots': '⋯',
  r'\ldots': '…',
  r'\leq': '≤',
  r'\le': '≤',
  r'\geq': '≥',
  r'\ge': '≥',
  r'\neq': '≠',
  r'\ne': '≠',
  r'\approx': '≈',
  r'\equiv': '≡',
  r'\sim': '∼',
  r'\propto': '∝',
  r'\rightarrow': '→',
  r'\to': '→',
  r'\leftarrow': '←',
  r'\leftrightarrow': '↔',
  r'\Rightarrow': '⇒',
  r'\Leftarrow': '⇐',
  r'\Leftrightarrow': '⇔',
  r'\iff': '⇔',
  r'\in': '∈',
  r'\notin': '∉',
  r'\subset': '⊂',
  r'\subseteq': '⊆',
  r'\cup': '∪',
  r'\cap': '∩',
  r'\emptyset': '∅',
  r'\forall': '∀',
  r'\exists': '∃',
  r'\partial': '∂',
  r'\nabla': '∇',
  r'\sum': '∑',
  r'\prod': '∏',
  r'\int': '∫',
  r'\degree': '°',
  r'\quad': '  ',
  r'\qquad': '   ',
  r'\,': ' ',
  r'\;': ' ',
  r'\!': '',
  r'\left': '',
  r'\right': '',
};

const Map<String, String> _latexSupMap = <String, String>{
  '0': '⁰',
  '1': '¹',
  '2': '²',
  '3': '³',
  '4': '⁴',
  '5': '⁵',
  '6': '⁶',
  '7': '⁷',
  '8': '⁸',
  '9': '⁹',
  '+': '⁺',
  '-': '⁻',
  '=': '⁼',
  '(': '⁽',
  ')': '⁾',
  'n': 'ⁿ',
  'i': 'ⁱ',
};

const Map<String, String> _latexSubMap = <String, String>{
  '0': '₀',
  '1': '₁',
  '2': '₂',
  '3': '₃',
  '4': '₄',
  '5': '₅',
  '6': '₆',
  '7': '₇',
  '8': '₈',
  '9': '₉',
  '+': '₊',
  '-': '₋',
  '=': '₌',
  '(': '₍',
  ')': '₎',
  'i': 'ᵢ',
  'j': 'ⱼ',
  'k': 'ₖ',
  'n': 'ₙ',
  'x': 'ₓ',
};

String _mapScriptChars(String raw, Map<String, String> table) {
  final sb = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    sb.write(table[ch] ?? ch);
  }
  return sb.toString();
}

/// Lightweight, balanced-brace LaTeX -> Unicode math pretty-formatter for inline & display math.
/// Preserves readability without external font bundles while display cards keep exact raw LaTeX on copy.
@visibleForTesting
String formatReadableLatexForTest(String tex) => _formatReadableLatex(tex);

@visibleForTesting
String stabilizeStreamingMarkdownForTest(String raw) =>
    _AssistantBodyState._stabilizeStreamingText(raw);

@visibleForTesting
List<String> splitMarkdownBlocksSummaryForTest(String raw) =>
    _AssistantBodyState._splitMarkdownBlocks(raw)
        .map((b) => '${b.kind.name}:${b.body}')
        .toList(growable: false);

int _findMatchingLatexBrace(String s, int openIdx) {
  if (openIdx < 0 || openIdx >= s.length || s.codeUnitAt(openIdx) != 0x7B /* '{' */) return -1;
  var depth = 0;
  for (var i = openIdx; i < s.length; i++) {
    final cu = s.codeUnitAt(i);
    if (cu == 0x5C /* '\' */ && i + 1 < s.length) {
      i++;
      continue;
    }
    if (cu == 0x7B) {
      depth++;
    } else if (cu == 0x7D) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

bool _isAsciiLetter(int cu) =>
    (cu >= 0x41 && cu <= 0x5A) || (cu >= 0x61 && cu <= 0x7A);

String _replaceLatexCmd1(
  String s,
  List<String> cmds,
  String Function(String arg) fmt,
) {
  final sb = StringBuffer();
  var i = 0;
  final len = s.length;
  while (i < len) {
    if (s.codeUnitAt(i) == 0x5C /* '\' */) {
      String? matched;
      for (final cmd in cmds) {
        if (s.startsWith(cmd, i)) {
          final afterCmd = i + cmd.length;
          if (afterCmd < len && _isAsciiLetter(s.codeUnitAt(afterCmd))) continue;
          matched = cmd;
          break;
        }
      }
      if (matched != null) {
        var j = i + matched.length;
        while (j < len && (s.codeUnitAt(j) == 0x20 || s.codeUnitAt(j) == 0x09)) {
          j++;
        }
        final close = _findMatchingLatexBrace(s, j);
        if (close > j) {
          sb.write(fmt(s.substring(j + 1, close)));
          i = close + 1;
          continue;
        }
      }
    }
    sb.writeCharCode(s.codeUnitAt(i));
    i++;
  }
  return sb.toString();
}

String _replaceLatexCmd2(
  String s,
  List<String> cmds,
  String Function(String a, String b) fmt,
) {
  final sb = StringBuffer();
  var i = 0;
  final len = s.length;
  while (i < len) {
    if (s.codeUnitAt(i) == 0x5C /* '\' */) {
      String? matched;
      for (final cmd in cmds) {
        if (s.startsWith(cmd, i)) {
          final afterCmd = i + cmd.length;
          if (afterCmd < len && _isAsciiLetter(s.codeUnitAt(afterCmd))) continue;
          matched = cmd;
          break;
        }
      }
      if (matched != null) {
        var j = i + matched.length;
        while (j < len && (s.codeUnitAt(j) == 0x20 || s.codeUnitAt(j) == 0x09)) {
          j++;
        }
        final close1 = _findMatchingLatexBrace(s, j);
        if (close1 > j) {
          var k = close1 + 1;
          while (k < len && (s.codeUnitAt(k) == 0x20 || s.codeUnitAt(k) == 0x09)) {
            k++;
          }
          final close2 = _findMatchingLatexBrace(s, k);
          if (close2 > k) {
            sb.write(fmt(s.substring(j + 1, close1), s.substring(k + 1, close2)));
            i = close2 + 1;
            continue;
          }
        }
      }
    }
    sb.writeCharCode(s.codeUnitAt(i));
    i++;
  }
  return sb.toString();
}

String _formatReadableLatex(String tex) {
  var s = tex.trim();
  if (s.isEmpty) return s;
  // Unwrap aligned/equation environments & line-break markers cleanly
  s = s.replaceAll(_latexEnvRe, '').trim();
  s = s.replaceAll(_latexLineBreakRe, '\n').replaceAll('&', ' ');
  // Expand `\mathbb{R}` and balanced-brace `\text`/`\mathrm`/`\sqrt`/`\frac` commands
  // so nested expressions like `\frac{x^{2}+1}{y_{i}-1}` and `\sqrt{a^{2}+b^{2}}` format cleanly!
  s = s.replaceAllMapped(_latexBbRe, (m) => _latexBbMap[m.group(1)!] ?? m.group(0)!);
  const textCmds = <String>[
    r'\operatorname',
    r'\boldsymbol',
    r'\mathrm',
    r'\mathbf',
    r'\mathit',
    r'\mathsf',
    r'\mathtt',
    r'\text',
  ];
  const sqrtCmds = <String>[r'\sqrt'];
  const fracCmds = <String>[r'\dfrac', r'\tfrac', r'\frac'];
  for (var pass = 0; pass < 4; pass++) {
    final prev = s;
    s = _replaceLatexCmd1(s, textCmds, (arg) => arg);
    s = _replaceLatexCmd1(s, sqrtCmds, (arg) => '√(${arg.trim()})');
    s = _replaceLatexCmd2(s, fracCmds, (a, b) => '(${a.trim()}) / (${b.trim()})');
    if (s == prev) break;
  }
  s = s.replaceAllMapped(_latexSymbolRe, (m) {
    final tok = m.group(0)!;
    return _latexSymbolMap[tok] ?? tok;
  });
  s = s.replaceAllMapped(_latexSupBracedRe, (m) => _mapScriptChars(m.group(1)!, _latexSupMap));
  s = s.replaceAllMapped(_latexSubBracedRe, (m) => _mapScriptChars(m.group(1)!, _latexSubMap));
  s = s.replaceAllMapped(_latexSupSingleRe, (m) => _latexSupMap[m.group(1)!] ?? m.group(0)!);
  s = s.replaceAllMapped(_latexSubSingleRe, (m) => _latexSubMap[m.group(1)!] ?? m.group(0)!);
  return s.trim();
}

class _DisplayMathCard extends StatefulWidget {
  const _DisplayMathCard({
    super.key,
    required this.rawLatex,
    this.isStreaming = false,
  });

  final String rawLatex;
  final bool isStreaming;

  @override
  State<_DisplayMathCard> createState() => _DisplayMathCardState();
}

class _DisplayMathCardState extends State<_DisplayMathCard> {
  bool _copied = false;
  String? _cachedRaw;
  String _cachedFormatted = '';

  String _formattedFor(String raw) {
    if (_cachedRaw == raw) return _cachedFormatted;
    _cachedRaw = raw;
    _cachedFormatted = _formatReadableLatex(raw);
    return _cachedFormatted;
  }

  void _copyLatex() {
    Clipboard.setData(ClipboardData(text: widget.rawLatex));
    if (!_copied) {
      setState(() => _copied = true);
      Future<void>.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _copied = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final formatted = _formattedFor(widget.rawLatex);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: GrassBagFresnelGlassSurface(
        borderRadius: 15,
        innerWell: true,
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectionContainer.disabled(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 8, 2),
                child: Row(
                  children: [
                    if (widget.isStreaming) ...[
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: _BreathingStatusDot(color: t.primary),
                      ),
                      const SizedBox(width: 5),
                    ],
                    Text(
                      '公式',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: t.text3,
                      ),
                    ),
                    const Spacer(),
                    Tooltip(
                      message: _copied ? '已复制 LaTeX' : '复制 LaTeX 源码',
                      excludeFromSemantics: true,
                      child: Semantics(
                        button: true,
                        label: _copied ? '已复制 LaTeX' : '复制 LaTeX 源码',
                        child: GrassBagSpringTap(
                          onTap: _copyLatex,
                          pressedScale: 0.94,
                          haptic: true,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _copied ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
                                  size: 11.5,
                                  color: _copied ? t.ok : t.text3,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _copied ? '已复制 LaTeX' : '复制 LaTeX',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: _copied ? t.ok : t.text3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 4, 16, 12),
              child: Text(
                formatted,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  height: 1.6,
                  fontStyle: FontStyle.italic,
                  color: t.isDark ? t.primaryHi : t.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Synthesizes a clean unified diff preview from tool call args (`old_string`/`new_string`,
/// `oldText`/`newText`, or `patch`/`diff`) for inline display inside expanded edit tool rows.
({String unified, int added, int removed})? _synthesizeInlineDiffFromArgs(Map argsMap) {
  if (argsMap.isEmpty) return null;
  final rawPatch = (argsMap['patch'] ?? argsMap['diff'] ?? argsMap['unifiedDiff'])?.toString().trim();
  if (rawPatch != null && rawPatch.isNotEmpty) {
    var added = 0;
    var removed = 0;
    for (final line in rawPatch.split('\n')) {
      if (line.startsWith('+') && !line.startsWith('+++')) added++;
      if (line.startsWith('-') && !line.startsWith('---')) removed++;
    }
    return (unified: rawPatch, added: added, removed: removed);
  }
  final oldStr = (argsMap['old_string'] ?? argsMap['oldString'] ?? argsMap['oldText'] ?? argsMap['target'])
      ?.toString();
  final newStr = (argsMap['new_string'] ?? argsMap['newString'] ?? argsMap['newText'] ?? argsMap['replacement'])
      ?.toString();
  if (oldStr == null && newStr == null) {
    final content = (argsMap['content'] ?? argsMap['text'] ?? argsMap['body'])?.toString();
    if (content == null || content.isEmpty) return null;
    final allLines = content.split('\n');
    const previewCap = 160;
    final shown = allLines.length > previewCap ? allLines.sublist(0, previewCap) : allLines;
    final buf = StringBuffer('@@ -0,0 +1,${allLines.length} @@\n');
    for (final l in shown) {
      buf.writeln('+$l');
    }
    if (allLines.length > previewCap) {
      buf.writeln('... (+${allLines.length - previewCap} more lines)');
    }
    return (
      unified: buf.toString().trimRight(),
      added: allLines.length,
      removed: 0,
    );
  }
  final oldLines = (oldStr != null && oldStr.isNotEmpty) ? oldStr.split('\n') : const <String>[];
  final newLines = (newStr != null && newStr.isNotEmpty) ? newStr.split('\n') : const <String>[];
  if (oldLines.isEmpty && newLines.isEmpty) return null;
  final buf = StringBuffer('@@ -1,${oldLines.length} +1,${newLines.length} @@\n');
  for (final l in oldLines) {
    buf.writeln('-$l');
  }
  for (final l in newLines) {
    buf.writeln('+$l');
  }
  return (
    unified: buf.toString().trimRight(),
    added: newLines.length,
    removed: oldLines.length,
  );
}

/// Syntax-colored unified diff span (distinguishes `+++`/`---` headers, `@@` hunks, `+` adds, `-` removes).
/// Adapts between crisp Xcode Light ink (on luminous pearl `codeBg`) and Obsidian Dark ink.
TextSpan _highlightDiffSpan(String displayText, {bool isDark = true}) {
  final displayLines = displayText.split('\n');
  final baseColor = isDark ? const Color(0xFFE2E8F0) : const Color(0xFF142436);
  final hdrStyle = TextStyle(
    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF5D728A),
    fontWeight: FontWeight.w600,
  );
  final hunkStyle = TextStyle(
    color: isDark ? const Color(0xFFC4B5FD) : const Color(0xFF6D35C7),
    backgroundColor: isDark ? const Color(0x1F8B5CF6) : const Color(0x168B5CF6),
    fontWeight: FontWeight.w600,
  );
  final addStyle = TextStyle(
    color: isDark ? const Color(0xFF6EE7B7) : const Color(0xFF0D7A4F),
    backgroundColor: isDark ? const Color(0x1F10B981) : const Color(0x1C10B981),
  );
  final delStyle = TextStyle(
    color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFFC42B2B),
    backgroundColor: isDark ? const Color(0x1FEF4444) : const Color(0x1AEF4444),
  );
  return TextSpan(
    style: TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      height: 1.52,
      color: baseColor,
    ),
    children: [
      for (int li = 0; li < displayLines.length; li++)
        () {
          final line = displayLines[li];
          final text = li == displayLines.length - 1 ? line : '$line\n';
          if (line.startsWith('+++') || line.startsWith('---') || line.startsWith('diff ')) {
            return TextSpan(text: text, style: hdrStyle);
          }
          if (line.startsWith('@@')) {
            return TextSpan(text: text, style: hunkStyle);
          }
          if (line.startsWith('+')) {
            return TextSpan(text: text, style: addStyle);
          }
          if (line.startsWith('-')) {
            return TextSpan(text: text, style: delStyle);
          }
          return TextSpan(text: text);
        }(),
    ],
  );
}

/// Zero-dependency, single-pass O(N) syntax highlighter for dark code cards.
/// Cached by `_FencedCodeBlockState` so scrolling and sibling rebuilds cost 0ms.
const String _kCodeTokenTailPattern =
    r'|"(?:\\.|[^"\\\n])*"' // double-quoted strings
    r"|'(?:\\.|[^'\\\n])*'" // single-quoted strings
    r'|`(?:\\.|[^`\\])*`' // backtick strings
    r'|@[A-Za-z_][A-Za-z0-9_]*' // annotations
    r'|\b0[xX][0-9a-fA-F_]+\b|\b\d+(?:\.\d+)?\b' // numbers
    r'|\b[A-Z][A-Za-z0-9_]*\b' // PascalCase types
    r'|\b[a-z_][A-Za-z0-9_]*\b'; // identifiers & keywords

final RegExp _codeTokenReGeneric = RegExp(
  r'(?://[^\n]*|/\*[\s\S]*?\*/|#[^\n]*)' + _kCodeTokenTailPattern,
);
final RegExp _codeTokenReCStyle = RegExp(
  r'(?://[^\n]*|/\*[\s\S]*?\*/)' + _kCodeTokenTailPattern,
);
final RegExp _codeTokenReHashOnly = RegExp(
  r'(?:#[^\n]*)' + _kCodeTokenTailPattern,
);

const Set<String> _codeKeywords = <String>{
  'abstract', 'as', 'async', 'await', 'bool', 'break', 'case', 'catch', 'class',
  'const', 'continue', 'covariant', 'def', 'default', 'defer', 'del', 'do', 'double',
  'dynamic', 'elif', 'else', 'enum', 'except', 'export', 'extends', 'extension',
  'external', 'factory', 'false', 'final', 'finally', 'float', 'fn', 'for', 'from',
  'func', 'function', 'get', 'go', 'if', 'impl', 'implements', 'import', 'in', 'int',
  'interface', 'is', 'lambda', 'late', 'let', 'match', 'mixin', 'mut', 'new', 'nil',
  'none', 'null', 'object', 'on', 'override', 'package', 'part', 'pass', 'private',
  'protected', 'pub', 'public', 'raise', 'required', 'return', 'sealed', 'select',
  'self', 'set', 'static', 'str', 'string', 'struct', 'super', 'switch', 'sync',
  'this', 'throw', 'trait', 'true', 'try', 'type', 'typedef', 'typeof', 'use', 'val',
  'var', 'void', 'where', 'while', 'with', 'yield',
  'SELECT', 'FROM', 'WHERE', 'INSERT', 'INTO', 'UPDATE', 'DELETE', 'JOIN', 'LEFT',
  'RIGHT', 'INNER', 'GROUP', 'ORDER', 'BY', 'LIMIT', 'CREATE', 'TABLE', 'ALTER',
};

const Set<String> _hashCommentLangs = <String>{
  'py', 'python', 'sh', 'bash', 'zsh', 'shell', 'yaml', 'yml', 'toml', 'rb', 'ruby', 'r', 'perl',
};

const Set<String> _noBlockCommentLangs = <String>{
  'py', 'python', 'sh', 'bash', 'zsh', 'shell', 'yaml', 'yml', 'toml', 'rb', 'ruby', 'r', 'perl',
  'ini', 'conf', 'cfg', 'env', 'dockerfile', 'makefile', 'json', 'md', 'markdown', 'txt', 'text',
  'plaintext', 'csv', 'tsv', 'html', 'xml', 'svg',
};

const TextStyle _kCodeCommentStyleDark = TextStyle(
  color: Color(0xFF8B9EB5),
  fontStyle: FontStyle.italic,
);
const TextStyle _kCodeCommentStyleLight = TextStyle(
  color: Color(0xFF6B7C93),
  fontStyle: FontStyle.italic,
);

TextSpan _highlightCodeSpan(String code, String rawLang, {bool isDark = true}) {
  final lang = rawLang.trim().toLowerCase();
  if (lang == 'diff' || lang == 'patch') {
    return _highlightDiffSpan(code, isDark: isDark);
  }
  final baseStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    height: 1.52,
    color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF142436),
  );
  // Skip tokenization on giant blobs (> 24k chars) to guarantee zero frame hitch.
  if (code.length > 24000) {
    return TextSpan(text: code, style: baseStyle);
  }
  final commentStyle = isDark ? _kCodeCommentStyleDark : _kCodeCommentStyleLight;
  final strStyle = TextStyle(
    color: isDark ? const Color(0xFF86EFAC) : const Color(0xFF0F7A52),
  );
  final keyOrFnStyle = TextStyle(
    color: isDark ? const Color(0xFF7DD3FC) : const Color(0xFF0E689D),
  );
  final annoStyle = TextStyle(
    color: isDark ? const Color(0xFFFDE68A) : const Color(0xFF9E5A00),
  );
  final numStyle = TextStyle(
    color: isDark ? const Color(0xFFFDBA74) : const Color(0xFFB84A0A),
  );
  final kwStyle = TextStyle(
    color: isDark ? const Color(0xFFC084FC) : const Color(0xFF8B2FC9),
    fontWeight: FontWeight.w600,
  );
  final typeStyle = TextStyle(
    color: isDark ? const Color(0xFF93C5FD) : const Color(0xFF1B56B5),
  );

  final isHashOnly = _hashCommentLangs.contains(lang);
  final allowHashComment = lang.isEmpty || isHashOnly;
  final tokenRe = isHashOnly
      ? _codeTokenReHashOnly
      : (lang.isEmpty ? _codeTokenReGeneric : _codeTokenReCStyle);
  final isJson = lang == 'json' || lang == 'jsonc';
  final spans = <TextSpan>[];
  var cursor = 0;

  for (final m in tokenRe.allMatches(code)) {
    if (m.start > cursor) {
      spans.add(TextSpan(text: code.substring(cursor, m.start)));
    }
    final tok = m.group(0)!;
    final first = tok.codeUnitAt(0);
    TextStyle? style;
    if (!isHashOnly && (tok.startsWith('//') || tok.startsWith('/*'))) {
      style = commentStyle;
    } else if (first == 0x23 /* '#' */) {
      if (allowHashComment) {
        style = commentStyle;
      }
    } else if (first == 0x22 /* '"' */ || first == 0x27 /* "'" */ || first == 0x60 /* '`' */) {
      if (isJson && first == 0x22) {
        // Check if followed by `:` (JSON key vs string value)
        var look = m.end;
        while (look < code.length && (code.codeUnitAt(look) == 0x20 || code.codeUnitAt(look) == 0x09)) {
          look++;
        }
        style = (look < code.length && code.codeUnitAt(look) == 0x3A /* ':' */)
            ? keyOrFnStyle
            : strStyle;
      } else {
        style = strStyle;
      }
    } else if (first == 0x40 /* '@' */) {
      style = annoStyle;
    } else if (first >= 0x30 && first <= 0x39) {
      style = numStyle;
    } else if (first >= 0x41 && first <= 0x5A) {
      style = _codeKeywords.contains(tok) ? kwStyle : typeStyle;
    } else {
      if (_codeKeywords.contains(tok)) {
        style = kwStyle;
      } else if (m.end < code.length && code.codeUnitAt(m.end) == 0x28 /* '(' */) {
        style = keyOrFnStyle;
      }
    }
    spans.add(TextSpan(text: tok, style: style));
    cursor = m.end;
  }
  if (cursor < code.length) {
    spans.add(TextSpan(text: code.substring(cursor)));
  }
  return TextSpan(style: baseStyle, children: spans);
}

/// Scans `line` starting at `from` for an unquoted C-style `/*` block-comment opener,
/// skipping `'...'`, `"..."`, and `` `...` `` string literals (with `\` escapes) and
/// stopping cleanly at unquoted `//` (or `#` when `allowHashComment` is true).
int _findUnquotedBlockCommentOpen(
  String line,
  int from, {
  required bool allowHashComment,
}) {
  final len = line.length;
  var i = from;
  while (i < len) {
    final cu = line.codeUnitAt(i);
    if (cu == 0x22 /* '"' */ || cu == 0x27 /* "'" */ || cu == 0x60 /* '`' */) {
      final quote = cu;
      i++;
      while (i < len) {
        final c = line.codeUnitAt(i);
        if (c == 0x5C /* '\' */ && i + 1 < len) {
          i += 2;
          continue;
        }
        if (c == quote) {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    if (allowHashComment && cu == 0x23 /* '#' */) {
      return -1;
    }
    if (cu == 0x2F && i + 1 < len) {
      final next = line.codeUnitAt(i + 1);
      if (next == 0x2F) return -1;
      if (next == 0x2A) return i;
    }
    i++;
  }
  return -1;
}

@visibleForTesting
({InlineSpan span, bool endInBlockComment}) highlightCodeLineForTest(
  String lineWithNl,
  String rawLang, {
  bool startInBlockComment = false,
}) =>
    _highlightLineIncremental(lineWithNl, rawLang, startInBlockComment);

/// Highlights a single line while propagating multi-line `/* ... */` block-comment state
/// ONLY for C-style-comment languages and strictly outside string literals!
({InlineSpan span, bool endInBlockComment}) _highlightLineIncremental(
  String lineWithNl,
  String rawLang,
  bool startInBlockComment, {
  bool isDark = true,
}) {
  final lang = rawLang.trim().toLowerCase();
  final commentStyle = isDark ? _kCodeCommentStyleDark : _kCodeCommentStyleLight;
  final supportsBlockComments = !_noBlockCommentLangs.contains(lang);
  if (!supportsBlockComments || (!startInBlockComment && !lineWithNl.contains('/*'))) {
    return (span: _highlightCodeSpan(lineWithNl, rawLang, isDark: isDark), endInBlockComment: false);
  }
  final allowHashComment = lang.isEmpty || _hashCommentLangs.contains(lang);
  final spans = <InlineSpan>[];
  var cursor = 0;
  var inComment = startInBlockComment;
  final len = lineWithNl.length;
  while (cursor < len) {
    if (inComment) {
      final closeIdx = lineWithNl.indexOf('*/', cursor);
      if (closeIdx < 0) {
        spans.add(TextSpan(text: lineWithNl.substring(cursor), style: commentStyle));
        return (span: TextSpan(children: spans), endInBlockComment: true);
      }
      spans.add(TextSpan(text: lineWithNl.substring(cursor, closeIdx + 2), style: commentStyle));
      cursor = closeIdx + 2;
      inComment = false;
    } else {
      final openIdx = _findUnquotedBlockCommentOpen(
        lineWithNl,
        cursor,
        allowHashComment: allowHashComment,
      );
      if (openIdx < 0) {
        spans.add(_highlightCodeSpan(lineWithNl.substring(cursor), rawLang, isDark: isDark));
        return (span: TextSpan(children: spans), endInBlockComment: false);
      }
      if (openIdx > cursor) {
        spans.add(_highlightCodeSpan(lineWithNl.substring(cursor, openIdx), rawLang, isDark: isDark));
      }
      final closeIdx = lineWithNl.indexOf('*/', openIdx + 2);
      if (closeIdx < 0) {
        spans.add(TextSpan(text: lineWithNl.substring(openIdx), style: commentStyle));
        return (span: TextSpan(children: spans), endInBlockComment: true);
      }
      spans.add(TextSpan(text: lineWithNl.substring(openIdx, closeIdx + 2), style: commentStyle));
      cursor = closeIdx + 2;
    }
  }
  return (span: TextSpan(children: spans), endInBlockComment: inComment);
}

class _FencedCodeBlock extends StatefulWidget {
  const _FencedCodeBlock({
    super.key,
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
  bool _userToggled = false;
  late bool _expanded;
  String? _cachedHighlightLang;
  bool? _cachedHighlightStreaming;
  bool? _cachedHighlightIsDark;
  String? _cachedHighlightText;
  TextSpan? _cachedBaseSpan;
  TextSpan? _cachedHighlightSpan;
  String? _cachedLineCountCode;
  int _cachedLineCount = 1;
  // Line-level incremental highlight cache with block-comment state propagation so streaming
  // even a 300-line block with `/* ... */` tokenizes ONLY the active tail line in O(line)!
  String _cachedLineLang = '';
  bool? _cachedLineIsDark;
  final List<String> _cachedLines = [];
  final List<bool> _cachedLineEndInComment = [];
  final List<InlineSpan> _cachedLineSpans = [];

  @override
  void initState() {
    super.initState();
    _expanded = widget.isStreaming || widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(covariant _FencedCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_userToggled && (widget.isStreaming || widget.initiallyExpanded) && !_expanded) {
      _expanded = true;
    }
  }

  @override
  void dispose() {
    _hCtrl.dispose();
    super.dispose();
  }

  int _lineCountFor(String s) {
    if (identical(_cachedLineCountCode, s) || _cachedLineCountCode == s) {
      return _cachedLineCount;
    }
    var count = 1;
    final len = s.length;
    for (var i = 0; i < len; i++) {
      if (s.codeUnitAt(i) == 0x0A /* '\n' */) count++;
    }
    _cachedLineCountCode = s;
    _cachedLineCount = count;
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

  TextSpan _ensureBaseSpan(String displayText, bool isDark) {
    if (_cachedBaseSpan != null &&
        _cachedHighlightLang == widget.lang &&
        _cachedHighlightIsDark == isDark &&
        _cachedHighlightText == displayText) {
      return _cachedBaseSpan!;
    }
    final lang = widget.lang.trim().toLowerCase();
    final canIncremental = displayText.length <= 24000 && lang != 'diff' && lang != 'patch';
    TextSpan baseSpan;
    if (canIncremental) {
      if (_cachedLineLang != lang || _cachedLineIsDark != isDark) {
        _cachedLineLang = lang;
        _cachedLineIsDark = isDark;
        _cachedLines.clear();
        _cachedLineEndInComment.clear();
        _cachedLineSpans.clear();
      }
      final lines = displayText.split('\n');
      var common = 0;
      final limit = math.min(_cachedLines.length, lines.length);
      // Completed lines before the final line hit O(1) string equality!
      while (common < limit - 1 && _cachedLines[common] == lines[common]) {
        common++;
      }
      if (common < _cachedLines.length) {
        _cachedLines.removeRange(common, _cachedLines.length);
        _cachedLineEndInComment.removeRange(common, _cachedLineEndInComment.length);
        _cachedLineSpans.removeRange(common, _cachedLineSpans.length);
      }
      var inComment = common > 0 ? _cachedLineEndInComment[common - 1] : false;
      for (var i = common; i < lines.length; i++) {
        final lineText = lines[i];
        final lineWithNl = i == lines.length - 1 ? lineText : '$lineText\n';
        final res = _highlightLineIncremental(lineWithNl, widget.lang, inComment, isDark: isDark);
        inComment = res.endInBlockComment;
        _cachedLines.add(lineText);
        _cachedLineEndInComment.add(inComment);
        _cachedLineSpans.add(res.span);
      }
      baseSpan = TextSpan(
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.52,
          color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF142436),
        ),
        children: List<InlineSpan>.of(_cachedLineSpans, growable: false),
      );
    } else {
      baseSpan = _highlightCodeSpan(displayText, widget.lang, isDark: isDark);
    }
    _cachedBaseSpan = baseSpan;
    return baseSpan;
  }

  Widget _buildCodeText(String displayText, GrassBagTokens t) {
    if (_cachedHighlightSpan == null ||
        _cachedHighlightLang != widget.lang ||
        _cachedHighlightIsDark != t.isDark ||
        _cachedHighlightStreaming != widget.isStreaming ||
        _cachedHighlightText != displayText) {
      final baseSpan = _ensureBaseSpan(displayText, t.isDark);
      _cachedHighlightLang = widget.lang;
      _cachedHighlightIsDark = t.isDark;
      _cachedHighlightStreaming = widget.isStreaming;
      _cachedHighlightText = displayText;
      _cachedHighlightSpan = widget.isStreaming
          ? TextSpan(
              style: baseSpan.style,
              children: [
                if (baseSpan.children != null) ...baseSpan.children! else baseSpan,
                const TextSpan(text: '\u2060'),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: SelectionContainer.disabled(
                    child: _LiveStreamingCaret(
                      color: t.isDark ? t.primaryHi : t.primary,
                      height: 13.5,
                    ),
                  ),
                ),
              ],
            )
          : baseSpan;
    }
    return Text.rich(
      _cachedHighlightSpan!,
      softWrap: _softWrap,
    );
  }

  void _openFullscreenCode(BuildContext context, int lineCount) {
    final t = GrassBagTokens.of(context);
    final label = widget.lang.isEmpty ? '代码查看' : '${widget.lang} · $lineCount 行';
    final fullSpan = (_cachedHighlightText == widget.code &&
            _cachedHighlightIsDark == t.isDark &&
            _cachedBaseSpan != null)
        ? _cachedBaseSpan!
        : _highlightCodeSpan(widget.code, widget.lang, isDark: t.isDark);
    var sheetSoftWrap = _softWrap;
    var sheetCopied = false;
    showGrassBagSheet(
      context,
      title: label,
      subtitle: '可横向滚动、切换自动换行或划选复制',
      icon: CupertinoIcons.chevron_left_slash_chevron_right,
      preferredHeight: 500,
      expandable: true,
      bodyBuilder: (_) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final st = GrassBagTokens.of(sheetCtx);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  GrassBagSpringTap(
                    onTap: () => setSheetState(() => sheetSoftWrap = !sheetSoftWrap),
                    child: GrassBagFresnelGlassSurface(
                      isPill: true,
                      innerWell: true,
                      tintColor: sheetSoftWrap ? st.primarySoft : null,
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6.5),
                      child: Text(
                        sheetSoftWrap ? '切换单行' : '自动换行',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: sheetSoftWrap ? (st.isDark ? st.primaryHi : st.primary) : st.text2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GrassBagSpringTap(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: widget.code));
                      HapticFeedback.selectionClick();
                      setSheetState(() => sheetCopied = true);
                      Future<void>.delayed(const Duration(milliseconds: 1400), () {
                        if (sheetCtx.mounted) setSheetState(() => sheetCopied = false);
                      });
                    },
                    child: GrassBagFresnelGlassSurface(
                      isPill: true,
                      innerWell: true,
                      tintColor: sheetCopied ? st.okSoft : null,
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6.5),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            sheetCopied ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
                            size: 12.5,
                            color: sheetCopied ? st.ok : st.text2,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            sheetCopied ? '已复制' : '复制代码',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: sheetCopied ? st.ok : st.text2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Builder(
                builder: (wellCtx) {
                  final wellTier = resolveAmbientGlassTier(wellCtx);
                  final wellBox = Container(
                    decoration: ShapeDecoration(
                      color: st.codeBg,
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: wellTier == GrassBagGlassTier.solid
                            ? BorderSide(
                                color: st.isDark ? Colors.white.withValues(alpha: 0.11) : st.sep,
                                width: 0.7,
                              )
                            : BorderSide.none,
                      ),
                    ),
                    padding: const EdgeInsets.all(13),
                    child: sheetSoftWrap
                        ? SelectionArea(
                            contextMenuBuilder: buildGrassBagSelectableContextMenu,
                            child: Text.rich(fullSpan, softWrap: true),
                          )
                        : SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SelectionArea(
                              contextMenuBuilder: buildGrassBagSelectableContextMenu,
                              child: Text.rich(fullSpan, softWrap: false),
                            ),
                          ),
                  );
                  if (wellTier == GrassBagGlassTier.solid) return wellBox;
                  return CustomPaint(
                    foregroundPainter: GrassBagFresnelRimPainter(
                      isDark: st.isDark,
                      borderRadius: 16,
                      accent: st.isDark ? st.primaryHi : null,
                      innerWell: true,
                      frosted: wellTier == GrassBagGlassTier.frosted,
                      paintTopSheen: false,
                      strokeWidth: 0.8,
                    ),
                    child: wellBox,
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final lineCount = _lineCountFor(widget.code);
    final isLong = !widget.isStreaming && lineCount > _collapseThreshold;
    final showFullscreenBtn = !widget.isStreaming && (lineCount > 12 || widget.code.length > 500);
    final displayText =
        (isLong && !_expanded) ? _takeFirstLines(widget.code, _collapsedPreviewLines) : widget.code;
    final barMuted = t.isDark ? const Color(0xFF94A3B8) : t.text2;
    final barDim = t.isDark ? const Color(0xFF8B9EB5) : t.text3;
    final barCopy = t.isDark ? const Color(0xFFCBD5E1) : t.text;
    final barOk = t.isDark ? const Color(0xFF34D399) : t.ok;

    final codeTier = resolveAmbientGlassTier(context);
    final codeSolid = codeTier == GrassBagGlassTier.solid;
    final codeBox = DecoratedBox(
      decoration: ShapeDecoration(
        color: t.codeBg,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(16),
          side: codeSolid
              ? BorderSide(
                  color: t.isDark ? Colors.white.withValues(alpha: 0.10) : t.sep,
                  width: 0.7,
                )
              : BorderSide.none,
        ),
      ),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectionContainer.disabled(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                decoration: BoxDecoration(
                  color: t.codeBar,
                  border: Border(
                    bottom: BorderSide(
                      color: t.isDark
                          ? Colors.white.withValues(alpha: 0.065)
                          : t.sep.withValues(alpha: t.sep.a * 0.72),
                      width: 0.5,
                    ),
                  ),
                ),
                child: LayoutBuilder(
                  builder: (headerCtx, headerBox) {
                    final compactBar = headerBox.maxWidth < 310 ||
                        MediaQuery.textScalerOf(headerCtx).scale(1.0) > 1.15;
                    final actionPad = compactBar
                        ? const EdgeInsets.symmetric(horizontal: 8, vertical: 9)
                        : const EdgeInsets.symmetric(horizontal: 8, vertical: 8);
                    return Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              if (widget.isStreaming) ...[
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: _BreathingStatusDot(
                                    color: t.isDark ? t.primaryHi : t.primary,
                                  ),
                                ),
                                const SizedBox(width: 5),
                              ],
                              Flexible(
                                child: Text(
                                  widget.lang.isEmpty ? 'code' : widget.lang,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: barMuted,
                                  ),
                                ),
                              ),
                              if (lineCount > 10 && !compactBar) ...[
                                const SizedBox(width: 6),
                                Text(
                                  '$lineCount 行',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                    color: barDim,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (isLong)
                          Semantics(
                            button: true,
                            label: _expanded ? '收起代码' : '展开代码',
                            child: Tooltip(
                              message: _expanded ? '收起代码' : '展开代码',
                              excludeFromSemantics: true,
                              child: GrassBagSpringTap(
                                haptic: true,
                                onTap: () => setState(() {
                                  _userToggled = true;
                                  _expanded = !_expanded;
                                }),
                                child: Padding(
                                  padding: actionPad,
                                  child: compactBar
                                      ? Icon(
                                          _expanded
                                              ? CupertinoIcons.chevron_up
                                              : CupertinoIcons.chevron_down,
                                          size: 13,
                                          color: barMuted,
                                        )
                                      : Text(
                                          _expanded ? '收起' : '展开',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: barMuted,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ),
                        if (showFullscreenBtn)
                          Semantics(
                            button: true,
                            label: '全屏查看代码',
                            child: Tooltip(
                              message: '全屏查看代码',
                              excludeFromSemantics: true,
                              child: GrassBagSpringTap(
                                haptic: true,
                                onTap: () => _openFullscreenCode(context, lineCount),
                                child: Padding(
                                  padding: actionPad,
                                  child: compactBar
                                      ? Icon(
                                          CupertinoIcons.arrow_up_left_arrow_down_right,
                                          size: 12.5,
                                          color: barMuted,
                                        )
                                      : Text(
                                          '全屏',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: barMuted,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ),
                        Semantics(
                          button: true,
                          toggled: _softWrap,
                          label: _softWrap ? '切换单行滚动' : '切换自动换行',
                          child: Tooltip(
                            message: _softWrap ? '切换单行滚动' : '切换自动换行',
                            excludeFromSemantics: true,
                            child: GrassBagSpringTap(
                              haptic: true,
                              onTap: () => setState(() => _softWrap = !_softWrap),
                              child: Padding(
                                padding: actionPad,
                                child: compactBar
                                    ? Icon(
                                        CupertinoIcons.text_alignleft,
                                        size: 13,
                                        color: _softWrap
                                            ? (t.isDark ? t.primaryHi : t.primary)
                                            : barMuted,
                                      )
                                    : Text(
                                        _softWrap ? '单行' : '换行',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: _softWrap
                                              ? (t.isDark ? t.primaryHi : t.primary)
                                              : barMuted,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        GrassBagSpringTap(
                          enablePointerGlow: false,
                          haptic: true,
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: widget.code));
                            setState(() => _copied = true);
                            Future<void>.delayed(const Duration(milliseconds: 1400), () {
                              if (mounted) setState(() => _copied = false);
                            });
                          },
                          child: GrassBagFresnelGlassSurface(
                            isPill: true,
                            innerWell: true,
                            interactive: true,
                            tintColor: _copied ? t.okSoft : null,
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _copied ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
                                  size: 11.5,
                                  color: _copied ? barOk : barCopy,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _copied ? '已复制' : '复制',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: _copied ? barOk : barCopy,
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
              ),
              AnimatedSize(
                duration: widget.isStreaming
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _softWrap
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: _buildCodeText(displayText, t),
                      )
                    : _HorizontalCodeScroller(
                        controller: _hCtrl,
                        fadeColor: t.codeBg,
                        child: _buildCodeText(displayText, t),
                      ),
              ),
              if (isLong && !_expanded)
                SelectionContainer.disabled(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() {
                      _userToggled = true;
                      _expanded = true;
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      decoration: BoxDecoration(
                        color: t.codeBar.withValues(alpha: t.isDark ? 0.72 : 0.84),
                        border: Border(
                          top: BorderSide(
                            color: t.isDark ? Colors.white.withValues(alpha: 0.08) : t.sep,
                            width: 0.6,
                          ),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '展开剩余 ${lineCount - _collapsedPreviewLines} 行（共 $lineCount 行）',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: t.text2,
                        ),
                      ),
                    ),
                  ),
                )
              else if (isLong && _expanded && lineCount > 40)
                SelectionContainer.disabled(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() {
                      _userToggled = true;
                      _expanded = false;
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      decoration: BoxDecoration(
                        color: t.codeBar.withValues(alpha: t.isDark ? 0.72 : 0.84),
                        border: Border(
                          top: BorderSide(
                            color: t.isDark ? Colors.white.withValues(alpha: 0.08) : t.sep,
                            width: 0.6,
                          ),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '收起代码（共 $lineCount 行）',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: t.text2,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: codeSolid
          ? codeBox
          : CustomPaint(
              foregroundPainter: GrassBagFresnelRimPainter(
                isDark: t.isDark,
                borderRadius: 16,
                accent: t.isDark ? t.primaryHi : null,
                innerWell: true,
                frosted: codeTier == GrassBagGlassTier.frosted,
                paintTopSheen: false,
                strokeWidth: 0.82,
              ),
              child: codeBox,
            ),
    );
  }
}

class _TurnUsageMicroBadge extends StatelessWidget {
  const _TurnUsageMicroBadge({required this.usage, this.toolCount = 0});
  final TurnUsage usage;
  final int toolCount;

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
    final durMs = usage.durationMs ?? 0;
    final durLabel = durMs >= 500 ? '${(durMs / 1000).toStringAsFixed(1)}s' : null;
    // Only display `t/s` when no multi-second tool calls polluted wall-clock `durationMs`.
    final tps = (toolCount == 0 && durMs >= 500 && usage.outputTokens > 0)
        ? (usage.outputTokens / (durMs / 1000.0))
        : null;
    final parts = <String>[
      if (usage.inputTokens > 0) '↑${_fmtTok(usage.inputTokens)}',
      if (usage.outputTokens > 0) '↓${_fmtTok(usage.outputTokens)}',
      if (hitPct != null) '缓存 $hitPct%',
      if (durLabel != null) durLabel,
      if (tps != null && tps >= 1.0) '${tps.round()} t/s',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return GrassBagFresnelGlassSurface(
      isPill: true,
      innerWell: true,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5.5),
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

/// Smooth height + fade reveal when a freshly streamed reply finishes typing
/// (historical turns mount immediately at full height & opacity with zero animation!).
class _ReplyActionStripReveal extends StatefulWidget {
  const _ReplyActionStripReveal({
    required this.animate,
    required this.child,
  });

  final bool animate;
  final Widget child;

  @override
  State<_ReplyActionStripReveal> createState() => _ReplyActionStripRevealState();
}

class _ReplyActionStripRevealState extends State<_ReplyActionStripReveal>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;
  Animation<double>? _size;
  Animation<double>? _fade;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _ctrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 220),
      );
      _size = CurvedAnimation(parent: _ctrl!, curve: Curves.easeOutCubic);
      _fade = CurvedAnimation(
        parent: _ctrl!,
        curve: const Interval(0.15, 1.0, curve: Curves.easeOut),
      );
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
    final size = _size;
    final fade = _fade;
    final ctrl = _ctrl;
    if (size == null || fade == null || ctrl == null) return widget.child;
    return AnimatedBuilder(
      animation: ctrl,
      child: widget.child,
      builder: (_, child) {
        if (ctrl.status == AnimationStatus.completed) return child!;
        return ClipRect(
          child: SizeTransition(
            sizeFactor: size,
            axisAlignment: -1.0,
            child: FadeTransition(
              opacity: fade,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// Zero-layout-twitch, non-copyable breathing capsule caret for streaming prose & code blocks.
class _LiveStreamingCaret extends StatefulWidget {
  const _LiveStreamingCaret({required this.color, this.height = 15.0});

  final Color color;
  final double height;

  @override
  State<_LiveStreamingCaret> createState() => _LiveStreamingCaretState();
}

class _LiveStreamingCaretState extends State<_LiveStreamingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 780),
      value: 1.0,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shouldRun = WidgetsBinding.instance is WidgetsFlutterBinding &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        !MediaQuery.disableAnimationsOf(context);
    if (shouldRun && !_running) {
      _running = true;
      _ctrl.repeat(reverse: true);
    } else if (!shouldRun && _running) {
      _running = false;
      _ctrl.stop();
      _ctrl.value = 1.0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.only(left: 2.5),
        child: SizedBox(
          width: 2.5,
          height: widget.height,
          child: CustomPaint(
            painter: _StreamingCaretPainter(animation: _ctrl, color: widget.color),
          ),
        ),
      ),
    );
  }
}

class _StreamingCaretPainter extends CustomPainter {
  _StreamingCaretPainter({required this.animation, required this.color})
      : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final v = Curves.easeInOut.transform(animation.value);
    _paint.color = color.withValues(alpha: 0.28 + 0.66 * v);
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.width * 0.5),
    );
    canvas.drawRRect(rrect, _paint);
  }

  @override
  bool shouldRepaint(covariant _StreamingCaretPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.animation != animation;
}

class _QuietReplyAction extends StatelessWidget {
  const _QuietReplyAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.showLabel = false,
    this.active = false,
    this.warnActive = false,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool showLabel;
  final bool active;
  final bool warnActive;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final activeFg = warnActive ? t.warn : t.ok;
    final activeBg = warnActive ? t.warnSoft : t.okSoft;
    final fg = !enabled
        ? t.text3.withValues(alpha: 0.34)
        : (active ? activeFg : t.text3);
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        selected: active,
        enabled: enabled,
        label: label,
        child: GrassBagSpringTap(
          onTap: onTap,
          enabled: enabled,
          pressedScale: 0.90,
          haptic: true,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
            padding: EdgeInsets.symmetric(horizontal: showLabel ? 10 : 8.5, vertical: 7),
          decoration: ShapeDecoration(
            color: active && enabled
                ? activeBg
                : (showLabel && enabled ? t.fill1 : Colors.transparent),
            shape: StadiumBorder(
              side: BorderSide(
                color: active && enabled
                    ? activeFg.withValues(alpha: 0.28)
                    : (showLabel && enabled ? t.sep : Colors.transparent),
                width: 0.6,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: fg),
              if (showLabel) ...[
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
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// Horizontal code block scroller that ONLY renders left/right gradient fades when
/// horizontal overflow exists (`maxScrollExtent > 2`), prevents desktop Shift+Wheel
/// from simultaneously scrolling the outer chat list vertically via `pointerSignalResolver`.
class _HorizontalCodeScroller extends StatefulWidget {
  const _HorizontalCodeScroller({
    required this.controller,
    required this.fadeColor,
    required this.child,
  });

  final ScrollController controller;
  final Color fadeColor;
  final Widget child;

  @override
  State<_HorizontalCodeScroller> createState() => _HorizontalCodeScrollerState();
}

class _HorizontalCodeScrollerState extends State<_HorizontalCodeScroller> {
  final ValueNotifier<(bool, bool)> _fadeEdges = ValueNotifier<(bool, bool)>((false, false));

  void _syncFade(ScrollMetrics m) {
    final canLeft = m.maxScrollExtent > 2.0 && m.pixels > 2.0;
    final canRight = m.maxScrollExtent > 2.0 && m.pixels < m.maxScrollExtent - 2.0;
    if (_fadeEdges.value.$1 != canLeft || _fadeEdges.value.$2 != canRight) {
      _fadeEdges.value = (canLeft, canRight);
    }
  }

  @override
  void dispose() {
    _fadeEdges.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent &&
                HardwareKeyboard.instance.isShiftPressed &&
                widget.controller.hasClients &&
                widget.controller.position.maxScrollExtent > 0) {
              GestureBinding.instance.pointerSignalResolver.register(event, (PointerSignalEvent resolved) {
                if (resolved is! PointerScrollEvent || !widget.controller.hasClients) return;
                final next = (widget.controller.offset + resolved.scrollDelta.dy)
                    .clamp(0.0, widget.controller.position.maxScrollExtent);
                widget.controller.jumpTo(next);
              });
            }
          },
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (n) {
              _syncFade(n.metrics);
              return false;
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                _syncFade(n.metrics);
                return false;
              },
              child: CupertinoScrollbar(
                controller: widget.controller,
                thumbVisibility: false,
                child: SingleChildScrollView(
                  controller: widget.controller,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(12),
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          left: 0,
          width: 16,
          child: IgnorePointer(
            child: ValueListenableBuilder<(bool, bool)>(
              valueListenable: _fadeEdges,
              builder: (_, edges, __) {
                if (!edges.$1) return const SizedBox.shrink();
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        widget.fadeColor.withValues(alpha: 0.90),
                        widget.fadeColor.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: 18,
          child: IgnorePointer(
            child: ValueListenableBuilder<(bool, bool)>(
              valueListenable: _fadeEdges,
              builder: (_, edges, __) {
                if (!edges.$2) return const SizedBox.shrink();
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        widget.fadeColor.withValues(alpha: 0.0),
                        widget.fadeColor.withValues(alpha: 0.90),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
