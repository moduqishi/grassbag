import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';
import '../features/plugins_center_page.dart';
import '../sdui/schemastery_form.dart';
import 'dsh_settings_sheets.dart';

/// Shared empty state card with consistent Apple iOS 26 spacing, icon badge, and optional CTA.
class GrassBagEmptyStateCard extends StatelessWidget {
  const GrassBagEmptyStateCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
    required this.tier,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;
  final GrassBagGlassTier tier;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GrassBagSquircleIcon(
            icon: icon,
            color: t.primary,
            size: 42,
            iconSize: 20,
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.text),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: t.text3),
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 14),
            GrassBagSecondaryGlassButton(
              label: actionLabel!,
              icon: actionIcon,
              height: 36,
              tier: tier,
              insideGlass: true,
              accentForeground: true,
              onTap: onAction!,
            ),
          ],
        ],
      ),
    );
  }
}

class _DshOfflineBannerCard extends StatelessWidget {
  const _DshOfflineBannerCard({
    required this.hostName,
    required this.tier,
    required this.onRetry,
  });

  final String hostName;
  final GrassBagGlassTier tier;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          GrassBagSquircleIcon(
            icon: CupertinoIcons.wifi_exclamationmark,
            color: t.warn,
            size: 34,
            iconSize: 16,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '未连接到 $hostName 的 DSH 核心',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: t.text),
                ),
                const SizedBox(height: 2),
                Text(
                  '所有权限、角色预设与引擎参数均由 DSH 统一读取与保存，连接后自动同步。',
                  style: TextStyle(fontSize: 11.5, height: 1.35, color: t.text3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GrassBagSecondaryGlassButton(
            label: '重试',
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            tier: tier,
            insideGlass: true,
            accentForeground: true,
            onTap: onRetry,
          ),
        ],
      ),
    );
  }
}

/// DSH General & Conversation Settings Page (`general` manifest section — mirrors
/// `@deepseek-ai/dsh-client-ui-settings-general`, `ui-chat`, `ui-conversation`,
/// `permission`, `agent-preset-registry`, and `session-log-deepseek`).
class DshGeneralSettingsView extends ConsumerWidget {
  const DshGeneralSettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      appProvider.select(
        (s) => (
          connectionPhase: s.connectionPhase,
          activeHostId: s.activeHostId,
          dshNamespaces: s.dshNamespaces,
          dshDynamicOptions: s.dshDynamicOptions,
          permissionTiers: s.permissionTiers,
          activePermissionId: s.activePermissionId,
          presets: s.presets,
          activePresetId: s.activePresetId,
          autoFoldSteps: s.autoFoldSteps,
          glassTier: s.glassTier,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final nsMap = {for (final n in state.effectiveDshNamespaces) n.ns: n};
    final sessionLogNs = nsMap['session-log-deepseek'];
    final presetRegistryNs = nsMap['agent-preset-registry'];
    final sessionLogEnabled = sessionLogNs?.value['enabled'] == true;
    final permTiers = state.effectivePermissionTiers;

    final convNamespaces = [
      for (final id in const ['ui-chat', 'ui-conversation', 'ui-theme', 'locale', 'ui-settings-account'])
        if (nsMap.containsKey(id)) nsMap[id]!,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!state.isDshConnected) ...[
          _DshOfflineBannerCard(
            hostName: state.activeHost.name,
            tier: state.glassTier,
            onRetry: () => ctrl.probeAndRefreshHost(state.activeHostId),
          ),
          const SizedBox(height: 16),
        ],
        // 1. Default Permissions (Direct inline selector)
        GrassBagGroupedSection(
          header: '默认操作权限（新建对话生效）',
          dividerIndent: 60,
          children: [
            for (final tierOpt in permTiers)
              GrassBagListTile(
                leading: GrassBagSquircleIcon(
                  icon: switch (tierOpt.id.toLowerCase()) {
                    'readonly' || 'read-only' || 'plan' => CupertinoIcons.lock_shield_fill,
                    'workspace' || 'workspace-write' || 'edit' => CupertinoIcons.shield_lefthalf_fill,
                    _ => tierOpt.risky
                        ? CupertinoIcons.exclamationmark_shield_fill
                        : CupertinoIcons.checkmark_shield_fill,
                  },
                  color: tierOpt.risky ? t.warn : t.primary,
                  size: 32,
                  iconSize: 15,
                  filled: state.activePermissionId == tierOpt.id,
                ),
                title: Text(tierOpt.name, style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
                subtitle: Text(tierOpt.desc),
                trailing: state.activePermissionId == tierOpt.id
                    ? Icon(
                        CupertinoIcons.checkmark_circle_fill,
                        size: 19,
                        color: tierOpt.risky ? t.warn : t.primary,
                      )
                    : null,
                onTap: () => ctrl.setPermission(tierOpt.id),
              ),
          ],
        ),
        const SizedBox(height: 16),

        // 2. Default Agent Presets (Direct inline selector + DSH registry editor)
        GrassBagGroupedSection(
          header: '默认角色与 Agent 预设 (${state.presets.length})',
          dividerIndent: 60,
          children: [
            for (final preset in state.presets)
              GrassBagListTile(
                leading: GrassBagSquircleIcon(
                  icon: CupertinoIcons.compass_fill,
                  color: t.isDark ? const Color(0xFFA993DE) : const Color(0xFF6B5B8E),
                  size: 32,
                  iconSize: 15,
                  filled: state.activePresetId == preset.id,
                ),
                title: Text(preset.name, style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
                subtitle: Text(preset.desc),
                trailing: state.activePresetId == preset.id
                    ? Icon(CupertinoIcons.checkmark_circle_fill, size: 19, color: t.primary)
                    : null,
                onTap: () => ctrl.setPreset(preset.id),
              ),
            if (presetRegistryNs != null)
              GrassBagListTile(
                leading: GrassBagSquircleIcon(
                  icon: CupertinoIcons.slider_horizontal_3,
                  color: t.primary,
                  size: 32,
                  iconSize: 15,
                ),
                title: Text('在 DSH 中管理角色预设', style: TextStyle(color: t.primary, fontWeight: FontWeight.w600)),
                subtitle: const Text('直接编辑 agent-preset-registry 命名空间配置'),
                showChevron: true,
                onTap: () => showDshNamespaceEditorSheet(context, ref, presetRegistryNs),
              ),
          ],
        ),
        const SizedBox(height: 16),

        // 3. Conversation & Display Controls (Directly synced to DSH namespaces!)
        if (convNamespaces.isNotEmpty) ...[
          GrassBagGroupedSection(
            header: '对话展示与交互行为（实时同步至 DSH）',
            dividerIndent: 56,
            children: [
              for (final ns in convNamespaces)
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: _iconForNs(ns.ns),
                    color: t.primary,
                    size: 30,
                    iconSize: 14,
                  ),
                  title: Text(ns.title, style: TextStyle(fontWeight: FontWeight.w500, color: t.text)),
                  subtitle: Text(_summarizeNamespaceValue(ns)),
                  showChevron: true,
                  onTap: () => showDshNamespaceEditorSheet(context, ref, ns),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],

        // 4. Direct Switches (Session Log Upload + App Behavior)
        GrassBagGroupedSection(
          header: '日志与客户端行为',
          children: [
            if (sessionLogNs != null)
              GrassBagListTile(
                title: const Text('使用官方 API 时上传 Session Log'),
                subtitle: const Text('帮助改进 DeepSeek 模型与产品体验'),
                trailing: GrassBagGlassSwitch(
                  value: sessionLogEnabled,
                  tier: state.glassTier,
                  activeColor: t.ok,
                  onChanged: sessionLogNs.writable && state.isDshConnected
                      ? (v) => ctrl.patchDshNamespace('session-log-deepseek', {'enabled': v})
                      : null,
                ),
              ),
            GrassBagListTile(
              title: const Text('回复完成后自动折叠思考过程'),
              subtitle: const Text('保持对话流清爽，随时可点开查看详细步骤'),
              trailing: GrassBagGlassSwitch(
                value: state.autoFoldSteps,
                tier: state.glassTier,
                onChanged: (v) => ctrl.setEngineFlags(autoFold: v),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// DSH Web Search & Fetch Settings Page (`web-search` manifest section).
/// Directly renders `web` (live provider selection from `web/listProviders`) plus
/// all `web-*` plugin settings inline!
class DshWebSearchSettingsView extends ConsumerWidget {
  const DshWebSearchSettingsView({super.key, this.namespaces = const []});
  final List<String> namespaces;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      appProvider.select(
        (s) => (
          connectionPhase: s.connectionPhase,
          activeHostId: s.activeHostId,
          dshNamespaces: s.dshNamespaces,
          dshDynamicOptions: s.dshDynamicOptions,
          glassTier: s.glassTier,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final nsMap = {for (final n in state.effectiveDshNamespaces) n.ns: n};
    final webNs = nsMap['web'];

    final extraWebNs = <DshSettingsNamespace>[
      for (final id in namespaces)
        if (id != 'web' && nsMap.containsKey(id)) nsMap[id]!,
    ];
    if (extraWebNs.isEmpty) {
      for (final ns in state.effectiveDshNamespaces) {
        if (ns.ns.startsWith('web-') && !extraWebNs.any((e) => e.ns == ns.ns)) {
          extraWebNs.add(ns);
        }
      }
    }

    if (webNs == null && extraWebNs.isEmpty) {
      return GrassBagEmptyStateCard(
        icon: CupertinoIcons.globe,
        title: state.isDshConnected ? '当前主机未加载联网搜索模块' : '尚未连接到 DSH 核心',
        subtitle: state.isDshConnected
            ? '前往插件中心启用联网搜索插件后即可在此配置搜索引擎。'
            : '所有联网搜索与抓取配置均直接读取自运行中的 DSH 主机。',
        actionLabel: state.isDshConnected ? '打开插件中心' : '重试连接',
        actionIcon: state.isDshConnected
            ? CupertinoIcons.square_stack_3d_up
            : CupertinoIcons.refresh,
        onAction: state.isDshConnected
            ? () => Navigator.of(context).push(
                  GrassBagPageRoute<void>(builder: (_) => const PluginsCenterPage()),
                )
            : () => ctrl.probeAndRefreshHost(state.activeHostId),
        tier: state.glassTier,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (webNs != null) ...[
          SchemasteryForm(
            key: ValueKey('${state.activeHostId}:${webNs.ns}'),
            namespaceId: webNs.ns,
            secretPaths: webNs.secrets,
            schema: webNs.schema,
            initialValues: webNs.value,
            tier: state.glassTier,
            readOnly: !webNs.writable || !state.isDshConnected,
            dynamicOptions: buildDynamicSchemaOptions(state),
            submitLabel: '保存默认搜索与抓取引擎',
            showJsonToggle: false,
            insideGlass: true,
            onSubmit: (vals) async {
              final ops = computeSchemasteryMutationOps(
                webNs.value,
                vals,
                secretPaths: webNs.secrets.toSet(),
              );
              if (ops.isEmpty) {
                ctrl.showToast('配置未发生变化', tone: ToastTone.info);
                return null;
              }
              return ctrl.mutateDshNamespace(webNs.ns, ops);
            },
          ),
          const SizedBox(height: 18),
        ],
        if (extraWebNs.isNotEmpty)
          GrassBagGroupedSection(
            header: '搜索引擎详细参数与计费',
            dividerIndent: 56,
            children: [
              for (final ns in extraWebNs)
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.search,
                    color: t.isDark ? const Color(0xFF56C2B2) : const Color(0xFF2D746D),
                    size: 32,
                    iconSize: 15,
                  ),
                  title: Text(ns.title, style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
                  subtitle: Text(_summarizeNamespaceValue(ns)),
                  showChevron: true,
                  onTap: () => showDshNamespaceEditorSheet(context, ref, ns),
                ),
            ],
          ),
      ],
    );
  }
}

/// DSH Agent Runtime & Shell Settings Page (`agent-runtime` manifest section):
/// Subagents, Subagent Model Selection, Agent Loop, and Shell Sandbox.
class DshAgentRuntimeSettingsView extends ConsumerWidget {
  const DshAgentRuntimeSettingsView({super.key, this.namespaces = const []});
  final List<String> namespaces;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      appProvider.select(
        (s) => (
          connectionPhase: s.connectionPhase,
          activeHostId: s.activeHostId,
          dshNamespaces: s.dshNamespaces,
          dshDynamicOptions: s.dshDynamicOptions,
          glassTier: s.glassTier,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final nsMap = {for (final n in state.effectiveDshNamespaces) n.ns: n};
    final targetIds = namespaces.isNotEmpty
        ? namespaces
        : const ['subagent', 'subagent-model-selection-settings', 'agent-loop', 'bash-sandbox'];
    final items = [for (final id in targetIds) if (nsMap.containsKey(id)) nsMap[id]!];

    if (items.isEmpty) {
      return GrassBagEmptyStateCard(
        icon: CupertinoIcons.person_2_fill,
        title: state.isDshConnected ? '暂无可配置的智能体与终端参数' : '尚未连接到 DSH 核心',
        subtitle: state.isDshConnected
            ? '当前 DSH 实例未暴露子智能体或沙箱配置命名空间。'
            : '连接运行中的 DSH 主机后将自动读取子智能体、并发循环与沙箱参数。',
        actionLabel: state.isDshConnected ? null : '重试连接',
        actionIcon: CupertinoIcons.refresh,
        onAction: state.isDshConnected ? null : () => ctrl.probeAndRefreshHost(state.activeHostId),
        tier: state.glassTier,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagGroupedSection(
          header: '子智能体、并发循环与 Shell 沙箱',
          footer: '点按任意模块可可视化编辑全部参数（含子智能体授权模型白名单、命令超时与输出上限）。',
          dividerIndent: 56,
          children: [
            for (final ns in items)
              GrassBagListTile(
                leading: GrassBagSquircleIcon(
                  icon: _iconForNs(ns.ns),
                  color: t.isDark ? const Color(0xFF4AC885) : t.ok,
                  size: 34,
                  iconSize: 16,
                ),
                title: Text(ns.title, style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
                subtitle: Text(_summarizeNamespaceValue(ns)),
                showChevron: true,
                onTap: () => showDshNamespaceEditorSheet(context, ref, ns),
              ),
          ],
        ),
      ],
    );
  }
}

/// DSH MCP Servers Management Page (`mcp` manifest section):
/// Live runtime server cards with Probe/Restart + inline recursive `mcp-manager` editor!
class DshMcpSettingsView extends ConsumerWidget {
  const DshMcpSettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      appProvider.select(
        (s) => (
          connectionPhase: s.connectionPhase,
          activeHostId: s.activeHostId,
          dshNamespaces: s.dshNamespaces,
          mcpServers: s.mcpServers,
          glassTier: s.glassTier,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final mcpNs = state.effectiveDshNamespaces.where((n) => n.ns == 'mcp-manager').firstOrNull;

    if (!state.isDshConnected && mcpNs == null && state.mcpServers.isEmpty) {
      return GrassBagEmptyStateCard(
        icon: CupertinoIcons.antenna_radiowaves_left_right,
        title: '尚未连接到 DSH 核心',
        subtitle: 'MCP 工具服务列表与服务器配置均由连接的 DSH 主机统一管理。',
        actionLabel: '重试连接',
        actionIcon: CupertinoIcons.refresh,
        onAction: () => ctrl.probeAndRefreshHost(state.activeHostId),
        tier: state.glassTier,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.mcpServers.isNotEmpty) ...[
          GrassBagGroupedSection(
            header: '运行中的 MCP 服务 (${state.mcpServers.length})',
            dividerIndent: 56,
            children: [
              for (final mcp in state.mcpServers)
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.antenna_radiowaves_left_right,
                    color: mcp.status == 'connected'
                        ? t.ok
                        : (mcp.status == 'error' ? t.err : t.warn),
                    size: 32,
                    iconSize: 15,
                  ),
                  title: Text(
                    mcp.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w600, color: t.text),
                  ),
                  subtitle: Text(
                    '${mcp.transport} · ${mcp.toolsCount} 个工具${mcp.lastLatencyMs != null ? ' · ${mcp.lastLatencyMs}ms' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GrassBagSecondaryGlassButton(
                        label: mcp.status == 'probing' ? '探测中' : '探测',
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tier: state.glassTier,
                        insideGlass: true,
                        enabled: mcp.status != 'probing',
                        onTap: mcp.status == 'probing' ? null : () => ctrl.probeMcpServer(mcp.name),
                      ),
                      const SizedBox(width: 4),
                      GrassBagSecondaryGlassButton(
                        label: '重启',
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tier: state.glassTier,
                        insideGlass: true,
                        enabled: mcp.status != 'probing',
                        onTap: mcp.status == 'probing' ? null : () => ctrl.restartMcpServer(mcp.name),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (mcpNs != null)
          SchemasteryForm(
            key: ValueKey('${state.activeHostId}:${mcpNs.ns}'),
            namespaceId: mcpNs.ns,
            secretPaths: mcpNs.secrets,
            schema: mcpNs.schema,
            initialValues: mcpNs.value,
            tier: state.glassTier,
            readOnly: !mcpNs.writable || !state.isDshConnected,
            submitLabel: '保存 MCP 服务器配置',
            insideGlass: true,
            onSubmit: (vals) async {
              final ops = computeSchemasteryMutationOps(
                mcpNs.value,
                vals,
                secretPaths: mcpNs.secrets.toSet(),
              );
              if (ops.isEmpty) {
                ctrl.showToast('配置未发生变化', tone: ToastTone.info);
                return null;
              }
              return ctrl.mutateDshNamespace(mcpNs.ns, ops);
            },
          )
        else
          GrassBagEmptyStateCard(
            icon: CupertinoIcons.antenna_radiowaves_left_right,
            title: '当前主机未启用 MCP 管理插件',
            subtitle: '在插件中心启用 mcp-manager 后即可在此添加 stdio / HTTP MCP 服务。',
            actionLabel: '打开插件中心',
            actionIcon: CupertinoIcons.square_stack_3d_up,
            onAction: () => Navigator.of(context).push(
              GrassBagPageRoute<void>(builder: (_) => const PluginsCenterPage()),
            ),
            tier: state.glassTier,
          ),
      ],
    );
  }
}

/// DSH Plugins & Auto-Discovered Third-Party Plugin Settings View (`plugins` manifest section).
class DshPluginsSettingsView extends ConsumerWidget {
  const DshPluginsSettingsView({super.key, this.thirdPartyNamespaces = const []});
  final List<String> thirdPartyNamespaces;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      appProvider.select(
        (s) => (
          dshNamespaces: s.dshNamespaces,
          plugins: s.plugins,
          dynamicCordis: s.dynamicCordis,
          glassTier: s.glassTier,
          isDshConnected: s.isDshConnected,
          activeHostName: s.activeHost.name,
        ),
      ),
    );
    final state = ref.read(appProvider);
    final ctrl = ref.read(appProvider.notifier);
    final t = GrassBagTokens.of(context);
    final nsMap = {for (final n in state.effectiveDshNamespaces) n.ns: n};
    final extraNs = [for (final id in thirdPartyNamespaces) if (nsMap.containsKey(id)) nsMap[id]!];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!state.isDshConnected) ...[
          _DshOfflineBannerCard(
            hostName: state.activeHost.name,
            tier: state.glassTier,
            onRetry: () => ctrl.probeAndRefreshHost(state.activeHostId),
          ),
          const SizedBox(height: 14),
        ],
        GrassBagPrimaryGlassButton(
          label: '打开插件市场与动态扩展中心',
          icon: CupertinoIcons.sparkles,
          tier: state.glassTier,
          insideGlass: true,
          onTap: () => Navigator.of(context).push(
            GrassBagPageRoute<void>(builder: (_) => const PluginsCenterPage()),
          ),
        ),
        const SizedBox(height: 16),
        if (extraNs.isNotEmpty) ...[
          GrassBagGroupedSection(
            header: '已发现的扩展插件配置 (${extraNs.length})',
            dividerIndent: 56,
            children: [
              for (final ns in extraNs)
                GrassBagListTile(
                  leading: GrassBagSquircleIcon(
                    icon: CupertinoIcons.slider_horizontal_3,
                    color: t.primary,
                    size: 32,
                    iconSize: 15,
                  ),
                  title: Text(ns.title, style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
                  subtitle: Text(_summarizeNamespaceValue(ns)),
                  showChevron: true,
                  onTap: () => showDshNamespaceEditorSheet(context, ref, ns),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (state.plugins.isEmpty)
          GrassBagEmptyStateCard(
            icon: CupertinoIcons.square_stack_3d_up,
            title: '暂未安装第三方插件包',
            subtitle: '你可以前往插件市场搜索并一键热安装 DSH 扩展包。',
            actionLabel: '浏览插件市场',
            actionIcon: CupertinoIcons.search,
            tier: state.glassTier,
            onAction: () => Navigator.of(context).push(
              GrassBagPageRoute<void>(builder: (_) => const PluginsCenterPage()),
            ),
          )
        else
          GrassBagGroupedSection(
            header: '已安装插件包 (${state.plugins.length})',
            footer: '系统核心运行组件（dsh-base / dsh-web-app / dsh-headless / dsh-gbridge）已锁定保护，防止误关导致引擎不可用。',
            children: [
              for (final plugin in state.plugins)
                () {
                  final idLower = plugin.id.toLowerCase();
                  final isCore = !plugin.optional ||
                      idLower.endsWith('dsh-base') ||
                      idLower.endsWith('dsh-web-app') ||
                      idLower.endsWith('dsh-headless') ||
                      idLower.endsWith('dsh-gbridge') ||
                      idLower == 'base';
                  return GrassBagListTile(
                    title: Text('${plugin.name}  ${plugin.version}'),
                    subtitle: Text(
                      plugin.desc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: isCore
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                            decoration: BoxDecoration(
                              color: t.fill1,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: t.sep, width: 0.6),
                            ),
                            child: Text(
                              '内置核心',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: t.text3,
                              ),
                            ),
                          )
                        : GrassBagGlassSwitch(
                            value: plugin.enabled,
                            tier: state.glassTier,
                            activeColor: t.ok,
                            onChanged: (_) => ctrl.togglePlugin(plugin.id),
                          ),
                  );
                }(),
            ],
          ),
      ],
    );
  }
}

/// Power-user searchable sheet showing ALL raw DSH namespaces (accessible from Diagnostics).
void showAllRawNamespacesSheet(BuildContext context, WidgetRef ref) {
  var query = '';
  showGrassBagSheet<void>(
    context,
    title: '全部 DSH 原始配置命名空间',
    subtitle: '开发者检查器 · 支持按命名空间实时编辑与 JSON 源码切换',
    bodyBuilder: (sheetCtx) {
      return StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Consumer(
            builder: (ctx, sheetRef, _) {
              sheetRef.watch(
                appProvider.select(
                  (s) => (dshNamespaces: s.dshNamespaces, glassTier: s.glassTier),
                ),
              );
              final state = sheetRef.read(appProvider);
              final t = GrassBagTokens.of(ctx);
              final q = query.trim().toLowerCase();
              final list = state.effectiveDshNamespaces.where((ns) {
                if (q.isEmpty) return true;
                return ns.ns.toLowerCase().contains(q) ||
                    ns.title.toLowerCase().contains(q) ||
                    ns.subtitle.toLowerCase().contains(q);
              }).toList(growable: false);

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GrassBagGlassSearchBar(
                    placeholder: '筛选命名空间…',
                    tier: state.glassTier,
                    insideGlass: true,
                    onChanged: (v) => setSheetState(() => query = v),
                  ),
              const SizedBox(height: 10),
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: Text('没有匹配的命名空间', style: TextStyle(fontSize: 13, color: t.text3)),
                  ),
                )
              else
                GrassBagSheetSection(
                  dividerIndent: 52,
                  children: [
                    for (final ns in list)
                      GrassBagListTile(
                        leading: GrassBagSquircleIcon(
                          icon: _iconForNs(ns.ns),
                          color: t.primary,
                          size: 30,
                          iconSize: 14,
                        ),
                        title: Text(ns.title, style: TextStyle(fontWeight: FontWeight.w500, color: t.text)),
                        subtitle: Text('${ns.ns} · ${_summarizeNamespaceValue(ns)}'),
                        showChevron: true,
                        onTap: () => showDshNamespaceEditorSheet(ctx, ref, ns),
                      ),
                  ],
                ),
              ],
            );
            },
          );
        },
      );
    },
  );
}

/// Recent errors inspection card shown in Diagnostics + tappable copy.
class RecentErrorsDiagnosticsCard extends StatelessWidget {
  const RecentErrorsDiagnosticsCard({super.key, required this.errors});
  final List<AppErrorRecord> errors;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    if (errors.isEmpty) return const SizedBox.shrink();
    return GrassBagGroupedSection(
      header: '最近捕获的错误 (${errors.length})',
      children: [
        for (final e in errors.take(8))
          GrassBagListTile(
            leading: GrassBagSquircleIcon(
              icon: CupertinoIcons.exclamationmark_triangle_fill,
              color: t.err,
              size: 30,
              iconSize: 14,
            ),
            title: Text(e.summary, style: TextStyle(fontWeight: FontWeight.w600, color: t.err)),
            subtitle: Text(
              e.detail,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: t.text2),
            ),
            onTap: () {
              Clipboard.setData(ClipboardData(text: '${e.summary}\n${e.detail}'));
              showGrassBagSheet<void>(
                context,
                title: e.summary,
                subtitle: '已自动复制到剪贴板',
                bodyBuilder: (ctx) {
                  final st = GrassBagTokens.of(ctx);
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: ShapeDecoration(
                      color: st.errSoft,
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: st.err.withValues(alpha: 0.28), width: 0.65),
                      ),
                    ),
                    child: SelectableText(
                      e.detail,
contextMenuBuilder: buildGrassBagEditableContextMenu,
                      style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5, color: st.err),
                    ),
                  );
                },
              );
            },
          ),
      ],
    );
  }
}

IconData _iconForNs(String ns) {
  if (ns.contains('model') || ns.startsWith('llm-')) return CupertinoIcons.sparkles;
  if (ns.contains('sandbox') || ns.contains('bash')) return CupertinoIcons.chevron_left_slash_chevron_right;
  if (ns.contains('permission')) return CupertinoIcons.shield_lefthalf_fill;
  if (ns.contains('subagent') || ns.contains('loop')) return CupertinoIcons.person_2_fill;
  if (ns.contains('preset')) return CupertinoIcons.compass_fill;
  if (ns.contains('web')) return CupertinoIcons.globe;
  if (ns.contains('mcp')) return CupertinoIcons.antenna_radiowaves_left_right;
  if (ns.contains('theme') || ns.contains('locale')) return CupertinoIcons.paintbrush_fill;
  if (ns.contains('chat') || ns.contains('conversation')) return CupertinoIcons.chat_bubble_2_fill;
  return CupertinoIcons.slider_horizontal_3;
}

final RegExp _secretKeyRe = RegExp(
  r'(key|secret|token|password|credential)',
  caseSensitive: false,
);

String _summarizeNamespaceValue(DshSettingsNamespace ns) {
  if (ns.value.isEmpty) return ns.subtitle;
  final secretKeys = ns.secrets.toSet();
  final bits = <String>[];
  for (final e in ns.value.entries) {
    if (bits.length >= 3) break;
    final key = e.key;
    final label = kDshFieldCatalog[key]?.$1 ?? key;
    final isSecret = secretKeys.contains(key) ||
        secretKeys.any((p) => p.startsWith('$key.')) ||
        (_secretKeyRe.hasMatch(key) && !key.toLowerCase().endsWith('env'));
    final v = e.value;
    if (isSecret && v != null && v.toString().isNotEmpty) {
      bits.add('$label: ••••••');
    } else if (v is Map) {
      bits.add('$label: ${v.length} 项');
    } else if (v is List) {
      bits.add('$label: ${v.length} 项');
    } else if (v is bool) {
      bits.add('$label: ${v ? '开' : '关'}');
    } else if (v != null && v.toString().isNotEmpty) {
      final str = kDshOptionLabels[v.toString()] ?? v.toString();
      bits.add('$label: $str');
    }
  }
  return bits.isEmpty ? ns.subtitle : bits.join(' · ');
}
