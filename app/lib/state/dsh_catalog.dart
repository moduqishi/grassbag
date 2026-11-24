import 'domain_models.dart';

/// Metadata for all 23 real `@deepseek-ai/dsh@0.2.2-rc.5` Schemastery namespaces.
/// Format: ns -> (Chinese title, logical group, subtitle)
const Map<String, (String, String, String)> kDshNamespaceMeta = {
  'agent-default-model': ('默认对话模型', '模型与推理', '默认提供商、模型 ID 与思考深度'),
  'llm-deepseek': ('DeepSeek API 参数', '模型与推理', 'Base URL、思考开关、重试策略与上下文窗口'),
  'llm-deepseek-account': ('DeepSeek 账号模型参数', '模型与推理', '官方账号登录渠道的模型覆盖与超时'),
  'llm-pi-ai': ('外部多渠道模型 (Pi-AI)', '模型与推理', 'OpenAI / Anthropic / Gemini / OpenRouter 等 40+ 渠道'),
  'llm-commandcode': ('CommandCode 渠道参数', '模型与推理', '企业/订阅账号模型可见性与配额显示'),
  'subagent-model-selection-settings': ('子代理模型选择策略', '模型与推理', '控制子代理是否独立选模与白名单'),
  'ui-chat': ('对话轨迹与展示密度', '对话与界面', '过程折叠时机、思考/工具视图与用量统计'),
  'ui-conversation': ('回复中输入交互', '对话与界面', '流式回复期间按回车排队或插话引导'),
  'ui-theme': ('字体与界面主题', '对话与界面', '主题模式、正文/代码/终端字号与字体族'),
  'locale': ('语言区域设置', '对话与界面', 'DSH 宿主机界面与提示语言'),
  'ui-settings': ('界面配置面板开关', '对话与界面', '控制 Web/客户端配置界面启用状态'),
  'ui-settings-general': ('通用欢迎与引导记录', '对话与界面', '记录已读欢迎通知版本'),
  'ui-settings-account': ('账号面板与开发者选项', '对话与界面', '账号引导步骤与开发者工具开关'),
  'agent-preset-registry': ('默认 Agent 预设', '代理与沙箱', '选择 standard / ptc / minimal / cordis'),
  'agent-loop': ('Agent 循环并发控制', '代理与沙箱', '单轮最大并发工具调用数'),
  'subagent': ('子代理深度与并发上限', '代理与沙箱', '最大嵌套层数与同时活跃子代理数'),
  'bash-sandbox': ('Shell 命令沙箱参数', '代理与沙箱', '工作目录、超时时间、输出截断与溢写上限'),
  'permission': ('默认操作权限预设', '代理与沙箱', '控制工具与命令执行的默认审批策略'),
  'web': ('联网搜索与抓取引擎', '联网与扩展', '选择 web_search 与 web_fetch 默认提供商'),
  'web-search-deepseek': ('DeepSeek 联网搜索配置', '联网与扩展', '搜索 API 地址、模型、Token 上限与单轮次数'),
  'web-deepseek-api': ('DeepSeek Web API 限流', '联网与扩展', '搜索条数、QPS 速率限制与抓取端点'),
  'mcp-manager': ('MCP 服务器管理', '联网与扩展', '配置 stdio / SSE / HTTP MCP 服务连接'),
  'session-log-deepseek': ('会话诊断日志上传', '联网与扩展', '控制 DeepSeek 会话诊断日志记录开关'),
};

const List<String> kDshNamespaceGroupOrder = [
  '模型与推理',
  '代理与沙箱',
  '对话与界面',
  '联网与扩展',
];

/// Parse live `GET /gbridge/v1/settings/schema` response from real `@deepseek-ai/dsh@0.2.2-rc.5`.
List<DshSettingsNamespace> parseDshSettingsNamespaces(Map<String, dynamic> description) {
  final rawList = description['namespaces'];
  if (rawList is! List) return const [];
  final writableDefault = description['writable'] != false;
  final out = <DshSettingsNamespace>[];

  for (final item in rawList) {
    if (item is! Map) continue;
    final m = Map<String, dynamic>.from(item);
    final ns = m['ns']?.toString() ?? '';
    if (ns.isEmpty) continue;
    final meta = kDshNamespaceMeta[ns];
    final rawSchema = m['schema'] is Map
        ? Map<String, dynamic>.from(m['schema'] as Map)
        : const <String, dynamic>{};
    final rawValue = m['value'] is Map
        ? Map<String, dynamic>.from(m['value'] as Map)
        : const <String, dynamic>{};
    final secrets = <String>[];
    if (m['secrets'] is List) {
      for (final s in m['secrets'] as List) {
        if (s is String) {
          secrets.add(s);
        } else if (s is Map && s['ref'] != null) {
          secrets.add(s['ref'].toString());
        }
      }
    }
    out.add(
      DshSettingsNamespace(
        ns: ns,
        title: meta?.$1 ?? ns,
        group: meta?.$2 ?? '其他扩展',
        subtitle: meta?.$3 ?? 'DSH 扩展命名空间 ($ns)',
        schema: rawSchema,
        value: rawValue,
        revision: (m['revision'] as num?)?.toInt() ?? 0,
        writable: m['writable'] != false && writableDefault,
        secrets: secrets,
      ),
    );
  }

  out.sort((a, b) {
    final ga = kDshNamespaceGroupOrder.indexOf(a.group);
    final gb = kDshNamespaceGroupOrder.indexOf(b.group);
    final ra = ga == -1 ? 99 : ga;
    final rb = gb == -1 ? 99 : gb;
    if (ra != rb) return ra.compareTo(rb);
    return a.ns.compareTo(b.ns);
  });
  return out;
}

/// Offline-ready default DSH 0.2.2-rc.5 namespaces (replaced 1:1 upon live host hydration).
final List<DshSettingsNamespace> kDefaultDshNamespaces = [
  const DshSettingsNamespace(
    ns: 'agent-default-model',
    title: '默认对话模型',
    group: '模型与推理',
    subtitle: '默认提供商、模型 ID 与思考深度',
    schema: {
      'type': 'object',
      'properties': {
        'provider': {
          'type': 'string',
          'enum': ['deepseek', 'deepseek-account', 'openai', 'anthropic', 'gemini', 'openrouter'],
          'default': 'deepseek',
        },
        'model': {'type': 'string', 'default': 'deepseek-reasoner'},
        'reasoningEffort': {
          'type': 'string',
          'enum': ['low', 'medium', 'high', 'max'],
          'default': 'high',
        },
      },
    },
    value: {
      'provider': 'deepseek',
      'model': 'deepseek-reasoner',
      'reasoningEffort': 'high',
    },
  ),
  const DshSettingsNamespace(
    ns: 'llm-deepseek',
    title: 'DeepSeek API 参数',
    group: '模型与推理',
    subtitle: 'Base URL、思考开关、重试策略与上下文窗口',
    schema: {
      'type': 'object',
      'properties': {
        'baseURL': {'type': 'string', 'default': 'https://api.deepseek.com'},
        'apiKeyEnv': {'type': 'string', 'role': 'credential-ref', 'default': 'DEEPSEEK_API_KEY'},
        'thinking': {'type': 'boolean', 'default': true},
        'reasoningEffort': {
          'type': 'string',
          'enum': ['low', 'medium', 'high', 'max'],
          'default': 'high',
        },
        'maxTokens': {'type': 'integer', 'default': 16384},
        'defaultContextWindow': {'type': 'integer', 'default': 131072},
        'streamIdleTimeoutMs': {'type': 'integer', 'default': 90000},
      },
    },
    value: {
      'baseURL': 'https://api.deepseek.com',
      'apiKeyEnv': 'DEEPSEEK_API_KEY',
      'thinking': true,
      'reasoningEffort': 'high',
      'maxTokens': 16384,
      'defaultContextWindow': 131072,
      'streamIdleTimeoutMs': 90000,
    },
  ),
  const DshSettingsNamespace(
    ns: 'agent-preset-registry',
    title: '默认 Agent 预设',
    group: '代理与沙箱',
    subtitle: '选择 standard / ptc / minimal / cordis',
    schema: {
      'type': 'object',
      'properties': {
        'selectedDefault': {
          'type': 'string',
          'enum': ['standard', 'ptc', 'minimal', 'cordis'],
          'default': 'standard',
        },
      },
    },
    value: {'selectedDefault': 'standard'},
  ),
  const DshSettingsNamespace(
    ns: 'agent-loop',
    title: 'Agent 循环并发控制',
    group: '代理与沙箱',
    subtitle: '单轮最大并发工具调用数',
    schema: {
      'type': 'object',
      'properties': {
        'maxParallelToolCalls': {'type': 'integer', 'minimum': 1, 'maximum': 32, 'default': 8},
      },
    },
    value: {'maxParallelToolCalls': 8},
  ),
  const DshSettingsNamespace(
    ns: 'subagent',
    title: '子代理深度与并发上限',
    group: '代理与沙箱',
    subtitle: '最大嵌套层数与同时活跃子代理数',
    schema: {
      'type': 'object',
      'properties': {
        'maxDepth': {'type': 'integer', 'minimum': 0, 'maximum': 6, 'default': 1},
        'maxActiveSubagents': {'type': 'integer', 'minimum': 1, 'maximum': 24, 'default': 8},
      },
    },
    value: {'maxDepth': 1, 'maxActiveSubagents': 8},
  ),
  const DshSettingsNamespace(
    ns: 'bash-sandbox',
    title: 'Shell 命令沙箱参数',
    group: '代理与沙箱',
    subtitle: '工作目录、超时时间、输出截断与溢写上限',
    schema: {
      'type': 'object',
      'properties': {
        'cwd': {'type': 'string', 'default': ''},
        'timeoutMs': {'type': 'integer', 'default': 60000},
        'maxTimeoutMs': {'type': 'integer', 'default': 600000},
        'maxOutputBytes': {'type': 'integer', 'default': 64000},
        'maxSpillBytes': {'type': 'integer', 'default': 67108864},
        'graceMs': {'type': 'integer', 'default': 3000},
      },
    },
    value: {
      'cwd': '',
      'timeoutMs': 60000,
      'maxTimeoutMs': 600000,
      'maxOutputBytes': 64000,
      'maxSpillBytes': 67108864,
      'graceMs': 3000,
    },
  ),
  const DshSettingsNamespace(
    ns: 'permission',
    title: '默认操作权限预设',
    group: '代理与沙箱',
    subtitle: '控制工具与命令执行的默认审批策略',
    schema: {
      'type': 'object',
      'properties': {
        'defaultPreset': {
          'type': 'string',
          'enum': ['read-only', 'workspace-write', 'full-auto', 'danger-full-access'],
          'default': 'workspace-write',
        },
      },
    },
    value: {'defaultPreset': 'workspace-write'},
  ),
  const DshSettingsNamespace(
    ns: 'ui-chat',
    title: '对话轨迹与展示密度',
    group: '对话与界面',
    subtitle: '过程折叠时机、思考/工具视图与用量统计',
    schema: {
      'type': 'object',
      'properties': {
        'transcriptView': {
          'type': 'string',
          'enum': ['compact', 'standard', 'detailed', 'verbose'],
          'default': 'standard',
        },
        'collapseTiming': {
          'type': 'string',
          'enum': ['completion', 'next-input', 'never'],
          'default': 'completion',
        },
        'foldedReplies': {
          'type': 'string',
          'enum': ['all', 'previous', 'none'],
          'default': 'all',
        },
        'performanceUsage': {
          'type': 'string',
          'enum': ['hidden', 'compact', 'detailed'],
          'default': 'detailed',
        },
        'linkOpening': {
          'type': 'string',
          'enum': ['sidebar', 'external'],
          'default': 'sidebar',
        },
      },
    },
    value: {
      'transcriptView': 'standard',
      'collapseTiming': 'completion',
      'foldedReplies': 'all',
      'performanceUsage': 'detailed',
      'linkOpening': 'sidebar',
    },
  ),
  const DshSettingsNamespace(
    ns: 'ui-conversation',
    title: '回复中输入交互',
    group: '对话与界面',
    subtitle: '流式回复期间按回车排队或插话引导',
    schema: {
      'type': 'object',
      'properties': {
        'busyEnter': {
          'type': 'string',
          'enum': ['queue', 'steer'],
          'default': 'queue',
        },
      },
    },
    value: {'busyEnter': 'queue'},
  ),
  const DshSettingsNamespace(
    ns: 'ui-theme',
    title: '字体与界面主题',
    group: '对话与界面',
    subtitle: '主题模式、正文/代码/终端字号与字体族',
    schema: {
      'type': 'object',
      'properties': {
        'preference': {
          'type': 'string',
          'enum': ['light', 'dark', 'system'],
          'default': 'system',
        },
        'fontSize': {'type': 'integer', 'minimum': 10, 'maximum': 22, 'default': 14},
        'codeFontSize': {'type': 'integer', 'minimum': 10, 'maximum': 16, 'default': 12},
        'terminalFontSize': {'type': 'integer', 'minimum': 10, 'maximum': 20, 'default': 13},
      },
    },
    value: {
      'preference': 'system',
      'fontSize': 14,
      'codeFontSize': 12,
      'terminalFontSize': 13,
    },
  ),
  const DshSettingsNamespace(
    ns: 'locale',
    title: '语言区域设置',
    group: '对话与界面',
    subtitle: 'DSH 宿主机界面与提示语言',
    schema: {
      'type': 'object',
      'properties': {
        'preference': {
          'type': 'string',
          'enum': ['auto', 'zh-CN', 'en-US'],
          'default': 'zh-CN',
        },
      },
    },
    value: {'preference': 'zh-CN'},
  ),
  const DshSettingsNamespace(
    ns: 'web',
    title: '联网搜索与抓取引擎',
    group: '联网与扩展',
    subtitle: '选择 web_search 与 web_fetch 默认提供商',
    schema: {
      'type': 'object',
      'properties': {
        'searchProvider': {
          'type': 'string',
          'enum': ['deepseek', 'tavily', 'exa', 'auto'],
          'default': 'deepseek',
        },
        'fetchProvider': {
          'type': 'string',
          'enum': ['deepseek', 'builtin', 'auto'],
          'default': 'deepseek',
        },
      },
    },
    value: {'searchProvider': 'deepseek', 'fetchProvider': 'deepseek'},
  ),
  const DshSettingsNamespace(
    ns: 'mcp-manager',
    title: 'MCP 服务器管理',
    group: '联网与扩展',
    subtitle: '配置 stdio / SSE / HTTP MCP 服务连接',
    schema: {
      'type': 'object',
      'properties': {
        'servers': {
          'type': 'dict',
          'default': {},
          'additionalProperties': {
            'type': 'object',
            'properties': {
              'command': {'type': 'string'},
              'args': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'url': {'type': 'string'},
              'env': {
                'type': 'dict',
                'additionalProperties': {'type': 'string'},
              },
              'disabled': {'type': 'boolean', 'default': false},
            },
          },
        },
      },
    },
    value: {'servers': {}},
  ),
  const DshSettingsNamespace(
    ns: 'session-log-deepseek',
    title: '会话诊断日志上传',
    group: '联网与扩展',
    subtitle: '控制 DeepSeek 会话诊断日志记录开关',
    schema: {
      'type': 'object',
      'properties': {
        'enabled': {'type': 'boolean', 'default': false},
      },
    },
    value: {'enabled': false},
  ),
];

const List<ProviderCredentialItem> kDefaultProviderCredentials = [
  ProviderCredentialItem(
    id: 'deepseek-official',
    name: 'DeepSeek 官方 API',
    settingsNs: 'llm-deepseek',
    envRef: 'DEEPSEEK_API_KEY',
    baseUrl: 'https://api.deepseek.com',
    configured: false,
    modelsCount: 0,
    description: 'DeepSeek 官方直连接口',
  ),
  ProviderCredentialItem(
    id: 'openai',
    name: 'OpenAI',
    settingsNs: 'llm-pi-ai',
    envRef: 'OPENAI_API_KEY',
    baseUrl: 'https://api.openai.com/v1',
    configured: false,
    modelsCount: 0,
    description: 'GPT-5 / o3 / Codex 兼容渠道',
  ),
  ProviderCredentialItem(
    id: 'anthropic',
    name: 'Anthropic Claude',
    settingsNs: 'llm-pi-ai',
    envRef: 'ANTHROPIC_API_KEY',
    baseUrl: 'https://api.anthropic.com',
    configured: false,
    modelsCount: 0,
    description: 'Claude Sonnet / Opus 原生 Messages 渠道',
  ),
  ProviderCredentialItem(
    id: 'google',
    name: 'Google Gemini',
    settingsNs: 'llm-pi-ai',
    envRef: 'GEMINI_API_KEY',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    configured: false,
    modelsCount: 0,
    description: 'Gemini 2.5 Pro / Flash 多模态渠道',
  ),
  ProviderCredentialItem(
    id: 'openrouter',
    name: 'OpenRouter 聚合',
    settingsNs: 'llm-pi-ai',
    envRef: 'OPENROUTER_API_KEY',
    baseUrl: 'https://openrouter.ai/api/v1',
    configured: false,
    modelsCount: 0,
    description: '单密钥统一接入多款开源与闭源模型',
  ),
];

const List<McpServerItem> kDefaultMcpServers = [
  McpServerItem(
    name: 'filesystem-local',
    transport: 'stdio',
    status: 'connected',
    endpoint: 'npx @modelcontextprotocol/server-filesystem /root',
    toolsCount: 9,
    lastLatencyMs: 14,
  ),
  McpServerItem(
    name: 'git-inspector',
    transport: 'stdio',
    status: 'connected',
    endpoint: 'uvx mcp-server-git --repository /root/projects',
    toolsCount: 6,
    lastLatencyMs: 22,
  ),
];

const List<ContainerToolkitItem> kDefaultContainerToolkits = [
  ContainerToolkitItem(
    id: 'core-node',
    name: 'Ubuntu 24.04.5 + Node.js 24 LTS',
    desc: '内置核心 Linux 运行时、DSH 0.2.2-rc.5 与 dsh-gbridge',
    packages: ['ubuntu-base', 'nodejs-24.22.3', 'npm', 'dsh'],
    sizeLabel: '已内置',
    installed: true,
  ),
  ContainerToolkitItem(
    id: 'python-uv',
    name: 'Python 3.12 与 pip 工具链',
    desc: '支持数据分析、自动化脚本、MCP Python 服务与 PTC 沙箱',
    packages: ['python3', 'python3-venv', 'python3-pip'],
    sizeLabel: '约 48 MB',
  ),
  ContainerToolkitItem(
    id: 'dev-git-cli',
    name: 'Git / Ripgrep / jq / SQLite3',
    desc: '代码检索、仓库分支管理、JSON 处理与本地数据库工具',
    packages: ['git', 'ripgrep', 'jq', 'sqlite3', 'curl', 'ca-certificates'],
    sizeLabel: '约 26 MB',
  ),
  ContainerToolkitItem(
    id: 'media-office',
    name: 'FFmpeg / ImageMagick / Pandoc',
    desc: '音视频转码、图片批量水印压缩与 Markdown/PDF 文档转换',
    packages: ['ffmpeg', 'imagemagick', 'pandoc'],
    sizeLabel: '约 84 MB',
  ),
];
