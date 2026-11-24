import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../common/grassbag_sheets.dart';

/// Dynamic option injected from live DSH APIs (e.g. `web/listProviders`,
/// `permissionPresets/catalog`, `agentPresets/list`, `session/modelCatalog`).
@immutable
class SchemaDynamicOption {
  const SchemaDynamicOption({
    required this.value,
    required this.label,
    this.description = '',
  });

  final String value;
  final String label;
  final String description;
}

/// Human-friendly Chinese labels & hints for real `@deepseek-ai/dsh` settings keys.
const Map<String, (String, String?)> kDshFieldCatalog = {
  // Models & Providers
  'provider': ('模型提供方', '如 deepseek-official / deepseek-account / opencode'),
  'model': ('模型 ID', '新建对话或子代理使用的模型标识'),
  'models': ('模型列表', '配置该渠道暴露的可用模型与能力参数'),
  'providers': ('自定义模型渠道', '配置 OpenAI / Anthropic / Gemini 或兼容聚合渠道'),
  'displayName': ('显示名称', '在模型列表中展示的友好名称'),
  'api': ('协议类型', '如 openai-completions / anthropic-messages / google'),
  'id': ('标识 ID', null),
  'name': ('名称', null),
  'reasoningEffort': ('默认思考深度', '平衡推理质量与响应速度'),
  'reasoningEfforts': ('推理深度映射', '各推理档位对应的上游参数值'),
  'thinking': ('启用深度思考模式', '开启模型推理链输出'),
  'thinkingBudgets': ('思考 Token 预算', '按推理档位配置思考预算上限'),
  'maxTokens': ('单次回复最大 Token', '控制单次输出长度上限'),
  'defaultMaxTokens': ('默认最大输出 Token', '未单独指定时的模型输出上限'),
  'contextWindow': ('上下文窗口', '模型支持的最大上下文 Token 数'),
  'defaultContextWindow': ('默认上下文窗口', '用于上下文压缩与用量估算'),
  'contextWindowOverrides': ('单模型上下文覆盖', '按模型 ID 自定义上下文窗口大小'),
  'input': ('支持输入模态', '如 text / image'),
  'defaultInput': ('默认输入模态', '未单独指定时模型接受的输入类型'),
  'compat': ('协议兼容选项', '针对第三方兼容网关的字段微调'),
  'modelOverrides': ('模型参数覆盖', '按模型 ID 单独覆盖参数'),
  'streamIdleTimeoutMs': ('流式空闲超时 (ms)', '等待模型首包或下一分片的超时时间'),
  'requestTimeoutMs': ('请求超时 (ms)', '单次 API 请求超时时间'),
  'transportMaxRetries': ('网络最大重试次数', '请求瞬断时的自动重试次数'),
  'retry': ('重试策略', '配置错误码重试次数与退避间隔'),
  'backoff': ('退避策略', '重试等待间隔与抖动比例'),
  'mode': ('模式', null),
  'maxRetries': ('最大重试次数', null),
  'retryableCodes': ('可重试错误码', '遇到这些错误码时自动重试'),
  'initialDelayMs': ('初始延迟 (ms)', null),
  'maxDelayMs': ('最大延迟 (ms)', null),
  'jitterRatio': ('随机抖动比例', '0 到 1 之间，避免并发雪崩'),
  'maxAttempts': ('最大重连次数', null),
  'baseURL': ('API 接口地址', '留空使用官方地址；自定义兼容网关需含前缀'),
  'apiBase': ('API 接口地址', '自定义服务端地址'),
  'apiKey': ('API 密钥', '直接填写密钥或优先使用下方环境变量引用'),
  'apiKeyEnv': ('密钥环境变量名', '从宿主机环境变量或凭据库读取'),
  'headers': ('自定义请求头', '随请求附带的 HTTP Headers'),
  'offloadSeenImagesForCache': ('缓存历史图片以省 Token', '卸载已读图片内容优化上下文缓存'),
  'filterModelsByPlan': ('按套餐过滤模型', '仅显示当前订阅计划支持的模型'),
  'visibleModels': ('可见模型列表', '限定在模型选择器中展示的模型 ID'),
  'modelVisibility': ('模型显隐开关表', '按模型 ID 单独控制是否显示'),
  'webSearch': ('启用渠道联网搜索', null),
  'showSidebarQuota': ('侧边栏显示配额', null),
  'accounts': ('多账号配置', '配置轮换或分流使用的多组账号凭据'),
  'label': ('标签名称', null),
  'zdr': ('零数据保留 (ZDR)', '仅路由至承诺零数据留存的端点'),
  'lang': ('默认语言', null),
  'workingDir': ('工作目录', null),
  'modelsCachePath': ('模型缓存路径', null),
  'modelAccountRules': ('模型账号分流规则', null),
  'credentialCleanupRefs': ('待清理凭据引用', null),
  'accountEnrollmentTasks': ('账号注册任务', null),
  'maxRequestImageBytes': ('单请求图片总大小上限 (字节)', null),
  'maxRequestImages': ('单请求最多图片数', null),
  'requestImagePixelBudget': ('图片像素总预算', null),
  'requestImageMaxBytes': ('单张图片最大字节数', null),
  'imageOffloadCountQuantum': ('图片卸载计数粒度', null),

  // Agent, Permissions, Subagent, Shell
  'defaultPreset': ('默认操作权限预设', '控制文件编辑与终端命令的默认审批级别'),
  'selectedDefault': ('默认 Agent 预设', '新建对话默认使用的角色与工具组合'),
  'maxParallelToolCalls': ('单轮最大并发工具数', '同一步内最多同时执行的工具数量'),
  'maxDepth': ('子智能体最大递归深度', '0 禁用子智能体，1 仅允许主 Agent 派生'),
  'maxActiveSubagents': ('子智能体并行数量上限', '同时存活的子智能体总数上限'),
  'enabled': ('启用此功能', null),
  'allowedModels': ('授权子智能体模型列表', '允许 Agent 为子智能体自主选择的模型白名单'),
  'cwd': ('默认工作目录', 'Shell 未指定目录时的默认起始路径'),
  'timeoutMs': ('命令超时 (ms)', '单条命令允许运行的最长时间'),
  'maxTimeoutMs': ('最大允许超时 (ms)', '工具单次可申请的最大超时上限'),
  'maxOutputBytes': ('单流输出上限 (字节)', '超过此大小的输出自动溢写至临时文件'),
  'maxSpillBytes': ('溢写文件最大容量 (字节)', '磁盘完整输出文件的最大保留体积'),
  'graceMs': ('优雅终止宽限期 (ms)', '发送 SIGTERM 后等待进程退出的毫秒数'),

  // Web Search & Fetch
  'searchProvider': ('网页搜索提供方', 'web_search 工具默认使用的搜索引擎'),
  'fetchProvider': ('网页抓取提供方', 'web_fetch 工具默认使用的内容抓取引擎'),
  'count': ('每次搜索结果数', '1–50 条，默认 10 条'),
  'searchRequestsPerSecond': ('搜索速率限制 (QPS)', '每秒最多发起的搜索请求数'),
  'sendOriginalQuestion': ('附带原始提问', '将用户原始问题一并发送以提升相关性'),
  'searchBilling': ('搜索计费方式', '自动跟随当前会话，或固定使用账号/API Key'),
  'fetchBilling': ('抓取计费方式', '自动跟随当前会话，或固定使用账号/API Key'),
  'searchBaseURL': ('搜索 API 地址', '留空使用官方地址'),
  'searchApiKeyEnv': ('搜索密钥环境变量', null),
  'fetchBaseURL': ('抓取 API 地址', '留空使用官方地址'),
  'fetchApiKeyEnv': ('抓取密钥环境变量', null),
  'apiVersion': ('API 版本', null),
  'maxUses': ('单次请求最多搜索次数', '每次对话请求允许的服务端搜索次数上限'),

  // MCP
  'servers': ('MCP 服务器列表', '按名称配置 stdio 或 Streamable HTTP MCP 服务'),
  'transport': ('传输协议', '本地命令行 stdio 或远程 Streamable HTTP'),
  'command': ('启动命令', '如 npx / uvx / node / python3'),
  'args': ('命令行参数', '逐条添加传递给启动命令的参数'),
  'env': ('环境变量', '仅注入该 MCP 子进程的键值对'),
  'url': ('服务地址 (URL)', '远程 Streamable HTTP MCP 服务端点'),
  'toolCallTimeoutMs': ('工具调用超时 (ms)', null),
  'startupTimeoutMs': ('服务启动超时 (ms)', null),
  'closeTimeoutMs': ('服务关闭超时 (ms)', null),
  'reconnect': ('自动重连策略', '连接断开时的自动重连与退避配置'),

  // UI, Conversation, Theme, Account
  'preference': ('偏好模式', null),
  'fontSize': ('正文字号', '对话阅读区域基础字体大小'),
  'codeFontSize': ('代码字号', '代码块与差异视图字体大小'),
  'terminalFontSize': ('终端字号', '交互式终端字体大小'),
  'textFontFamily': ('正文字体族', '留空使用系统默认字体'),
  'codeFontFamily': ('代码字体族', '留空使用等宽系统字体'),
  'terminalFontFamily': ('终端字体族', '留空使用终端默认等宽字体'),
  'busyEnter': ('回复中按回车行为', '选择排队等待回复完成或立即插话引导'),
  'transcriptView': ('轨迹详细程度', '控制思考与工具步骤的默认展示密度'),
  'collapseTiming': ('过程折叠时机', '回复完成时或下次输入时自动折叠过程'),
  'foldedReplies': ('自动折叠范围', '控制哪些历史轮次的回复过程自动收起'),
  'performanceUsage': ('性能与用量统计', '控制回复底部耗时与 Token 统计密度'),
  'linkOpening': ('链接打开方式', '在侧边栏预览或新标签页打开'),
  'developerTools': ('开发者工具', '显示高级调试信息与开发者入口'),
  'version': ('配置版本', null),
  'step': ('引导步骤', null),
  'purpose': ('使用场景', null),
  'process': ('思考展示偏好', null),
  'completion': ('完成状态', null),
  'usage': ('用量展示偏好', null),
  'welcomeNoticeVersion': ('已读欢迎版本', null),
};

/// Human-readable Chinese labels for common DSH enum/const option values.
const Map<String, String> kDshOptionLabels = {
  'auto': '自动',
  'account': '官方账号',
  'api-key': 'API Key',
  'light': '浅色',
  'dark': '深色',
  'system': '跟随系统',
  'queue': '排队发送',
  'steer': '立即插话',
  'compact': '紧凑',
  'standard': '标准',
  'normal': '常规',
  'detailed': '详细',
  'verbose': '完整',
  'expanded': '展开',
  'completion': '回复完成时',
  'next-input': '下次输入时',
  'never': '从不自动折叠',
  'all': '全部折叠',
  'previous': '仅历史轮次',
  'final': '仅保留最终答复',
  'none': '不折叠',
  'hidden': '隐藏',
  'sidebar': '侧边栏预览',
  'new-tab': '新标签打开',
  'external': '外部浏览器',
  'stdio': '本地命令 (stdio)',
  'streamable-http': '远程 HTTP (Streamable)',
  'always': '持续重试',
  'off': '关闭',
  'low': '低',
  'medium': '中',
  'high': '高',
  'max': '极高',
  'zh-CN': '简体中文',
  'en-US': 'English',
  'office': '办公写作',
  'development': '软件研发',
  'both': '综合场景',
  'text': '文本 (text)',
  'image': '图片 (image)',
};

String _pickLocalizedDesc(dynamic raw) {
  if (raw == null) return '';
  if (raw is String) return raw.trim();
  if (raw is Map) {
    final zh = raw['zh'] ?? raw['zh-CN'];
    if (zh != null && zh.toString().trim().isNotEmpty) return zh.toString().trim();
    final en = raw['en'] ?? raw['en-US'];
    if (en != null && en.toString().trim().isNotEmpty) return en.toString().trim();
    for (final v in raw.values) {
      if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
    }
  }
  return raw.toString().trim();
}

/// Convert real `@deepseek-ai/dsh` Schemastery `{ uid, refs }` wire graph into a complete
/// recursive JSON-Schema-like tree preserving objects, dicts, arrays, unions, intersections,
/// discriminated object unions (`oneOf`), consts, secrets, bounds, and localized descriptions.
Map<String, dynamic> normalizeSchemasteryToJsonSchema(Map<String, dynamic> raw) {
  if (!raw.containsKey('uid') || raw['refs'] is! Map) {
    return raw;
  }
  final refs = <String, Map<String, dynamic>>{};
  for (final e in (raw['refs'] as Map).entries) {
    if (e.value is Map) {
      refs[e.key.toString()] = Map<String, dynamic>.from(e.value as Map);
    }
  }
  return _resolveSchemasteryRef(raw['uid'].toString(), refs, <String>{});
}

Map<String, dynamic> _resolveSchemasteryRef(
  String id,
  Map<String, Map<String, dynamic>> refs,
  Set<String> visited,
) {
  if (!visited.add(id)) return const {'type': 'any'};
  final node = refs[id];
  if (node == null) return const {'type': 'string'};

  final type = node['type']?.toString() ?? 'string';
  final meta = node['meta'] is Map
      ? Map<String, dynamic>.from(node['meta'] as Map)
      : const <String, dynamic>{};

  final out = <String, dynamic>{};
  final desc = _pickLocalizedDesc(meta['description']);
  if (desc.isNotEmpty) out['description'] = desc;
  if (meta.containsKey('default')) out['default'] = meta['default'];
  if (meta['required'] == true) out['required'] = true;
  if (meta['hidden'] == true) out['hidden'] = true;
  final role = meta['role']?.toString();
  if (role == 'secret' || role == 'credential-ref' || role == 'textarea') {
    out['secret'] = role == 'secret';
    out['role'] = role;
  }

  switch (type) {
    case 'object':
      out['type'] = 'object';
      final dict = node['dict'];
      final props = <String, dynamic>{};
      if (dict is Map) {
        for (final entry in dict.entries) {
          final key = entry.key.toString();
          final child = _resolveSchemasteryRef(
            entry.value.toString(),
            refs,
            Set<String>.from(visited),
          );
          final info = kDshFieldCatalog[key];
          if (info != null) {
            child.putIfAbsent('title', () => info.$1);
            if (info.$2 != null) child.putIfAbsent('description', () => info.$2);
          }
          props[key] = child;
        }
      }
      out['properties'] = props;
      break;

    case 'intersect':
      final props = <String, dynamic>{};
      final oneOfBranches = <List<Map<String, dynamic>>>[];
      final list = node['list'];
      if (list is List) {
        for (final childId in list) {
          final resolved = _resolveSchemasteryRef(
            childId.toString(),
            refs,
            Set<String>.from(visited),
          );
          if (resolved['type'] == 'oneOf' && resolved['variants'] is List) {
            final branchVariants = (resolved['variants'] as List)
                .whereType<Map<String, dynamic>>()
                .toList(growable: false);
            if (branchVariants.isNotEmpty) {
              oneOfBranches.add(branchVariants);
            }
          } else if (resolved['properties'] is Map) {
            props.addAll(Map<String, dynamic>.from(resolved['properties'] as Map));
          }
        }
      }
      if (oneOfBranches.isNotEmpty) {
        final mergedVariants = <Map<String, dynamic>>[];
        for (final variant in oneOfBranches.first) {
          final merged = Map<String, dynamic>.from(variant);
          final variantProps = variant['properties'] is Map
              ? Map<String, dynamic>.from(variant['properties'] as Map)
              : <String, dynamic>{};
          merged['type'] = 'object';
          merged['properties'] = <String, dynamic>{
            ...props,
            ...variantProps,
          };
          mergedVariants.add(merged);
        }
        out['type'] = 'oneOf';
        out['variants'] = mergedVariants;
      } else {
        out['type'] = 'object';
        out['properties'] = props;
      }
      break;

    case 'union':
      final list = node['list'];
      final constValues = <dynamic>[];
      final objectVariants = <Map<String, dynamic>>[];
      bool nullable = false;
      bool hasOpenString = false;
      String? fallbackType;
      Map<String, dynamic>? singleNonNullSchema;

      void collectUnionBranch(String childId) {
        final childNode = refs[childId];
        if (childNode == null) return;
        final ct = childNode['type']?.toString();
        if (ct == 'const') {
          final v = childNode['value'];
          if (v == null) {
            nullable = true;
          } else {
            constValues.add(v);
          }
        } else if (ct == 'union' && childNode['list'] is List) {
          for (final grandId in childNode['list'] as List) {
            collectUnionBranch(grandId.toString());
          }
        } else if (ct == 'object' || ct == 'intersect') {
          objectVariants.add(
            _resolveSchemasteryRef(childId, refs, Set<String>.from(visited)),
          );
        } else if (ct == 'string') {
          hasOpenString = true;
          fallbackType ??= 'string';
          singleNonNullSchema ??=
              _resolveSchemasteryRef(childId, refs, Set<String>.from(visited));
        } else if (ct == 'boolean' ||
            ct == 'number' ||
            ct == 'natural' ||
            ct == 'percent' ||
            ct == 'array' ||
            ct == 'dict' ||
            ct == 'any') {
          fallbackType ??= (ct == 'natural' || ct == 'percent') ? 'number' : ct;
          singleNonNullSchema ??=
              _resolveSchemasteryRef(childId, refs, Set<String>.from(visited));
        }
      }

      if (list is List) {
        for (final childId in list) {
          collectUnionBranch(childId.toString());
        }
      }

      if (nullable) out['nullable'] = true;

      if (objectVariants.length >= 2) {
        out['type'] = 'oneOf';
        out['variants'] = objectVariants;
      } else if (objectVariants.length == 1 && constValues.isEmpty) {
        out.addAll(objectVariants.first);
        if (nullable) out['nullable'] = true;
      } else if (objectVariants.length == 1 && constValues.isNotEmpty) {
        // e.g. `reasoningEfforts`: `false | Record<...>` -> favor object/dict editor with optional const toggle
        out.addAll(objectVariants.first);
        out['altConsts'] = constValues;
      } else if (singleNonNullSchema != null &&
          (singleNonNullSchema!['type'] == 'dict' || singleNonNullSchema!['type'] == 'array') &&
          constValues.isNotEmpty) {
        out.addAll(singleNonNullSchema!);
        out['altConsts'] = constValues;
      } else if (constValues.isNotEmpty) {
        out['type'] = constValues.every((v) => v is bool)
            ? 'boolean'
            : (constValues.every((v) => v is num) ? 'number' : 'string');
        out['enum'] = constValues;
        if (hasOpenString || meta['loose'] == true) {
          out['allowCustom'] = true;
        }
      } else if (singleNonNullSchema != null) {
        out.addAll(singleNonNullSchema!);
        if (nullable) out['nullable'] = true;
      } else {
        out['type'] = fallbackType ?? 'string';
      }
      break;

    case 'const':
      final val = node['value'];
      out['type'] = 'const';
      out['constValue'] = val;
      out['readOnly'] = true;
      out.putIfAbsent('default', () => val);
      break;

    case 'boolean':
      out['type'] = 'boolean';
      break;

    case 'number':
    case 'natural':
    case 'percent':
      final step = (meta['step'] as num?)?.toDouble() ?? (type == 'natural' ? 1.0 : null);
      out['type'] = (step != null && step == 1.0) ? 'integer' : 'number';
      if (meta['min'] is num) out['minimum'] = meta['min'];
      if (meta['max'] is num) out['maximum'] = meta['max'];
      if (step != null) out['step'] = step;
      break;

    case 'array':
      out['type'] = 'array';
      if (node['inner'] != null) {
        out['items'] = _resolveSchemasteryRef(
          node['inner'].toString(),
          refs,
          Set<String>.from(visited),
        );
      } else {
        out['items'] = const {'type': 'string'};
      }
      break;

    case 'dict':
      out['type'] = 'dict';
      if (node['inner'] != null) {
        out['additionalProperties'] = _resolveSchemasteryRef(
          node['inner'].toString(),
          refs,
          Set<String>.from(visited),
        );
      } else {
        out['additionalProperties'] = const {'type': 'any'};
      }
      break;

    case 'any':
      out['type'] = 'any';
      break;

    default:
      out['type'] = 'string';
  }
  return out;
}

/// Generate sensible schema-compliant defaults for newly added object/dict/array items.
dynamic buildDefaultValueForSchema(Map<String, dynamic> schema) {
  if (schema.containsKey('default') && schema['default'] != null) {
    return _deepCopyDynamic(schema['default']);
  }
  final type = schema['type']?.toString() ?? 'string';
  switch (type) {
    case 'boolean':
      return false;
    case 'integer':
    case 'number':
      return schema['minimum'] ?? 0;
    case 'array':
      return <dynamic>[];
    case 'dict':
      return <String, dynamic>{};
    case 'const':
      return schema['constValue'];
    case 'oneOf':
      final variants = schema['variants'];
      if (variants is List && variants.isNotEmpty && variants.first is Map<String, dynamic>) {
        return buildDefaultValueForSchema(variants.first as Map<String, dynamic>);
      }
      return <String, dynamic>{};
    case 'object':
      final out = <String, dynamic>{};
      final props = schema['properties'];
      if (props is Map) {
        for (final e in props.entries) {
          if (e.value is! Map) continue;
          final child = Map<String, dynamic>.from(e.value as Map);
          if (child['type'] == 'const') {
            out[e.key.toString()] = child['constValue'];
          } else if (child.containsKey('default') && child['default'] != null) {
            out[e.key.toString()] = _deepCopyDynamic(child['default']);
          } else if (child['required'] == true) {
            out[e.key.toString()] = buildDefaultValueForSchema(child);
          }
        }
      }
      return out;
    default:
      final en = schema['enum'];
      if (en is List && en.isNotEmpty) return en.first;
      return '';
  }
}

dynamic _deepCopyDynamic(dynamic src) {
  if (src is Map) {
    return <String, dynamic>{
      for (final e in src.entries) e.key.toString(): _deepCopyDynamic(e.value),
    };
  }
  if (src is List) {
    return [for (final item in src) _deepCopyDynamic(item)];
  }
  return src;
}

/// Compute minimal DSH `settings/mutate` patch ops (`set` / `unset`) between [before] and [after]
/// so untouched redacted `role('secret')` paths are NEVER overwritten or wiped on save.
List<Map<String, dynamic>> computeSchemasteryMutationOps(
  Map<String, dynamic> before,
  Map<String, dynamic> after, {
  Set<String> secretPaths = const {},
}) {
  final ops = <Map<String, dynamic>>[];

  bool deepEq(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final e in a.entries) {
        if (!b.containsKey(e.key) || !deepEq(e.value, b[e.key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!deepEq(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  void walk(Map<String, dynamic> oldM, Map<String, dynamic> newM, List<String> prefix) {
    final allKeys = <String>{...oldM.keys, ...newM.keys};
    for (final k in allKeys) {
      final path = [...prefix, k];
      final dotted = path.join('.');
      final hadOld = oldM.containsKey(k);
      final hasNew = newM.containsKey(k);
      final oldV = oldM[k];
      final newV = newM[k];
      final isSecretPath = secretPaths.contains(dotted) || secretPaths.contains(k);
      if (isSecretPath && (!hasNew || newV == null || (newV is String && newV.isEmpty))) {
        // Leave redacted secret untouched unless explicitly replaced with a new non-empty value.
        continue;
      }
      if (!hasNew && hadOld) {
        ops.add({'op': 'unset', 'path': path});
      } else if (hasNew && !hadOld) {
        ops.add({'op': 'set', 'path': path, 'value': _deepCopyDynamic(newV)});
      } else if (oldV is Map && newV is Map) {
        walk(
          Map<String, dynamic>.from(oldV),
          Map<String, dynamic>.from(newV),
          path,
        );
      } else if (!deepEq(oldV, newV)) {
        ops.add({'op': 'set', 'path': path, 'value': _deepCopyDynamic(newV)});
      }
    }
  }

  walk(before, after, const []);
  return ops;
}

/// Complete Recursive Schemastery (`{ uid, refs }`) & JSON-Schema -> Native Apple iOS 26 Form Renderer.
/// Supports ALL real DSH 0.2.x types: `object`, `dict<object>`, `dict<boolean>`, `dict<string>`,
/// `dict<number>`, `array<object>`, `array<string>`, `oneOf` discriminated unions, `enum`,
/// `boolean`, `number`, `string`, `secret`, `credential-ref`, `const`, plus a live JSON toggle
/// and real inline save error reporting!
class SchemasteryForm extends StatefulWidget {
  const SchemasteryForm({
    super.key,
    required this.schema,
    required this.initialValues,
    required this.tier,
    required this.onSubmit,
    this.namespaceId = '',
    this.secretPaths = const [],
    this.submitLabel = '保存配置',
    this.readOnly = false,
    this.dynamicOptions = const {},
    this.availableModels = const [],
    this.showJsonToggle = true,
    this.insideGlass = true,
  });

  final Map<String, dynamic> schema;
  final Map<String, dynamic> initialValues;
  final GrassBagGlassTier tier;

  /// Return `null` when saved successfully, or a human-readable error message when rejected.
  final Future<String?> Function(Map<String, dynamic> values) onSubmit;

  final String namespaceId;
  final List<String> secretPaths;
  final String submitLabel;
  final bool readOnly;

  /// Keyed by `'ns.field'` or `'field'` (e.g. `'web.searchProvider'`).
  final Map<String, List<SchemaDynamicOption>> dynamicOptions;

  /// Optional list of `(providerId, modelId, displayLabel)` for quick-picking `allowedModels`.
  final List<(String, String, String)> availableModels;

  final bool showJsonToggle;
  final bool insideGlass;

  @override
  State<SchemasteryForm> createState() => _SchemasteryFormState();
}

class _SchemasteryFormState extends State<SchemasteryForm> {
  late Map<String, dynamic> _values;
  late Map<String, dynamic> _normalizedSchema;
  bool _dirty = false;
  bool _saving = false;
  bool _jsonMode = false;
  bool _copiedError = false;
  String? _saveError;
  String? _jsonParseError;
  final Map<String, String> _fieldErrors = <String, String>{};
  final Map<String, String> _pendingFieldErrors = <String, String>{};
  Timer? _jsonValidateTimer;
  Timer? _numValidateTimer;
  final TextEditingController _jsonCtrl = TextEditingController();
  final FocusNode _jsonFocusNode = FocusNode();

  bool _hasStructuredProperties() {
    final props = _normalizedSchema['properties'];
    final hasProps = props is Map<String, dynamic> && props.isNotEmpty;
    final rawVariants = _normalizedSchema['type'] == 'oneOf' ? _normalizedSchema['variants'] : null;
    final hasVariants = rawVariants is List &&
        rawVariants.whereType<Map<String, dynamic>>().isNotEmpty;
    return hasProps || hasVariants;
  }

  @override
  void initState() {
    super.initState();
    _normalizedSchema = normalizeSchemasteryToJsonSchema(widget.schema);
    _values = _deepCopyMap(widget.initialValues);
    if (!_hasStructuredProperties()) {
      _jsonMode = true;
      _syncJsonText(force: true);
    }
  }

  @override
  void didUpdateWidget(covariant SchemasteryForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.schema != widget.schema) {
      _normalizedSchema = normalizeSchemasteryToJsonSchema(widget.schema);
    }
    if (oldWidget.initialValues != widget.initialValues && !_dirty) {
      _values = _deepCopyMap(widget.initialValues);
      if (_jsonMode && !_jsonFocusNode.hasFocus) _syncJsonText();
    }
  }

  @override
  void dispose() {
    _jsonValidateTimer?.cancel();
    _numValidateTimer?.cancel();
    _jsonFocusNode.dispose();
    _jsonCtrl.dispose();
    super.dispose();
  }

  void _syncJsonText({bool force = false}) {
    final nextText = const JsonEncoder.withIndent('  ').convert(_values);
    if (force || (!_jsonFocusNode.hasFocus && _jsonCtrl.text != nextText)) {
      _jsonCtrl.text = nextText;
    }
    _jsonParseError = null;
  }

  Map<String, dynamic> _deepCopyMap(Map<String, dynamic> src) {
    return Map<String, dynamic>.from(_deepCopyDynamic(src) as Map);
  }

  dynamic _readPath(List<String> path, dynamic fallback) {
    dynamic cur = _values;
    for (final seg in path) {
      if (cur is Map && cur.containsKey(seg)) {
        cur = cur[seg];
      } else {
        return fallback;
      }
    }
    return cur ?? fallback;
  }

  void _writePath(
    List<String> path,
    dynamic value, {
    bool removeIfNull = false,
    bool rebuild = true,
  }) {
    if (widget.readOnly) return;
    void applyMutation() {
      _dirty = true;
      _saveError = null;
      Map<String, dynamic> cur = _values;
      for (var i = 0; i < path.length - 1; i++) {
        final seg = path[i];
        if (cur[seg] is! Map<String, dynamic>) {
          cur[seg] = cur[seg] is Map
              ? Map<String, dynamic>.from(cur[seg] as Map)
              : <String, dynamic>{};
        }
        cur = cur[seg] as Map<String, dynamic>;
      }
      if (removeIfNull && value == null) {
        cur.remove(path.last);
      } else {
        cur[path.last] = value;
      }
    }

    // Avoid full-form rebuilds on every text keystroke once the form is already dirty & error-free.
    if (!rebuild && _dirty && _saveError == null) {
      applyMutation();
    } else {
      setState(applyMutation);
    }
  }

  List<SchemaDynamicOption>? _lookupDynamicOptions(List<String> path) {
    final fullKey = widget.namespaceId.isNotEmpty
        ? '${widget.namespaceId}.${path.join('.')}'
        : path.join('.');
    return widget.dynamicOptions[fullKey] ?? widget.dynamicOptions[path.join('.')];
  }

  Future<void> _handleSave() async {
    if (_saving || widget.readOnly) return;
    final isRawJson = _jsonMode || !_hasStructuredProperties();
    if (isRawJson) {
      try {
        final parsed = jsonDecode(_jsonCtrl.text);
        if (parsed is! Map) {
          setState(() => _jsonParseError = '根节点必须为 JSON 对象 ({ ... })');
          return;
        }
        _values = _deepCopyMap(Map<String, dynamic>.from(parsed));
        _jsonParseError = null;
      } catch (e) {
        setState(() => _jsonParseError = 'JSON 语法错误：$e');
        return;
      }
    } else if (_fieldErrors.isNotEmpty || _pendingFieldErrors.isNotEmpty) {
      _numValidateTimer?.cancel();
      _fieldErrors.addAll(_pendingFieldErrors);
      setState(() => _saveError = _fieldErrors.values.first);
      return;
    }
    HapticFeedback.lightImpact();
    setState(() {
      _saving = true;
      _saveError = null;
    });
    String? err;
    try {
      err = await widget.onSubmit(_deepCopyMap(_values));
    } catch (e) {
      err = e.toString();
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          if (err == null) {
            _dirty = false;
            _saveError = null;
            _fieldErrors.clear();
            _pendingFieldErrors.clear();
            // Keep the freshly submitted `_values` (do NOT overwrite with stale `widget.initialValues`
            // before the parent finishes rebuilding with the persisted config!).
            if (_jsonMode) _syncJsonText();
          } else {
            _saveError = err;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final props = _normalizedSchema['properties'];
    final hasProps = props is Map<String, dynamic> && props.isNotEmpty;
    final rawVariants = _normalizedSchema['type'] == 'oneOf' ? _normalizedSchema['variants'] : null;
    final rootVariants = rawVariants is List
        ? rawVariants.whereType<Map<String, dynamic>>().toList(growable: false)
        : const <Map<String, dynamic>>[];
    final isRootOneOf = !hasProps && rootVariants.isNotEmpty;
    final hasStructured = hasProps || isRootOneOf;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.readOnly)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: t.warnSoft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(CupertinoIcons.lock_fill, size: 14, color: t.warn),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '当前部署将此配置设为只读，仅支持查看。',
                    style: TextStyle(fontSize: 12.5, color: t.warn),
                  ),
                ),
              ],
            ),
          ),

        if (widget.showJsonToggle && hasStructured) ...[
          Row(
            children: [
              Expanded(
                child: GrassBagSegmentedControl(
                  labels: const ['可视化配置', 'JSON 源码'],
                  selectedIndex: _jsonMode ? 1 : 0,
                  tier: widget.tier,
                  height: 34,
                  onSelected: (idx) {
                      if (idx == 1 && !_jsonMode) {
                        _numValidateTimer?.cancel();
                        _pendingFieldErrors.clear();
                        _fieldErrors.clear();
                        _syncJsonText(force: true);
                        setState(() => _jsonMode = true);
                      } else if (idx == 0 && _jsonMode) {
                        try {
                          final parsed = jsonDecode(_jsonCtrl.text);
                          if (parsed is Map) {
                            _numValidateTimer?.cancel();
                            _pendingFieldErrors.clear();
                            setState(() {
                              _values = _deepCopyMap(Map<String, dynamic>.from(parsed));
                              _fieldErrors.clear();
                              _jsonParseError = null;
                              _jsonMode = false;
                            });
                          } else {
                            setState(() => _jsonParseError = '根节点必须为 JSON 对象');
                          }
                        } catch (e) {
                          setState(() => _jsonParseError = 'JSON 格式无效，无法切回可视化：$e');
                        }
                      }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],

        if (_jsonMode || !hasStructured)
          _buildRawJsonEditor(context)
        else if (isRootOneOf)
          ..._buildRootOneOfFields(context, rootVariants)
        else
          ..._buildStructuredFields(context, props as Map<String, dynamic>),

        if (_saveError != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.errSoft,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.err.withValues(alpha: 0.35), width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 14, color: t.err),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '写入 DSH 配置失败（修改已保留）',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.err),
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: _saveError!));
                        HapticFeedback.selectionClick();
                        setState(() => _copiedError = true);
                        Future<void>.delayed(const Duration(milliseconds: 1400), () {
                          if (mounted) setState(() => _copiedError = false);
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Text(
                          _copiedError ? '已复制' : '复制报错',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: _copiedError ? t.ok : t.err,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                SelectableText(
                  _saveError!,
contextMenuBuilder: buildGrassBagEditableContextMenu,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.4, color: t.err),
                ),
              ],
            ),
          ),
        ],

        if (!widget.readOnly) ...[
          const SizedBox(height: 14),
          GrassBagPrimaryGlassButton(
            label: _saving
                ? '正在写入 DSH…'
                : (_dirty ? '${widget.submitLabel}（有未保存改动）' : widget.submitLabel),
            icon: _saving ? CupertinoIcons.hourglass : CupertinoIcons.checkmark_alt,
            height: 44,
            tier: widget.tier,
            insideGlass: widget.insideGlass,
            enabled: !_saving,
            onTap: _saving ? null : _handleSave,
          ),
        ],
      ],
    );
  }

  Widget _buildRawJsonEditor(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagTextField(
          controller: _jsonCtrl,
          focusNode: _jsonFocusNode,
          readOnly: widget.readOnly,
          insideGlass: widget.insideGlass,
          monospace: true,
          fontSize: 12,
          minLines: 6,
          maxLines: 14,
          borderRadius: 16,
          padding: const EdgeInsets.all(12),
          hasError: _jsonParseError != null,
          onChanged: (v) {
            if (!_dirty) {
              setState(() => _dirty = true);
            }
            _jsonValidateTimer?.cancel();
            _jsonValidateTimer = Timer(const Duration(milliseconds: 220), () {
              if (!mounted) return;
              String? nextErr;
              try {
                final decoded = jsonDecode(v);
                if (decoded is! Map) {
                  nextErr = '需要 JSON 对象 ({ ... })';
                }
              } catch (e) {
                nextErr = 'JSON 语法错误：$e';
              }
              if (nextErr != _jsonParseError) {
                setState(() => _jsonParseError = nextErr);
              }
            });
          },
        ),
        if (_jsonParseError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(_jsonParseError!, style: TextStyle(fontSize: 11.5, color: t.err)),
          ),
      ],
    );
  }

  List<Widget> _buildRootOneOfFields(
    BuildContext context,
    List<Map<String, dynamic>> variants,
  ) {
    final t = GrassBagTokens.of(context);
    String? discKey;
    final variantLabels = <String>[];
    for (var i = 0; i < variants.length; i++) {
      final props = variants[i]['properties'];
      String? foundVal;
      if (props is Map) {
        for (final e in props.entries) {
          if (e.value is Map && e.value['type'] == 'const') {
            discKey ??= e.key.toString();
            if (e.key.toString() == discKey) {
              foundVal = e.value['constValue']?.toString();
              break;
            }
          }
        }
      }
      variantLabels.add(foundVal != null ? _labelForOption(foundVal) : '模式 ${i + 1}');
    }

    int activeIdx = 0;
    if (discKey != null && _values.containsKey(discKey)) {
      final curDisc = _values[discKey]?.toString();
      for (var i = 0; i < variants.length; i++) {
        final props = variants[i]['properties'];
        if (props is Map &&
            props[discKey] is Map &&
            props[discKey]['constValue']?.toString() == curDisc) {
          activeIdx = i;
          break;
        }
      }
    }

    final activeVariant = variants[activeIdx];
    final activeProps = activeVariant['properties'] is Map<String, dynamic>
        ? activeVariant['properties'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final discTitle = discKey != null ? (kDshFieldCatalog[discKey]?.$1 ?? discKey) : '配置模式';

    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: _buildFormSection(
          header: discTitle,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 12, 15, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '切换类型后自动适配对应字段',
                    style: TextStyle(fontSize: 12, color: t.text3),
                  ),
                  const SizedBox(height: 9),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < variants.length; i++)
                        _EnumChip(
                          label: variantLabels[i],
                          selected: i == activeIdx,
                          onTap: () {
                            if (widget.readOnly || i == activeIdx) return;
                            final target = variants[i];
                            final fresh = buildDefaultValueForSchema(target);
                            final nextMap = fresh is Map<String, dynamic>
                                ? Map<String, dynamic>.from(fresh)
                                : <String, dynamic>{};
                            final targetProps = target['properties'];
                            if (targetProps is Map) {
                              for (final entry in targetProps.entries) {
                                final k = entry.key.toString();
                                final fieldSchema = entry.value;
                                if (fieldSchema is Map && fieldSchema['type'] == 'const') {
                                  nextMap[k] = fieldSchema['constValue'];
                                } else if (_values.containsKey(k)) {
                                  nextMap[k] = _deepCopyDynamic(_values[k]);
                                }
                              }
                            }
                            _numValidateTimer?.cancel();
                            _pendingFieldErrors.clear();
                            setState(() {
                              _values = nextMap;
                              _fieldErrors.clear();
                              _dirty = true;
                              _saveError = null;
                            });
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      if (activeProps.isNotEmpty) ..._buildStructuredFields(context, activeProps),
    ];
  }

  List<Widget> _buildStructuredFields(BuildContext context, Map<String, dynamic> props) {
    final sections = <Widget>[];
    final looseFields = <Widget>[];

    for (final entry in props.entries) {
      final fieldSchema = entry.value;
      if (fieldSchema is! Map<String, dynamic>) continue;
      if (fieldSchema['hidden'] == true) continue;
      final type = fieldSchema['type']?.toString() ?? 'string';
      if (type == 'object' && fieldSchema['properties'] is Map<String, dynamic>) {
        final nested = fieldSchema['properties'] as Map<String, dynamic>;
        final rows = <Widget>[];
        for (final sub in nested.entries) {
          if (sub.value is Map<String, dynamic> && (sub.value as Map<String, dynamic>)['hidden'] != true) {
            rows.add(_buildField(context, [entry.key, sub.key], sub.value as Map<String, dynamic>));
          }
        }
        if (rows.isNotEmpty) {
          final catalog = kDshFieldCatalog[entry.key];
          sections.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: _buildFormSection(
                header: fieldSchema['title']?.toString() ?? catalog?.$1 ?? entry.key,
                children: rows,
              ),
            ),
          );
        }
      } else {
        looseFields.add(_buildField(context, [entry.key], fieldSchema));
      }
    }

    if (looseFields.isNotEmpty) {
      sections.insert(
        0,
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _buildFormSection(children: looseFields),
        ),
      );
    }
    return sections;
  }

  Widget _buildFormSection({String? header, required List<Widget> children}) {
    if (widget.insideGlass) {
      return GrassBagSheetSection(header: header, children: children);
    }
    return GrassBagGroupedSection(header: header, children: children);
  }

  String _labelForOption(dynamic rawOpt) {
    final s = rawOpt.toString();
    return kDshOptionLabels[s] ?? s;
  }

  Widget _buildField(
    BuildContext context,
    List<String> path,
    Map<String, dynamic> schema,
  ) {
    final t = GrassBagTokens.of(context);
    final type = schema['type']?.toString() ?? 'string';
    final key = path.last;
    final catalog = kDshFieldCatalog[key];
    final title = schema['title']?.toString() ?? catalog?.$1 ?? key;
    final desc = schema['description']?.toString() ?? catalog?.$2;
    final defVal = schema['default'];
    final current = _readPath(path, defVal);
    final dynOpts = _lookupDynamicOptions(path);

    // 1. Read-only const
    if (type == 'const' || schema['readOnly'] == true) {
      return GrassBagListTile(
        title: Text(title),
        subtitle: desc != null ? Text(desc) : null,
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: t.fill1,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '${current ?? schema['constValue'] ?? ''}',
            style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: t.text2),
          ),
        ),
      );
    }

    // 2. Boolean toggle
    if (type == 'boolean') {
      final boolVal = current == true;
      return GrassBagListTile(
        title: Text(title),
        subtitle: desc != null ? Text(desc) : null,
        trailing: GrassBagGlassSwitch(
          value: boolVal,
          tier: widget.tier,
          onChanged: widget.readOnly ? null : (v) => _writePath(path, v),
        ),
      );
    }

    // 3. Dynamic options from live DSH APIs (e.g. web search/fetch providers, presets, permissions)
    if (dynOpts != null && dynOpts.isNotEmpty) {
      final curStr = current?.toString() ?? '';
      return Padding(
        padding: const EdgeInsets.fromLTRB(15, 12, 15, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: t.text)),
            if (desc != null) ...[
              const SizedBox(height: 2),
              Text(desc, style: TextStyle(fontSize: 12, color: t.text3)),
            ],
            const SizedBox(height: 10),
            for (final opt in dynOpts)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: GrassBagSpringTap(
                  onTap: () => _writePath(path, opt.value),
                  pressedScale: 0.98,
                  haptic: true,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: curStr == opt.value ? t.primarySoft : t.fill1,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: curStr == opt.value ? t.primary : t.sep,
                        width: curStr == opt.value ? 1.1 : 0.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                opt.label,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: curStr == opt.value ? t.primary : t.text,
                                ),
                              ),
                              if (opt.description.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  opt.description,
                                  style: TextStyle(fontSize: 11.5, height: 1.35, color: t.text3),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (curStr == opt.value)
                          Icon(CupertinoIcons.checkmark_circle_fill, size: 18, color: t.primary),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    // 4. Discriminated Union of Objects (`oneOf`, e.g. retry: normal | always)
    if (type == 'oneOf' && schema['variants'] is List) {
      return _buildOneOfField(context, path, title, desc, schema, current);
    }

    // 5. Enum (union of consts, nullable or open-string aware)
    final enumVals = schema['enum'];
    if (enumVals is List && enumVals.isNotEmpty) {
      final isNullable = schema['nullable'] == true;
      final allowCustom = schema['allowCustom'] == true;
      final isNumericEnum = type == 'integer' || type == 'number';
      final options = enumVals.map((e) => e.toString()).toList(growable: false);
      final curStr = current?.toString();
      return Padding(
        padding: const EdgeInsets.fromLTRB(15, 12, 15, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: t.text)),
            if (desc != null) ...[
              const SizedBox(height: 2),
              Text(desc, style: TextStyle(fontSize: 12, color: t.text3)),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (isNullable)
                  _EnumChip(
                    label: '未设置',
                    selected: curStr == null || curStr.isEmpty,
                    onTap: () {
                      if (widget.readOnly) return;
                      FocusManager.instance.primaryFocus?.unfocus();
                      _writePath(path, null, removeIfNull: true);
                    },
                  ),
                for (var i = 0; i < enumVals.length; i++)
                  _EnumChip(
                    label: _labelForOption(options[i]),
                    selected: curStr == options[i],
                    onTap: () {
                      if (widget.readOnly) return;
                      FocusManager.instance.primaryFocus?.unfocus();
                      _writePath(path, enumVals[i]);
                    },
                  ),
              ],
            ),
            if (allowCustom) ...[
              const SizedBox(height: 8),
              _InlineTextInput(
                key: ValueKey('${path.join('.')}_custom_enum'),
                fieldKey: '${path.join('.')}_custom_enum',
                initialValue: (curStr != null && !options.contains(curStr)) ? curStr : '',
                placeholder: '或输入自定义值…',
                numeric: isNumericEnum,
                readOnly: widget.readOnly,
                onChanged: (v) {
                  if (v.trim().isEmpty) {
                    _writePath(path, null, removeIfNull: true);
                    return;
                  }
                  if (isNumericEnum) {
                    final parsed = type == 'integer'
                        ? int.tryParse(v.trim())
                        : (int.tryParse(v.trim()) ?? double.tryParse(v.trim()));
                    if (parsed != null) _writePath(path, parsed);
                  } else {
                    _writePath(path, v);
                  }
                },
              ),
            ],
          ],
        ),
      );
    }

    // 6. Number / Integer
    if (type == 'integer' || type == 'number') {
      final rawMin = (schema['minimum'] as num?)?.toDouble();
      final rawMax = (schema['maximum'] as num?)?.toDouble();
      final isBoundedSlider =
          rawMin != null && rawMax != null && rawMax > rawMin && (rawMax - rawMin) <= 100;
      if (isBoundedSlider) {
        final numCur = ((current as num?)?.toDouble() ?? rawMin).clamp(rawMin, rawMax);
        final isInt = type == 'integer' || (schema['step'] as num?)?.toDouble() == 1.0;
        return Padding(
          padding: const EdgeInsets.fromLTRB(15, 12, 15, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title,
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: t.text)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                      color: t.primarySoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      isInt ? '${numCur.round()}' : numCur.toStringAsFixed(2),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: t.primary,
                      ),
                    ),
                  ),
                ],
              ),
              if (desc != null) ...[
                const SizedBox(height: 2),
                Text(desc, style: TextStyle(fontSize: 12, color: t.text3)),
              ],
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: () {
                  final divs = (rawMax - rawMin).round();
                  return GrassBagGlassSlider(
                    value: numCur,
                    min: rawMin,
                    max: rawMax,
                    divisions: isInt && divs > 0 && divs <= 100 ? divs : null,
                    activeColor: t.primary,
                    onChanged: widget.readOnly
                        ? null
                        : (v) => _writePath(path, isInt ? v.round() : double.parse(v.toStringAsFixed(2))),
                  );
                }(),
              ),
            ],
          ),
        );
      }

      final numPathKey = path.join('.');
      final rawInValues = _readPath(path, null);
      final fieldErr = _fieldErrors[numPathKey];
      return Padding(
        padding: const EdgeInsets.fromLTRB(15, 12, 15, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: t.text)),
                ),
                Text(key, style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: t.text3)),
              ],
            ),
            if (desc != null) ...[
              const SizedBox(height: 2),
              Text(desc, style: TextStyle(fontSize: 12, color: t.text3)),
            ],
            const SizedBox(height: 8),
            _InlineTextInput(
              key: ValueKey('${numPathKey}_num'),
              fieldKey: '${numPathKey}_num',
              initialValue: rawInValues?.toString() ?? '',
              placeholder: defVal != null ? '默认 $defVal' : '留空使用默认值',
              mono: true,
              numeric: true,
              readOnly: widget.readOnly,
              onChanged: (v) {
                final trimmed = v.trim();
                _numValidateTimer?.cancel();
                if (trimmed.isEmpty) {
                  _pendingFieldErrors.remove(numPathKey);
                  final hadErr = _fieldErrors.remove(numPathKey) != null;
                  _writePath(path, null, removeIfNull: true, rebuild: hadErr);
                  return;
                }
                final parsed = type == 'integer'
                    ? int.tryParse(trimmed)
                    : (int.tryParse(trimmed) ?? double.tryParse(trimmed));
                String? pendingErr;
                if (parsed == null) {
                  pendingErr = '$title 需要有效的${type == 'integer' ? '整数' : '数字'}';
                } else if (rawMin != null && parsed < rawMin) {
                  pendingErr = '$title 不能小于 $rawMin';
                } else if (rawMax != null && parsed > rawMax) {
                  pendingErr = '$title 不能大于 $rawMax';
                }
                if (pendingErr == null) {
                  _pendingFieldErrors.remove(numPathKey);
                  final hadErr = _fieldErrors.remove(numPathKey) != null;
                  _writePath(path, parsed, rebuild: hadErr);
                } else {
                  // Record synchronously so tapping Save within 450ms still catches invalid input,
                  // while debouncing the inline banner so multi-digit typing doesn't bounce layout.
                  final errMsg = pendingErr;
                  _pendingFieldErrors[numPathKey] = errMsg;
                  _numValidateTimer = Timer(const Duration(milliseconds: 450), () {
                    if (!mounted) return;
                    if (_pendingFieldErrors[numPathKey] == errMsg &&
                        _fieldErrors[numPathKey] != errMsg) {
                      setState(() => _fieldErrors[numPathKey] = errMsg);
                    }
                  });
                }
              },
            ),
            if (fieldErr != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Text(fieldErr, style: TextStyle(fontSize: 11.5, color: t.err)),
              ),
          ],
        ),
      );
    }

    // 7. Nested Object (recursive!)
    if (type == 'object' && schema['properties'] is Map<String, dynamic>) {
      final nestedProps = schema['properties'] as Map<String, dynamic>;
      final mapVal = current is Map ? Map<String, dynamic>.from(current) : <String, dynamic>{};
      return Padding(
        padding: const EdgeInsets.fromLTRB(15, 12, 15, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.text)),
                      if (desc != null) Text(desc, style: TextStyle(fontSize: 12, color: t.text3)),
                    ],
                  ),
                ),
                GrassBagSpringTap(
                  onTap: () => _openNestedObjectSheet(
                    context,
                    title: title,
                    schema: schema,
                    initialValue: mapVal,
                    pathPrefix: path,
                    onApply: (updated) => _writePath(path, updated),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                    decoration: BoxDecoration(
                      color: t.primarySoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '编辑 (${nestedProps.length} 项)',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.primary),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // 8. Array (`array<string>`, `array<object>`, `array<enum>`)
    if (type == 'array') {
      return _buildArrayField(context, path, title, desc, schema, current);
    }

    // 9. Dict (`dict<object>`, `dict<boolean>`, `dict<string>`, `dict<number>`)
    if (type == 'dict') {
      return _buildDictField(context, path, title, desc, schema, current);
    }

    // 10. String / Secret / Credential-ref / Any fallback
    final dottedPath = path.join('.');
    final isRedactedSecret = widget.secretPaths.contains(dottedPath) || widget.secretPaths.contains(key);
    final isSecret = schema['format'] == 'password' || schema['secret'] == true || isRedactedSecret;
    final isCredRef = schema['role'] == 'credential-ref';
    final isTextarea = schema['role'] == 'textarea';
    final rawStrVal = _readPath(path, null);
    final secretPlaceholder = isRedactedSecret
        ? '已配置（留空保持不变，输入新值可覆盖）'
        : (defVal != null && defVal.toString().isNotEmpty ? '默认 $defVal' : '输入 $title');
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 12, 15, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: t.text)),
              ),
              if (isRedactedSecret)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: t.okSoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '已加密保存',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: t.ok),
                  ),
                )
              else if (isCredRef)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: t.primarySoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '环境变量',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: t.primary),
                  ),
                ),
            ],
          ),
          if (desc != null) ...[
            const SizedBox(height: 2),
            Text(desc, style: TextStyle(fontSize: 12, color: t.text3)),
          ],
          const SizedBox(height: 8),
          _InlineTextInput(
            key: ValueKey('${dottedPath}_str'),
            fieldKey: '${dottedPath}_str',
            initialValue: rawStrVal?.toString() ?? '',
            placeholder: secretPlaceholder,
            secret: isSecret,
            multiline: isTextarea,
            mono: isCredRef || key.toLowerCase().contains('url') || key.toLowerCase().contains('path'),
            readOnly: widget.readOnly,
            onChanged: (v) => _writePath(
              path,
              v.isEmpty && schema['required'] != true ? null : v,
              removeIfNull: true,
              rebuild: false,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOneOfField(
    BuildContext context,
    List<String> path,
    String title,
    String? desc,
    Map<String, dynamic> schema,
    dynamic current,
  ) {
    final t = GrassBagTokens.of(context);
    final variants = (schema['variants'] as List)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final curMap = current is Map ? Map<String, dynamic>.from(current) : <String, dynamic>{};

    // Detect discriminator key (a property whose schema is `type: const`)
    String? discKey;
    final variantLabels = <String>[];
    for (var i = 0; i < variants.length; i++) {
      final props = variants[i]['properties'];
      String? foundVal;
      if (props is Map) {
        for (final e in props.entries) {
          if (e.value is Map && e.value['type'] == 'const') {
            discKey ??= e.key.toString();
            if (e.key.toString() == discKey) {
              foundVal = e.value['constValue']?.toString();
              break;
            }
          }
        }
      }
      variantLabels.add(foundVal != null ? _labelForOption(foundVal) : '模式 ${i + 1}');
    }

    int activeIdx = 0;
    if (discKey != null && curMap.containsKey(discKey)) {
      final curDisc = curMap[discKey]?.toString();
      for (var i = 0; i < variants.length; i++) {
        final props = variants[i]['properties'];
        if (props is Map && props[discKey] is Map && props[discKey]['constValue']?.toString() == curDisc) {
          activeIdx = i;
          break;
        }
      }
    }

    final activeVariant = variants[activeIdx];
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 12, 15, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: t.text)),
                    if (desc != null) Text(desc, style: TextStyle(fontSize: 12, color: t.text3)),
                  ],
                ),
              ),
              GrassBagSpringTap(
                onTap: () => _openNestedObjectSheet(
                  context,
                  title: '$title (${variantLabels[activeIdx]})',
                  schema: activeVariant,
                  initialValue: curMap.isEmpty
                      ? Map<String, dynamic>.from(buildDefaultValueForSchema(activeVariant) as Map)
                      : curMap,
                  pathPrefix: path,
                  onApply: (updated) => _writePath(path, updated),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: t.primarySoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('详细设置',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.primary)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < variants.length; i++)
                _EnumChip(
                  label: variantLabels[i],
                  selected: i == activeIdx,
                  onTap: () {
                    if (widget.readOnly || i == activeIdx) return;
                    final target = variants[i];
                    final fresh = buildDefaultValueForSchema(target);
                    final nextMap = fresh is Map<String, dynamic>
                        ? Map<String, dynamic>.from(fresh)
                        : <String, dynamic>{};
                    final targetProps = target['properties'];
                    if (targetProps is Map) {
                      for (final entry in targetProps.entries) {
                        final k = entry.key.toString();
                        final fieldSchema = entry.value;
                        if (fieldSchema is Map && fieldSchema['type'] == 'const') {
                          nextMap[k] = fieldSchema['constValue'];
                        } else if (curMap.containsKey(k)) {
                          nextMap[k] = _deepCopyDynamic(curMap[k]);
                        }
                      }
                    }
                    _writePath(path, nextMap);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildArrayField(
    BuildContext context,
    List<String> path,
    String title,
    String? desc,
    Map<String, dynamic> schema,
    dynamic current,
  ) {
    final t = GrassBagTokens.of(context);
    final itemsSchema = schema['items'] is Map<String, dynamic>
        ? schema['items'] as Map<String, dynamic>
        : const <String, dynamic>{'type': 'string'};
    final itemType = itemsSchema['type']?.toString() ?? 'string';
    final list = current is List ? List<dynamic>.from(current) : <dynamic>[];

    // Case A: array<object> (e.g., llm-deepseek.models, allowedModels, accounts)
    if (itemType == 'object' || itemType == 'oneOf') {
      final isAllowedModels = path.last == 'allowedModels' && widget.availableModels.isNotEmpty;
      return Padding(
        padding: const EdgeInsets.fromLTRB(15, 12, 15, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.text)),
                      if (desc != null) Text(desc, style: TextStyle(fontSize: 12, color: t.text3)),
                    ],
                  ),
                ),
                Text('${list.length} 项', style: TextStyle(fontSize: 12, color: t.text3)),
              ],
            ),
            const SizedBox(height: 10),
            if (list.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                decoration: BoxDecoration(
                  color: t.fill1,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('暂无条目，点击下方按钮添加', style: TextStyle(fontSize: 12.5, color: t.text3)),
              )
            else
              for (var i = 0; i < list.length; i++)
                _ComplexEntryTile(
                  title: _summarizeObjectItem(list[i], fallback: '条目 #${i + 1}'),
                  subtitle: _summarizeObjectMeta(list[i]),
                  onTap: () {
                    final itemMap = list[i] is Map
                        ? Map<String, dynamic>.from(list[i] as Map)
                        : <String, dynamic>{};
                    _openNestedObjectSheet(
                      context,
                      title: '$title · #${i + 1}',
                      schema: itemsSchema,
                      initialValue: itemMap,
                      pathPrefix: [...path, '$i'],
                      onApply: (updated) {
                        final next = List<dynamic>.from(list);
                        next[i] = updated;
                        _writePath(path, next);
                      },
                    );
                  },
                  onDelete: widget.readOnly
                      ? null
                      : () {
                          final next = List<dynamic>.from(list)..removeAt(i);
                          _writePath(path, next);
                        },
                ),
            if (!widget.readOnly) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (isAllowedModels) ...[
                    Expanded(
                      child: GrassBagSecondaryGlassButton(
                        label: '从可用模型选取',
                        icon: CupertinoIcons.sparkles,
                        height: 36,
                        tier: widget.tier,
                        insideGlass: true,
                        accentForeground: true,
                        onTap: () => _openPickAllowedModelSheet(context, path, list),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: GrassBagSecondaryGlassButton(
                      label: '新增一项',
                      icon: CupertinoIcons.add,
                      height: 36,
                      tier: widget.tier,
                      insideGlass: true,
                      onTap: () {
                        final fresh = buildDefaultValueForSchema(itemsSchema);
                        final map = fresh is Map<String, dynamic> ? fresh : <String, dynamic>{};
                        _openNestedObjectSheet(
                          context,
                          title: '新增 $title',
                          schema: itemsSchema,
                          initialValue: map,
                          pathPrefix: [...path, '*'],
                          onApply: (created) {
                            _writePath(path, [...list, created]);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      );
    }

    // Case B: array<enum> / array<string> / array<number> (e.g. args, visibleModels, defaultInput, retryableCodes)
    final isNumericItem = itemType == 'integer' || itemType == 'number';
    final rawItemEnums = itemsSchema['enum'] is List ? (itemsSchema['enum'] as List) : const <dynamic>[];
    final itemEnums = rawItemEnums.map((e) => e.toString()).toList(growable: false);
    final strItems = list.map((e) => e.toString()).toList(growable: false);

    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 12, 15, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: t.text)),
              ),
              Text('${strItems.length} 项', style: TextStyle(fontSize: 12, color: t.text3)),
            ],
          ),
          if (desc != null) ...[
            const SizedBox(height: 2),
            Text(desc, style: TextStyle(fontSize: 12, color: t.text3)),
          ],
          if (itemEnums.isNotEmpty) ...[
            const SizedBox(height: 9),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (var i = 0; i < itemEnums.length; i++)
                  _EnumChip(
                    label: _labelForOption(itemEnums[i]),
                    selected: strItems.contains(itemEnums[i]),
                    onTap: () {
                      final next = List<dynamic>.from(list);
                      final existingIdx = next.indexWhere((e) => e.toString() == itemEnums[i]);
                      if (existingIdx >= 0) {
                        next.removeAt(existingIdx);
                      } else {
                        next.add(rawItemEnums[i]);
                      }
                      _writePath(path, next);
                    },
                  ),
              ],
            ),
          ],
          if (strItems.isNotEmpty && (itemEnums.isEmpty || strItems.any((e) => !itemEnums.contains(e)))) ...[
            const SizedBox(height: 9),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (var i = 0; i < strItems.length; i++)
                  if (itemEnums.isEmpty || !itemEnums.contains(strItems[i]))
                    Container(
                      padding: const EdgeInsets.only(left: 10, right: 6, top: 5, bottom: 5),
                      decoration: BoxDecoration(
                        color: t.primarySoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            strItems[i],
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: t.primary,
                            ),
                          ),
                          if (!widget.readOnly) ...[
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () {
                                final next = List<dynamic>.from(list)..removeAt(i);
                                _writePath(path, next);
                              },
                              child: Icon(CupertinoIcons.xmark_circle_fill, size: 14, color: t.primary),
                            ),
                          ],
                        ],
                      ),
                    ),
              ],
            ),
          ],
          if (!widget.readOnly && (itemEnums.isEmpty || itemsSchema['allowCustom'] == true)) ...[
            const SizedBox(height: 9),
            _QuickAddChipInput(
              placeholder: isNumericItem ? '输入数值后点击添加…' : '输入后点击添加…',
              numeric: isNumericItem,
              onAdd: (val) {
                if (isNumericItem) {
                  final parsed = itemType == 'integer'
                      ? int.tryParse(val)
                      : (int.tryParse(val) ?? double.tryParse(val));
                  if (parsed == null) return false;
                  _writePath(path, [...list, parsed]);
                  return true;
                } else {
                  _writePath(path, [...list, val]);
                  return true;
                }
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDictField(
    BuildContext context,
    List<String> path,
    String title,
    String? desc,
    Map<String, dynamic> schema,
    dynamic current,
  ) {
    final t = GrassBagTokens.of(context);
    final valSchema = schema['additionalProperties'] is Map<String, dynamic>
        ? schema['additionalProperties'] as Map<String, dynamic>
        : const <String, dynamic>{'type': 'string'};
    final valType = valSchema['type']?.toString() ?? 'string';
    final map = current is Map ? Map<String, dynamic>.from(current) : <String, dynamic>{};

    // Case A: dict<object> (e.g. mcp-manager.servers, llm-pi-ai.providers, modelOverrides)
    if (valType == 'object' || valType == 'oneOf') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(15, 12, 15, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.text)),
                      if (desc != null) Text(desc, style: TextStyle(fontSize: 12, color: t.text3)),
                    ],
                  ),
                ),
                Text('${map.length} 项', style: TextStyle(fontSize: 12, color: t.text3)),
              ],
            ),
            const SizedBox(height: 10),
            if (map.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                decoration: BoxDecoration(
                  color: t.fill1,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('暂未配置任何条目，点击下方新增', style: TextStyle(fontSize: 12.5, color: t.text3)),
              )
            else
              for (final entry in map.entries)
                _ComplexEntryTile(
                  title: entry.key,
                  subtitle: _summarizeObjectMeta(entry.value),
                  onTap: () {
                    final itemMap = entry.value is Map
                        ? Map<String, dynamic>.from(entry.value as Map)
                        : <String, dynamic>{};
                    _openNestedObjectSheet(
                      context,
                      title: entry.key,
                      subtitle: title,
                      schema: valSchema,
                      initialValue: itemMap,
                      pathPrefix: [...path, entry.key],
                      onApply: (updated) {
                        final next = Map<String, dynamic>.from(map);
                        next[entry.key] = updated;
                        _writePath(path, next);
                      },
                    );
                  },
                  onDelete: widget.readOnly
                      ? null
                      : () {
                          final next = Map<String, dynamic>.from(map)..remove(entry.key);
                          _writePath(path, next);
                        },
                ),
            if (!widget.readOnly) ...[
              const SizedBox(height: 8),
              GrassBagSecondaryGlassButton(
                label: '新增条目',
                icon: CupertinoIcons.add,
                height: 36,
                tier: widget.tier,
                insideGlass: true,
                accentForeground: true,
                onTap: () => _openAddDictObjectSheet(context, path, title, valSchema, map),
              ),
            ],
          ],
        ),
      );
    }

    // Case B: dict<boolean> (e.g. llm-commandcode.modelVisibility)
    if (valType == 'boolean') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(15, 12, 15, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: t.text)),
                ),
                Text('${map.length} 项', style: TextStyle(fontSize: 12, color: t.text3)),
              ],
            ),
            if (desc != null) ...[
              const SizedBox(height: 2),
              Text(desc, style: TextStyle(fontSize: 12, color: t.text3)),
            ],
            const SizedBox(height: 9),
            if (map.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('暂无条目', style: TextStyle(fontSize: 12.5, color: t.text3)),
              )
            else
              for (final entry in map.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      color: t.fill1,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.readOnly
                                ? null
                                : () {
                                    HapticFeedback.lightImpact();
                                    final next = Map<String, dynamic>.from(map);
                                    next[entry.key] = !(entry.value == true);
                                    _writePath(path, next);
                                  },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                entry.key,
                                style: TextStyle(fontFamily: 'monospace', fontSize: 12.5, color: t.text),
                              ),
                            ),
                          ),
                        ),
                        GrassBagGlassSwitch(
                          value: entry.value == true,
                          tier: widget.tier,
                          onChanged: widget.readOnly
                              ? null
                              : (v) {
                                  final next = Map<String, dynamic>.from(map);
                                  next[entry.key] = v;
                                  _writePath(path, next);
                                },
                        ),
                        if (!widget.readOnly) ...[
                          const SizedBox(width: 4),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              final next = Map<String, dynamic>.from(map)..remove(entry.key);
                              _writePath(path, next);
                            },
                            child: SizedBox(
                              width: 34,
                              height: 34,
                              child: Center(
                                child: Icon(CupertinoIcons.trash, size: 15, color: t.text3),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            if (!widget.readOnly)
              _QuickAddChipInput(
                placeholder: '输入键名后添加开关…',
                onAdd: (k) {
                  final next = Map<String, dynamic>.from(map);
                  next[k] = true;
                  _writePath(path, next);
                  return true;
                },
              ),
          ],
        ),
      );
    }

    // Case C: dict<string> / dict<number> / dict<any> (e.g. env, headers, contextWindowOverrides)
    final isNumVal = valType == 'integer' || valType == 'number';
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 12, 15, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: t.text)),
              ),
              Text('${map.length} 对', style: TextStyle(fontSize: 12, color: t.text3)),
            ],
          ),
          if (desc != null) ...[
            const SizedBox(height: 2),
            Text(desc, style: TextStyle(fontSize: 12, color: t.text3)),
          ],
          const SizedBox(height: 9),
          for (final entry in map.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                decoration: BoxDecoration(
                  color: t.fill1,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Flexible(
                      flex: 4,
                      child: Text(
                        entry.key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text('=', style: TextStyle(color: t.text3)),
                    ),
                    Expanded(
                      flex: 5,
                      child: Text(
                        '${entry.value}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: t.text2),
                      ),
                    ),
                    if (!widget.readOnly)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          final next = Map<String, dynamic>.from(map)..remove(entry.key);
                          _writePath(path, next);
                        },
                        child: SizedBox(
                          width: 34,
                          height: 34,
                          child: Center(
                            child: Icon(CupertinoIcons.xmark_circle_fill, size: 15, color: t.text3),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (!widget.readOnly)
            _QuickAddKeyValueInput(
              keyPlaceholder: '键名',
              valPlaceholder: isNumVal ? '数值' : '值',
              numericValue: isNumVal,
              onAdd: (k, v) {
                final next = Map<String, dynamic>.from(map);
                if (isNumVal) {
                  final parsed = int.tryParse(v) ?? double.tryParse(v);
                  if (parsed == null) return false;
                  next[k] = parsed;
                } else {
                  next[k] = v;
                }
                _writePath(path, next);
                return true;
              },
            ),
        ],
      ),
    );
  }

  List<String> _scopedSecretPaths(List<String> pathPrefix) {
    if (pathPrefix.isEmpty || widget.secretPaths.isEmpty) return widget.secretPaths;
    final out = <String>[];
    for (final raw in widget.secretPaths) {
      final segs = raw.split('.');
      if (segs.length <= pathPrefix.length) continue;
      var matches = true;
      for (var i = 0; i < pathPrefix.length; i++) {
        if (segs[i] != pathPrefix[i] && segs[i] != '*' && pathPrefix[i] != '*') {
          matches = false;
          break;
        }
      }
      if (matches) {
        out.add(segs.sublist(pathPrefix.length).join('.'));
      }
    }
    return out;
  }

  void _openNestedObjectSheet(
    BuildContext context, {
    required String title,
    String? subtitle,
    required Map<String, dynamic> schema,
    required Map<String, dynamic> initialValue,
    required ValueChanged<Map<String, dynamic>> onApply,
    List<String> pathPrefix = const [],
  }) {
    final nestedSecrets = _scopedSecretPaths(pathPrefix);
    showGrassBagSheet<void>(
      context,
      title: title,
      subtitle: subtitle ?? '编辑子配置属性',
      bodyBuilder: (ctx) => SchemasteryForm(
        namespaceId: widget.namespaceId,
        secretPaths: nestedSecrets,
        schema: schema,
        initialValues: initialValue,
        tier: widget.tier,
        readOnly: widget.readOnly,
        submitLabel: '确定应用',
        dynamicOptions: widget.dynamicOptions,
        availableModels: widget.availableModels,
        onSubmit: (updated) async {
          onApply(updated);
          if (ctx.mounted) Navigator.of(ctx).pop();
          return null;
        },
      ),
    );
  }

  void _openAddDictObjectSheet(
    BuildContext context,
    List<String> path,
    String dictTitle,
    Map<String, dynamic> valSchema,
    Map<String, dynamic> currentMap,
  ) {
    showGrassBagSheet<void>(
      context,
      title: '新增 $dictTitle 条目',
      subtitle: '输入唯一标识名称（英文/数字/连字符）',
      bodyBuilder: (ctx) => _AddDictObjectKeyBody(
        placeholder: path.last == 'servers'
            ? '例如 filesystem 或 github'
            : (path.last == 'providers' ? '例如 my-openai' : '条目键名'),
        existingKeys: currentMap.keys.toSet(),
        tier: widget.tier,
        onNext: (k) {
          Navigator.of(ctx).pop();
          final fresh = buildDefaultValueForSchema(valSchema);
          final initMap = fresh is Map<String, dynamic> ? fresh : <String, dynamic>{};
          Future<void>.delayed(const Duration(milliseconds: 180), () {
            if (!context.mounted) return;
            _openNestedObjectSheet(
              context,
              title: k,
              subtitle: '配置 $dictTitle · $k',
              schema: valSchema,
              initialValue: initMap,
              pathPrefix: [...path, k],
              onApply: (created) {
                final next = Map<String, dynamic>.from(currentMap);
                next[k] = created;
                _writePath(path, next);
              },
            );
          });
        },
      ),
    );
  }

  void _openPickAllowedModelSheet(
    BuildContext context,
    List<String> path,
    List<dynamic> currentList,
  ) {
    showGrassBagSheet<void>(
      context,
      title: '选择授权模型',
      subtitle: '点选允许子智能体使用的模型',
      bodyBuilder: (ctx) {
        final t = GrassBagTokens.of(ctx);
        return GrassBagSheetSection(
          children: [
            for (final m in widget.availableModels)
              GrassBagListTile(
                title: Text(m.$3, style: TextStyle(fontWeight: FontWeight.w500, color: t.text)),
                subtitle: Text('${m.$1} / ${m.$2}', style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5)),
                trailing: currentList.any((e) => e is Map && e['provider'] == m.$1 && e['model'] == m.$2)
                    ? Icon(CupertinoIcons.checkmark_circle_fill, size: 18, color: t.primary)
                    : Icon(CupertinoIcons.plus_circle, size: 18, color: t.text3),
                onTap: () {
                  final exists = currentList.any((e) => e is Map && e['provider'] == m.$1 && e['model'] == m.$2);
                  if (!exists) {
                    _writePath(path, [...currentList, {'provider': m.$1, 'model': m.$2}]);
                  }
                  Navigator.of(ctx).pop();
                },
              ),
          ],
        );
      },
    );
  }

  String _summarizeObjectItem(dynamic item, {required String fallback}) {
    if (item is! Map) return item.toString();
    final primary = item['displayName'] ?? item['name'] ?? item['label'] ?? item['model'] ?? item['id'] ?? item['command'] ?? item['url'];
    if (primary != null && primary.toString().trim().isNotEmpty) {
      if (item['provider'] != null && primary == item['model']) {
        return '${item['provider']} / $primary';
      }
      return primary.toString();
    }
    return fallback;
  }

  String _summarizeObjectMeta(dynamic item) {
    if (item is! Map) return '';
    final bits = <String>[];
    if (item['displayName'] != null && item['displayName'].toString().isNotEmpty) {
      bits.add(item['displayName'].toString());
    }
    if (item['transport'] != null) bits.add(item['transport'].toString());
    if (item['api'] != null) bits.add(item['api'].toString());
    if (item['baseURL'] != null && item['baseURL'].toString().isNotEmpty) {
      bits.add(item['baseURL'].toString());
    }
    if (item['command'] != null && item['command'].toString().isNotEmpty) {
      bits.add(item['command'].toString());
    }
    if (item['url'] != null && item['url'].toString().isNotEmpty) {
      bits.add(item['url'].toString());
    }
    if (item['models'] is List) bits.add('${(item['models'] as List).length} 个模型');
    if (item['contextWindow'] != null) bits.add('${item['contextWindow']} ctx');
    if (item['apiKeyEnv'] != null && item['apiKeyEnv'].toString().isNotEmpty) {
      bits.add(item['apiKeyEnv'].toString());
    }
    if (item['enabled'] == false) bits.add('已停用');
    return bits.isEmpty ? '${item.length} 个属性 · 点击编辑' : bits.join(' · ');
  }
}

class _EnumChip extends StatelessWidget {
  const _EnumChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GrassBagFilterChip(
      label: label,
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      fontSize: 12.5,
    );
  }
}

class _ComplexEntryTile extends StatelessWidget {
  const _ComplexEntryTile({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onDelete,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: GrassBagSpringTap(
        onTap: onTap,
        pressedScale: 0.985,
        haptic: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: t.fill1,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: t.sep, width: 0.5),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: t.text,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: t.text3),
                      ),
                    ],
                  ],
                ),
              ),
              if (onDelete != null)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    final ok = await showGrassBagConfirmDialog(
                      context,
                      title: '删除「$title」？',
                      message: '移除该配置条目后，点击底部保存按钮将同步写入当前 DSH 主机。',
                      confirmLabel: '删除',
                      isDestructive: true,
                    );
                    if (ok) onDelete!();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Icon(CupertinoIcons.trash, size: 15, color: t.err),
                  ),
                ),
              Icon(CupertinoIcons.chevron_right, size: 13.5, color: t.text3),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddDictObjectKeyBody extends StatefulWidget {
  const _AddDictObjectKeyBody({
    required this.placeholder,
    required this.tier,
    required this.onNext,
    this.existingKeys = const {},
  });

  final String placeholder;
  final GrassBagGlassTier tier;
  final ValueChanged<String> onNext;
  final Set<String> existingKeys;

  @override
  State<_AddDictObjectKeyBody> createState() => _AddDictObjectKeyBodyState();
}

class _AddDictObjectKeyBodyState extends State<_AddDictObjectKeyBody> {
  final TextEditingController _keyCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final k = _keyCtrl.text.trim();
    if (k.isEmpty) {
      setState(() => _error = '请输入唯一的条目名称');
      return;
    }
    if (widget.existingKeys.contains(k)) {
      setState(() => _error = '已存在同名条目「$k」，请更换名称或直接编辑原有条目');
      return;
    }
    widget.onNext(k);
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GrassBagTextField(
          controller: _keyCtrl,
          autofocus: true,
          insideGlass: true,
          monospace: true,
          placeholder: widget.placeholder,
          fontSize: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          hasError: _error != null,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!, style: TextStyle(fontSize: 12, color: t.err)),
        ],
        const SizedBox(height: 14),
        GrassBagPrimaryGlassButton(
          label: '下一步：配置属性',
          icon: CupertinoIcons.arrow_right,
          tier: widget.tier,
          insideGlass: true,
          onTap: _submit,
        ),
      ],
    );
  }
}

class _InlineTextInput extends StatefulWidget {
  const _InlineTextInput({
    super.key,
    required this.fieldKey,
    required this.initialValue,
    required this.placeholder,
    required this.onChanged,
    this.secret = false,
    this.mono = false,
    this.numeric = false,
    this.multiline = false,
    this.readOnly = false,
  });

  final String fieldKey;
  final String initialValue;
  final String placeholder;
  final ValueChanged<String> onChanged;
  final bool secret;
  final bool mono;
  final bool numeric;
  final bool multiline;
  final bool readOnly;

  @override
  State<_InlineTextInput> createState() => _InlineTextInputState();
}

class _InlineTextInputState extends State<_InlineTextInput> {
  late bool _obscure;
  late TextEditingController _ctrl;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _obscure = widget.secret;
    _ctrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(covariant _InlineTextInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fieldKey != widget.fieldKey || oldWidget.secret != widget.secret) {
      _obscure = widget.secret;
    }
    if (oldWidget.fieldKey != widget.fieldKey) {
      _ctrl.value = TextEditingValue(
        text: widget.initialValue,
        selection: TextSelection.collapsed(offset: widget.initialValue.length),
      );
    } else if (!_focusNode.hasFocus &&
        oldWidget.initialValue != widget.initialValue &&
        _ctrl.text != widget.initialValue) {
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
    final t = GrassBagTokens.of(context);
    return GrassBagTextField(
      key: ValueKey(widget.fieldKey),
      controller: _ctrl,
      focusNode: _focusNode,
      readOnly: widget.readOnly,
      obscureText: _obscure,
      insideGlass: true,
      monospace: widget.mono,
      minLines: widget.multiline ? 2 : 1,
      maxLines: widget.multiline ? 5 : 1,
      keyboardType: widget.numeric
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : (widget.multiline ? TextInputType.multiline : TextInputType.text),
      fontSize: 13.5,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      placeholder: widget.placeholder,
      suffix: widget.secret
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _obscure = !_obscure),
              child: SizedBox(
                width: 36,
                height: 36,
                child: Center(
                  child: Icon(
                    _obscure ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
                    size: 16,
                    color: t.text3,
                  ),
                ),
              ),
            )
          : null,
      onChanged: widget.onChanged,
    );
  }
}

class _QuickAddChipInput extends StatefulWidget {
  const _QuickAddChipInput({
    required this.placeholder,
    required this.onAdd,
    this.numeric = false,
  });
  final String placeholder;
  final bool Function(String value) onAdd;
  final bool numeric;

  @override
  State<_QuickAddChipInput> createState() => _QuickAddChipInputState();
}

class _QuickAddChipInputState extends State<_QuickAddChipInput> {
  final _ctrl = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    final ok = widget.onAdd(v);
    if (ok) {
      _ctrl.clear();
      if (_err != null) setState(() => _err = null);
    } else {
      setState(() => _err = '格式无效，请检查后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: GrassBagTextField(
                controller: _ctrl,
                placeholder: widget.placeholder,
                insideGlass: true,
                monospace: true,
                keyboardType: widget.numeric
                    ? const TextInputType.numberWithOptions(decimal: true, signed: true)
                    : TextInputType.text,
                fontSize: 12.5,
                borderRadius: 12,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                hasError: _err != null,
                onChanged: (_) {
                  if (_err != null) setState(() => _err = null);
                },
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 8),
            GrassBagSpringTap(
              onTap: _submit,
              haptic: true,
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: t.primarySoft,
                  borderRadius: BorderRadius.circular(999),
                ),
                alignment: Alignment.center,
                child: Text('添加', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.primary)),
              ),
            ),
          ],
        ),
        if (_err != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(_err!, style: TextStyle(fontSize: 11, color: t.err)),
          ),
      ],
    );
  }
}

class _QuickAddKeyValueInput extends StatefulWidget {
  const _QuickAddKeyValueInput({
    required this.keyPlaceholder,
    required this.valPlaceholder,
    required this.onAdd,
    this.numericValue = false,
  });

  final String keyPlaceholder;
  final String valPlaceholder;
  final bool Function(String key, String val) onAdd;
  final bool numericValue;

  @override
  State<_QuickAddKeyValueInput> createState() => _QuickAddKeyValueInputState();
}

class _QuickAddKeyValueInputState extends State<_QuickAddKeyValueInput> {
  final _kCtrl = TextEditingController();
  final _vCtrl = TextEditingController();
  final _vFocus = FocusNode();
  String? _err;

  @override
  void dispose() {
    _kCtrl.dispose();
    _vCtrl.dispose();
    _vFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final k = _kCtrl.text.trim();
    final v = _vCtrl.text.trim();
    if (k.isEmpty) return;
    final ok = widget.onAdd(k, v);
    if (ok) {
      _kCtrl.clear();
      _vCtrl.clear();
      if (_err != null) setState(() => _err = null);
    } else {
      setState(() => _err = '数值格式无效');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              flex: 4,
              child: GrassBagTextField(
                controller: _kCtrl,
                placeholder: widget.keyPlaceholder,
                insideGlass: true,
                monospace: true,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _vFocus.requestFocus(),
                fontSize: 12,
                borderRadius: 12,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 4,
              child: GrassBagTextField(
                controller: _vCtrl,
                focusNode: _vFocus,
                placeholder: widget.valPlaceholder,
                insideGlass: true,
                monospace: true,
                textInputAction: TextInputAction.done,
                keyboardType: widget.numericValue
                    ? const TextInputType.numberWithOptions(decimal: true, signed: true)
                    : TextInputType.text,
                fontSize: 12,
                borderRadius: 12,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                hasError: _err != null,
                onChanged: (_) {
                  if (_err != null) setState(() => _err = null);
                },
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 6),
            GrassBagSpringTap(
              onTap: _submit,
              haptic: true,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: t.primarySoft,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(CupertinoIcons.add, size: 16, color: t.primary),
              ),
            ),
          ],
        ),
        if (_err != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(_err!, style: TextStyle(fontSize: 11, color: t.err)),
          ),
      ],
    );
  }
}
