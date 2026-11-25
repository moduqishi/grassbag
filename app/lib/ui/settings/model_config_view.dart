import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/models_dev_service.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import '../web/deepseek_signin_page.dart';
import 'dsh_dynamic_sections.dart';
import 'dsh_settings_sheets.dart';

class _ProviderPresetSpec {
  const _ProviderPresetSpec({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.settingsNs,
    required this.apiProtocol,
    required this.defaultBaseUrl,
    required this.envRef,
    required this.icon,
    required this.color,
    this.isCustomTemplate = false,
  });

  final String id;
  final String name;
  final String subtitle;
  final String settingsNs;
  final String apiProtocol;
  final String defaultBaseUrl;
  final String envRef;
  final IconData icon;
  final Color color;
  final bool isCustomTemplate;
}

const _kApiProtocols = <(String, String)>[
  ('openai-completions', 'OpenAI 兼容'),
  ('openai-responses', 'OpenAI Responses'),
  ('anthropic-messages', 'Anthropic'),
];

const _kAllowedApiProtocols = <String>{
  'openai-completions',
  'openai-responses',
  'anthropic-messages',
};

/// Resolves a valid DSH `llm-pi-ai` wire protocol, ignoring non-protocol
/// labels (such as `'llm-pi-ai'`) and inferring sensible defaults for built-ins.
String resolveProviderApiProtocol({
  String? explicit,
  String providerId = '',
  String baseUrl = '',
}) {
  final clean = explicit?.trim() ?? '';
  if (_kAllowedApiProtocols.contains(clean)) return clean;
  final pid = providerId.trim().toLowerCase();
  final url = baseUrl.trim().toLowerCase();
  if (pid == 'anthropic' || pid.contains('claude') || url.contains('anthropic')) {
    return 'anthropic-messages';
  }
  if (pid == 'openai' || (url.contains('api.openai.com') && pid.isEmpty)) {
    return 'openai-responses';
  }
  return 'openai-completions';
}

String _protocolZhLabel(String? proto) => switch (proto) {
      'openai-completions' => 'OpenAI 兼容',
      'openai-responses' => 'OpenAI Responses',
      'anthropic-messages' => 'Anthropic',
      'llm-deepseek' => 'DeepSeek 官方',
      'llm-deepseek-account' => 'DeepSeek 账号',
      _ => (proto == null || proto.isEmpty || proto == 'llm-pi-ai') ? '标准渠道' : proto,
    };

String _formatCtxWindow(int? tokens) {
  if (tokens == null || tokens <= 0) return '';
  if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(tokens % 1000000 == 0 ? 0 : 1)}M';
  return '${(tokens / 1000).round()}K';
}

/// Flagship Cherry Studio × Cursor × iOS 26 Model & Provider Configuration View.
///
/// Unifies default model/effort switching, configured providers, 1-tap popular/custom
/// OpenAI-compatible relay setup, inline model management, global model search, and
/// collapsible raw engine schemas into one intuitive screen.
class DshModelConfigView extends ConsumerStatefulWidget {
  const DshModelConfigView({super.key, this.onOpenHostSettings});

  final VoidCallback? onOpenHostSettings;

  @override
  ConsumerState<DshModelConfigView> createState() => _DshModelConfigViewState();
}

class _DshModelConfigViewState extends ConsumerState<DshModelConfigView> {
  int _tabIndex = 0; // 0 = 模型渠道, 1 = 全部模型
  int _prevTabIndex = 0;
  bool _refreshing = false;
  bool _showAllBuiltin = false;
  bool _showRawSchemas = false;
  final TextEditingController _providerSearchCtrl = TextEditingController();
  final TextEditingController _modelSearchCtrl = TextEditingController();
  String _providerSearch = '';
  String _modelSearch = '';
  String? _modelGroupFilter; // null = 全部
  int _allModelsLimit = 60;
  int _builtinProvidersLimit = 40;
  Timer? _providerSearchTimer;
  Timer? _modelSearchTimer;

  @override
  void dispose() {
    _providerSearchTimer?.cancel();
    _modelSearchTimer?.cancel();
    _providerSearchCtrl.dispose();
    _modelSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshCatalog() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await ref.read(appProvider.notifier).refreshModelCatalog();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  List<_ProviderPresetSpec> _quickPresets(GrassBagTokens t) => [
        _ProviderPresetSpec(
          id: 'custom-openai',
          name: '自定义中转 / 兼容站',
          subtitle: '任意 OpenAI / Claude / Gemini 接口',
          settingsNs: 'llm-pi-ai',
          apiProtocol: 'openai-completions',
          defaultBaseUrl: '',
          envRef: '',
          icon: CupertinoIcons.plus_circle_fill,
          color: t.primary,
          isCustomTemplate: true,
        ),
        _ProviderPresetSpec(
          id: 'deepseek-official',
          name: 'DeepSeek 官方',
          subtitle: 'api.deepseek.com',
          settingsNs: 'llm-deepseek',
          apiProtocol: 'openai-completions',
          defaultBaseUrl: 'https://api.deepseek.com',
          envRef: 'DEEPSEEK_API_KEY',
          icon: CupertinoIcons.sparkles,
          color: const Color(0xFF3B82F6),
        ),
        const _ProviderPresetSpec(
          id: 'openai',
          name: 'OpenAI',
          subtitle: 'GPT / o3 / Codex',
          settingsNs: 'llm-pi-ai',
          apiProtocol: 'openai-responses',
          defaultBaseUrl: 'https://api.openai.com/v1',
          envRef: 'OPENAI_API_KEY',
          icon: CupertinoIcons.bolt_fill,
          color: Color(0xFF10A37F),
        ),
        const _ProviderPresetSpec(
          id: 'anthropic',
          name: 'Anthropic Claude',
          subtitle: 'Claude Sonnet / Opus',
          settingsNs: 'llm-pi-ai',
          apiProtocol: 'anthropic-messages',
          defaultBaseUrl: 'https://api.anthropic.com',
          envRef: 'ANTHROPIC_API_KEY',
          icon: CupertinoIcons.flame_fill,
          color: Color(0xFFD97757),
        ),
        const _ProviderPresetSpec(
          id: 'google',
          name: 'Google Gemini',
          subtitle: 'Gemini 2.5 Pro / Flash (OpenAI 兼容)',
          settingsNs: 'llm-pi-ai',
          apiProtocol: 'openai-completions',
          defaultBaseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
          envRef: 'GEMINI_API_KEY',
          icon: CupertinoIcons.sun_max_fill,
          color: Color(0xFF4285F4),
        ),
        const _ProviderPresetSpec(
          id: 'openrouter',
          name: 'OpenRouter 聚合',
          subtitle: '单密钥聚合 100+ 模型',
          settingsNs: 'llm-pi-ai',
          apiProtocol: 'openai-completions',
          defaultBaseUrl: 'https://openrouter.ai/api/v1',
          envRef: 'OPENROUTER_API_KEY',
          icon: CupertinoIcons.arrow_branch,
          color: Color(0xFF8B5CF6),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          modelGroups: s.modelGroups,
          providerCredentials: s.providerCredentials,
          dshNamespaces: s.dshNamespaces,
          activeModelProvider: s.activeModelProvider,
          activeModelId: s.activeModelId,
          modelName: s.modelName,
          modelShort: s.modelShort,
          modelEffort: s.modelEffort,
          modelEffortId: s.modelEffortId,
          connectionPhase: s.connectionPhase,
          hydratingDomains: s.hydratingDomains,
          routableProviders: s.routableProviders,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);

    final groups = state.modelGroups;
    final totalModels = groups.fold<int>(0, (acc, g) => acc + g.models.length);
    final activeEntry = state.effectiveActiveModelEntry;
    final hasUsableModel = activeEntry != null;
    final effectiveModelName = activeEntry?.name ?? state.modelName;
    final effectiveModelShort = activeEntry?.shortLabel ?? state.modelShort;
    final effectiveProviderId = activeEntry?.providerId ?? state.activeModelProvider;
    final effectiveModelId = activeEntry?.id ?? state.activeModelId;
    final supportsReasoning = activeEntry != null && activeEntry.efforts.isNotEmpty;
    final effortOpts = supportsReasoning ? activeEntry.efforts : const <ModelEffortOption>[];
    int curEffortIdx = 0;
    if (effortOpts.isNotEmpty) {
      final matchedIdx = effortOpts.indexWhere(
        (e) =>
            (state.modelEffortId.isNotEmpty && e.id == state.modelEffortId) ||
            (state.modelEffort.isNotEmpty && e.zhLabel == state.modelEffort),
      );
      if (matchedIdx >= 0) {
        curEffortIdx = matchedIdx;
      } else {
        final defIdx = effortOpts.indexWhere((e) => e.id == activeEntry?.defaultEffort);
        curEffortIdx = (defIdx >= 0 ? defIdx : 0).clamp(0, effortOpts.length - 1);
      }
    }

    final piAiNs = state.effectiveDshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
    final piAiProviders = piAiNs != null && piAiNs.value['providers'] is Map
        ? Map<String, dynamic>.from(piAiNs.value['providers'] as Map)
        : const <String, dynamic>{};

    final configuredProviders = state.providerCredentials.where((p) => p.configured).toList(growable: false);
    final unconfiguredProviders = state.providerCredentials.where((p) => !p.configured).toList(growable: false);
    final llmNamespaces = state.effectiveDshNamespaces
        .where((ns) => ns.ns.startsWith('llm-'))
        .toList(growable: false);
    final isConnected = state.connectionPhase == ConnectionPhase.connected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isConnected) ...[
          GrassBagCard(
            borderRadius: 20,
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    GrassBagSquircleIcon(
                      icon: CupertinoIcons.wifi_exclamationmark,
                      color: t.warn,
                      size: 36,
                      iconSize: 17,
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '等待连接 DSH 核心',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '所有模型、渠道与 API 密钥均由已连接的 DSH 核心统一读取与保存，不会缓存在客户端本地。',
                            style: TextStyle(fontSize: 11.5, height: 1.35, color: t.text3),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: '重试连接',
                        icon: CupertinoIcons.refresh,
                        height: 34,
                        tier: state.glassTier,
                        insideGlass: true,
                        accentForeground: true,
                        onTap: () => unawaited(ctrl.probeAndRefreshHost(state.activeHostId)),
                      ),
                    ),
                    if (widget.onOpenHostSettings != null) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: GrassBagSecondaryGlassButton(
                          label: '前往主机管理',
                          icon: CupertinoIcons.tray_2_fill,
                          height: 34,
                          tier: state.glassTier,
                          insideGlass: true,
                          onTap: widget.onOpenHostSettings,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        // 1. Default Model & Effort Hero Card (1-glance status + 1-tap quick switch)
        // Uses GrassBagCard instead of GrassBagGlass so scrolling stays 120fps AND
        // inner GrassBagSegmentedControl never nests inside a refractive glass layer!
        GrassBagCard(
          borderRadius: 24,
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  GrassBagSquircleIcon(
                    icon: CupertinoIcons.sparkles,
                    color: t.primary,
                    size: 38,
                    iconSize: 18,
                    filled: true,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          !hasUsableModel
                              ? (state.hydratingDomains ? '正在同步模型目录…' : '尚未配置可用模型')
                              : effectiveModelName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                            color: t.text,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            if (activeEntry != null && activeEntry.providerName.isNotEmpty) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: t.primarySoft,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  activeEntry.providerName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: t.primary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                hasUsableModel
                                    ? '$effectiveProviderId / $effectiveModelId'
                                    : '登录 DeepSeek 账号或添加自定义渠道即可开始对话',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: hasUsableModel ? 'monospace' : null,
                                  fontSize: 11.2,
                                  color: t.text3,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (totalModels > 0)
                    GrassBagSecondaryGlassButton(
                      label: '切换',
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      tier: state.glassTier,
                      insideGlass: true,
                      accentForeground: true,
                      onTap: () => showModelSheet(context, ref),
                    ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: '刷新模型目录',
                    child: GrassBagSpringTap(
                      onTap: _refreshCatalog,
                      pressedScale: 0.88,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: t.fill1,
                          shape: BoxShape.circle,
                        ),
                        child: _refreshing
                            ? Center(child: CupertinoActivityIndicator(radius: 7, color: t.primary))
                            : Icon(CupertinoIcons.refresh, size: 15, color: t.text2),
                      ),
                    ),
                  ),
                ],
              ),
              if (!hasUsableModel && isConnected && !state.hydratingDomains) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: GrassBagPrimaryGlassButton(
                        label: '登录 DeepSeek',
                        icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                        height: 36,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        tier: state.glassTier,
                        insideGlass: true,
                        onTap: () => unawaited(launchDeepSeekSignInFlow(context, ref)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: '添加自定义渠道',
                        icon: CupertinoIcons.plus_circle,
                        height: 36,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        tier: state.glassTier,
                        insideGlass: true,
                        accentForeground: true,
                        onTap: () => showVisualProviderEditorSheet(
                          context,
                          providerId: '',
                          settingsNs: 'llm-pi-ai',
                          initialDisplayName: '',
                          initialBaseUrl: '',
                          initialEnvRef: '',
                          initialProtocol: 'openai-completions',
                          isCustomNew: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ] else if (hasUsableModel && supportsReasoning) ...[
                const SizedBox(height: 13),
                Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 6),
                  child: Text(
                    '默认推理思考深度',
                    style: TextStyle(fontSize: 11.5, color: t.text3),
                  ),
                ),
                GrassBagSegmentedControl(
                  labels: [for (final e in effortOpts) e.zhLabel],
                  selectedIndex: curEffortIdx,
                  tier: state.glassTier,
                  height: 36,
                  onSelected: (idx) {
                    final picked = effortOpts[idx];
                    ctrl.setModel(
                      effectiveModelName,
                      effectiveModelShort,
                      provider: effectiveProviderId,
                      modelId: effectiveModelId,
                      effort: picked.zhLabel,
                      effortId: picked.id,
                    );
                  },
                ),
              ] else if (hasUsableModel) ...[
                const SizedBox(height: 11),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  decoration: BoxDecoration(
                    color: t.fill1,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.info_circle, size: 14, color: t.text3),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '当前模型为标准模式（不支持单独调节思考深度）',
                          style: TextStyle(fontSize: 12, color: t.text3),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 2. Clean 2-Tab Switcher: Providers vs All Models
        GrassBagSegmentedControl(
          labels: [
            '模型渠道 (${configuredProviders.length})',
            '全部模型 ($totalModels)',
          ],
          selectedIndex: _tabIndex,
          tier: state.glassTier,
          height: 38,
          onSelected: (idx) => setState(() {
            _prevTabIndex = _tabIndex;
            _tabIndex = idx;
          }),
        ),
        const SizedBox(height: 14),

        GrassBagDirectionalTabSwitcher(
          direction: _tabIndex >= _prevTabIndex ? 1 : -1,
          duration: const Duration(milliseconds: 175),
          child: KeyedSubtree(
            key: ValueKey('model-tab-$_tabIndex'),
            child: _tabIndex == 0
                ? _buildProvidersTab(
                    context,
                    state: state,
                    t: t,
                    configured: configuredProviders,
                    unconfigured: unconfiguredProviders,
                    piAiProviders: piAiProviders,
                    llmNamespaces: llmNamespaces,
                  )
                : _buildAllModelsTab(
                    context,
                    state: state,
                    ctrl: ctrl,
                    t: t,
                    groups: groups,
                    totalModels: totalModels,
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildProvidersTab(
    BuildContext context, {
    required GrassBagAppState state,
    required GrassBagTokens t,
    required List<ProviderCredentialItem> configured,
    required List<ProviderCredentialItem> unconfigured,
    required Map<String, dynamic> piAiProviders,
    required List<DshSettingsNamespace> llmNamespaces,
  }) {
    final presets = _quickPresets(t);
    final pq = _providerSearch.trim().toLowerCase();
    final filteredUnconfigured = pq.isEmpty
        ? unconfigured
        : unconfigured
            .where((p) =>
                p.name.toLowerCase().contains(pq) ||
                p.id.toLowerCase().contains(pq) ||
                p.envRef.toLowerCase().contains(pq))
            .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A. Configured / Active Providers (Always right at top!)
        if (configured.isNotEmpty) ...[
          GrassBagGroupedSection(
            header: '已启用渠道 (${configured.length})',
            footer: '点击任意渠道即可直接修改 API Key、接口地址 (Base URL) 及自定义模型列表，保存后自动刷新。',
            dividerIndent: 60,
            children: [
              for (final p in configured)
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: p.id == 'deepseek-official' || p.id == 'deepseek-account'
                        ? CupertinoIcons.sparkles
                        : (piAiProviders.containsKey(p.id)
                            ? CupertinoIcons.bolt_horizontal_circle_fill
                            : CupertinoIcons.checkmark_seal_fill),
                    color: t.ok,
                    size: 36,
                    iconSize: 17,
                    filled: true,
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w600, color: t.text),
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (p.modelsCount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: t.okSoft,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${p.modelsCount} 模型',
                            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: t.ok),
                          ),
                        ),
                    ],
                  ),
                  subtitle: Text(
                    p.baseUrl.isNotEmpty
                        ? '${_protocolZhLabel(p.description)} · ${p.baseUrl}'
                        : '${_protocolZhLabel(p.description)} · ${p.envRef}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  showChevron: true,
                  onTap: () => showVisualProviderEditorSheet(
                    context,
                    providerId: p.id,
                    settingsNs: p.settingsNs,
                    initialDisplayName: p.name,
                    initialBaseUrl: p.baseUrl,
                    initialEnvRef: p.envRef,
                    initialProtocol: resolveProviderApiProtocol(
                      explicit: piAiProviders[p.id] is Map
                          ? (piAiProviders[p.id] as Map)['api']?.toString()
                          : p.description,
                      providerId: p.id,
                      baseUrl: p.baseUrl,
                    ),
                    isCustomNew: false,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],

        // B. 1-Tap Quick Add Presets (2-column grid — Custom OpenAI Relay + Top 5 Providers)
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 8),
          child: Text(
            '快捷添加渠道 / 自定义中转站',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text3),
          ),
        ),
        LayoutBuilder(
          builder: (ctx, box) {
            final twoCol = box.maxWidth >= 320;
            final credById = <String, ProviderCredentialItem>{
              for (final p in state.providerCredentials) p.id: p,
            };
            Widget buildCard(_ProviderPresetSpec spec) {
              final existing = credById[spec.id];
              final isConfigured = !spec.isCustomTemplate && (existing?.configured ?? false);
              return GrassBagSpringTap(
                pressedScale: 0.97,
                haptic: true,
                onTap: () {
                  if (spec.isCustomTemplate) {
                    showVisualProviderEditorSheet(
                      context,
                      providerId: '',
                      settingsNs: 'llm-pi-ai',
                      initialDisplayName: '',
                      initialBaseUrl: '',
                      initialEnvRef: '',
                      initialProtocol: 'openai-completions',
                      isCustomNew: true,
                    );
                  } else {
                    final piCfg = piAiProviders[spec.id] is Map
                        ? Map<String, dynamic>.from(piAiProviders[spec.id] as Map)
                        : null;
                    showVisualProviderEditorSheet(
                      context,
                      providerId: spec.id,
                      settingsNs: existing?.settingsNs ?? spec.settingsNs,
                      initialDisplayName: existing?.name ?? spec.name,
                      initialBaseUrl: (existing?.baseUrl.isNotEmpty == true)
                          ? existing!.baseUrl
                          : spec.defaultBaseUrl,
                      initialEnvRef: (existing?.envRef.isNotEmpty == true)
                          ? existing!.envRef
                          : spec.envRef,
                      initialProtocol: piCfg?['api']?.toString() ?? spec.apiProtocol,
                      isCustomNew: false,
                    );
                  }
                },
                child: GrassBagCard(
                  borderRadius: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  child: Row(
                    children: [
                      GrassBagSquircleIcon(
                        icon: spec.icon,
                        color: spec.color,
                        size: 32,
                        iconSize: 15,
                        filled: spec.isCustomTemplate || isConfigured,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    spec.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: t.text,
                                    ),
                                  ),
                                ),
                                if (isConfigured) ...[
                                  const SizedBox(width: 4),
                                  Icon(CupertinoIcons.checkmark_circle_fill, size: 13, color: t.ok),
                                ],
                              ],
                            ),
                            const SizedBox(height: 1),
                            Text(
                              spec.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: t.text3),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            if (!twoCol) {
              return Column(
                children: [
                  for (final s in presets)
                    Padding(padding: const EdgeInsets.only(bottom: 8), child: buildCard(s)),
                ],
              );
            }
            return Column(
              children: [
                for (int i = 0; i < presets.length; i += 2) ...[
                  Row(
                    children: [
                      Expanded(child: buildCard(presets[i])),
                      const SizedBox(width: 8),
                      Expanded(
                        child: i + 1 < presets.length
                            ? buildCard(presets[i + 1])
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                  if (i + 2 < presets.length) const SizedBox(height: 8),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 16),

        // C. Collapsible & Searchable All Other Built-in Providers (Zero visual clutter!)
        if (unconfigured.isNotEmpty) ...[
          GrassBagCard(
            borderRadius: 22,
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.search,
                    color: t.text2,
                    size: 32,
                    iconSize: 15,
                  ),
                  title: Text(
                    '更多内置渠道 (${unconfigured.length})',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text),
                  ),
                  subtitle: const Text('按名称搜索 Groq、Mistral、xAI、SiliconFlow、Bedrock 等'),
                  trailing: AnimatedRotation(
                    turns: _showAllBuiltin ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      CupertinoIcons.chevron_down,
                      size: 14,
                      color: t.text3,
                    ),
                  ),
                  onTap: () => setState(() => _showAllBuiltin = !_showAllBuiltin),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: _showAllBuiltin
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Divider(height: 0.5, color: t.sep),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                    child: GrassBagGlassSearchBar(
                      controller: _providerSearchCtrl,
                      placeholder: '搜索渠道名称或密钥标识…',
                      tier: state.glassTier,
                      insideGlass: true,
                      onChanged: (v) {
                        _providerSearchTimer?.cancel();
                        if (v.isEmpty) {
                          if (_providerSearch.isNotEmpty) {
                            setState(() {
                              _providerSearch = '';
                              _builtinProvidersLimit = 40;
                            });
                          }
                          return;
                        }
                        _providerSearchTimer = Timer(const Duration(milliseconds: 120), () {
                          if (mounted && _providerSearch != v) {
                            setState(() {
                              _providerSearch = v;
                              _builtinProvidersLimit = 40;
                            });
                          }
                        });
                      },
                    ),
                  ),
                  if (filteredUnconfigured.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '未找到匹配「$_providerSearch」的内置渠道',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12.5, color: t.text3),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            alignment: WrapAlignment.center,
                            children: [
                              GrassBagPrimaryGlassButton(
                                label: '用「${_providerSearch.trim()}」新建自定义渠道',
                                icon: CupertinoIcons.plus_circle,
                                height: 34,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                tier: state.glassTier,
                                insideGlass: true,
                                onTap: () => showVisualProviderEditorSheet(
                                  context,
                                  providerId: '',
                                  settingsNs: 'llm-pi-ai',
                                  initialDisplayName: _providerSearch.trim(),
                                  initialBaseUrl: '',
                                  initialEnvRef: '',
                                  initialProtocol: 'openai-completions',
                                  isCustomNew: true,
                                ),
                              ),
                              GrassBagSecondaryGlassButton(
                                label: '清除搜索',
                                height: 34,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                tier: state.glassTier,
                                insideGlass: true,
                                onTap: () {
                                  _providerSearchCtrl.clear();
                                  setState(() => _providerSearch = '');
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    )
                  else ...[
                    for (int i = 0; i < math.min(filteredUnconfigured.length, _builtinProvidersLimit); i++) ...[
                      Builder(
                        builder: (_) {
                          final p = filteredUnconfigured[i];
                          return GrassBagListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
                            title: Text(p.name, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: t.text)),
                            subtitle: Text(
                              p.baseUrl.isNotEmpty ? '${p.envRef} · ${p.baseUrl}' : p.envRef,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                              decoration: BoxDecoration(
                                color: t.primarySoft,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '配置',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: t.primary),
                              ),
                            ),
                            onTap: () {
                              final lowerId = p.id.toLowerCase();
                              final lowerUrl = p.baseUrl.toLowerCase();
                              final inferredProto = (lowerId.contains('anthropic') || lowerUrl.contains('anthropic'))
                                  ? 'anthropic-messages'
                                  : (lowerId == 'openai' ? 'openai-responses' : 'openai-completions');
                              showVisualProviderEditorSheet(
                                context,
                                providerId: p.id,
                                settingsNs: p.settingsNs,
                                initialDisplayName: p.name,
                                initialBaseUrl: p.baseUrl,
                                initialEnvRef: p.envRef,
                                initialProtocol: inferredProto,
                                isCustomNew: false,
                              );
                            },
                          );
                        },
                      ),
                      if (i < math.min(filteredUnconfigured.length, _builtinProvidersLimit) - 1)
                        Divider(height: 0.5, indent: 15, endIndent: 15, color: t.sep),
                    ],
                    if (filteredUnconfigured.length > _builtinProvidersLimit) ...[
                      Divider(height: 0.5, color: t.sep),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: GrassBagSecondaryGlassButton(
                          label: '展开更多渠道（还有 ${filteredUnconfigured.length - _builtinProvidersLimit} 个）',
                          icon: CupertinoIcons.chevron_down,
                          height: 34,
                          tier: state.glassTier,
                          insideGlass: true,
                          accentForeground: true,
                          onTap: () => setState(() => _builtinProvidersLimit += 50),
                        ),
                      ),
                    ],
                  ],
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],

        // D. Low-level Raw DSH Engine Schemas (Tucked cleanly at bottom for power users)
        if (llmNamespaces.isNotEmpty)
          GrassBagCard(
            borderRadius: 20,
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.slider_horizontal_3,
                    color: t.text3,
                    size: 30,
                    iconSize: 14,
                  ),
                  title: Text(
                    '高级引擎参数（开发者）',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: t.text2),
                  ),
                  subtitle: Text('${llmNamespaces.length} 个底层配置模块 · 超时、兼容性开关与源码'),
                  trailing: AnimatedRotation(
                    turns: _showRawSchemas ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      CupertinoIcons.chevron_down,
                      size: 13.5,
                      color: t.text3,
                    ),
                  ),
                  onTap: () => setState(() => _showRawSchemas = !_showRawSchemas),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: _showRawSchemas
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Divider(height: 0.5, color: t.sep),
                            for (int i = 0; i < llmNamespaces.length; i++) ...[
                              GrassBagListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
                                title: Text(llmNamespaces[i].title, style: TextStyle(fontSize: 13.5, color: t.text)),
                                subtitle: Text(llmNamespaces[i].ns, style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: t.text3)),
                                showChevron: true,
                                onTap: () => showDshNamespaceEditorSheet(context, ref, llmNamespaces[i]),
                              ),
                              if (i < llmNamespaces.length - 1)
                                Divider(height: 0.5, indent: 15, endIndent: 15, color: t.sep),
                            ],
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildAllModelsTab(
    BuildContext context, {
    required GrassBagAppState state,
    required GrassBagController ctrl,
    required GrassBagTokens t,
    required List<ModelCatalogGroup> groups,
    required int totalModels,
  }) {
    if (groups.isEmpty) {
      return GrassBagEmptyStateCard(
        icon: CupertinoIcons.sparkles,
        title: state.connectionPhase == ConnectionPhase.connected
            ? '暂未加载到可用模型'
            : '尚未连接到 DSH 主机',
        subtitle: state.connectionPhase == ConnectionPhase.connected
            ? '请先在「模型渠道」中配置 DeepSeek、OpenAI、Claude 或自定义中转站的 API Key，保存后自动加载模型。'
            : '连接运行中的 DSH 主机后将自动同步全部可用模型目录。',
        actionLabel: state.connectionPhase == ConnectionPhase.connected
            ? '去配置模型渠道'
            : '重新探测主机',
        actionIcon: state.connectionPhase == ConnectionPhase.connected
            ? CupertinoIcons.plus_circle
            : CupertinoIcons.refresh,
        tier: state.glassTier,
        onAction: () {
          if (state.connectionPhase == ConnectionPhase.connected) {
            setState(() => _tabIndex = 0);
          } else {
            ctrl.probeAndRefreshHost(state.activeHostId);
          }
        },
      );
    }

    final credById = <String, ProviderCredentialItem>{
      for (final p in state.providerCredentials) p.id: p,
    };
    final activeGroupFilter = (_modelGroupFilter != null && groups.any((g) => g.id == _modelGroupFilter))
        ? _modelGroupFilter
        : null;
    final q = _modelSearch.trim().toLowerCase();
    final visibleEntries = <(ModelCatalogGroup, ModelCatalogEntry)>[];
    for (final g in groups) {
      if (activeGroupFilter != null && g.id != activeGroupFilter) continue;
      for (final m in g.models) {
        if (q.isEmpty ||
            m.name.toLowerCase().contains(q) ||
            m.id.toLowerCase().contains(q) ||
            m.description.toLowerCase().contains(q) ||
            g.name.toLowerCase().contains(q)) {
          visibleEntries.add((g, m));
        }
      }
    }

    // Hoist effective active model resolution ONCE outside the N-row loop (eliminates O(N^2) scan!).
    final eff = state.effectiveActiveModelEntry;
    final effId = eff?.id ?? state.activeModelId;
    final effProv = eff?.providerId ?? state.activeModelProvider;
    final shownModelsCount = math.min(visibleEntries.length, _allModelsLimit);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagGlassSearchBar(
          controller: _modelSearchCtrl,
          placeholder: '全局搜索全部 $totalModels 个模型或渠道…',
          tier: state.glassTier,
          insideGlass: true,
          onChanged: (v) {
            _modelSearchTimer?.cancel();
            if (v.isEmpty) {
              if (_modelSearch.isNotEmpty) {
                setState(() {
                  _modelSearch = '';
                  _allModelsLimit = 60;
                });
              }
              return;
            }
            _modelSearchTimer = Timer(const Duration(milliseconds: 120), () {
              if (mounted && _modelSearch != v) {
                setState(() {
                  _modelSearch = v;
                  _allModelsLimit = 60;
                });
              }
            });
          },
        ),
        if (groups.length > 1) ...[
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FilterPill(
                  label: '全部 ($totalModels)',
                  active: activeGroupFilter == null,
                  onTap: () => setState(() {
                    _modelGroupFilter = null;
                    _allModelsLimit = 60;
                  }),
                ),
                for (final g in groups) ...[
                  const SizedBox(width: 6),
                  _FilterPill(
                    label: '${g.name} (${g.models.length})',
                    active: activeGroupFilter == g.id,
                    onTap: () => setState(() {
                      _modelGroupFilter = g.id;
                      _allModelsLimit = 60;
                    }),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (visibleEntries.isEmpty)
          GrassBagCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '未找到匹配「$_modelSearch」的模型',
                  style: TextStyle(fontSize: 13, color: t.text3),
                ),
                const SizedBox(height: 10),
                GrassBagSecondaryGlassButton(
                  label: '清除搜索与筛选',
                  icon: CupertinoIcons.clear_circled,
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  tier: state.glassTier,
                  insideGlass: true,
                  accentForeground: true,
                  onTap: () {
                    _modelSearchCtrl.clear();
                    setState(() {
                      _modelSearch = '';
                      _modelGroupFilter = null;
                      _allModelsLimit = 60;
                    });
                  },
                ),
              ],
            ),
          )
        else
          GrassBagCard(
            borderRadius: 22,
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < shownModelsCount; i++) ...[
                  Builder(
                    builder: (_) {
                      final g = visibleEntries[i].$1;
                      final m = visibleEntries[i].$2;
                      final selected = effId == m.id &&
                          (effProv.isEmpty || effProv == g.id);
                      final cred = credById[g.id];
                      final canEditParams = cred != null
                          ? cred.settingsNs == 'llm-pi-ai'
                          : (g.id != 'deepseek-official' &&
                              g.id != 'deepseek-account' &&
                              g.id != 'commandcode');
                      final ctxTag = _formatCtxWindow(m.contextWindow);
                      return GrassBagListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                m.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                                  color: selected ? t.primary : t.text,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: selected ? t.primarySoft : t.fill1,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                g.name,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                  color: selected ? t.primary : t.text3,
                                ),
                              ),
                            ),
                            if (ctxTag.isNotEmpty) ...[
                              const SizedBox(width: 5),
                              Text(ctxTag, style: TextStyle(fontSize: 10.5, color: t.text3)),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          m.description.isNotEmpty
                              ? m.description
                              : '${m.id}${m.supportsReasoning ? ' · 支持思考深度' : ''}${m.supportsImage ? ' · 识图' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (canEditParams)
                              Tooltip(
                                message: '编辑模型参数',
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => showModelParamsEditorSheet(
                                    context,
                                    providerId: g.id,
                                    entry: m,
                                  ),
                                  child: SizedBox(
                                    width: 38,
                                    height: 38,
                                    child: Center(
                                      child: Icon(
                                        CupertinoIcons.slider_horizontal_3,
                                        size: 16.5,
                                        color: t.text3,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (selected)
                              Icon(CupertinoIcons.checkmark_circle_fill, size: 19, color: t.primary),
                          ],
                        ),
                        onTap: () => ctrl.setModel(
                          m.name,
                          m.shortLabel,
                          provider: g.id,
                          modelId: m.id,
                          effortId: m.efforts.any((e) => e.id == state.modelEffortId)
                              ? state.modelEffortId
                              : m.defaultEffort,
                        ),
                      );
                    },
                  ),
                  if (i < shownModelsCount - 1)
                    Divider(height: 0.5, indent: 15, endIndent: 15, color: t.sep),
                ],
                if (visibleEntries.length > shownModelsCount) ...[
                  Divider(height: 0.5, color: t.sep),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: GrassBagSecondaryGlassButton(
                      label: '加载更多模型（还有 ${visibleEntries.length - shownModelsCount} 个）',
                      icon: CupertinoIcons.chevron_down,
                      height: 34,
                      tier: state.glassTier,
                      insideGlass: true,
                      accentForeground: true,
                      onTap: () => setState(() => _allModelsLimit += 80),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GrassBagFilterChip(
      label: label,
      selected: active,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      fontSize: 12,
    );
  }
}

/// All-in-One Visual Provider & Custom Model Workbench Sheet.
/// Owns its own [ConsumerState] `ref` and controllers (zero disposed-ref risk!).
void showVisualProviderEditorSheet(
  BuildContext context, {
  required String providerId,
  required String settingsNs,
  required String initialDisplayName,
  required String initialBaseUrl,
  required String initialEnvRef,
  String? initialProtocol,
  bool isCustomNew = false,
}) {
  showGrassBagSheet<void>(
    context,
    title: isCustomNew
        ? '添加自定义渠道 / 中转站'
        : '配置 ${initialDisplayName.isNotEmpty ? initialDisplayName : providerId}',
    subtitle: isCustomNew
        ? '填写 API 地址、密钥与模型即可接入任意 OpenAI / Anthropic / Gemini 兼容服务'
        : '密钥加密写入宿主机凭据库，修改保存后自动刷新模型目录',
    bodyBuilder: (_) => _VisualProviderEditorBody(
      outerContext: context,
      providerId: providerId,
      settingsNs: settingsNs,
      initialDisplayName: initialDisplayName,
      initialBaseUrl: initialBaseUrl,
      initialEnvRef: initialEnvRef,
      initialProtocol: initialProtocol,
      isCustomNew: isCustomNew,
    ),
  );
}

class _VisualProviderEditorBody extends ConsumerStatefulWidget {
  const _VisualProviderEditorBody({
    required this.outerContext,
    required this.providerId,
    required this.settingsNs,
    required this.initialDisplayName,
    required this.initialBaseUrl,
    required this.initialEnvRef,
    required this.initialProtocol,
    required this.isCustomNew,
  });

  final BuildContext outerContext;
  final String providerId;
  final String settingsNs;
  final String initialDisplayName;
  final String initialBaseUrl;
  final String initialEnvRef;
  final String? initialProtocol;
  final bool isCustomNew;

  @override
  ConsumerState<_VisualProviderEditorBody> createState() => _VisualProviderEditorBodyState();
}

class _VisualProviderEditorBodyState extends ConsumerState<_VisualProviderEditorBody> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _idCtrl;
  late final TextEditingController _baseUrlCtrl;
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _envRefCtrl;

  // Inline "Add / Edit Model" mini-form controllers
  final TextEditingController _newModelIdCtrl = TextEditingController();
  final TextEditingController _newModelNameCtrl = TextEditingController();
  final TextEditingController _newModelCtxCtrl = TextEditingController(text: '200000');
  final TextEditingController _newModelMaxTokCtrl = TextEditingController(text: '16384');
  final TextEditingController _discoveredFilterCtrl = TextEditingController();
  int _newModelCtx = 200000;
  int _newModelMaxTok = 16384;
  bool _newModelVision = true;
  bool _newModelReasoning = false;
  Map<String, String?> _newModelEffortMap = <String, String?>{
    'off': null,
    'low': 'low',
    'medium': 'medium',
    'high': 'high',
  };
  bool _showAddModel = false;
  int? _editingModelIndex;
  Timer? _modelsDevDebounce;
  int _modelsDevReqSeq = 0;
  bool _modelsDevLoading = false;
  ModelsDevSpec? _modelsDevMatched;
  List<ModelsDevSpec> _modelsDevSuggestions = const [];
  bool _userEditedNewModelParams = false;
  List<Map<String, dynamic>> _discoveredPool = const [];
  final Set<String> _selectedDiscoveredIds = <String>{};

  late String _protocol;
  late final String _generatedFallbackId;
  bool _protocolManuallyPicked = false;
  bool _obscureKey = true;
  bool _showAdvancedEnv = false;
  bool _saving = false;
  bool _testingConnection = false;
  bool _discovering = false;
  String? _errorMsg;
  String? _probeSuccessMsg;
  String? _lastTplName;
  String? _lastTplModel;
  late List<Map<String, dynamic>> _models;
  late Set<String> _savedModelIds;

  bool _isBuiltinProvider(String pid) {
    if (pid == 'deepseek-official' || pid == 'deepseek-account') return true;
    final cred = ref
        .read(appProvider)
        .providerCredentials
        .where((p) => p.id == pid)
        .firstOrNull;
    return cred?.isBuiltin == true;
  }

  static const _kCustomQuickTemplates = <({
    String label,
    String name,
    String protocol,
    String baseUrl,
    String sampleModel,
  })>[
    (
      label: 'OpenAI 中转',
      name: '我的 OpenAI 中转',
      protocol: 'openai-completions',
      baseUrl: 'https://api.openai.com/v1',
      sampleModel: 'gpt-4.1',
    ),
    (
      label: 'SiliconFlow',
      name: 'SiliconFlow 硅基流动',
      protocol: 'openai-completions',
      baseUrl: 'https://api.siliconflow.cn/v1',
      sampleModel: 'deepseek-ai/DeepSeek-V3',
    ),
    (
      label: 'Ollama 本地',
      name: 'Ollama 本地模型',
      protocol: 'openai-completions',
      baseUrl: 'http://127.0.0.1:11434/v1',
      sampleModel: 'qwen2.5-coder:7b',
    ),
    (
      label: 'Claude 中转',
      name: '我的 Claude 中转',
      protocol: 'anthropic-messages',
      baseUrl: 'https://api.anthropic.com',
      sampleModel: 'claude-sonnet-4-5',
    ),
    (
      label: 'Gemini 兼容',
      name: 'Gemini 中转',
      protocol: 'openai-completions',
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
      sampleModel: 'gemini-2.5-pro',
    ),
  ];

  void _applyCustomTemplate(({
    String label,
    String name,
    String protocol,
    String baseUrl,
    String sampleModel,
  }) tpl) {
    setState(() {
      _errorMsg = null;
      final curName = _nameCtrl.text.trim();
      if (curName.isEmpty || curName == _lastTplName) {
        _nameCtrl.text = tpl.name;
      }
      _baseUrlCtrl.text = tpl.baseUrl;
      _protocol = tpl.protocol;
      _protocolManuallyPicked = true;
      final curModel = _newModelIdCtrl.text.trim();
      if (curModel.isEmpty || curModel == _lastTplModel) {
        _newModelIdCtrl.text = tpl.sampleModel;
      }
      if (_models.isEmpty) {
        _showAddModel = true;
      }
      _lastTplName = tpl.name;
      _lastTplModel = tpl.sampleModel;
    });
  }

  void _maybeInferProtocolFromUrl(String url) {
    if (_protocolManuallyPicked || widget.settingsNs != 'llm-pi-ai') return;
    final lower = url.trim().toLowerCase();
    String? inferred;
    if (lower.contains('anthropic')) {
      inferred = 'anthropic-messages';
    } else if (lower.contains('openai.com') && widget.providerId == 'openai') {
      inferred = 'openai-responses';
    }
    if (inferred != null && inferred != _protocol) {
      setState(() => _protocol = inferred!);
    }
  }

  Future<void> _discoverModels({bool testOnly = false}) async {
    if (_discovering || _testingConnection || _saving) return;
    final baseUrl = _baseUrlCtrl.text.trim();
    if (baseUrl.isEmpty) {
      setState(() => _errorMsg = '请先填写 API 地址 (Base URL) 后再测试或拉取模型列表');
      return;
    }
    setState(() {
      if (testOnly) {
        _testingConnection = true;
      } else {
        _discovering = true;
      }
      _errorMsg = null;
      _probeSuccessMsg = null;
    });
    final pid = _derivedProviderId();
    List<Map<String, dynamic>> discovered = const [];
    try {
      discovered = await ref.read(appProvider.notifier).discoverProviderModels(
            providerId: pid,
            apiProtocol: _protocol,
            baseUrl: baseUrl,
            apiKeyValue: _apiKeyCtrl.text.trim(),
            envRef: _derivedEnvRef(pid),
            testOnly: testOnly,
          );
      // Best-effort enrich discovered `/v1/models` items with accurate models.dev parameters
      // while keeping the busy indicator active and capped to a short timeout.
      if (!testOnly && discovered.isNotEmpty) {
        final catalog = await ModelsDevCatalogService.instance
            .loadCatalog()
            .timeout(const Duration(seconds: 2), onTimeout: () => const <ModelsDevSpec>[])
            .catchError((_) => const <ModelsDevSpec>[]);
        discovered = [
          for (final raw in discovered)
            () {
              final copy = Map<String, dynamic>.from(raw);
              final mid = copy['id']?.toString() ?? '';
              final hadLegacyReasoning = copy.remove('reasoning') == true;
              final spec = catalog.isEmpty ? null : ModelsDevCatalogService.matchInList(catalog, mid);
              if (spec != null) {
                if ((copy['name']?.toString().trim().isEmpty ?? true) || copy['name'] == mid) {
                  copy['name'] = spec.name;
                }
                if (spec.contextWindow != null && spec.contextWindow! > 0) {
                  copy['contextWindow'] = spec.contextWindow;
                }
                if (spec.maxOutputTokens != null && spec.maxOutputTokens! > 0) {
                  copy['maxTokens'] = spec.maxOutputTokens;
                }
                copy['input'] = spec.supportsImage ? const ['text', 'image'] : const ['text'];
                if (spec.reasoning || spec.reasoningEfforts.isNotEmpty) {
                  copy['reasoningEfforts'] = _serializeEffortMap(_effortMapFromModelsDev(spec.reasoningEfforts));
                }
              } else if (hadLegacyReasoning && copy['reasoningEfforts'] == null) {
                copy['reasoningEfforts'] = _serializeEffortMap(const <String, String?>{
                  'off': null,
                  'low': 'low',
                  'medium': 'medium',
                  'high': 'high',
                });
              }
              return copy;
            }(),
        ];
      }
    } finally {
      if (mounted) {
        setState(() {
          _testingConnection = false;
          _discovering = false;
        });
      }
    }
    if (!mounted) return;
    setState(() {
      if (discovered.isEmpty) {
        _errorMsg = '未能从该接口获取到可用模型，请检查 Base URL、协议类型或 API 密钥是否正确；也可在下方手动填写模型 ID。';
        if (_models.isEmpty) {
          _showAddModel = true;
        }
      } else {
        _probeSuccessMsg = '连通正常，发现 ${discovered.length} 个模型';
        if (!testOnly) {
          final existingIds = _models.map((m) => m['id']?.toString()).toSet();
          final fresh = discovered
              .where((m) {
                final id = m['id']?.toString() ?? '';
                return id.isNotEmpty && !existingIds.contains(id);
              })
              .toList(growable: false);
          if (fresh.length <= 6) {
            _models.addAll(fresh);
            _discoveredPool = const [];
            _selectedDiscoveredIds.clear();
            if (_editingModelIndex == null) {
              _newModelIdCtrl.clear();
              _newModelNameCtrl.clear();
              _showAddModel = false;
            }
          } else {
            _discoveredPool = fresh;
            _selectedDiscoveredIds
              ..clear()
              ..addAll(fresh.take(5).map((m) => m['id'].toString()));
          }
        }
      }
    });
  }

  void _commitSelectedDiscoveredModels({bool all = false}) {
    if (_discoveredPool.isEmpty) return;
    final existingIds = _models.map((m) => m['id']?.toString()).toSet();
    final toAdd = all
        ? _discoveredPool
        : _discoveredPool.where((m) => _selectedDiscoveredIds.contains(m['id']?.toString()));
    setState(() {
      for (final m in toAdd) {
        final id = m['id']?.toString() ?? '';
        if (id.isNotEmpty && !existingIds.contains(id)) {
          _models.add(Map<String, dynamic>.from(m));
          existingIds.add(id);
        }
      }
      _discoveredPool = const [];
      _selectedDiscoveredIds.clear();
      _discoveredFilterCtrl.clear();
      if (_models.isNotEmpty && _editingModelIndex == null) {
        _newModelIdCtrl.clear();
        _newModelNameCtrl.clear();
        _showAddModel = false;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _generatedFallbackId = 'custom-${DateTime.now().millisecondsSinceEpoch % 100000}';
    _nameCtrl = TextEditingController(text: widget.initialDisplayName);
    _idCtrl = TextEditingController(text: widget.providerId);
    _baseUrlCtrl = TextEditingController(text: widget.initialBaseUrl);
    _apiKeyCtrl = TextEditingController();
    _envRefCtrl = TextEditingController(text: widget.initialEnvRef);
    _protocol = resolveProviderApiProtocol(
      explicit: widget.initialProtocol,
      providerId: widget.providerId,
      baseUrl: widget.initialBaseUrl,
    );

    final state = ref.read(appProvider);
    if (widget.settingsNs == 'llm-deepseek') {
      final dsNs = state.effectiveDshNamespaces.where((n) => n.ns == 'llm-deepseek').firstOrNull;
      if (dsNs != null) {
        if (_baseUrlCtrl.text.isEmpty && dsNs.value['baseURL'] is String) {
          _baseUrlCtrl.text = dsNs.value['baseURL'].toString();
        }
        if (_envRefCtrl.text.isEmpty && dsNs.value['apiKeyEnv'] is String) {
          _envRefCtrl.text = dsNs.value['apiKeyEnv'].toString();
        }
      }
    } else if (widget.settingsNs == 'llm-commandcode') {
      final ccNs = state.effectiveDshNamespaces.where((n) => n.ns == 'llm-commandcode').firstOrNull;
      if (ccNs != null) {
        if (_baseUrlCtrl.text.isEmpty && ccNs.value['apiBase'] is String) {
          _baseUrlCtrl.text = ccNs.value['apiBase'].toString();
        }
        if (_envRefCtrl.text.isEmpty && ccNs.value['apiKeyEnv'] is String) {
          _envRefCtrl.text = ccNs.value['apiKeyEnv'].toString();
        }
      }
    }

    final piAiNs = state.effectiveDshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
    final providersMap = piAiNs != null && piAiNs.value['providers'] is Map
        ? Map<String, dynamic>.from(piAiNs.value['providers'] as Map)
        : const <String, dynamic>{};
    final existingCfg = widget.providerId.isNotEmpty && providersMap[widget.providerId] is Map
        ? Map<String, dynamic>.from(providersMap[widget.providerId] as Map)
        : null;
    if (existingCfg != null && existingCfg['api'] is String) {
      final savedApi = existingCfg['api'].toString().trim();
      if (_kAllowedApiProtocols.contains(savedApi)) {
        _protocol = savedApi;
      }
    }
    if (existingCfg != null && existingCfg['baseURL'] is String && _baseUrlCtrl.text.isEmpty) {
      _baseUrlCtrl.text = existingCfg['baseURL'].toString();
    }
    if (existingCfg != null && existingCfg['apiKeyEnv'] is String && _envRefCtrl.text.isEmpty) {
      _envRefCtrl.text = existingCfg['apiKeyEnv'].toString();
    }
    final rawModels = existingCfg?['models'];
    _models = rawModels is List
        ? rawModels
            .whereType<Map<dynamic, dynamic>>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];
    _savedModelIds = _models
        .map((m) => m['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    // When connected, keep the manual Add Model form collapsed so the 1-tap auto-discover CTA leads;
    // when offline (auto-discover unavailable), open it immediately so manual entry is ready.
    if (widget.isCustomNew && state.connectionPhase != ConnectionPhase.connected) {
      _showAddModel = true;
    }
  }

  @override
  void dispose() {
    _modelsDevDebounce?.cancel();
    _nameCtrl.dispose();
    _idCtrl.dispose();
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _envRefCtrl.dispose();
    _newModelIdCtrl.dispose();
    _newModelNameCtrl.dispose();
    _newModelCtxCtrl.dispose();
    _newModelMaxTokCtrl.dispose();
    _discoveredFilterCtrl.dispose();
    super.dispose();
  }

  void _scheduleNewModelLookup(String query, {bool forceFill = false}) {
    _modelsDevDebounce?.cancel();
    final q = query.trim();
    if (q.length < 2) {
      if (_modelsDevSuggestions.isNotEmpty || _modelsDevMatched != null || _modelsDevLoading) {
        setState(() {
          _modelsDevSuggestions = const [];
          _modelsDevMatched = null;
          _modelsDevLoading = false;
        });
      }
      return;
    }
    _modelsDevDebounce = Timer(Duration(milliseconds: forceFill ? 10 : 420), () {
      unawaited(_runNewModelLookup(q, forceFill: forceFill));
    });
  }

  Future<void> _runNewModelLookup(String query, {bool forceFill = false}) async {
    final seq = ++_modelsDevReqSeq;
    if (mounted) setState(() => _modelsDevLoading = true);
    final results = await Future.wait([
      ModelsDevCatalogService.instance.lookupModel(query),
      ModelsDevCatalogService.instance.searchSuggestions(query, limit: 5),
    ]);
    if (!mounted || seq != _modelsDevReqSeq) return;
    final matched = results[0] as ModelsDevSpec?;
    final suggestions = results[1] as List<ModelsDevSpec>;
    setState(() {
      _modelsDevLoading = false;
      _modelsDevSuggestions = suggestions;
      if (matched != null) {
        final shouldAutoApply = forceFill || (!_userEditedNewModelParams && _editingModelIndex == null);
        if (shouldAutoApply) {
          _applyModelsDevSpecToNewForm(matched, overwriteId: false);
        } else {
          _modelsDevMatched = matched;
        }
      } else {
        _modelsDevMatched = null;
      }
    });
  }

  void _applyModelsDevSpecToNewForm(ModelsDevSpec spec, {required bool overwriteId}) {
    if (overwriteId) {
      _newModelIdCtrl.text = spec.id;
    }
    if (spec.name.isNotEmpty) {
      _newModelNameCtrl.text = spec.name;
    }
    if (spec.contextWindow != null && spec.contextWindow! > 0) {
      _newModelCtx = spec.contextWindow!;
      _newModelCtxCtrl.text = '${spec.contextWindow}';
    }
    if (spec.maxOutputTokens != null && spec.maxOutputTokens! > 0) {
      _newModelMaxTok = spec.maxOutputTokens!;
      _newModelMaxTokCtrl.text = '${spec.maxOutputTokens}';
    }
    _newModelVision = spec.supportsImage;
    _newModelReasoning = spec.reasoning || spec.reasoningEfforts.isNotEmpty;
    if (_newModelReasoning) {
      _newModelEffortMap = _effortMapFromModelsDev(spec.reasoningEfforts);
    }
    _modelsDevMatched = spec;
    _errorMsg = null;
  }

  String _derivedProviderId() {
    if (!widget.isCustomNew && widget.providerId.isNotEmpty) return widget.providerId;
    final explicit = _idCtrl.text.trim();
    if (explicit.isNotEmpty) {
      final clean = explicit
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
          .replaceAll(RegExp(r'^-+|-+$'), '');
      if (clean.isNotEmpty) return clean;
    }
    final fromName = _nameCtrl.text
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (fromName.isNotEmpty) {
      final existingIds = ref.read(appProvider).providerCredentials.map((p) => p.id.toLowerCase()).toSet();
      if (!existingIds.contains(fromName)) return fromName;
      final customCandidate = '$fromName-custom';
      if (!existingIds.contains(customCandidate)) return customCandidate;
      for (var i = 2; i < 100; i++) {
        final numbered = '$fromName-$i';
        if (!existingIds.contains(numbered)) return numbered;
      }
    }
    return _generatedFallbackId;
  }

  String _derivedEnvRef(String pid) {
    final raw = _envRefCtrl.text.trim().isNotEmpty
        ? _envRefCtrl.text.trim()
        : '${pid.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_')}_API_KEY';
    final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_').replaceAll(RegExp(r'^_+'), '');
    if (cleaned.isEmpty) return 'CUSTOM_API_KEY';
    if (RegExp(r'^[0-9]').hasMatch(cleaned)) return 'P_$cleaned';
    return cleaned;
  }

  void _startEditingModel(int index) {
    final m = _models[index];
    final ctx = (m['contextWindow'] as num?)?.toInt() ?? 128000;
    final maxTok = (m['maxTokens'] as num?)?.toInt() ?? 16384;
    final rawInput = m['input'];
    final hasVision = rawInput is List && rawInput.any((e) => e.toString().toLowerCase().contains('image'));
    final rawEfforts = m['reasoningEfforts'];
    final hasReasoning = m['reasoning'] == true ||
        (rawEfforts is Map && rawEfforts.isNotEmpty);
    final parsedEffortMap = _parseEffortMapFromModelJson(rawEfforts);
    setState(() {
      _editingModelIndex = index;
      _showAddModel = true;
      _errorMsg = null;
      _userEditedNewModelParams = true;
      _modelsDevMatched = null;
      _modelsDevSuggestions = const [];
      _newModelIdCtrl.text = m['id']?.toString() ?? '';
      _newModelNameCtrl.text = m['name']?.toString() ?? '';
      _newModelCtx = ctx;
      _newModelCtxCtrl.text = '$ctx';
      _newModelMaxTok = maxTok;
      _newModelMaxTokCtrl.text = '$maxTok';
      _newModelVision = hasVision;
      _newModelReasoning = hasReasoning;
      _newModelEffortMap = parsedEffortMap;
    });
  }

  void _cancelEditingModel() {
    _modelsDevDebounce?.cancel();
    setState(() {
      _editingModelIndex = null;
      _userEditedNewModelParams = false;
      _modelsDevMatched = null;
      _modelsDevSuggestions = const [];
      _newModelIdCtrl.clear();
      _newModelNameCtrl.clear();
      _newModelCtx = 200000;
      _newModelCtxCtrl.text = '200000';
      _newModelMaxTok = 16384;
      _newModelMaxTokCtrl.text = '16384';
      _newModelVision = true;
      _newModelReasoning = false;
      _newModelEffortMap = <String, String?>{
        'off': null,
        'low': 'low',
        'medium': 'medium',
        'high': 'high',
      };
      _showAddModel = false;
    });
  }

  bool _addCustomModel() {
    final id = _newModelIdCtrl.text.trim();
    if (id.isEmpty) {
      setState(() => _errorMsg = '请先填写模型 ID，例如 gpt-4.1 或 claude-sonnet-4-5');
      return false;
    }
    final ctxText = _newModelCtxCtrl.text.trim();
    final maxTokText = _newModelMaxTokCtrl.text.trim();
    final parsedCtx = ctxText.isEmpty ? _newModelCtx : int.tryParse(ctxText);
    final parsedMaxTok = maxTokText.isEmpty ? _newModelMaxTok : int.tryParse(maxTokText);
    if (parsedCtx == null || parsedCtx <= 0) {
      setState(() => _errorMsg = '上下文窗口必须为正整数');
      return false;
    }
    if (parsedMaxTok == null || parsedMaxTok <= 0) {
      setState(() => _errorMsg = '最大输出 Token 必须为正整数');
      return false;
    }
    final safeCtx = parsedCtx;
    final safeMaxTok = parsedMaxTok;
    if (safeMaxTok > safeCtx) {
      setState(() => _errorMsg = '最大输出 Token ($safeMaxTok) 不能大于上下文窗口 ($safeCtx)');
      return false;
    }
    final isEditing = _editingModelIndex != null &&
        _editingModelIndex! >= 0 &&
        _editingModelIndex! < _models.length;
    if (isEditing) {
      final duplicate = _models.asMap().entries.any(
            (e) => e.key != _editingModelIndex && e.value['id']?.toString() == id,
          );
      if (duplicate) {
        setState(() => _errorMsg = '模型 ID「$id」已存在于当前渠道列表中');
        return false;
      }
    }
    final name = _newModelNameCtrl.text.trim().isEmpty ? id : _newModelNameCtrl.text.trim();

    final baseObj = isEditing
        ? Map<String, dynamic>.from(_models[_editingModelIndex!])
        : <String, dynamic>{};

    baseObj['id'] = id;
    baseObj['name'] = name;
    baseObj['contextWindow'] = safeCtx;
    baseObj['maxTokens'] = safeMaxTok;
    baseObj['input'] = _newModelVision ? ['text', 'image'] : ['text'];
    baseObj.remove('reasoning');
    if (_newModelReasoning) {
      final err = _validateEffortMap(_newModelEffortMap);
      if (err != null) {
        setState(() => _errorMsg = err);
        return false;
      }
      baseObj['reasoningEfforts'] = _serializeEffortMap(_newModelEffortMap);
    } else {
      baseObj['reasoningEfforts'] = false;
    }

    setState(() {
      _errorMsg = null;
      if (isEditing) {
        _models[_editingModelIndex!] = baseObj;
        _editingModelIndex = null;
        _showAddModel = false;
      } else {
        _models.removeWhere((m) => m['id']?.toString() == id);
        _models.add(baseObj);
      }
      _userEditedNewModelParams = false;
      _modelsDevMatched = null;
      _modelsDevSuggestions = const [];
      _newModelIdCtrl.clear();
      _newModelNameCtrl.clear();
    });
    return true;
  }

  Future<void> _save() async {
    if (_saving || _discovering) return;
    final pid = _derivedProviderId();
    final name = _nameCtrl.text.trim().isEmpty ? pid : _nameCtrl.text.trim();
    final baseUrl = _baseUrlCtrl.text.trim();
    final envRef = _derivedEnvRef(pid);
    final secret = _apiKeyCtrl.text.trim();

    if (widget.isCustomNew && baseUrl.isEmpty) {
      setState(() => _errorMsg = '请填写 API 地址 (Base URL)，例如 https://api.example.com/v1');
      return;
    }
    if (baseUrl.isNotEmpty) {
      final parsedUrl = Uri.tryParse(baseUrl);
      if (parsedUrl == null ||
          (parsedUrl.scheme != 'http' && parsedUrl.scheme != 'https') ||
          parsedUrl.host.isEmpty) {
        setState(() => _errorMsg = 'API 地址格式无效，请以 http:// 或 https:// 开头并包含主机名');
        return;
      }
    }
    if (widget.isCustomNew) {
      final existingIds = ref.read(appProvider).providerCredentials.map((p) => p.id.toLowerCase()).toSet();
      if (existingIds.contains(pid.toLowerCase())) {
        setState(() {
          _showAdvancedEnv = true;
          _errorMsg = '渠道 ID「$pid」已存在，请在「密钥标识设置」中修改渠道 ID 或直接编辑原有渠道';
        });
        return;
      }
    }
    if (_discoveredPool.isNotEmpty && _selectedDiscoveredIds.isNotEmpty) {
      _commitSelectedDiscoveredModels();
    }
    if (_showAddModel && _newModelIdCtrl.text.trim().isNotEmpty) {
      if (!_addCustomModel()) return;
    }
    final isCustomProvider = widget.isCustomNew || !_isBuiltinProvider(pid);
    if (isCustomProvider && widget.settingsNs == 'llm-pi-ai' && _models.isEmpty) {
      setState(() => _errorMsg = '自定义中转站请至少添加或自动拉取 1 个模型后再保存');
      return;
    }

    setState(() {
      _saving = true;
      _errorMsg = null;
    });

    String? err;
    try {
      err = await ref.read(appProvider.notifier).saveProviderConfig(
            providerId: pid,
            settingsNs: widget.settingsNs,
            displayName: name,
            apiProtocol: _protocol,
            baseUrl: baseUrl,
            envRef: envRef,
            apiKeyValue: secret,
            customModels: widget.settingsNs == 'llm-pi-ai' ? _models : null,
            isCustomProvider: isCustomProvider,
          );
    } catch (e) {
      err = e.toString();
    } finally {
      if (mounted && err != null) {
        setState(() {
          _saving = false;
          _errorMsg = err;
        });
      } else if (mounted && _saving) {
        setState(() => _saving = false);
      }
    }

    if (!mounted || err != null) return;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      appProvider.select(
        (s) => (
          glassTier: s.glassTier,
          modelGroups: s.modelGroups,
          providerCredentials: s.providerCredentials,
          dshNamespaces: s.dshNamespaces,
          activeModelProvider: s.activeModelProvider,
          activeModelId: s.activeModelId,
          connectionPhase: s.connectionPhase,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final tier = state.glassTier;
    final isPiAi = widget.settingsNs == 'llm-pi-ai';

    final existingCred = state.providerCredentials
        .where((p) => p.id == widget.providerId)
        .firstOrNull;
    final alreadyHasKey = !widget.isCustomNew &&
        (existingCred?.configured ?? false) &&
        existingCred?.maskedKey != '免密钥端点';
    final liveGroup = state.modelGroups.where((g) => g.id == widget.providerId).firstOrNull;
    final piAiNs = state.effectiveDshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
    final canDeleteCustom = !widget.isCustomNew &&
        isPiAi &&
        piAiNs != null &&
        piAiNs.value['providers'] is Map &&
        (piAiNs.value['providers'] as Map).containsKey(widget.providerId);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_probeSuccessMsg != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: t.okSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(CupertinoIcons.checkmark_circle_fill, size: 14, color: t.ok),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_probeSuccessMsg!, style: TextStyle(fontSize: 12, color: t.ok)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        if (_errorMsg != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: t.errSoft,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.err.withValues(alpha: 0.35), width: 0.6),
            ),
            child: Text(_errorMsg!, style: TextStyle(fontSize: 12.5, color: t.err)),
          ),
          const SizedBox(height: 10),
        ],

        // DeepSeek official quick switch: offer 1-tap account sign-in before manual API Key entry
        if (widget.settingsNs == 'llm-deepseek' && !widget.isCustomNew) ...[
          GrassBagStatusBanner(
            tone: GrassBagBannerTone.info,
            icon: CupertinoIcons.sparkles,
            title: '不想手动填 API Key？',
            message: '支持一键登录 DeepSeek 账号免密直连，额度与网页版同步。',
            padding: const EdgeInsets.all(11),
            borderRadius: 14,
            action: GrassBagPrimaryGlassButton(
              label: '一键登录 DeepSeek 账号',
              icon: CupertinoIcons.person_crop_circle_badge_checkmark,
              height: 34,
              tier: tier,
              insideGlass: true,
              onTap: () {
                final outer = widget.outerContext;
                Navigator.of(context).pop();
                Future<void>.delayed(const Duration(milliseconds: 160), () {
                  if (outer.mounted) launchDeepSeekSignInFlow(outer, ref);
                });
              },
            ),
          ),
          const SizedBox(height: 12),
        ],

        // 0. 1-Tap Relay Templates for Brand New Custom Channels
        if (widget.isCustomNew && isPiAi) ...[
          Text('快捷填充常见中转模板', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.text2)),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (int i = 0; i < _kCustomQuickTemplates.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  _FilterPill(
                    label: _kCustomQuickTemplates[i].label,
                    active: _baseUrlCtrl.text.trim() == _kCustomQuickTemplates[i].baseUrl,
                    onTap: () => _applyCustomTemplate(_kCustomQuickTemplates[i]),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],

        // 1. Provider Name (and optional ID on new custom relay)
        if (isPiAi) ...[
          Text('渠道名称', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.text2)),
          const SizedBox(height: 5),
          GrassBagTextField(
            controller: _nameCtrl,
            insideGlass: true,
            placeholder: '例如：我的中转站 / OpenAI / DeepSeek',
            fontSize: 13.5,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          ),
          const SizedBox(height: 11),
        ],

        // 2. API Protocol Selector (only for llm-pi-ai)
        if (isPiAi) ...[
          Text('接口协议', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.text2)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final proto in _kApiProtocols)
                _FilterPill(
                  label: proto.$2,
                  active: _protocol == proto.$1,
                  onTap: () => setState(() {
                    _protocol = proto.$1;
                    _protocolManuallyPicked = true;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            '常见中转站 / 聚合站选「OpenAI 兼容」，Claude 官方或原生中转选「Anthropic」',
            style: TextStyle(fontSize: 11, color: t.text3),
          ),
          const SizedBox(height: 11),
        ],

        // 3. Base URL
        Text('API 地址 (Base URL)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.text2)),
        const SizedBox(height: 5),
        GrassBagTextField(
          controller: _baseUrlCtrl,
          insideGlass: true,
          monospace: true,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          onChanged: _maybeInferProtocolFromUrl,
          placeholder: _protocol == 'anthropic-messages'
              ? 'https://api.anthropic.com'
              : 'https://api.example.com/v1',
          fontSize: 13,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        ),
        const SizedBox(height: 4),
        Text(
          'OpenAI 兼容地址通常以 /v1 结尾，Anthropic 协议一般不含 /v1',
          style: TextStyle(fontSize: 11, color: t.text3),
        ),
        const SizedBox(height: 11),

        // 4. API Key with Paste + Eye Toggle + Configured Status Pill
        Row(
          children: [
            Text('API 密钥 (Key)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.text2)),
            const SizedBox(width: 8),
            if (alreadyHasKey)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                decoration: BoxDecoration(color: t.okSoft, borderRadius: BorderRadius.circular(999)),
                child: Text('已配置', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: t.ok)),
              ),
            const Spacer(),
            GestureDetector(
              onTap: () => setState(() => _showAdvancedEnv = !_showAdvancedEnv),
              child: Text(
                _showAdvancedEnv ? '隐藏密钥标识' : '密钥标识设置',
                style: TextStyle(fontSize: 11.5, color: t.primary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        GrassBagTextField(
          controller: _apiKeyCtrl,
          insideGlass: true,
          monospace: true,
          obscureText: _obscureKey,
          placeholder: alreadyHasKey ? '留空保持当前密钥，或粘贴新密钥覆盖…' : 'sk-…',
          fontSize: 13,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          suffix: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  final pasted = data?.text?.trim() ?? '';
                  if (!mounted) return;
                  if (pasted.isEmpty) {
                    ctrl.showToast('剪贴板为空', tone: ToastTone.info);
                    return;
                  }
                  _apiKeyCtrl.text = pasted;
                  setState(() => _errorMsg = null);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: t.primarySoft,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    '粘贴',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: t.primary),
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _obscureKey = !_obscureKey),
                child: Padding(
                  padding: const EdgeInsets.only(right: 10, left: 4),
                  child: Icon(
                    _obscureKey ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
                    size: 16,
                    color: t.text3,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Optional Advanced ID + EnvRef fields (tucked out of the way by default!)
        if (_showAdvancedEnv) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              if (widget.isCustomNew) ...[
                Expanded(
                  child: GrassBagTextField(
                    controller: _idCtrl,
                    insideGlass: true,
                    monospace: true,
                    placeholder: '渠道 ID（如 my-relay）',
                    fontSize: 12,
                    borderRadius: 12,
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: GrassBagTextField(
                  controller: _envRefCtrl,
                  insideGlass: true,
                  monospace: true,
                  placeholder: '密钥变量名（如 CPA_API_KEY）',
                  fontSize: 12,
                  borderRadius: 12,
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                ),
              ),
            ],
          ),
        ],

        // 5a. Built-in / Live-synced models for this provider (when not already listed as custom models)
        if (!widget.isCustomNew &&
            liveGroup != null &&
            liveGroup.models.isNotEmpty &&
            (!isPiAi || _models.isEmpty)) ...[
          const SizedBox(height: 14),
          Text(
            '该渠道可用模型 (${liveGroup.models.length})',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text2),
          ),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: t.fill1,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.sep, width: 0.5),
            ),
            child: Column(
              children: [
                for (int i = 0; i < liveGroup.models.length && i < 6; i++) ...[
                  Builder(
                    builder: (_) {
                      final m = liveGroup.models[i];
                      final isDefault = state.activeModelId == m.id &&
                          state.activeModelProvider == liveGroup.id;
                      return GrassBagListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        title: Text(
                          m.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isDefault ? FontWeight.w600 : FontWeight.w500,
                            color: isDefault ? t.primary : t.text,
                          ),
                        ),
                        subtitle: Text(m.id, style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: t.text3)),
                        trailing: isDefault
                            ? Icon(CupertinoIcons.checkmark_circle_fill, size: 17, color: t.primary)
                            : Text('设为默认', style: TextStyle(fontSize: 11.5, color: t.primary)),
                        onTap: () => ctrl.setModel(
                          m.name,
                          m.shortLabel,
                          provider: liveGroup.id,
                          modelId: m.id,
                          effortId: m.defaultEffort,
                        ),
                      );
                    },
                  ),
                  if (i < liveGroup.models.length - 1 && i < 5)
                    Divider(height: 0.5, indent: 12, endIndent: 12, color: t.sep),
                ],
                if (liveGroup.models.length > 6)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                    child: Text(
                      '还有 ${liveGroup.models.length - 6} 个模型，可在「全部模型」标签页搜索切换',
                      style: TextStyle(fontSize: 11, color: t.text3),
                    ),
                  ),
              ],
            ),
          ),
        ],

        // 5b. Visual Custom Models List & Quick Add Model (for llm-pi-ai / custom relays!)
        if (isPiAi) ...[
          const SizedBox(height: 14),
          if (widget.isCustomNew &&
              _models.isEmpty &&
              state.connectionPhase == ConnectionPhase.connected) ...[
            GrassBagSecondaryGlassButton(
              label: _discovering ? '正在测试并拉取模型…' : '测试连通并自动拉取模型（推荐）',
              icon: CupertinoIcons.cloud_download,
              height: 38,
              tier: tier,
              insideGlass: true,
              accentForeground: true,
              enabled: !_discovering && !_testingConnection && !_saving,
              onTap: (_discovering || _testingConnection || _saving)
                  ? null
                  : () => _discoverModels(testOnly: false),
            ),
            const SizedBox(height: 10),
          ],
          Text(
            '自定义模型列表 (${_models.length})',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text2),
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 7,
            runSpacing: 6,
            children: [
              if (state.connectionPhase == ConnectionPhase.connected) ...[
                GrassBagSpringTap(
                  enabled: !_testingConnection && !_discovering && !_saving,
                  onTap: () => _discoverModels(testOnly: true),
                  pressedScale: 0.94,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
                    decoration: BoxDecoration(
                      color: t.fill1,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: t.sep, width: 0.65),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_testingConnection)
                          CupertinoActivityIndicator(radius: 6, color: t.text2)
                        else
                          Icon(CupertinoIcons.checkmark_shield, size: 13, color: t.text2),
                        const SizedBox(width: 4),
                        Text(
                          _testingConnection ? '测试中…' : '测试连通',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.text2),
                        ),
                      ],
                    ),
                  ),
                ),
                GrassBagSpringTap(
                  enabled: !_discovering && !_testingConnection && !_saving,
                  onTap: () => _discoverModels(testOnly: false),
                  pressedScale: 0.94,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
                    decoration: BoxDecoration(
                      color: t.primarySoft,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: t.primary.withValues(alpha: 0.25), width: 0.65),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_discovering)
                          CupertinoActivityIndicator(radius: 6, color: t.primary)
                        else
                          Icon(CupertinoIcons.cloud_download, size: 13, color: t.primary),
                        const SizedBox(width: 4),
                        Text(
                          _discovering ? '拉取中…' : '自动拉取',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.primary),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              GrassBagSpringTap(
                onTap: () {
                  if (_showAddModel) {
                    _cancelEditingModel();
                  } else {
                    setState(() => _showAddModel = true);
                  }
                },
                pressedScale: 0.94,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
                  decoration: BoxDecoration(
                    color: _showAddModel ? t.fill2 : t.primarySoft,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: _showAddModel ? t.sep : t.primary.withValues(alpha: 0.25),
                      width: 0.65,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _showAddModel ? CupertinoIcons.minus_circle : CupertinoIcons.plus_circle_fill,
                        size: 13.5,
                        color: _showAddModel ? t.text2 : t.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _showAddModel ? '收起添加' : '手动添加',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _showAddModel ? t.text2 : t.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (_models.isNotEmpty)
            Container(
              decoration: BoxDecoration(
                color: t.fill1,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: t.sep, width: 0.5),
              ),
              child: Column(
                children: [
                  for (int i = 0; i < _models.length; i++) ...[
                    Builder(
                      builder: (_) {
                        final m = _models[i];
                        final mid = m['id']?.toString() ?? '';
                        final mname = m['name']?.toString().isNotEmpty == true
                            ? m['name'].toString()
                            : mid;
                        final ctxLabel = _formatCtxWindow((m['contextWindow'] as num?)?.toInt());
                        final maxTokLabel = _formatCtxWindow((m['maxTokens'] as num?)?.toInt());
                        final hasReasoning = m['reasoning'] == true ||
                            (m['reasoningEfforts'] is Map && (m['reasoningEfforts'] as Map).isNotEmpty);
                        final isDefault = state.activeModelId == mid &&
                            state.activeModelProvider == widget.providerId;
                        final isEditingThis = _editingModelIndex == i;
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            mname,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: isDefault ? t.primary : t.text,
                                            ),
                                          ),
                                        ),
                                        if (ctxLabel.isNotEmpty) ...[
                                          const SizedBox(width: 5),
                                          Text(
                                            maxTokLabel.isNotEmpty ? '$ctxLabel / $maxTokLabel' : ctxLabel,
                                            style: TextStyle(fontSize: 10.5, color: t.text3),
                                          ),
                                        ],
                                        if (hasReasoning) ...[
                                          const SizedBox(width: 5),
                                          Text(
                                            '思考',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: t.primary,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    if (mname != mid)
                                      Text(
                                        mid,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: t.text3),
                                      ),
                                  ],
                                ),
                              ),
                              if (!widget.isCustomNew &&
                                  mid.isNotEmpty &&
                                  _savedModelIds.contains(mid))
                                GestureDetector(
                                  onTap: () {
                                    final short = mname.contains('/')
                                        ? mname.split('/').last
                                        : mname;
                                    final catalogEntry = liveGroup?.models
                                        .where((entry) => entry.id == mid)
                                        .firstOrNull;
                                    ctrl.setModel(
                                      mname,
                                      short.length > 18 ? '${short.substring(0, 17)}…' : short,
                                      provider: widget.providerId,
                                      modelId: mid,
                                      effortId: catalogEntry?.defaultEffort ??
                                          (m['reasoning'] == true ? 'medium' : null),
                                    );
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: isDefault ? t.primarySoft : t.fill2,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      isDefault ? '当前默认' : '设为默认',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: isDefault ? t.primary : t.text2,
                                      ),
                                    ),
                                  ),
                                ),
                              const SizedBox(width: 4),
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _startEditingModel(i),
                                child: SizedBox(
                                  width: 34,
                                  height: 34,
                                  child: Center(
                                    child: Icon(
                                      CupertinoIcons.pencil_circle,
                                      size: 17,
                                      color: isEditingThis ? t.primary : t.text2,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 2),
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () async {
                                  final modelLabel =
                                      (_models[i]['name'] ?? _models[i]['id'] ?? '该模型').toString();
                                  final ok = await showGrassBagConfirmDialog(
                                    context,
                                    title: '移除模型「$modelLabel」？',
                                    message: '移除后点击底部「保存并刷新模型」即生效。',
                                    confirmLabel: '移除',
                                    isDestructive: true,
                                  );
                                  if (!ok || !mounted) return;
                                  if (i >= _models.length) return;
                                  if (_editingModelIndex == i) {
                                    _models.removeAt(i);
                                    _cancelEditingModel();
                                  } else {
                                    setState(() {
                                      if (_editingModelIndex != null && i < _editingModelIndex!) {
                                        _editingModelIndex = _editingModelIndex! - 1;
                                      }
                                      _models.removeAt(i);
                                    });
                                  }
                                },
                                child: SizedBox(
                                  width: 34,
                                  height: 34,
                                  child: Center(
                                    child: Icon(CupertinoIcons.trash, size: 15, color: t.err),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    if (i < _models.length - 1) Divider(height: 0.5, indent: 12, endIndent: 12, color: t.sep),
                  ],
                ],
              ),
            ),
          if (_discoveredPool.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: t.fill1,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: t.ok.withValues(alpha: 0.35), width: 0.7),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '已发现 ${_discoveredPool.length} 个远端模型（点选导入）',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => _commitSelectedDiscoveredModels(all: true),
                        child: Text(
                          '全部添加',
                          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.primary),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  GrassBagGlassSearchBar(
                    controller: _discoveredFilterCtrl,
                    placeholder: '筛选模型 ID…',
                    tier: tier,
                    insideGlass: true,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Builder(
                    builder: (_) {
                      final q = _discoveredFilterCtrl.text.trim().toLowerCase();
                      final filteredDiscovered = _discoveredPool.where((m) {
                        if (q.isEmpty) return true;
                        return (m['id']?.toString().toLowerCase().contains(q) ?? false) ||
                            (m['name']?.toString().toLowerCase().contains(q) ?? false);
                      }).toList(growable: false);
                      final visibleDiscovered = filteredDiscovered.take(40).toList(growable: false);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 140),
                            child: SingleChildScrollView(
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final dm in visibleDiscovered)
                                    _FilterPill(
                                      label: dm['id']?.toString() ?? '',
                                      active: _selectedDiscoveredIds.contains(dm['id']?.toString()),
                                      onTap: () => setState(() {
                                        final id = dm['id']?.toString() ?? '';
                                        if (!_selectedDiscoveredIds.add(id)) {
                                          _selectedDiscoveredIds.remove(id);
                                        }
                                      }),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (filteredDiscovered.length > 40) ...[
                            const SizedBox(height: 6),
                            Text(
                              '已展示前 40 / ${filteredDiscovered.length} 个模型，输入关键词可继续筛选',
                              style: TextStyle(fontSize: 11, color: t.text3),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  GrassBagPrimaryGlassButton(
                    label: '添加已选模型 (${_selectedDiscoveredIds.length})',
                    icon: CupertinoIcons.plus_circle,
                    height: 34,
                    tier: tier,
                    insideGlass: true,
                    enabled: _selectedDiscoveredIds.isNotEmpty,
                    onTap: _selectedDiscoveredIds.isEmpty
                        ? null
                        : () => _commitSelectedDiscoveredModels(all: false),
                  ),
                ],
              ),
            ),
          ],
          if (_showAddModel) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: t.fill1,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: t.primary.withValues(alpha: 0.30), width: 0.7),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        _editingModelIndex != null ? '编辑模型参数' : '新增自定义模型',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.primary),
                      ),
                      const Spacer(),
                      GrassBagSpringTap(
                        onTap: _modelsDevLoading
                            ? () {}
                            : () => _scheduleNewModelLookup(_newModelIdCtrl.text, forceFill: true),
                        pressedScale: 0.94,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_modelsDevLoading)
                              CupertinoActivityIndicator(radius: 6, color: t.primary)
                            else
                              Icon(CupertinoIcons.sparkles, size: 12, color: t.primary),
                            const SizedBox(width: 4),
                            Text(
                              _modelsDevLoading ? '查询中…' : 'models.dev 智能填充',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: t.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_editingModelIndex != null) ...[
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: _cancelEditingModel,
                          child: Text('取消编辑', style: TextStyle(fontSize: 11.5, color: t.text3)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 7),
                  GrassBagTextField(
                    controller: _newModelIdCtrl,
                    insideGlass: true,
                    monospace: true,
                    placeholder: '输入模型 ID 自动匹配 models.dev（如 gpt-5 / claude-sonnet-4-5）',
                    fontSize: 12.5,
                    borderRadius: 12,
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8.5),
                    onChanged: (v) => _scheduleNewModelLookup(v),
                  ),
                  if (_modelsDevMatched != null) ...[
                    const SizedBox(height: 6),
                    _ModelsDevMatchedChip(
                      spec: _modelsDevMatched!,
                      onReapply: () => setState(
                        () => _applyModelsDevSpecToNewForm(_modelsDevMatched!, overwriteId: false),
                      ),
                    ),
                  ],
                  if (_modelsDevSuggestions.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: [
                        for (final s in _modelsDevSuggestions)
                          _FilterPill(
                            label:
                                '${s.id}${s.contextWindow != null ? ' · ${(s.contextWindow! / 1000).round()}K' : ''}',
                            active: _modelsDevMatched?.id == s.id,
                            onTap: () => setState(() {
                              _userEditedNewModelParams = false;
                              _applyModelsDevSpecToNewForm(s, overwriteId: true);
                              _modelsDevSuggestions = const [];
                            }),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 7),
                  GrassBagTextField(
                    controller: _newModelNameCtrl,
                    insideGlass: true,
                    placeholder: '显示名称（选填，默认同模型 ID）',
                    fontSize: 12.5,
                    borderRadius: 12,
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8.5),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('上下文窗口 (Tokens)', style: TextStyle(fontSize: 11, color: t.text3)),
                            const SizedBox(height: 4),
                            GrassBagTextField(
                              controller: _newModelCtxCtrl,
                              insideGlass: true,
                              monospace: true,
                              keyboardType: TextInputType.number,
                              placeholder: '200000',
                              fontSize: 12,
                              borderRadius: 12,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              onChanged: (v) {
                                _userEditedNewModelParams = true;
                                final parsed = int.tryParse(v.trim());
                                if (parsed != null && parsed > 0 && parsed != _newModelCtx) {
                                  setState(() => _newModelCtx = parsed);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('最大输出 (Max Tokens)', style: TextStyle(fontSize: 11, color: t.text3)),
                            const SizedBox(height: 4),
                            GrassBagTextField(
                              controller: _newModelMaxTokCtrl,
                              insideGlass: true,
                              monospace: true,
                              keyboardType: TextInputType.number,
                              placeholder: '16384',
                              fontSize: 12,
                              borderRadius: 12,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              onChanged: (v) {
                                _userEditedNewModelParams = true;
                                final parsed = int.tryParse(v.trim());
                                if (parsed != null && parsed > 0) _newModelMaxTok = parsed;
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final ctxOpt in const [(64000, '64K'), (128000, '128K'), (200000, '200K'), (1000000, '1M')])
                        _FilterPill(
                          label: ctxOpt.$2,
                          active: _newModelCtx == ctxOpt.$1,
                          onTap: () => setState(() {
                            _userEditedNewModelParams = true;
                            _newModelCtx = ctxOpt.$1;
                            _newModelCtxCtrl.text = '${ctxOpt.$1}';
                          }),
                        ),
                      _FilterPill(
                        label: _newModelVision ? '✓ 识图' : '纯文本',
                        active: _newModelVision,
                        onTap: () => setState(() {
                          _userEditedNewModelParams = true;
                          _newModelVision = !_newModelVision;
                        }),
                      ),
                      _FilterPill(
                        label: _newModelReasoning ? '✓ 深度思考' : '标准推理',
                        active: _newModelReasoning,
                        onTap: () => setState(() {
                          _userEditedNewModelParams = true;
                          _newModelReasoning = !_newModelReasoning;
                        }),
                      ),
                    ],
                  ),
                  if (_newModelReasoning) ...[
                    const SizedBox(height: 9),
                    _ReasoningEffortsEditor(
                      efforts: _newModelEffortMap,
                      onChanged: (next) => setState(() {
                        _userEditedNewModelParams = true;
                        _newModelEffortMap = next;
                      }),
                    ),
                  ],
                  const SizedBox(height: 9),
                  GrassBagSecondaryGlassButton(
                    label: _editingModelIndex != null ? '更新该模型参数' : '添加到模型列表',
                    icon: _editingModelIndex != null ? CupertinoIcons.checkmark_alt : CupertinoIcons.plus,
                    height: 34,
                    tier: tier,
                    insideGlass: true,
                    accentForeground: true,
                    onTap: _addCustomModel,
                  ),
                ],
              ),
            ),
          ],
        ],

        const SizedBox(height: 16),

        // 6. Inline error near bottom Save CTA + Primary Save / Clear Key / Delete Custom Provider
        if (_errorMsg != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: t.errSoft,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.err.withValues(alpha: 0.35), width: 0.6),
            ),
            child: Text(_errorMsg!, style: TextStyle(fontSize: 12.5, color: t.err)),
          ),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            if (alreadyHasKey && existingCred != null && existingCred.envRef.isNotEmpty) ...[
              Expanded(
                child: GrassBagSecondaryGlassButton(
                  label: '清除密钥',
                  tier: tier,
                  insideGlass: true,
                  destructive: true,
                  enabled: !_saving,
                  onTap: _saving
                      ? null
                      : () async {
                    final ok = await showGrassBagConfirmDialog(
                      context,
                      title: '清除「${existingCred.name}」的 API 密钥？',
                      message: '清除环境变量 ${existingCred.envRef} 后，该渠道模型将暂时无法调用，需重新填入密钥。',
                      confirmLabel: '确认清除',
                      isDestructive: true,
                    );
                    if (ok && context.mounted) {
                      Navigator.of(context).pop();
                      unawaited(ctrl.removeProviderCredential(existingCred.envRef));
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              flex: 2,
              child: GrassBagPrimaryGlassButton(
                label: _saving ? '保存中…' : '保存并刷新模型',
                icon: CupertinoIcons.checkmark_alt,
                tier: tier,
                insideGlass: true,
                enabled: !_saving && !_discovering,
                onTap: (_saving || _discovering) ? null : _save,
              ),
            ),
          ],
        ),
        if (canDeleteCustom) ...[
          const SizedBox(height: 8),
          Builder(
            builder: (_) {
              final isBuiltin = _isBuiltinProvider(widget.providerId);
              return Center(
                child: GestureDetector(
                  onTap: _saving
                      ? null
                      : () async {
                    final ok = await showGrassBagConfirmDialog(
                      context,
                      title: isBuiltin
                          ? '重置「${widget.initialDisplayName}」为默认配置？'
                          : '移除渠道「${widget.initialDisplayName}」？',
                      message: isBuiltin
                          ? '将清除此内置渠道的自定义接口地址与模型覆盖，恢复 DSH 默认配置。'
                          : '将从 DSH llm-pi-ai 配置中移除该自定义渠道、模型列表及凭据。',
                      confirmLabel: isBuiltin ? '重置' : '移除',
                      isDestructive: true,
                    );
                    if (ok && context.mounted) {
                      Navigator.of(context).pop();
                      unawaited(
                        ctrl.deleteCustomProvider(
                          widget.providerId,
                          isCustom: !isBuiltin,
                        ),
                      );
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Text(
                      isBuiltin ? '重置为 DSH 默认渠道配置' : '删除此自定义渠道',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: t.err),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

/// Dedicated sheet to edit a single model's parameters (`name`, `contextWindow`, `maxTokens`,
/// `reasoning`, `supportsImage`) and persist directly into DSH `llm-pi-ai`.
void showModelParamsEditorSheet(
  BuildContext context, {
  required String providerId,
  required ModelCatalogEntry entry,
}) {
  showGrassBagSheet<void>(
    context,
    title: '编辑模型参数',
    subtitle: '$providerId / ${entry.id}',
    bodyBuilder: (_) => _ModelParamsEditorBody(providerId: providerId, entry: entry),
  );
}

class _ModelParamsEditorBody extends ConsumerStatefulWidget {
  const _ModelParamsEditorBody({
    required this.providerId,
    required this.entry,
  });

  final String providerId;
  final ModelCatalogEntry entry;

  @override
  ConsumerState<_ModelParamsEditorBody> createState() => _ModelParamsEditorBodyState();
}

class _ModelParamsEditorBodyState extends ConsumerState<_ModelParamsEditorBody> {
  late final TextEditingController _idCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _ctxCtrl;
  late final TextEditingController _maxTokCtrl;
  late bool _reasoning;
  late Map<String, String?> _effortMap;
  late bool _vision;
  bool _setDefault = false;
  bool _saving = false;
  bool _modelsDevLoading = false;
  ModelsDevSpec? _modelsDevMatched;
  List<ModelsDevSpec> _modelsDevSuggestions = const [];
  Timer? _modelsDevDebounce;
  int _modelsDevReqSeq = 0;
  String? _err;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _idCtrl = TextEditingController(text: e.id);
    _nameCtrl = TextEditingController(text: e.name);
    _ctxCtrl = TextEditingController(text: '${e.contextWindow ?? 128000}');
    _maxTokCtrl = TextEditingController(text: '${e.maxTokens ?? 16384}');
    _reasoning = e.supportsReasoning;
    // Load stored DSH `llm-pi-ai` wire spelling map if available so custom wire spellings stay intact!
    final piAiNs = ref.read(appProvider).effectiveDshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
    final rawProviders = piAiNs?.value['providers'];
    final provCfg = rawProviders is Map ? rawProviders[widget.providerId] : null;
    final rawModels = provCfg is Map ? provCfg['models'] : null;
    Map<dynamic, dynamic>? storedModel;
    if (rawModels is List) {
      for (final item in rawModels) {
        if (item is Map && item['id']?.toString() == e.id) {
          storedModel = item;
          break;
        }
      }
    }
    if (storedModel != null && storedModel['reasoningEfforts'] is Map) {
      _effortMap = _parseEffortMapFromModelJson(storedModel['reasoningEfforts']);
    } else if (e.efforts.isNotEmpty) {
      final map = <String, String?>{};
      for (final ef in e.efforts) {
        final k = ef.id.toLowerCase();
        if (_kDshThinkingLevels.any((l) => l.$1 == k)) {
          map[k] = k == 'off' ? null : k;
        }
      }
      _effortMap = map.isNotEmpty
          ? map
          : <String, String?>{'off': null, 'low': 'low', 'medium': 'medium', 'high': 'high'};
    } else {
      _effortMap = <String, String?>{'off': null, 'low': 'low', 'medium': 'medium', 'high': 'high'};
    }
    _vision = e.supportsImage;
  }

  @override
  void dispose() {
    _modelsDevDebounce?.cancel();
    _idCtrl.dispose();
    _nameCtrl.dispose();
    _ctxCtrl.dispose();
    _maxTokCtrl.dispose();
    super.dispose();
  }

  void _scheduleLookup(String query, {bool forceFill = false}) {
    _modelsDevDebounce?.cancel();
    final q = query.trim();
    if (q.length < 2) {
      setState(() {
        _modelsDevSuggestions = const [];
        _modelsDevMatched = null;
        _modelsDevLoading = false;
      });
      return;
    }
    _modelsDevDebounce = Timer(Duration(milliseconds: forceFill ? 10 : 420), () {
      unawaited(_runLookup(q, forceFill: forceFill));
    });
  }

  Future<void> _runLookup(String query, {bool forceFill = false}) async {
    final seq = ++_modelsDevReqSeq;
    if (mounted) setState(() => _modelsDevLoading = true);
    final results = await Future.wait([
      ModelsDevCatalogService.instance.lookupModel(query),
      ModelsDevCatalogService.instance.searchSuggestions(query, limit: 5),
    ]);
    if (!mounted || seq != _modelsDevReqSeq) return;
    final matched = results[0] as ModelsDevSpec?;
    final suggestions = results[1] as List<ModelsDevSpec>;
    setState(() {
      _modelsDevLoading = false;
      _modelsDevSuggestions = suggestions;
      _modelsDevMatched = matched;
      if (matched != null && forceFill) {
        _applySpec(matched, overwriteId: false);
      } else if (matched == null && forceFill) {
        ref.read(appProvider.notifier).showToast('models.dev 暂未收录「$query」，可手动填写参数', tone: ToastTone.info);
      }
    });
  }

  void _applySpec(ModelsDevSpec spec, {required bool overwriteId}) {
    if (overwriteId) _idCtrl.text = spec.id;
    if (spec.name.isNotEmpty) _nameCtrl.text = spec.name;
    if (spec.contextWindow != null && spec.contextWindow! > 0) {
      _ctxCtrl.text = '${spec.contextWindow}';
    }
    if (spec.maxOutputTokens != null && spec.maxOutputTokens! > 0) {
      _maxTokCtrl.text = '${spec.maxOutputTokens}';
    }
    _vision = spec.supportsImage;
    _reasoning = spec.reasoning || spec.reasoningEfforts.isNotEmpty;
    if (_reasoning) {
      _effortMap = _effortMapFromModelsDev(spec.reasoningEfforts);
    }
    _modelsDevMatched = spec;
    _err = null;
  }

  Future<void> _save() async {
    final id = _idCtrl.text.trim();
    if (id.isEmpty) {
      setState(() => _err = '模型 ID 不能为空');
      return;
    }
    final ctx = int.tryParse(_ctxCtrl.text.trim());
    final maxTok = int.tryParse(_maxTokCtrl.text.trim());
    if (_ctxCtrl.text.trim().isNotEmpty && (ctx == null || ctx <= 0)) {
      setState(() => _err = '上下文窗口必须为正整数');
      return;
    }
    if (_maxTokCtrl.text.trim().isNotEmpty && (maxTok == null || maxTok <= 0)) {
      setState(() => _err = '最大输出 Token 必须为正整数');
      return;
    }
    if (ctx != null && maxTok != null && maxTok > ctx) {
      setState(() => _err = '最大输出 Token ($maxTok) 不能大于上下文窗口 ($ctx)');
      return;
    }
    if (_reasoning) {
      final effortErr = _validateEffortMap(_effortMap);
      if (effortErr != null) {
        setState(() => _err = effortErr);
        return;
      }
    }
    if (id != widget.entry.id) {
      final st = ref.read(appProvider);
      final group = st.modelGroups.where((g) => g.id == widget.providerId).firstOrNull;
      final dupInCatalog = group?.models.any((m) => m.id == id) == true;
      final piAiNs = st.effectiveDshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
      final providersMap = piAiNs != null && piAiNs.value['providers'] is Map
          ? piAiNs.value['providers'] as Map
          : const {};
      final provCfg = providersMap[widget.providerId] is Map ? providersMap[widget.providerId] as Map : null;
      final rawModels = provCfg?['models'] is List ? provCfg!['models'] as List : const [];
      final dupInConfig = rawModels.any((m) => m is Map && m['id']?.toString().trim() == id);
      if (dupInCatalog || dupInConfig) {
        setState(() => _err = '模型 ID「$id」已存在于当前渠道中，请勿重复命名');
        return;
      }
    }
    final normalizedEffortMap = _reasoning
        ? <String, String?>{
            for (final e in _orderedEffortMap(_effortMap).entries)
              e.key: e.key == 'off'
                  ? (e.value?.trim().isNotEmpty == true ? e.value!.trim() : null)
                  : (e.value?.trim().isNotEmpty == true ? e.value!.trim() : e.key),
          }
        : null;
    setState(() {
      _saving = true;
      _err = null;
    });
    String? err;
    try {
      err = await ref.read(appProvider.notifier).saveModelParams(
            providerId: widget.providerId,
            modelId: id,
            previousModelId: widget.entry.id,
            displayName: _nameCtrl.text.trim(),
            contextWindow: ctx,
            maxTokens: maxTok,
            reasoning: _reasoning,
            reasoningEffortMap: normalizedEffortMap,
            supportsImage: _vision,
            setAsDefault: _setDefault,
          );
    } catch (e) {
      err = e.toString();
    } finally {
      if (mounted && err != null) {
        setState(() {
          _saving = false;
          _err = err;
        });
      } else if (mounted && _saving) {
        setState(() => _saving = false);
      }
    }
    if (!mounted || err != null) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final curCtx = int.tryParse(_ctxCtrl.text.trim()) ?? 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_err != null) ...[
          GrassBagStatusBanner(
            tone: GrassBagBannerTone.error,
            message: _err!,
            borderRadius: 14,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            Text('模型 ID', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.text2)),
            const Spacer(),
            GrassBagSpringTap(
              onTap: _modelsDevLoading
                  ? () {}
                  : () => _scheduleLookup(_idCtrl.text, forceFill: true),
              pressedScale: 0.94,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_modelsDevLoading)
                    CupertinoActivityIndicator(radius: 6, color: t.primary)
                  else
                    Icon(CupertinoIcons.sparkles, size: 12.5, color: t.primary),
                  const SizedBox(width: 4),
                  Text(
                    _modelsDevLoading ? '正在拉取…' : '从 models.dev 智能填充',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.primary),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        GrassBagTextField(
          controller: _idCtrl,
          insideGlass: true,
          monospace: true,
          fontSize: 13,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          onChanged: (v) => _scheduleLookup(v),
        ),
        if (_modelsDevMatched != null) ...[
          const SizedBox(height: 7),
          _ModelsDevMatchedChip(
            spec: _modelsDevMatched!,
            onReapply: () => setState(() => _applySpec(_modelsDevMatched!, overwriteId: false)),
          ),
        ],
        if (_modelsDevSuggestions.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              for (final s in _modelsDevSuggestions)
                _FilterPill(
                  label: '${s.id}${s.contextWindow != null ? ' · ${(s.contextWindow! / 1000).round()}K' : ''}',
                  active: _modelsDevMatched?.id == s.id,
                  onTap: () => setState(() {
                    _applySpec(s, overwriteId: true);
                    _modelsDevSuggestions = const [];
                  }),
                ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Text('显示名称', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.text2)),
        const SizedBox(height: 5),
        GrassBagTextField(
          controller: _nameCtrl,
          insideGlass: true,
          fontSize: 13.5,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('上下文窗口', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.text2)),
                  const SizedBox(height: 5),
                  GrassBagTextField(
                    controller: _ctxCtrl,
                    insideGlass: true,
                    monospace: true,
                    keyboardType: TextInputType.number,
                    fontSize: 13,
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('最大输出 Token', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.text2)),
                  const SizedBox(height: 5),
                  GrassBagTextField(
                    controller: _maxTokCtrl,
                    insideGlass: true,
                    monospace: true,
                    keyboardType: TextInputType.number,
                    fontSize: 13,
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final opt in const [(32000, '32K'), (64000, '64K'), (128000, '128K'), (200000, '200K'), (1000000, '1M')])
              _FilterPill(
                label: opt.$2,
                active: curCtx == opt.$1,
                onTap: () => setState(() => _ctxCtrl.text = '${opt.$1}'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        GrassBagSheetSection(
          children: [
            GrassBagListTile(
              title: const Text('支持深度思考（可自定义档位与参数）'),
              trailing: GrassBagGlassSwitch(
                value: _reasoning,
                tier: tier,
                activeColor: t.ok,
                onChanged: (v) => setState(() => _reasoning = v),
              ),
            ),
            if (_reasoning)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
                child: _ReasoningEffortsEditor(
                  efforts: _effortMap,
                  onChanged: (next) => setState(() => _effortMap = next),
                ),
              ),
            GrassBagListTile(
              title: const Text('支持图片视觉输入'),
              trailing: GrassBagGlassSwitch(
                value: _vision,
                tier: tier,
                activeColor: t.ok,
                onChanged: (v) => setState(() => _vision = v),
              ),
            ),
            GrassBagListTile(
              title: const Text('保存后设为默认模型'),
              trailing: GrassBagGlassSwitch(
                value: _setDefault,
                tier: tier,
                onChanged: (v) => setState(() => _setDefault = v),
              ),
            ),
          ],
        ),
        if (_err != null) ...[
          const SizedBox(height: 10),
          GrassBagStatusBanner(
            tone: GrassBagBannerTone.error,
            message: _err!,
            borderRadius: 14,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
        ],
        const SizedBox(height: 14),
        GrassBagPrimaryGlassButton(
          label: _saving ? '正在写入 DSH…' : '保存模型参数',
          icon: CupertinoIcons.checkmark_alt,
          tier: tier,
          insideGlass: true,
          enabled: !_saving,
          onTap: _saving ? null : _save,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// DSH Canonical 7-Level Thinking Efforts + Custom Wire Spelling Editor
// ---------------------------------------------------------------------------

/// Canonical DSH `dsh-llm-pi-ai` `THINKING_LEVELS` in exact escalation order.
const List<(String, String)> _kDshThinkingLevels = [
  ('off', '关闭'),
  ('minimal', '极轻'),
  ('low', '轻度'),
  ('medium', '均衡'),
  ('high', '深度'),
  ('xhigh', '超高'),
  ('max', '极限'),
];

Map<String, String?> _parseEffortMapFromModelJson(dynamic raw) {
  final out = <String, String?>{};
  if (raw is Map) {
    for (final entry in raw.entries) {
      final k = entry.key.toString().trim().toLowerCase();
      if (_kDshThinkingLevels.any((l) => l.$1 == k)) {
        final v = entry.value?.toString().trim();
        out[k] = k == 'off' ? (v == null || v.isEmpty ? null : v) : (v == null || v.isEmpty ? k : v);
      }
    }
  }
  if (out.isEmpty) {
    return <String, String?>{'off': null, 'low': 'low', 'medium': 'medium', 'high': 'high'};
  }
  return out;
}

Map<String, String?> _effortMapFromModelsDev(List<String> rawEfforts) {
  if (rawEfforts.isEmpty) {
    return <String, String?>{'off': null, 'low': 'low', 'medium': 'medium', 'high': 'high'};
  }
  final out = <String, String?>{'off': null};
  for (final raw in rawEfforts) {
    final norm = raw.trim().toLowerCase();
    if (norm.isEmpty) continue;
    final mappedKey = switch (norm) {
      'none' || 'off' => 'off',
      'minimal' => 'minimal',
      'low' => 'low',
      'medium' || 'mid' => 'medium',
      'high' => 'high',
      'xhigh' || 'very_high' || 'very-high' => 'xhigh',
      'max' || 'ultra' => 'max',
      _ => null,
    };
    if (mappedKey != null) {
      out[mappedKey] = mappedKey == 'off' ? (norm == 'off' ? null : norm) : raw.trim();
    }
  }
  if (!out.keys.any((k) => k != 'off')) {
    out['low'] = 'low';
    out['medium'] = 'medium';
    out['high'] = 'high';
  }
  return _orderedEffortMap(out);
}

Map<String, String?> _orderedEffortMap(Map<String, String?> src) {
  final ordered = <String, String?>{};
  for (final lvl in _kDshThinkingLevels) {
    if (src.containsKey(lvl.$1)) {
      ordered[lvl.$1] = src[lvl.$1];
    }
  }
  return ordered;
}

Map<String, dynamic> _serializeEffortMap(Map<String, String?> src) {
  final ordered = _orderedEffortMap(src);
  return <String, dynamic>{
    for (final entry in ordered.entries)
      entry.key: entry.key == 'off'
          ? (entry.value?.trim().isNotEmpty == true ? entry.value!.trim() : null)
          : (entry.value?.trim().isNotEmpty == true ? entry.value!.trim() : entry.key),
  };
}

String? _validateEffortMap(Map<String, String?> src) {
  final activeKeys = src.keys.where((k) => k != 'off').toList(growable: false);
  if (activeKeys.isEmpty) {
    return '开启深度思考时，请至少保留 1 个非关闭 (off) 的思考档位';
  }
  return null;
}

class _ModelsDevMatchedChip extends StatelessWidget {
  const _ModelsDevMatchedChip({
    required this.spec,
    required this.onReapply,
  });

  final ModelsDevSpec spec;
  final VoidCallback onReapply;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final parts = <String>[
      if (spec.contextWindow != null) '上下文 ${(spec.contextWindow! / 1000).round()}K',
      if (spec.maxOutputTokens != null) '输出 ${(spec.maxOutputTokens! / 1000).round()}K',
      if (spec.reasoning) '深度思考',
      if (spec.supportsImage) '识图',
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: t.okSoft,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: t.ok.withValues(alpha: 0.28), width: 0.65),
      ),
      child: Row(
        children: [
          Icon(CupertinoIcons.checkmark_seal_fill, size: 13.5, color: t.ok),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'models.dev 已匹配 ${spec.name}${parts.isNotEmpty ? ' · ${parts.join(' · ')}' : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.2, fontWeight: FontWeight.w500, color: t.ok),
            ),
          ),
          const SizedBox(width: 6),
          GrassBagSpringTap(
            onTap: onReapply,
            pressedScale: 0.92,
            child: Text(
              '重新填充',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: t.primary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Interactive editor for DSH `reasoningEfforts` offering all 7 canonical tiers
/// (`off | minimal | low | medium | high | xhigh | max`) plus per-tier customizable
/// wire parameter values (e.g., `max -> ultra`, `off -> null`).
class _ReasoningEffortsEditor extends StatefulWidget {
  const _ReasoningEffortsEditor({
    required this.efforts,
    required this.onChanged,
  });

  final Map<String, String?> efforts;
  final ValueChanged<Map<String, String?>> onChanged;

  @override
  State<_ReasoningEffortsEditor> createState() => _ReasoningEffortsEditorState();
}

class _ReasoningEffortsEditorState extends State<_ReasoningEffortsEditor> {
  bool _showWireCustom = false;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final ordered = _orderedEffortMap(widget.efforts);
    final hasCustomWire = ordered.entries.any(
      (e) => e.key == 'off' ? (e.value?.isNotEmpty == true) : (e.value != null && e.value != e.key),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '思考深度档位（点选启用/停用）',
              style: TextStyle(fontSize: 11.5, color: t.text3),
            ),
            const Spacer(),
            GrassBagSpringTap(
              onTap: () => setState(() => _showWireCustom = !_showWireCustom),
              pressedScale: 0.94,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _showWireCustom ? CupertinoIcons.chevron_up : CupertinoIcons.slider_horizontal_3,
                    size: 11.5,
                    color: hasCustomWire ? t.primary : t.text3,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    _showWireCustom ? '收起参数映射' : (hasCustomWire ? '已自定义参数' : '自定义发送值'),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: hasCustomWire ? t.primary : t.text3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final lvl in _kDshThinkingLevels)
              _FilterPill(
                label: '${lvl.$2} (${lvl.$1})',
                active: ordered.containsKey(lvl.$1),
                onTap: () {
                  final next = Map<String, String?>.from(ordered);
                  if (next.containsKey(lvl.$1)) {
                    final nonOffCount = next.keys.where((k) => k != 'off').length;
                    if (lvl.$1 != 'off' && nonOffCount <= 1) return;
                    next.remove(lvl.$1);
                  } else {
                    next[lvl.$1] = lvl.$1 == 'off' ? null : lvl.$1;
                  }
                  widget.onChanged(_orderedEffortMap(next));
                },
              ),
          ],
        ),
        if (_showWireCustom) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: t.fill1,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.sep, width: 0.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '为每个档位自定义发送给 API 的 reasoning_effort 值（留空则使用默认档位名；off 留空表示不发送参数）',
                  style: TextStyle(fontSize: 10.8, height: 1.38, color: t.text3),
                ),
                const SizedBox(height: 7),
                for (final entry in ordered.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 68,
                          child: Text(
                            entry.key,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: t.text2,
                            ),
                          ),
                        ),
                        Expanded(
                          child: _WireValueField(
                            key: ValueKey('wire-${entry.key}'),
                            levelKey: entry.key,
                            initialValue: entry.value ?? '',
                            onChanged: (val) {
                              final next = Map<String, String?>.from(ordered);
                              final trimmed = val.trim();
                              next[entry.key] = trimmed.isEmpty ? null : trimmed;
                              widget.onChanged(next);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _WireValueField extends StatefulWidget {
  const _WireValueField({
    super.key,
    required this.levelKey,
    required this.initialValue,
    required this.onChanged,
  });

  final String levelKey;
  final String initialValue;
  final ValueChanged<String> onChanged;

  @override
  State<_WireValueField> createState() => _WireValueFieldState();
}

class _WireValueFieldState extends State<_WireValueField> {
  late final TextEditingController _ctrl;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _WireValueField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && oldWidget.initialValue != widget.initialValue && _ctrl.text != widget.initialValue) {
      _ctrl.value = TextEditingValue(
        text: widget.initialValue,
        selection: TextSelection.collapsed(offset: widget.initialValue.length),
      );
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GrassBagTextField(
      controller: _ctrl,
      focusNode: _focusNode,
      insideGlass: true,
      monospace: true,
      fontSize: 11.5,
      borderRadius: 10,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6.5),
      placeholder: widget.levelKey == 'off' ? '留空（不发送）' : '默认 ${widget.levelKey}（如 ultra）',
      onChanged: widget.onChanged,
    );
  }
}
