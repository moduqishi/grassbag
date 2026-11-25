import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import 'schemastery_form.dart';

typedef SduiActionCallback = FutureOr<String?> Function(String actionId, Map<String, dynamic>? payload);

/// Tier 2 SDUI v1 Declarative Native Renderer supporting all 14 atomic node types
/// from `docs/gbridge-v1-spec.md` §6 (`column`, `row`, `card`, `section`, `tabs`,
/// `text`, `markdown`, `code_diff`, `metric`, `kv_list`, `progress`, `badge`,
/// `table`, `chart`, `schema_form`, `actions`).
class SduiNodeRenderer extends StatelessWidget {
  const SduiNodeRenderer({
    super.key,
    required this.node,
    required this.tier,
    required this.onAction,
    this.onCopied,
    this.depth = 0,
  });

  static const int maxDepth = 24;

  final Map<String, dynamic> node;
  final GrassBagGlassTier tier;
  final SduiActionCallback onAction;
  final ValueChanged<String>? onCopied;
  final int depth;

  @override
  Widget build(BuildContext context) {
    if (depth > maxDepth) {
      final t = GrassBagTokens.of(context);
      return Text(
        '（嵌套层级超过上限，已省略渲染）',
        style: TextStyle(fontSize: 12, color: t.text3),
      );
    }
    final type = node['type']?.toString() ?? 'text';
    return switch (type) {
      'column' => _buildColumn(context),
      'row' => _buildRow(context),
      'card' || 'section' => _SduiCardSection(
          node: node,
          tier: tier,
          onAction: onAction,
          onCopied: onCopied,
          depth: depth,
        ),
      'tabs' => _SduiTabsNode(
          node: node,
          tier: tier,
          onAction: onAction,
          onCopied: onCopied,
          depth: depth,
        ),
      'metric' => _buildMetric(context),
      'kv_list' => _buildKvList(context),
      'progress' => _buildProgress(context),
      'badge' => _buildBadge(context),
      'table' => _buildTable(context),
      'chart' => _buildChart(context),
      'code_diff' => _buildCodeDiff(context),
      'schema_form' => _buildSchemaForm(context),
      'actions' => _buildActions(context),
      'button' => _buildSingleAction(context, node),
      'alert' => _buildAlert(context),
      'markdown' => _buildMarkdown(context),
      'text' || _ => _buildText(context),
    };
  }

  static List<Map<String, dynamic>> _mapList(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  static Map<String, dynamic> _mapOrEmpty(Object? raw) =>
      raw is Map ? Map<String, dynamic>.from(raw) : const {};

  static double _parseFiniteDouble(Object? raw, {double fallback = 0.0}) {
    final v = raw is num ? raw.toDouble() : double.tryParse(raw?.toString().trim() ?? '');
    return (v != null && v.isFinite) ? v : fallback;
  }

  List<Map<String, dynamic>> _children() => _mapList(node['children']);

  Widget _buildColumn(BuildContext context) {
    final gap = _parseFiniteDouble(node['gap'], fallback: 10.0).clamp(0.0, 64.0).toDouble();
    final items = _children();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          SduiNodeRenderer(
            node: items[i],
            tier: tier,
            onAction: onAction,
            onCopied: onCopied,
            depth: depth + 1,
          ),
        ],
      ],
    );
  }

  Widget _buildRow(BuildContext context) {
    final gap = _parseFiniteDouble(node['gap'], fallback: 10.0).clamp(0.0, 64.0).toDouble();
    final items = _children();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(width: gap),
          Expanded(
            child: SduiNodeRenderer(
              node: items[i],
              tier: tier,
              onAction: onAction,
              onCopied: onCopied,
              depth: depth + 1,
            ),
          ),
        ],
      ],
    );
  }

  Color _toneColor(GrassBagTokens t, String? tone) => switch (tone) {
        'good' || 'ok' => t.ok,
        'warn' || 'warning' => t.warn,
        'bad' || 'danger' || 'error' => t.err,
        'accent' || 'info' => t.primary,
        'muted' => t.text3,
        _ => t.text,
      };

  Widget _buildMarkdown(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final raw = node['value']?.toString() ?? '';
    final tone = _toneColor(t, node['tone']?.toString());
    final lines = raw.split('\n');
    final inlineRe = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\))');

    List<InlineSpan> parseInline(String text, TextStyle base) {
      final spans = <InlineSpan>[];
      var cursor = 0;
      for (final m in inlineRe.allMatches(text)) {
        if (m.start > cursor) {
          spans.add(TextSpan(text: text.substring(cursor, m.start)));
        }
        final tok = m.group(0)!;
        if (tok.startsWith('**') && tok.endsWith('**') && tok.length > 4) {
          spans.add(
            TextSpan(
              text: tok.substring(2, tok.length - 2),
              style: base.copyWith(fontWeight: FontWeight.w700),
            ),
          );
        } else if (tok.startsWith('`') && tok.endsWith('`') && tok.length > 2) {
          spans.add(
            TextSpan(
              text: tok.substring(1, tok.length - 1),
              style: base.copyWith(
                fontFamily: 'monospace',
                fontSize: (base.fontSize ?? 14.0) - 1.0,
                backgroundColor: t.fill1,
              ),
            ),
          );
        } else if (tok.startsWith('[')) {
          final sep = tok.indexOf('](');
          final label = sep > 1 ? tok.substring(1, sep) : tok;
          spans.add(
            TextSpan(
              text: label,
              style: base.copyWith(color: t.primary, fontWeight: FontWeight.w500),
            ),
          );
        } else {
          spans.add(TextSpan(text: tok));
        }
        cursor = m.end;
      }
      if (cursor < text.length) {
        spans.add(TextSpan(text: text.substring(cursor)));
      }
      return spans;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final rawLine in lines)
          if (rawLine.trim().isEmpty)
            const SizedBox(height: 6)
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: () {
                final trimmed = rawLine.trim();
                if (trimmed.startsWith('### ')) {
                  return Text(
                    trimmed.substring(4).trim(),
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: tone),
                  );
                }
                if (trimmed.startsWith('## ')) {
                  return Text(
                    trimmed.substring(3).trim(),
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: tone),
                  );
                }
                if (trimmed.startsWith('# ')) {
                  return Text(
                    trimmed.substring(2).trim(),
                    style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: tone),
                  );
                }
                final isBullet = trimmed.startsWith('- ') || trimmed.startsWith('* ');
                final body = isBullet ? trimmed.substring(2).trim() : trimmed;
                final baseStyle = TextStyle(fontSize: 14, height: 1.48, color: tone);
                final rich = Text.rich(TextSpan(style: baseStyle, children: parseInline(body, baseStyle)));
                if (!isBullet) return rich;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 7, right: 7),
                      child: Container(
                        width: 4.5,
                        height: 4.5,
                        decoration: BoxDecoration(color: t.primary, shape: BoxShape.circle),
                      ),
                    ),
                    Expanded(child: rich),
                  ],
                );
              }(),
            ),
      ],
    );
  }

  Widget _buildText(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final val = node['value']?.toString() ?? '';
    final style = node['style']?.toString() ?? 'body';
    final tone = _toneColor(t, node['tone']?.toString());
    return Text(
      val,
      style: TextStyle(
        fontSize: switch (style) {
          'title' => 16,
          'caption' => 12,
          'mono' => 12.5,
          _ => 14,
        },
        fontWeight: style == 'title' ? FontWeight.w600 : FontWeight.w400,
        fontFamily: style == 'mono' ? 'monospace' : null,
        height: 1.48,
        color: tone,
      ),
    );
  }

  Widget _buildMetric(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final label = node['label']?.toString() ?? '';
    final value = node['value']?.toString() ?? '-';
    final delta = node['delta']?.toString();
    final color = _toneColor(t, node['tone']?.toString());
    return GrassBagCard(
      borderRadius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: t.text3)),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: color),
          ),
          if (delta != null && delta.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(delta, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
          ],
        ],
      ),
    );
  }

  Widget _buildKvList(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final raw = _mapList(node['items']);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < raw.length; i++) ...[
          if (i > 0) Divider(height: 14, thickness: 0.5, color: t.sep),
          Row(
            children: [
              Expanded(
                flex: 4,
                child: Text(raw[i]['key']?.toString() ?? '', style: TextStyle(fontSize: 13, color: t.text3)),
              ),
              Expanded(
                flex: 6,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        raw[i]['value']?.toString() ?? '',
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          fontFamily: raw[i]['copyable'] == true ? 'monospace' : null,
                          color: t.text,
                        ),
                      ),
                    ),
                    if (raw[i]['copyable'] == true) ...[
                      const SizedBox(width: 4),
                      GrassBagSpringTap(
                        onTap: () {
                          final val = raw[i]['value']?.toString() ?? '';
                          Clipboard.setData(ClipboardData(text: val));
                          onCopied?.call(val);
                        },
                        haptic: true,
                        pressedScale: 0.88,
                        child: SizedBox(
                          width: 34,
                          height: 34,
                          child: Center(
                            child: Icon(CupertinoIcons.doc_on_doc, size: 13.5, color: t.primary),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildProgress(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final val = _parseFiniteDouble(node['value']);
    final maxVal = _parseFiniteDouble(node['max'], fallback: 100.0);
    final rawRatio = maxVal <= 0 ? 0.0 : val / maxVal;
    final ratio = rawRatio.isFinite ? rawRatio.clamp(0.0, 1.0).toDouble() : 0.0;
    final label = node['label']?.toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(label, style: TextStyle(fontSize: 12.5, color: t.text2)),
          const SizedBox(height: 8),
        ],
        GrassBagProgressBar(
          value: ratio,
          height: 6.5,
          trackColor: t.fill1,
          color: t.primary,
        ),
      ],
    );
  }

  Widget _buildBadge(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tone = _toneColor(t, node['tone']?.toString());
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: tone.withValues(alpha: t.isDark ? 0.22 : 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          node['label']?.toString() ?? '',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: tone),
        ),
      ),
    );
  }

  Widget _buildTable(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final rawCols = node['columns'];
    final cols = rawCols is List ? rawCols.map((e) => e.toString()).toList() : const <String>[];
    final rawRows = node['rows'];
    final rows = rawRows is List
        ? rawRows
            .whereType<List<dynamic>>()
            .map((r) => r.map((c) => c.toString()).toList())
            .toList()
        : const <List<String>>[];
    final colCount = cols.isNotEmpty
        ? cols.length
        : rows.fold<int>(0, (m, r) => math.max(m, r.length));
    if (colCount == 0) return const SizedBox.shrink();
    final tableBody = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (cols.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                for (var i = 0; i < colCount; i++)
                  Expanded(
                    flex: i == 0 ? 16 : 9,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        i < cols.length ? cols[i] : '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.text3),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        for (final row in rows) ...[
          Divider(height: 1, thickness: 0.5, color: t.sep),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                for (var i = 0; i < colCount; i++)
                  Expanded(
                    flex: i == 0 ? 16 : 9,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        i < row.length ? row[i] : '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: i == 0 ? FontWeight.w500 : FontWeight.w400,
                          color: i == 0 ? t.text : t.text2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
    if (colCount < 4) return tableBody;
    return LayoutBuilder(
      builder: (_, box) {
        final minW = math.max(box.maxWidth.isFinite ? box.maxWidth : 320.0, colCount * 110.0);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: minW, child: tableBody),
        );
      },
    );
  }

  Widget _buildChart(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final chartType = node['chartType']?.toString() ?? 'bar';
    final rawSeries = _mapList(node['series']);
    final parsedSeries = <({String name, List<Map<String, dynamic>> points})>[
      for (final s in rawSeries)
        if (_mapList(s['points']).isNotEmpty)
          (name: s['name']?.toString() ?? '', points: _mapList(s['points'])),
    ];
    if (parsedSeries.isEmpty) return const SizedBox.shrink();
    final palette = <Color>[t.primary, t.ok, t.warn, t.dusk];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (parsedSeries.length > 1) ...[
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (var i = 0; i < parsedSeries.length; i++)
                if (parsedSeries[i].name.isNotEmpty)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: palette[i % palette.length],
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(parsedSeries[i].name, style: TextStyle(fontSize: 11, color: t.text2)),
                    ],
                  ),
            ],
          ),
          const SizedBox(height: 6),
        ],
        SizedBox(
          height: 148,
          child: CustomPaint(
            painter: _SduiChartPainter(
              chartType: chartType,
              seriesList: [for (final s in parsedSeries) s.points],
              palette: palette,
              labelColor: t.text3,
              gridColor: t.sep,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }

  Widget _buildAlert(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final toneName = node['tone']?.toString() ?? 'warn';
    final tone = _toneColor(t, toneName);
    final title = node['title']?.toString() ?? '';
    final message = node['message']?.toString() ?? node['value']?.toString() ?? '';
    final icon = switch (toneName) {
      'good' || 'ok' => CupertinoIcons.checkmark_circle_fill,
      'bad' || 'danger' || 'error' => CupertinoIcons.exclamationmark_triangle_fill,
      'accent' || 'info' => CupertinoIcons.info_circle_fill,
      _ => CupertinoIcons.exclamationmark_circle_fill,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: t.isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tone.withValues(alpha: 0.35), width: 0.7),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: tone),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title.isNotEmpty)
                  Text(
                    title,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: tone),
                  ),
                if (message.isNotEmpty) ...[
                  if (title.isNotEmpty) const SizedBox(height: 3),
                  Text(
                    message,
                    style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text2),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeDiff(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final path = node['path']?.toString() ?? 'diff';
    final diff = node['diff']?.toString() ?? '';
    final lines = diff.split('\n');
    var maxCols = 40;
    for (final l in lines) {
      var cols = 0;
      for (final cu in l.codeUnits) {
        cols += cu > 0xFF ? 2 : 1;
      }
      if (cols > maxCols) maxCols = cols;
    }
    final contentWidth = (maxCols * 7.4 + 28.0).clamp(280.0, 2600.0);

    return RepaintBoundary(
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: ShapeDecoration(
            color: t.codeBg,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.08), width: 0.6),
            ),
          ),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              color: t.codeBar,
              child: Text(
                path,
                style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: t.codeFg),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: contentWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final line in lines)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          color: line.startsWith('+') && !line.startsWith('+++')
                              ? t.ok.withValues(alpha: 0.16)
                              : (line.startsWith('-') && !line.startsWith('---')
                                  ? t.err.withValues(alpha: 0.16)
                                  : null),
                          child: Text(
                            line,
                            softWrap: false,
                            overflow: TextOverflow.visible,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              color: line.startsWith('+') && !line.startsWith('+++')
                                  ? const Color(0xFF6EE7B7)
                                  : (line.startsWith('-') && !line.startsWith('---')
                                      ? const Color(0xFFFCA5A5)
                                      : (line.startsWith('@@')
                                          ? const Color(0xFF93C5FD)
                                          : t.codeFg)),
                            ),
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
    );
  }

  Widget _buildSchemaForm(BuildContext context) {
    final schema = _mapOrEmpty(node['schema']);
    final values = _mapOrEmpty(node['values']);
    final submitId = node['submitActionId']?.toString() ?? 'submit';
    return SchemasteryForm(
      schema: schema,
      initialValues: values,
      tier: tier,
      onSubmit: (v) async => await onAction(submitId, v),
    );
  }

  Widget _buildActions(BuildContext context) {
    final items = _mapList(node['items']);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          _buildSingleAction(context, item),
      ],
    );
  }

  Widget _buildSingleAction(BuildContext context, Map<String, dynamic> item) {
    final id = (item['id'] ?? item['actionId'])?.toString() ?? 'action';
    final label = item['label']?.toString() ?? id;
    final style = (item['style'] ?? item['variant'])?.toString() ?? 'secondary';
    final confirmText = item['confirmText']?.toString().trim();
    final payload = item['payload'] is Map
        ? Map<String, dynamic>.from(item['payload'] as Map)
        : null;
    return _SduiActionButton(
      actionId: id,
      label: label,
      style: style,
      confirmText: confirmText,
      payload: payload,
      tier: tier,
      onAction: onAction,
    );
  }
}

class _SduiActionButton extends StatefulWidget {
  const _SduiActionButton({
    required this.actionId,
    required this.label,
    required this.style,
    required this.confirmText,
    required this.payload,
    required this.tier,
    required this.onAction,
  });

  final String actionId;
  final String label;
  final String style;
  final String? confirmText;
  final Map<String, dynamic>? payload;
  final GrassBagGlassTier tier;
  final SduiActionCallback onAction;

  @override
  State<_SduiActionButton> createState() => _SduiActionButtonState();
}

class _SduiActionButtonState extends State<_SduiActionButton> {
  bool _busy = false;
  String? _error;

  Future<void> _trigger() async {
    if (_busy) return;
    final confirm = widget.confirmText;
    if (confirm != null && confirm.isNotEmpty) {
      final ok = await showGrassBagConfirmDialog(
        context,
        title: widget.label,
        message: confirm,
        confirmLabel: '确认执行',
        isDestructive: widget.style == 'danger',
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? err;
    try {
      err = await widget.onAction(widget.actionId, widget.payload);
    } catch (e) {
      err = e.toString();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = err;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final btn = widget.style == 'primary'
        ? GrassBagPrimaryGlassButton(
            label: _busy ? '执行中…' : widget.label,
            height: 40,
            tier: widget.tier,
            insideGlass: true,
            enabled: !_busy,
            onTap: _busy ? null : _trigger,
          )
        : GrassBagSecondaryGlassButton(
            label: _busy ? '执行中…' : widget.label,
            height: 40,
            tier: widget.tier,
            insideGlass: true,
            destructive: widget.style == 'danger',
            enabled: !_busy,
            onTap: _busy ? null : _trigger,
          );
    if (_error == null) return btn;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        btn,
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 4),
          child: Text(_error!, style: TextStyle(fontSize: 11.5, color: t.err)),
        ),
      ],
    );
  }
}

class _SduiCardSection extends StatefulWidget {
  const _SduiCardSection({
    required this.node,
    required this.tier,
    required this.onAction,
    this.onCopied,
    required this.depth,
  });

  final Map<String, dynamic> node;
  final GrassBagGlassTier tier;
  final SduiActionCallback onAction;
  final ValueChanged<String>? onCopied;
  final int depth;

  @override
  State<_SduiCardSection> createState() => _SduiCardSectionState();
}

class _SduiCardSectionState extends State<_SduiCardSection> {
  late bool _collapsed;

  @override
  void initState() {
    super.initState();
    _collapsed = widget.node['collapsed'] == true;
  }

  @override
  void didUpdateWidget(covariant _SduiCardSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldCollapsed = oldWidget.node['collapsed'] == true;
    final newCollapsed = widget.node['collapsed'] == true;
    if (oldCollapsed != newCollapsed) {
      _collapsed = newCollapsed;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final title = widget.node['title']?.toString();
    final subtitle = widget.node['subtitle']?.toString();
    final collapsible = widget.node['collapsible'] == true;
    final children = SduiNodeRenderer._mapList(widget.node['children']);

    return GrassBagCard(
      borderRadius: 22,
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: collapsible ? () => setState(() => _collapsed = !_collapsed) : null,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.text),
                        ),
                        if (subtitle != null)
                          Text(subtitle, style: TextStyle(fontSize: 12, color: t.text3)),
                      ],
                    ),
                  ),
                  if (collapsible)
                    Icon(
                      _collapsed ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_up,
                      size: 14,
                      color: t.text3,
                    ),
                ],
              ),
            ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: (!_collapsed && children.isNotEmpty)
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (title != null) const SizedBox(height: 12),
                      for (var i = 0; i < children.length; i++) ...[
                        if (i > 0) const SizedBox(height: 10),
                        SduiNodeRenderer(
                          node: children[i],
                          tier: widget.tier,
                          onAction: widget.onAction,
                          onCopied: widget.onCopied,
                          depth: widget.depth + 1,
                        ),
                      ],
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _SduiTabsNode extends StatefulWidget {
  const _SduiTabsNode({
    required this.node,
    required this.tier,
    required this.onAction,
    this.onCopied,
    required this.depth,
  });

  final Map<String, dynamic> node;
  final GrassBagGlassTier tier;
  final SduiActionCallback onAction;
  final ValueChanged<String>? onCopied;
  final int depth;

  @override
  State<_SduiTabsNode> createState() => _SduiTabsNodeState();
}

class _SduiTabsNodeState extends State<_SduiTabsNode> {
  int _idx = 0;

  @override
  Widget build(BuildContext context) {
    final items = SduiNodeRenderer._mapList(widget.node['items']);
    if (items.isEmpty) return const SizedBox.shrink();
    final safeIdx = _idx.clamp(0, items.length - 1);
    final rawChild = items[safeIdx]['child'];
    final child = rawChild is Map ? Map<String, dynamic>.from(rawChild) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        GrassBagSegmentedControl(
          labels: [for (final it in items) it['label']?.toString() ?? ''],
          selectedIndex: safeIdx,
          tier: widget.tier,
          onSelected: (i) => setState(() => _idx = i),
        ),
        const SizedBox(height: 12),
        if (child != null)
          SduiNodeRenderer(
            key: ValueKey('sdui-tab-$safeIdx'),
            node: child,
            tier: widget.tier,
            onAction: widget.onAction,
            onCopied: widget.onCopied,
            depth: widget.depth + 1,
          ),
      ],
    );
  }
}

class _SduiChartPainter extends CustomPainter {
  const _SduiChartPainter({
    required this.chartType,
    required this.seriesList,
    required this.palette,
    required this.labelColor,
    required this.gridColor,
  });

  final String chartType;
  final List<List<Map<String, dynamic>>> seriesList;
  final List<Color> palette;
  final Color labelColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (seriesList.isEmpty || size.width <= 0 || size.height <= 0) return;
    final count = seriesList.fold<int>(0, (m, pts) => math.max(m, pts.length));
    if (count == 0) return;
    var maxY = 1.0;
    for (final pts in seriesList) {
      for (final p in pts) {
        final v = SduiNodeRenderer._parseFiniteDouble(p['y']);
        if (v > maxY) maxY = v;
      }
    }
    final plotBottom = size.height - 22;
    final plotTop = 8.0;
    final plotH = math.max(20.0, plotBottom - plotTop);

    // Subtle baseline grid
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.6;
    canvas.drawLine(Offset(0, plotBottom), Offset(size.width, plotBottom), gridPaint);
    canvas.drawLine(Offset(0, plotTop + plotH * 0.5), Offset(size.width, plotTop + plotH * 0.5), gridPaint);

    final slotW = size.width / count;

    if (chartType == 'line') {
      for (var sIdx = 0; sIdx < seriesList.length; sIdx++) {
        final pts = seriesList[sIdx];
        final color = palette[sIdx % palette.length];
        final path = Path();
        final linePaint = Paint()
          ..color = color
          ..strokeWidth = 2.4
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
        for (var i = 0; i < pts.length; i++) {
          final y = math.max(0.0, SduiNodeRenderer._parseFiniteDouble(pts[i]['y']));
          final cx = slotW * (i + 0.5);
          final cy = plotBottom - (y / maxY) * plotH;
          if (i == 0) {
            path.moveTo(cx, cy);
          } else {
            path.lineTo(cx, cy);
          }
          canvas.drawCircle(Offset(cx, cy), pts.length > 24 ? 2.2 : 3.2, Paint()..color = color);
        }
        canvas.drawPath(path, linePaint);
      }
    } else {
      final sCount = seriesList.length;
      final groupW = math.min(slotW * 0.72, sCount * 28.0);
      final singleBarW = (groupW / sCount).clamp(2.5, math.max(2.5, math.min(28.0, slotW * 0.62)));
      for (var sIdx = 0; sIdx < sCount; sIdx++) {
        final pts = seriesList[sIdx];
        final color = palette[sIdx % palette.length];
        for (var i = 0; i < pts.length; i++) {
          final y = math.max(0.0, SduiNodeRenderer._parseFiniteDouble(pts[i]['y']));
          if (y <= 0) continue;
          final h = math.max(2.0, (y / maxY) * plotH);
          final groupLeft = slotW * (i + 0.5) - (singleBarW * sCount) / 2;
          final left = groupLeft + sIdx * singleBarW;
          final radius = Radius.circular(math.min(6.0, singleBarW / 2));
          final rrect = RRect.fromRectAndCorners(
            Rect.fromLTWH(left, plotBottom - h, math.max(1.5, singleBarW - (sCount > 1 ? 1.5 : 0.0)), h),
            topLeft: radius,
            topRight: radius,
          );
          canvas.drawRRect(
            rrect,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [color, color.withValues(alpha: 0.55)],
              ).createShader(rrect.outerRect),
          );
        }
      }
    }

    // X-axis labels (automatically thinned on dense series + collision-checked so
    // rightmost adjacent ticks never collide)
    final primaryPoints = seriesList.first;
    final maxLabels = math.max(2, (size.width / 46.0).floor());
    final labelStep = math.max(1, (count / maxLabels).ceil());
    final lastIdx = primaryPoints.length - 1;
    var lastPaintedRight = double.negativeInfinity;
    for (var i = 0; i < primaryPoints.length; i++) {
      if (i != 0 && i != lastIdx && i % labelStep != 0) continue;
      final lbl = primaryPoints[i]['x']?.toString() ?? '';
      if (lbl.isEmpty) continue;
      final tp = TextPainter(
        text: TextSpan(text: lbl, style: TextStyle(fontSize: 10.5, color: labelColor)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(18.0, slotW * labelStep - 4.0));
      final dx = (slotW * (i + 0.5) - tp.width / 2)
          .clamp(0.0, math.max(0.0, size.width - tp.width))
          .toDouble();
      if (dx < lastPaintedRight + 4.0) continue;
      tp.paint(canvas, Offset(dx, plotBottom + 5));
      lastPaintedRight = dx + tp.width;
    }
  }

  @override
  bool shouldRepaint(covariant _SduiChartPainter old) =>
      old.chartType != chartType ||
      old.seriesList != seriesList ||
      old.palette != palette ||
      old.labelColor != labelColor ||
      old.gridColor != gridColor;
}
