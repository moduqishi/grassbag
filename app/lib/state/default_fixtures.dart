import 'package:gbridge_client/gbridge_client.dart';

import 'domain_models.dart';

const kDefaultSlashCommands = <SlashCommandItem>[
  SlashCommandItem(
    command: '/compact',
    title: '精简上下文',
    desc: '压缩早期对话历史，释放上下文窗口',
    category: '对话',
  ),
  SlashCommandItem(
    command: '/plan',
    title: '切换计划模式',
    desc: '先输出步骤方案再执行改动与命令',
    category: '模式',
  ),
  SlashCommandItem(
    command: '/new',
    title: '新建对话',
    desc: '在当前工作区开启全新空白对话',
    category: '对话',
  ),
  SlashCommandItem(
    command: '/fork',
    title: '分叉当前对话',
    desc: '基于当前进度创建独立实验分支',
    category: '对话',
  ),
  SlashCommandItem(
    command: '/goal',
    title: '设定长期目标',
    desc: '为当前对话绑定可持续验收目标',
    category: '目标',
  ),
  SlashCommandItem(
    command: '/export',
    title: '导出会话归档',
    desc: '打包本轮对话与产物以便备份分享',
    category: '工具',
  ),
  SlashCommandItem(
    command: '/status',
    title: '查看引擎状态',
    desc: '显示当前主机版本、延迟与能力域状态',
    category: '系统',
  ),
];

const kDefaultWorkspaceFiles = <WorkspaceFileNode>[
  WorkspaceFileNode(
    name: 'src',
    path: 'src',
    isDir: true,
    subtitle: '4 个文件',
    children: [
      WorkspaceFileNode(
        name: 'pdf-renderer.ts',
        path: 'src/pdf-renderer.ts',
        isDir: false,
        subtitle: '3.4 KB · 已修改',
        content: '''import { PdfDocument } from './pdf-doc';

export interface RenderOptions {
  exportDpi?: number;
  logicalWidthPt: number;
  logicalHeightPt: number;
}

export async function renderPage(
  page: HTMLCanvasElement,
  doc: PdfDocument,
  opts: RenderOptions,
): Promise<void> {
  const dpr = Math.max(2, opts.exportDpi ? opts.exportDpi / 96 : 2);
  page.width = Math.round(opts.logicalWidthPt * dpr);
  page.height = Math.round(opts.logicalHeightPt * dpr);

  const ctx = page.getContext('2d')!;
  ctx.scale(dpr, dpr);
  doc.addImage(page, {
    widthPt: opts.logicalWidthPt,
    heightPt: opts.logicalHeightPt,
  });
}
''',
      ),
      WorkspaceFileNode(
        name: 'font-embed.ts',
        path: 'src/font-embed.ts',
        isDir: false,
        subtitle: '2.1 KB · 已修改',
        content: '''export interface FontEmbedConfig {
  family: string;
  mode: 'vector-subset' | 'bitmap-fallback';
}

export function resolveCjkEmbed(family: string): FontEmbedConfig {
  return {
    family,
    mode: 'vector-subset',
  };
}
''',
      ),
      WorkspaceFileNode(
        name: 'components',
        path: 'src/components',
        isDir: true,
        subtitle: '1 个文件',
        children: [
          WorkspaceFileNode(
            name: 'HomeSkeleton.tsx',
            path: 'src/components/HomeSkeleton.tsx',
            isDir: false,
            subtitle: '1.9 KB',
            content: '''export function HomeSkeleton() {
  return (
    <div className="skeleton-fade" style={{ transitionDuration: '180ms' }}>
      <div className="skeleton-bar" />
    </div>
  );
}
''',
          ),
        ],
      ),
    ],
  ),
  WorkspaceFileNode(
    name: 'tests',
    path: 'tests',
    isDir: true,
    subtitle: '2 个测试文件',
    children: [
      WorkspaceFileNode(
        name: 'pdf-export.test.ts',
        path: 'tests/pdf-export.test.ts',
        isDir: false,
        subtitle: '2.8 KB · 8/8 通过',
        content: '''import { describe, expect, it } from 'vitest';
import { renderPage } from '../src/pdf-renderer';

describe('pdf-export', () => {
  it('renders at >= 2x print DPI without doubling A4 pt bounds', async () => {
    expect(renderPage).toBeTypeOf('function');
  });
});
''',
      ),
    ],
  ),
  WorkspaceFileNode(
    name: 'package.json',
    path: 'package.json',
    isDir: false,
    subtitle: '1.8 KB',
    content: '''{
  "name": "my-app",
  "version": "1.4.0",
  "scripts": {
    "dev": "vite --port 5173",
    "test": "vitest run",
    "build": "vite build"
  }
}
''',
  ),
  WorkspaceFileNode(
    name: 'export-preview-2x.pdf',
    path: 'export-preview-2x.pdf',
    isDir: false,
    subtitle: '168 KB · 产物 PDF',
    content: 'PDF 1.7 · A4 (595×842 pt) · 2x Print DPI · Embedded CJK Vector Subset · 2 Pages',
  ),
];

const kDefaultDiffRecords = <WorkspaceDiffRecord>[
  WorkspaceDiffRecord(
    path: 'src/pdf-renderer.ts',
    summary: '画布 2x 采样与 A4 逻辑页边距修正',
    added: 14,
    removed: 3,
    unifiedDiff: '''@@ -44,9 +44,18 @@ export async function renderPage(page, doc, opts) {
-  const dpr = 1;
-  page.width = opts.logicalWidthPt;
-  doc.addImage(page, { widthPt: page.width, heightPt: page.height });
+  const dpr = Math.max(2, opts.exportDpi ? opts.exportDpi / 96 : 2);
+  page.width = Math.round(opts.logicalWidthPt * dpr);
+  page.height = Math.round(opts.logicalHeightPt * dpr);
+
+  const ctx = page.getContext('2d')!;
+  ctx.scale(dpr, dpr);
+  doc.addImage(page, {
+    widthPt: opts.logicalWidthPt,
+    heightPt: opts.logicalHeightPt,
+  });
 }''',
  ),
  WorkspaceDiffRecord(
    path: 'src/font-embed.ts',
    summary: '开启中文矢量字体子集嵌入',
    added: 8,
    removed: 2,
    unifiedDiff: '''@@ -12,6 +12,12 @@ export function resolveCjkEmbed(family: string) {
-  return { family, mode: 'bitmap-fallback' };
+  return {
+    family,
+    mode: 'vector-subset',
+    hinting: 'preserve-outline',
+  };
 }''',
  ),
];

const kDefaultTodos = <SessionTodoRecord>[
  SessionTodoRecord(id: 'td1', title: '排查 PDF 导出高分屏模糊原因', done: true),
  SessionTodoRecord(id: 'td2', title: '修复 2x 画布倍率与 A4 逻辑页边距', done: true),
  SessionTodoRecord(id: 'td3', title: '启用中文字体矢量子集并跑通 8 项单测', done: true),
  SessionTodoRecord(id: 'td4', title: '核验高清对比样张并归档交付', done: false, active: true),
];

const kDefaultGoals = <SessionGoalRecord>[
  SessionGoalRecord(
    id: 'goal-1',
    title: 'PDF 导出链路清晰度与回归保障',
    criteria: '高分屏 2x 打印清晰度、中文矢量嵌入、单测覆盖率 100%',
    status: 'active',
    progressPct: 82,
  ),
];

const kDefaultSubagents = <SubagentItem>[
  SubagentItem(
    id: 'sub-1',
    name: '字体渲染分析员',
    role: 'Codebase Researcher',
    status: 'completed',
    taskSummary: '定位 font-embed.ts 中文字体降级位图的触发条件',
    model: 'DeepSeek V4',
    durationLabel: '3.2s',
    outputPreview: '确认第 14 行在缺少 subset 配置时直接走 bitmap-fallback，建议切 vector-subset。',
    worktreeBranch: 'wt/font-audit',
  ),
  SubagentItem(
    id: 'sub-2',
    name: '导出单测验证员',
    role: 'Verification Runner',
    status: 'completed',
    taskSummary: '执行 pdf-export 回归套件并比对 A4 逻辑宽度边界',
    model: 'DeepSeek Chat',
    durationLabel: '2.1s',
    outputPreview: '8/8 测试全部通过，A4 宽度 595.28pt 零偏移，生成 168 KB 高清样张。',
    worktreeBranch: 'wt/pdf-verify',
  ),
];

const kDefaultJobs = <BackgroundJobRecord>[
  BackgroundJobRecord(
    id: 'job-1',
    command: 'npm run dev -- --port 5173',
    cwd: '~/projects/my-app',
    status: 'running',
    startedAtLabel: '12 分钟前',
    outputLines: [
      'VITE v6.1.0 ready in 218 ms',
      '➜  Local:   http://127.0.0.1:5173/',
      '[HMR] updated /src/pdf-renderer.ts (14ms)',
      '[HMR] updated /src/font-embed.ts (9ms)',
    ],
  ),
  BackgroundJobRecord(
    id: 'job-2',
    command: 'npm test -- pdf-export.test.ts',
    cwd: '~/projects/my-app',
    status: 'completed',
    startedAtLabel: '4 分钟前',
    outputLines: [
      'RUN  v3.0.4 /root/projects/my-app',
      '✓ tests/pdf-export.test.ts (8 tests) 214ms',
      'Test Files  1 passed (1)',
      '     Tests  8 passed (8)',
    ],
  ),
];

const kDefaultSchedules = <ScheduleTaskRecord>[
  ScheduleTaskRecord(
    id: 'sch-1',
    name: '每日早间依赖与构建体检',
    cronExpr: '0 9 * * *',
    humanSchedule: '每天 09:00',
    timezone: 'Asia/Shanghai',
    prompt: '检查工作区 git 状态、依赖安全更新并跑一遍核心单元测试，汇总异常项。',
    enabled: true,
    lastRunAt: '今天 09:00',
    lastStatus: 'ok',
    history: [
      '今天 09:00 · 通过（耗时 18s · 0 失败）',
      '昨天 09:00 · 通过（耗时 16s · 0 失败）',
    ],
  ),
  ScheduleTaskRecord(
    id: 'sch-2',
    name: '每周下载目录发票归档',
    cronExpr: '0 20 * * 0',
    humanSchedule: '每周日 20:00',
    timezone: 'Asia/Shanghai',
    prompt: '扫描 /sdcard/Download 中本周新增的 PDF 发票，整理归档清单后待我确认移动。',
    enabled: false,
    lastRunAt: '上周日 20:00',
    lastStatus: 'ok',
    history: [
      '上周日 20:00 · 扫描到 4 份发票并完成归档',
    ],
  ),
];

const kDefaultMarketPlugins = <PluginMarketEntry>[
  PluginMarketEntry(
    name: '@grassbag/dsh-gbridge',
    displayName: '连接助手 (dsh-gbridge)',
    version: '0.1.0',
    desc: '零侵入 Cordis 桥插件，提供 /gbridge/v1 全功能域、流式续传与 SDUI 扩展',
    author: 'GrassBag',
    installed: true,
  ),
  PluginMarketEntry(
    name: '@dsh/plugin-web-search',
    displayName: '联网检索增强',
    version: '1.3.2',
    desc: '自动抓取实时网页与技术文档，附带可点击来源引用',
    author: 'DSH Official',
    installed: true,
  ),
  PluginMarketEntry(
    name: '@dsh/plugin-office-preview',
    displayName: 'Office 转 PDF 高清预览',
    version: '0.9.4',
    desc: '在主机端将 docx/xlsx/pptx 无损渲染为移动端可预览 PDF',
    author: 'DSH Official',
    installed: false,
  ),
  PluginMarketEntry(
    name: '@dsh/plugin-git-worktree',
    displayName: 'Git Worktree 并行隔离',
    version: '0.6.1',
    desc: '为每个子代理自动分配独立 worktree 分支，改动互不污染',
    author: 'DSH Labs',
    installed: false,
  ),
];

const kDefaultDynamicCordis = <DynamicCordisEntry>[
  DynamicCordisEntry(
    id: 'cordis-gbridge',
    name: 'gbridge',
    status: 'running',
    description: '挂载 /gbridge/v1 12 大功能域路由与多路复用 WebSocket',
    capabilities: ['chat', 'files', 'terminal', 'sdui', 'web-ticket'],
  ),
  DynamicCordisEntry(
    id: 'cordis-cot-zh',
    name: 'cot-translation',
    status: 'running',
    description: '实时将英文思考轨迹翻译为自然中文',
    capabilities: ['cotTranslation/translate'],
  ),
];

/// Default Schemastery-compatible engine settings schema (replaced live by `GET /gbridge/v1/settings/schema`).
const Map<String, dynamic> kDefaultEngineSettingsSchema = {
  'type': 'object',
  'properties': {
    'agent': {
      'type': 'object',
      'title': 'Agent 循环与并发',
      'properties': {
        'maxStepsPerTurn': {
          'type': 'integer',
          'title': '单轮最大工具调用步数',
          'description': '防止死循环的安全上限，默认 24 步',
          'minimum': 4,
          'maximum': 100,
          'default': 24,
        },
        'autoCompactThreshold': {
          'type': 'integer',
          'title': '自动精简上下文阈值 (%)',
          'description': '上下文占用超过此比例时自动触发精简',
          'minimum': 50,
          'maximum': 95,
          'default': 80,
        },
        'parallelSubagents': {
          'type': 'boolean',
          'title': '允许子代理并行执行',
          'description': '开启后复杂任务可并行分发给多个只读/验证子代理',
          'default': true,
        },
      },
    },
    'execution': {
      'type': 'object',
      'title': '命令执行与沙箱',
      'properties': {
        'commandTimeoutSec': {
          'type': 'integer',
          'title': '单条命令超时时间 (秒)',
          'minimum': 10,
          'maximum': 600,
          'default': 120,
        },
        'defaultShell': {
          'type': 'string',
          'title': '默认终端 Shell',
          'enum': ['/bin/zsh', '/bin/bash', '/system/bin/sh'],
          'default': '/bin/zsh',
        },
        'redactSecrets': {
          'type': 'boolean',
          'title': '自动遮挡消息中的 API 密钥',
          'description': '发送和展示时自动脱敏 sk-/ghp-/Bearer 等敏感凭据',
          'default': true,
        },
      },
    },
    'network': {
      'type': 'object',
      'title': '网络与联网搜索',
      'properties': {
        'webSearchProvider': {
          'type': 'string',
          'title': '默认搜索引擎',
          'enum': ['auto', 'tavily', 'exa', 'searxng'],
          'default': 'auto',
        },
        'proxyUrl': {
          'type': 'string',
          'title': '自定义 HTTP/SOCKS 代理地址',
          'description': '留空则直连或跟随系统代理',
          'default': '',
        },
      },
    },
  },
};

const Map<String, dynamic> kDefaultEngineSettingsValues = {
  'agent': {
    'maxStepsPerTurn': 24,
    'autoCompactThreshold': 80,
    'parallelSubagents': true,
  },
  'execution': {
    'commandTimeoutSec': 120,
    'defaultShell': '/bin/zsh',
    'redactSecrets': true,
  },
  'network': {
    'webSearchProvider': 'auto',
    'proxyUrl': '',
  },
};

/// Built-in offline fallback SDUI surfaces (replaced/augmented dynamically by `GET /gbridge/v1/sdui/surfaces`).
const kDefaultSduiSurfaces = <SduiSurfaceMeta>[
  SduiSurfaceMeta(
    id: 'host-diagnostics',
    title: '主机运行诊断',
    subtitle: 'DSH 能力域、连接通道与运行时探针',
    icon: 'pulse',
    placement: 'settings',
    order: 10,
  ),
  SduiSurfaceMeta(
    id: 'exp-stats',
    title: '用量与效能统计',
    subtitle: '近期 Token 消耗、缓存命中率与响应耗时',
    icon: 'chart',
    placement: 'experimental',
    order: 20,
  ),
  SduiSurfaceMeta(
    id: 'exp-forge',
    title: '工作区实验工坊 (Forge)',
    subtitle: 'Git Worktree 隔离沙箱与快速对比实验',
    icon: 'sparkles',
    placement: 'experimental',
    order: 30,
  ),
];

SduiView buildFallbackSduiView(
  String viewId, {
  required String hostName,
  required String dshVersion,
  required String bridgeVersion,
  required String activeSlot,
  required String executorMode,
  required int endpointsCount,
  required int sessionsCount,
}) {
  if (viewId == 'exp-stats') {
    return const SduiView(
      viewId: 'exp-stats',
      title: '用量与效能统计',
      subtitle: '由已连接的 DSH 核心实时统计',
      root: {
        'type': 'column',
        'gap': 12,
        'children': [
          {
            'type': 'alert',
            'tone': 'info',
            'message': '当前未连接到 DSH 核心，无法读取真实 Token 用量与效能统计。连接主机后点击刷新即可获取实时数据。',
          },
          {
            'type': 'actions',
            'items': [
              {'id': 'refresh', 'label': '刷新实时统计', 'style': 'primary'},
            ],
          },
        ],
      },
    );
  }

  if (viewId == 'exp-forge') {
    return const SduiView(
      viewId: 'exp-forge',
      title: '工作区实验工坊 (Forge)',
      subtitle: '独立 Git Worktree 沙箱与实时共享状态',
      root: {
        'type': 'column',
        'gap': 12,
        'children': [
          {
            'type': 'alert',
            'tone': 'info',
            'message': '需要连接到运行中的 DSH 核心才能列出与管理 Git Worktree 沙箱。',
          },
          {
            'type': 'actions',
            'items': [
              {'id': 'refresh', 'label': '刷新沙箱状态', 'style': 'primary'},
            ],
          },
        ],
      },
    );
  }

  return SduiView(
    viewId: 'host-diagnostics',
    title: '主机运行诊断',
    subtitle: 'DSH 能力域与零侵入 gbridge 通道状态',
    root: {
      'type': 'column',
      'gap': 12,
      'children': [
        {
          'type': 'row',
          'gap': 10,
          'children': [
            {'type': 'metric', 'label': 'DSH 版本', 'value': dshVersion},
            {'type': 'metric', 'label': '已发现 RPC', 'value': '$endpointsCount'},
            {'type': 'metric', 'label': '活跃会话', 'value': '$sessionsCount'},
          ],
        },
        {
          'type': 'card',
          'title': '运行时与物理存储详情',
          'children': [
            {
              'type': 'kv_list',
              'items': [
                {'key': '当前主机', 'value': hostName, 'copyable': true},
                {'key': 'gbridge 桥版本', 'value': bridgeVersion},
                {'key': '活跃槽位', 'value': activeSlot},
                {'key': '容器执行器', 'value': executorMode},
                {'key': '活跃会话数', 'value': '$sessionsCount'},
              ],
            },
          ],
        },
        {
          'type': 'actions',
          'items': [
            {'id': 'refresh', 'label': '刷新诊断探针', 'style': 'primary'},
          ],
        },
      ],
    },
  );
}
