import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import '../sdui/sdui_renderer.dart';

class SduiExtensionsPage extends ConsumerStatefulWidget {
  const SduiExtensionsPage({super.key, this.initialViewId});

  final String? initialViewId;

  @override
  ConsumerState<SduiExtensionsPage> createState() => _SduiExtensionsPageState();
}

class _SduiExtensionsPageState extends ConsumerState<SduiExtensionsPage> {
  String _activeViewId = 'host-diagnostics';
  bool _loading = false;
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    final surfaces = ref.read(appProvider).sduiSurfaces;
    if (widget.initialViewId != null && widget.initialViewId!.isNotEmpty) {
      _activeViewId = widget.initialViewId!;
    } else if (surfaces.isNotEmpty) {
      _activeViewId = surfaces.first.id;
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _loadCurrent(refreshSurfaces: surfaces.isEmpty),
    );
  }

  Future<void> _loadCurrent({bool refreshSurfaces = false}) async {
    if (!mounted) return;
    final seq = ++_loadSeq;
    setState(() => _loading = true);
    try {
      if (refreshSurfaces) {
        await ref.read(appProvider.notifier).refreshSduiSurfaces(silent: true);
      }
      if (!mounted || seq != _loadSeq) return;
      final surfaces = ref.read(appProvider).sduiSurfaces;
      if (surfaces.isNotEmpty && !surfaces.any((s) => s.id == _activeViewId)) {
        setState(() => _activeViewId = surfaces.first.id);
      }
      if (_activeViewId.isNotEmpty) {
        await ref.read(appProvider.notifier).loadSduiView(_activeViewId);
      }
    } finally {
      if (mounted && seq == _loadSeq) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(appProvider.select((s) => s.activeHostId), (prev, next) {
      if (prev != null && prev != next && mounted) {
        _loadCurrent(refreshSurfaces: true);
      }
    });
    ref.watch(
      appProvider.select(
        (s) => (
          sduiSurfaces: s.sduiSurfaces,
          sduiViews: s.sduiViews,
          glassTier: s.glassTier,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final topPad = MediaQuery.viewPaddingOf(context).top;
    final botPad = MediaQuery.viewPaddingOf(context).bottom;
    final isWide = MediaQuery.sizeOf(context).width >= 760;

    final surfaces = state.sduiSurfaces;
    final activeView = state.sduiViews[_activeViewId];

    return GrassBagGlassPage(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: isWide ? 740 : double.infinity),
                  child: ListView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                    padding: EdgeInsets.fromLTRB(16, topPad + 72, 16, 40 + botPad),
                    children: [
                      if (surfaces.isNotEmpty)
                        SizedBox(
                          height: 40,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: surfaces.length,
                            separatorBuilder: (_, __) => const SizedBox(width: 8),
                            itemBuilder: (_, i) {
                              final meta = surfaces[i];
                              final selected = meta.id == _activeViewId;
                              return Center(
                                child: GrassBagFilterChip(
                                  label: meta.title,
                                  selected: selected,
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7.5),
                                  fontSize: 13,
                                  onTap: () {
                                    if (_activeViewId == meta.id) return;
                                    setState(() => _activeViewId = meta.id);
                                    _loadCurrent();
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                      const SizedBox(height: 14),
                      if (_loading && activeView == null)
                        GrassBagCard(
                          padding: const EdgeInsets.symmetric(vertical: 36),
                          child: Center(
                            child: CupertinoActivityIndicator(color: t.primary),
                          ),
                        )
                      else if (activeView != null)
                        SduiNodeRenderer(
                          key: ValueKey(_activeViewId),
                          node: activeView.root,
                          tier: state.glassTier,
                          onAction: (actionId, payload) async {
                            final navigator = Navigator.of(context);
                            final prevSid = ref.read(appProvider).activeSessionId;
                            final err = await ctrl.invokeSduiAction(_activeViewId, actionId, payload);
                            if (mounted && ref.read(appProvider).activeSessionId != prevSid) {
                              navigator.pop();
                            }
                            return err;
                          },
                          onCopied: (val) => ctrl.showToast('已复制：$val', tone: ToastTone.info),
                        )
                      else
                        GrassBagCard(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
                          child: Column(
                            children: [
                              Icon(CupertinoIcons.square_grid_2x2, size: 30, color: t.text3),
                              const SizedBox(height: 10),
                              Text(
                                '暂无可用扩展面板',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text2),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '当已连接的 DSH 主机注册扩展面板时会在此自动渲染',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, color: t.text3),
                              ),
                              const SizedBox(height: 14),
                              GrassBagSecondaryGlassButton(
                                label: '重新加载',
                                icon: CupertinoIcons.refresh,
                                tier: state.glassTier,
                                insideGlass: true,
                                accentForeground: true,
                                onTap: () => _loadCurrent(refreshSurfaces: true),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GrassBagUnifiedHeader(
                title: '诊断与扩展',
                subtitle: activeView?.title ?? state.activeHost.name,
                tier: state.glassTier,
                onBack: () => Navigator.of(context).pop(),
                trailing: GrassBagGlassCircleButton(
                  icon: CupertinoIcons.refresh,
                  tooltip: '刷新数据',
                  tier: state.glassTier,
                  useOwnLayer: false,
                  onTap: () => _loadCurrent(refreshSurfaces: true),
                ),
              ),
            ),
            const GrassBagToastOverlay(bottomOffset: 28),
          ],
        ),
      ),
    );
  }
}
