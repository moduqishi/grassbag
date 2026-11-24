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
  });

  final Map<String, dynamic> node;
  final GrassBagGlassTier tier;
  final SduiActionCallback onAction;
  final ValueChanged<String>? onCopied;

  @override
  Widget build(BuildContext context) {
    final type = node['type']?.toString() ?? 'text';
    return switch (type) {
      'column' => _buildColumn(context),
      'row' => _buildRow(context),
      'card' || 'section' => _SduiCardSection(
          node: node,
          tier: tier,
          onAction: onAction,
          onCopied: onCopied,
        ),
      'tabs' => _SduiTabsNode(
          node: node,
          tier: tier,
          onAction: onAction,
          onCopied: onCopied,
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
      'markdown' || 'text' || _ => _buildText(context),
    };
  }

  List<Map<String, dynamic>> _children() {
    final raw = node['children'];
    if (raw is! List) return const [];
    return raw.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  Widget _buildColumn(BuildContext context) {
    final gap = (node['gap'] as num?)?.toDouble() ?? 10.0;
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
          ),
        ],
      ],
    );
  }

  Widget _buildRow(BuildContext context) {
    final gap = (node['gap'] as num?)?.toDouble() ?? 10.0;
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
    final raw = (node['items'] as List<dynamic>?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
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
    final val = (node['value'] as num?)?.toDouble() ?? 0.0;
    final maxVal = (node['max'] as num?)?.toDouble() ?? 100.0;
    final ratio = maxVal <= 0 ? 0.0 : (val / maxVal).clamp(0.0, 1.0);
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
    final cols = (node['columns'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [];
    final rows = (node['rows'] as List<dynamic>?)
            ?.whereType<List<dynamic>>()
            .map((r) => r.map((c) => c.toString()).toList())
            .toList() ??
        const [];
    final colCount = cols.isNotEmpty ? cols.length : (rows.isNotEmpty ? rows.first.length : 0);
    final tableBody = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (cols.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                for (var i = 0; i < cols.length; i++)
                  Expanded(
                    flex: i == 0 ? 16 : 9,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        cols[i],
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
                for (var i = 0; i < row.length; i++)
                  Expanded(
                    flex: i == 0 ? 16 : 9,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        row[i],
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
    final series = (node['series'] as List<dynamic>?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
    final points = series.isEmpty
        ? const <Map<String, dynamic>>[]
        : ((series.first['points'] as List<dynamic>?)?.whereType<Map<String, dynamic>>().toList() ?? const []);
    if (points.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 148,
      child: CustomPaint(
        painter: _SduiChartPainter(
          chartType: chartType,
          points: points,
          barColor: t.primary,
          secondaryColor: t.dusk,
          labelColor: t.text3,
          gridColor: t.sep,
        ),
        child: const SizedBox.expand(),
      ),
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
    final schema = (node['schema'] as Map<String, dynamic>?) ?? const {};
    final values = (node['values'] as Map<String, dynamic>?) ?? const {};
    final submitId = node['submitActionId']?.toString() ?? 'submit';
    return SchemasteryForm(
      schema: schema,
      initialValues: values,
      tier: tier,
      onSubmit: (v) async => await onAction(submitId, v),
    );
  }

  Widget _buildActions(BuildContext context) {
    final items = (node['items'] as List<dynamic>?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
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
    final payload = item['payload'] is Map<String, dynamic>
        ? item['payload'] as Map<String, dynamic>
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
  });

  final Map<String, dynamic> node;
  final GrassBagGlassTier tier;
  final SduiActionCallback onAction;
  final ValueChanged<String>? onCopied;

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
    final children = (widget.node['children'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList(growable: false) ??
        const [];

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
  });

  final Map<String, dynamic> node;
  final GrassBagGlassTier tier;
  final SduiActionCallback onAction;
  final ValueChanged<String>? onCopied;

  @override
  State<_SduiTabsNode> createState() => _SduiTabsNodeState();
}

class _SduiTabsNodeState extends State<_SduiTabsNode> {
  int _idx = 0;

  @override
  Widget build(BuildContext context) {
    final items = (widget.node['items'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList(growable: false) ??
        const [];
    if (items.isEmpty) return const SizedBox.shrink();
    final safeIdx = _idx.clamp(0, items.length - 1);
    final child = items[safeIdx]['child'];
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
        if (child is Map<String, dynamic>)
          SduiNodeRenderer(
            key: ValueKey('sdui-tab-$safeIdx'),
            node: child,
            tier: widget.tier,
            onAction: widget.onAction,
            onCopied: widget.onCopied,
          ),
      ],
    );
  }
}

class _SduiChartPainter extends CustomPainter {
  const _SduiChartPainter({
    required this.chartType,
    required this.points,
    required this.barColor,
    required this.secondaryColor,
    required this.labelColor,
    required this.gridColor,
  });

  final String chartType;
  final List<Map<String, dynamic>> points;
  final Color barColor;
  final Color secondaryColor;
  final Color labelColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final maxY = points
        .map((p) => (p['y'] as num?)?.toDouble() ?? 0.0)
        .fold<double>(1.0, math.max);
    final plotBottom = size.height - 22;
    final plotTop = 8.0;
    final plotH = math.max(20.0, plotBottom - plotTop);

    // Subtle baseline grid
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.6;
    canvas.drawLine(Offset(0, plotBottom), Offset(size.width, plotBottom), gridPaint);
    canvas.drawLine(Offset(0, plotTop + plotH * 0.5), Offset(size.width, plotTop + plotH * 0.5), gridPaint);

    final count = points.length;
    final slotW = size.width / count;

    if (chartType == 'line') {
      final path = Path();
      final linePaint = Paint()
        ..color = barColor
        ..strokeWidth = 2.4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < count; i++) {
        final y = math.max(0.0, (points[i]['y'] as num?)?.toDouble() ?? 0.0);
        final cx = slotW * (i + 0.5);
        final cy = plotBottom - (y / maxY) * plotH;
        if (i == 0) {
          path.moveTo(cx, cy);
        } else {
          path.lineTo(cx, cy);
        }
        canvas.drawCircle(Offset(cx, cy), 3.4, Paint()..color = barColor);
      }
      canvas.drawPath(path, linePaint);
    } else {
      final barW = (slotW * 0.52).clamp(10.0, 28.0);
      for (var i = 0; i < count; i++) {
        final y = math.max(0.0, (points[i]['y'] as num?)?.toDouble() ?? 0.0);
        final h = math.max(4.0, (y / maxY) * plotH);
        final left = slotW * (i + 0.5) - barW / 2;
        final rrect = RRect.fromRectAndCorners(
          Rect.fromLTWH(left, plotBottom - h, barW, h),
          topLeft: const Radius.circular(6),
          topRight: const Radius.circular(6),
        );
        canvas.drawRRect(
          rrect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [barColor, barColor.withValues(alpha: 0.55)],
            ).createShader(rrect.outerRect),
        );
      }
    }

    // X-axis labels
    for (var i = 0; i < count; i++) {
      final lbl = points[i]['x']?.toString() ?? '';
      final tp = TextPainter(
        text: TextSpan(text: lbl, style: TextStyle(fontSize: 10.5, color: labelColor)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(12.0, slotW - 4.0));
      tp.paint(canvas, Offset(slotW * (i + 0.5) - tp.width / 2, plotBottom + 5));
    }
  }

  @override
  bool shouldRepaint(covariant _SduiChartPainter old) =>
      old.chartType != chartType ||
      old.points != points ||
      old.barColor != barColor ||
      old.secondaryColor != secondaryColor ||
      old.labelColor != labelColor ||
      old.gridColor != gridColor;
}
