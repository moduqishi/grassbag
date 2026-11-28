import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import '../sdui/schemastery_form.dart';
import 'model_config_view.dart';

/// Build live dynamic schema option map from connected DSH host metadata.
Map<String, List<SchemaDynamicOption>> buildDynamicSchemaOptions(GrassBagAppState state) {
  final out = <String, List<SchemaDynamicOption>>{};
  for (final e in state.dshDynamicOptions.entries) {
    out[e.key] = [
      for (final o in e.value)
        SchemaDynamicOption(value: o.value, label: o.label, description: o.description),
    ];
  }
  if (!out.containsKey('permission.defaultPreset') && state.effectivePermissionTiers.isNotEmpty) {
    out['permission.defaultPreset'] = [
      for (final p in state.effectivePermissionTiers)
        SchemaDynamicOption(value: p.id, label: p.name, description: p.desc),
    ];
  }
  if (!out.containsKey('agent-preset-registry.selectedDefault') && state.presets.isNotEmpty) {
    out['agent-preset-registry.selectedDefault'] = [
      for (final p in state.presets)
        SchemaDynamicOption(value: p.id, label: p.name, description: p.desc),
    ];
  }
  return out;
}

/// Flatten live DSH model catalog for quick model pickers inside Schemastery forms.
List<(String, String, String)> buildAvailableModelTuples(GrassBagAppState state) {
  final out = <(String, String, String)>[];
  for (final g in state.modelGroups) {
    for (final m in g.models) {
      out.add((g.id, m.id, '${m.name} (${g.name})'));
    }
  }
  return out;
}

/// Open a live recursive Schemastery editor sheet for ANY real DSH namespace.
void showDshNamespaceEditorSheet(
  BuildContext context,
  WidgetRef ref,
  DshSettingsNamespace ns,
) {
  var isDirty = false;
  showGrassBagSheet<void>(
    context,
    title: ns.title,
    subtitle: '${ns.ns} · ${ns.subtitle}',
    expandable: true,
    onWillDismiss: () async {
      if (!isDirty || !context.mounted) return true;
      return showGrassBagConfirmDialog(
        context,
        title: '放弃未保存的配置修改？',
        message: '「${ns.title}」中存在尚未写入 DSH 的改动，关闭后将丢失。',
        confirmLabel: '放弃修改',
        isDestructive: true,
      );
    },
    bodyBuilder: (ctx) => Consumer(
      builder: (cCtx, cRef, _) {
        cRef.watch(
          appProvider.select(
            (s) => (
              dshNamespaces: s.dshNamespaces,
              dshDynamicOptions: s.dshDynamicOptions,
              presets: s.presets,
              permissionTiers: s.permissionTiers,
              modelGroups: s.modelGroups,
              glassTier: s.glassTier,
              connectionPhase: s.connectionPhase,
            ),
          ),
        );
        final state = cRef.read(appProvider);
        final ctrl = cRef.read(appProvider.notifier);
        final liveNs = state.effectiveDshNamespaces.where((n) => n.ns == ns.ns).firstOrNull ?? ns;
        return SchemasteryForm(
          namespaceId: liveNs.ns,
          secretPaths: liveNs.secrets,
          schema: liveNs.schema,
          initialValues: liveNs.value,
          tier: state.glassTier,
          readOnly: !liveNs.writable || !state.isDshConnected,
          dynamicOptions: buildDynamicSchemaOptions(state),
          availableModels: buildAvailableModelTuples(state),
          submitLabel: '保存配置',
          onDirtyChanged: (d) => isDirty = d,
          onSubmit: (vals) async {
            final ops = computeSchemasteryMutationOps(
              liveNs.value,
              vals,
              secretPaths: liveNs.secrets.toSet(),
            );
            if (ops.isEmpty) {
              isDirty = false;
              ctrl.showToast('配置未发生变化', tone: ToastTone.info);
              if (cCtx.mounted) Navigator.of(cCtx).pop();
              return null;
            }
            final err = await ctrl.mutateDshNamespace(liveNs.ns, ops);
            if (err == null) {
              isDirty = false;
              if (cCtx.mounted) Navigator.of(cCtx).pop();
            }
            return err;
          },
        );
      },
    ),
  );
}

/// Searchable external LLM Providers & API Credentials sheet (`/gbridge/v1/providers` & `/credentials`).
/// Configured providers always stay pinned at top, and tapping any row opens the unified visual editor.
void showProviderCredentialsSheet(BuildContext context, WidgetRef ref) {
  showGrassBagSheet<void>(
    context,
    title: '模型渠道与 API 密钥',
    subtitle: '已配置渠道优先置顶，支持搜索并一键接入自定义中转站',
    bodyBuilder: (_) => const _SearchableProviderCredentialsBody(),
  );
}

class _SearchableProviderCredentialsBody extends ConsumerStatefulWidget {
  const _SearchableProviderCredentialsBody();

  @override
  ConsumerState<_SearchableProviderCredentialsBody> createState() =>
      _SearchableProviderCredentialsBodyState();
}

class _SearchableProviderCredentialsBodyState
    extends ConsumerState<_SearchableProviderCredentialsBody> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      appProvider.select(
        (s) => (
          providerCredentials: s.providerCredentials,
          glassTier: s.glassTier,
          connectionPhase: s.connectionPhase,
        ),
      ),
    );
    final st = ref.read(appProvider);
    final t = GrassBagTokens.of(context);
    final q = _query.trim().toLowerCase();
    final sorted = List<ProviderCredentialItem>.of(st.providerCredentials)
      ..sort((a, b) => (b.configured ? 1 : 0) - (a.configured ? 1 : 0));
    final visible = q.isEmpty
        ? sorted
        : sorted
            .where((p) =>
                p.name.toLowerCase().contains(q) ||
                p.id.toLowerCase().contains(q) ||
                p.envRef.toLowerCase().contains(q))
            .toList(growable: false);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagGlassSearchBar(
          controller: _searchCtrl,
          placeholder: '搜索 ${st.providerCredentials.length} 个模型渠道或密钥变量…',
          tier: st.glassTier,
          insideGlass: true,
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 10),
        GrassBagSecondaryGlassButton(
          label: '添加自定义中转站 / OpenAI 兼容渠道',
          icon: CupertinoIcons.plus_circle_fill,
          tier: st.glassTier,
          insideGlass: true,
          accentForeground: true,
          onTap: () {
            final navCtx = Navigator.of(context, rootNavigator: true).context;
            Navigator.of(context).pop();
            Future<void>.delayed(const Duration(milliseconds: 180), () {
              if (!navCtx.mounted) return;
              showVisualProviderEditorSheet(
                navCtx,
                providerId: '',
                settingsNs: 'llm-pi-ai',
                initialDisplayName: '',
                initialBaseUrl: '',
                initialEnvRef: '',
                initialProtocol: 'openai-completions',
                isCustomNew: true,
              );
            });
          },
        ),
        const SizedBox(height: 10),
        if (visible.isEmpty)
          GrassBagSheetSection(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    st.providerCredentials.isEmpty
                        ? '暂未获取到渠道列表，请确认 DSH 主机已连接'
                        : '未找到匹配「$_query」的渠道',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: t.text3),
                  ),
                  if (q.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    GrassBagSecondaryGlassButton(
                      label: '清除搜索',
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tier: st.glassTier,
                      insideGlass: true,
                      onTap: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    ),
                  ],
                ],
              ),
            ],
          )
        else
          GrassBagSheetSection(
            dividerIndent: 56,
            children: [
              for (final p in visible)
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: p.configured
                        ? CupertinoIcons.checkmark_seal_fill
                        : CupertinoIcons.lock_fill,
                    color: p.configured ? t.ok : t.text3,
                    size: 32,
                    iconSize: 15,
                    filled: p.configured,
                  ),
                  title: Text(p.name, style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
                  subtitle: Text(
                    p.configured
                        ? '${p.envRef} · ${p.baseUrl.isNotEmpty ? p.baseUrl : (p.maskedKey.isEmpty ? '已配置' : p.maskedKey)}'
                        : '${p.envRef} · 未配置密钥',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: GrassBagFresnelGlassSurface(
                    isPill: true,
                    innerWell: true,
                    tintColor: p.configured ? t.okSoft : t.fill1,
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                    child: Text(
                      p.configured ? '编辑' : '配置',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: p.configured ? t.ok : t.text2,
                      ),
                    ),
                  ),
                  onTap: () {
                    final navCtx = Navigator.of(context, rootNavigator: true).context;
                    final piAiNs = st.effectiveDshNamespaces.where((n) => n.ns == 'llm-pi-ai').firstOrNull;
                    final providersMap = piAiNs != null && piAiNs.value['providers'] is Map
                        ? piAiNs.value['providers'] as Map
                        : const {};
                    final piCfg = providersMap[p.id] is Map ? providersMap[p.id] as Map : null;
                    final proto = resolveProviderApiProtocol(
                      explicit: piCfg?['api']?.toString() ?? p.description,
                      providerId: p.id,
                      baseUrl: p.baseUrl,
                    );
                    Navigator.of(context).pop();
                    Future<void>.delayed(const Duration(milliseconds: 180), () {
                      if (!navCtx.mounted) return;
                      showVisualProviderEditorSheet(
                        navCtx,
                        providerId: p.id,
                        settingsNs: p.settingsNs,
                        initialDisplayName: p.name,
                        initialBaseUrl: p.baseUrl,
                        initialEnvRef: p.envRef,
                        initialProtocol: proto,
                        isCustomNew: false,
                      );
                    });
                  },
                ),
            ],
          ),
      ],
    );
  }
}

/// Real Config Export / Import JSON Sync Sheet (disposes `TextEditingController` cleanly).
void showConfigSyncSheet(BuildContext context, WidgetRef ref) {
  showGrassBagSheet<void>(
    context,
    title: '客户端偏好与主机清单同步',
    subtitle: '仅含客户端外观偏好与主机清单（已自动脱敏访问令牌；模型与引擎配置保存在各 DSH 核心中）',
    bodyBuilder: (_) => const _ConfigSyncSheetBody(),
  );
}

class _ConfigSyncSheetBody extends ConsumerStatefulWidget {
  const _ConfigSyncSheetBody();

  @override
  ConsumerState<_ConfigSyncSheetBody> createState() => _ConfigSyncSheetBodyState();
}

class _ConfigSyncSheetBodyState extends ConsumerState<_ConfigSyncSheetBody> {
  late final TextEditingController _jsonCtrl;
  String? _err;

  bool _replaceHosts = false;

  @override
  void initState() {
    super.initState();
    _jsonCtrl = TextEditingController(text: ref.read(appProvider.notifier).exportConfigJson());
  }

  @override
  void dispose() {
    _jsonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final ctrl = ref.read(appProvider.notifier);
    final preview = ctrl.previewImportConfigJson(_jsonCtrl.text);
    final addedHosts = (preview?['addedHosts'] as int?) ?? 0;
    final updatedHosts = (preview?['updatedHosts'] as int?) ?? 0;
    final preservedHosts = (preview?['preservedExistingHosts'] as int?) ?? 0;
    final originChanged = (preview?['originChangedHosts'] as int?) ?? 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagTextField(
          controller: _jsonCtrl,
          insideGlass: true,
          monospace: true,
          fontSize: 11.5,
          minLines: 8,
          maxLines: 11,
          borderRadius: 16,
          padding: const EdgeInsets.all(12),
          hasError: _err != null,
          onChanged: (_) {
            setState(() => _err = null);
          },
        ),
        if (preview != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              color: t.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.primary.withValues(alpha: 0.22)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _replaceHosts
                      ? '替换模式预览：新增 $addedHosts 台 · 更新 $updatedHosts 台 · 移除现有未列出 $preservedHosts 台主机及其凭证'
                      : '合并模式预览：新增 $addedHosts 台 · 更新 $updatedHosts 台 · 保留现有 $preservedHosts 台主机及凭证',
                  style: TextStyle(fontSize: 11.5, color: t.text, height: 1.35),
                ),
                if (originChanged > 0) ...[
                  const SizedBox(height: 3),
                  Text(
                    '有 $originChanged 台主机地址已变化，将不会复用旧凭证（需重新认证）',
                    style: TextStyle(fontSize: 11, color: t.warn, height: 1.3),
                  ),
                ],
                const SizedBox(height: 4),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _replaceHosts = !_replaceHosts),
                  child: Row(
                    children: [
                      Icon(
                        _replaceHosts
                            ? CupertinoIcons.checkmark_square_fill
                            : CupertinoIcons.square,
                        size: 15,
                        color: _replaceHosts ? t.warn : t.text3,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '改为覆盖替换主机列表（清空未列出的远程主机与凭证）',
                          style: TextStyle(
                            fontSize: 11,
                            color: _replaceHosts ? t.warn : t.text2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_err != null) ...[
          const SizedBox(height: 6),
          Text(_err!, style: TextStyle(fontSize: 12, color: t.err)),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: GrassBagSecondaryGlassButton(
                label: '复制快照',
                icon: CupertinoIcons.doc_on_doc,
                tier: tier,
                insideGlass: true,
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _jsonCtrl.text));
                  ctrl.showToast('已复制脱敏后的配置快照 JSON');
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GrassBagPrimaryGlassButton(
                label: _replaceHosts ? '替换并应用' : '合并应用',
                icon: CupertinoIcons.square_arrow_down,
                tier: tier,
                insideGlass: true,
                onTap: () {
                  final ok = ctrl.importConfigJson(
                    _jsonCtrl.text,
                    replaceHosts: _replaceHosts,
                  );
                  if (ok) {
                    Navigator.of(context).pop();
                  } else {
                    setState(() => _err = '配置 JSON 格式无效，请检查语法后重试');
                  }
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Open live DSH `agent-preset-registry` namespace editor directly (no dead local stub).
void showCreatePresetSheet(BuildContext context, WidgetRef ref) {
  final state = ref.read(appProvider);
  final ns = state.effectiveDshNamespaces
      .where((n) => n.ns == 'agent-preset-registry')
      .firstOrNull;
  if (ns != null) {
    showDshNamespaceEditorSheet(context, ref, ns);
    return;
  }
  ref.read(appProvider.notifier).showToast(
        state.isDshConnected
            ? '当前主机未暴露 agent-preset-registry 配置项'
            : '请先连接到运行中的 DSH 主机后再管理角色预设',
        tone: ToastTone.warn,
      );
}
