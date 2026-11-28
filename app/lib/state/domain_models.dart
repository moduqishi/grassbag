import 'package:flutter/foundation.dart';
import 'package:gbridge_client/gbridge_client.dart';

/// Attachment queued inside the floating composer prior to sending.
@immutable
class ComposerAttachment {
  const ComposerAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    this.bytes,
    this.uploadedId,
  });

  final String id;
  final String name;
  final String mimeType;
  final int sizeBytes;
  final Uint8List? bytes;
  final String? uploadedId;

  bool get isImage => mimeType.startsWith('image/');

  String get humanSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Interactive slash command or skill item shown when typing `/` in composer.
@immutable
class SlashCommandItem {
  const SlashCommandItem({
    required this.command,
    required this.title,
    required this.desc,
    this.category = '指令',
  });

  final String command;
  final String title;
  final String desc;
  final String category;
}

/// Navigable file/directory entry for Workspace Files & FS Directory Browser.
@immutable
class WorkspaceFileNode {
  const WorkspaceFileNode({
    required this.name,
    required this.path,
    required this.isDir,
    this.subtitle = '',
    this.content,
    this.children = const [],
  });

  final String name;
  final String path;
  final bool isDir;
  final String subtitle;
  final String? content;
  final List<WorkspaceFileNode> children;
}

/// File-level diff record with full unified diff body.
@immutable
class WorkspaceDiffRecord {
  const WorkspaceDiffRecord({
    required this.path,
    required this.summary,
    required this.added,
    required this.removed,
    required this.unifiedDiff,
    this.previousPath,
    this.binary = false,
    this.oversized = false,
    this.untracked = false,
  });

  final String path;
  final String summary;
  final int added;
  final int removed;
  final String unifiedDiff;
  final String? previousPath;
  final bool binary;
  final bool oversized;
  final bool untracked;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WorkspaceDiffRecord &&
        other.path == path &&
        other.summary == summary &&
        other.added == added &&
        other.removed == removed &&
        other.unifiedDiff == unifiedDiff &&
        other.previousPath == previousPath &&
        other.binary == binary &&
        other.oversized == oversized &&
        other.untracked == untracked;
  }

  @override
  int get hashCode => Object.hash(
        path,
        summary,
        added,
        removed,
        unifiedDiff,
        previousPath,
        binary,
        oversized,
        untracked,
      );
}

/// Task checklist item tracked inside the Session Workbench Progress tab.
@immutable
class SessionTodoRecord {
  const SessionTodoRecord({
    required this.id,
    required this.title,
    required this.done,
    this.active = false,
  });

  final String id;
  final String title;
  final bool done;
  final bool active;

  SessionTodoRecord copyWith({String? title, bool? done, bool? active}) => SessionTodoRecord(
        id: id,
        title: title ?? this.title,
        done: done ?? this.done,
        active: active ?? this.active,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SessionTodoRecord &&
        other.id == id &&
        other.title == title &&
        other.done == done &&
        other.active == active;
  }

  @override
  int get hashCode => Object.hash(id, title, done, active);
}

/// Long-term autonomous Goal managed in Session Workbench & `/gbridge/v1/sessions/:id/goals`.
@immutable
class SessionGoalRecord {
  const SessionGoalRecord({
    required this.id,
    required this.title,
    required this.criteria,
    required this.status, // active | paused | completed | blocked
    this.progressPct = 0,
    this.revision = 0,
    this.activation = 'armed', // armed | disarmed
    this.roundsStarted = 0,
    this.maxGoalRounds,
    this.blockedReasonCode,
    this.blockedReasonMessage,
  });

  factory SessionGoalRecord.fromJson(Map<String, dynamic> rawMap) {
    // Unwrap DSH `GoalProjection = { goal: GoalSnapshot, roundsStarted, createdAt, updatedAt }`
    // seamlessly alongside direct `GoalView` / `GoalSnapshot` maps!
    final nestedGoal = rawMap['goal'];
    final Map<String, dynamic> m = nestedGoal is Map
        ? {
            ...rawMap,
            ...Map<String, dynamic>.from(nestedGoal),
          }
        : rawMap;
    final rawObj = (m['title'] ?? m['objective'] ?? (nestedGoal is String ? nestedGoal : null) ?? m['text'] ?? '')
        .toString()
        .trim();
    var title = rawObj;
    var criteria = (m['criteria'] ?? m['description'] ?? '').toString().trim();
    if (criteria.isEmpty && rawObj.contains('\n验收标准：')) {
      final idx = rawObj.indexOf('\n验收标准：');
      title = rawObj.substring(0, idx).trim();
      criteria = rawObj.substring(idx + '\n验收标准：'.length).trim();
    }
    final roundsStarted = (m['roundsStarted'] as num?)?.toInt() ??
        (rawMap['roundsStarted'] as num?)?.toInt() ??
        0;
    final maxRoundsRaw = (m['maxGoalRounds'] as num?)?.toInt() ??
        (rawMap['maxGoalRounds'] as num?)?.toInt();
    final maxRounds = (maxRoundsRaw != null && maxRoundsRaw > 0) ? maxRoundsRaw : null;
    final rawStatus = (m['phase'] ?? m['status'] ?? 'active').toString().toLowerCase();
    final normStatus = rawStatus == 'complete' ? 'completed' : rawStatus;
    final activation = (m['activation']?.toString().toLowerCase() ??
            (normStatus == 'active' ? 'armed' : 'disarmed'))
        .trim();
    final blockedObj = m['blockedReason'];
    String? blockedCode = m['blockedReasonCode']?.toString();
    String? blockedMsg = m['blockedReasonMessage']?.toString();
    if (blockedObj is Map) {
      blockedCode ??= blockedObj['code']?.toString();
      blockedMsg ??= blockedObj['message']?.toString();
    } else if (blockedObj is String && blockedObj.trim().isNotEmpty) {
      blockedMsg ??= blockedObj.trim();
    }

    var pct = (m['progressPct'] as num?)?.toInt() ?? 0;
    if (pct == 0) {
      if (normStatus == 'completed') {
        pct = 100;
      } else if (maxRounds != null && maxRounds > 0 && roundsStarted > 0) {
        pct = ((roundsStarted / maxRounds) * 100).round().clamp(5, 95);
      }
    }
    return SessionGoalRecord(
      id: m['id']?.toString() ?? 'goal-active',
      title: title,
      criteria: criteria,
      status: normStatus,
      progressPct: pct,
      revision: (m['revision'] as num?)?.toInt() ?? 0,
      activation: activation.isEmpty ? 'armed' : activation,
      roundsStarted: roundsStarted,
      maxGoalRounds: maxRounds,
      blockedReasonCode: blockedCode,
      blockedReasonMessage: blockedMsg,
    );
  }

  final String id;
  final String title;
  final String criteria;
  final String status;
  final int progressPct;
  final int revision;
  final String activation;
  final int roundsStarted;
  final int? maxGoalRounds;
  final String? blockedReasonCode;
  final String? blockedReasonMessage;

  bool get isCompleted => status == 'completed';
  bool get isPaused => status == 'paused';
  bool get isBlocked => status == 'blocked';
  bool get isDisarmed => status == 'active' && activation == 'disarmed';
  bool get isArmed => status == 'active' && activation != 'disarmed';

  String get statusLabel {
    if (isCompleted) return '已达成';
    if (isBlocked) return '已阻塞';
    if (isPaused) return '已暂停';
    if (isDisarmed) return '待恢复';
    if (maxGoalRounds != null && maxGoalRounds! > 0) {
      return '第 $roundsStarted / $maxGoalRounds 轮';
    }
    return roundsStarted > 0 ? '已推进 $roundsStarted 轮' : '自主推进中';
  }

  SessionGoalRecord copyWith({
    String? title,
    String? criteria,
    String? status,
    int? progressPct,
    int? revision,
    String? activation,
    int? roundsStarted,
    int? maxGoalRounds,
    String? blockedReasonCode,
    String? blockedReasonMessage,
  }) =>
      SessionGoalRecord(
        id: id,
        title: title ?? this.title,
        criteria: criteria ?? this.criteria,
        status: status ?? this.status,
        progressPct: progressPct ?? this.progressPct,
        revision: revision ?? this.revision,
        activation: activation ?? this.activation,
        roundsStarted: roundsStarted ?? this.roundsStarted,
        maxGoalRounds: maxGoalRounds ?? this.maxGoalRounds,
        blockedReasonCode: blockedReasonCode ?? this.blockedReasonCode,
        blockedReasonMessage: blockedReasonMessage ?? this.blockedReasonMessage,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'criteria': criteria,
        'status': status,
        'progressPct': progressPct,
        'revision': revision,
        'activation': activation,
        'roundsStarted': roundsStarted,
        if (maxGoalRounds != null) 'maxGoalRounds': maxGoalRounds,
        if (blockedReasonCode != null) 'blockedReasonCode': blockedReasonCode,
        if (blockedReasonMessage != null) 'blockedReasonMessage': blockedReasonMessage,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SessionGoalRecord &&
        other.id == id &&
        other.title == title &&
        other.criteria == criteria &&
        other.status == status &&
        other.progressPct == progressPct &&
        other.revision == revision &&
        other.activation == activation &&
        other.roundsStarted == roundsStarted &&
        other.maxGoalRounds == maxGoalRounds &&
        other.blockedReasonCode == blockedReasonCode &&
        other.blockedReasonMessage == blockedReasonMessage;
  }

  @override
  int get hashCode => Object.hash(
        id,
        title,
        criteria,
        status,
        progressPct,
        revision,
        activation,
        roundsStarted,
        maxGoalRounds,
        blockedReasonCode,
        blockedReasonMessage,
      );
}

/// Subagent lineage & Agent Team task item.
@immutable
class SubagentItem {
  const SubagentItem({
    required this.id,
    required this.name,
    required this.role,
    required this.status, // running | completed | interrupted
    required this.taskSummary,
    required this.model,
    required this.durationLabel,
    this.outputPreview = '',
    this.worktreeBranch,
  });

  final String id;
  final String name;
  final String role;
  final String status;
  final String taskSummary;
  final String model;
  final String durationLabel;
  final String outputPreview;
  final String? worktreeBranch;

  SubagentItem copyWith({
    String? status,
    String? outputPreview,
    String? durationLabel,
  }) =>
      SubagentItem(
        id: id,
        name: name,
        role: role,
        status: status ?? this.status,
        taskSummary: taskSummary,
        model: model,
        durationLabel: durationLabel ?? this.durationLabel,
        outputPreview: outputPreview ?? this.outputPreview,
        worktreeBranch: worktreeBranch,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SubagentItem &&
        other.id == id &&
        other.name == name &&
        other.role == role &&
        other.status == status &&
        other.taskSummary == taskSummary &&
        other.model == model &&
        other.durationLabel == durationLabel &&
        other.outputPreview == outputPreview &&
        other.worktreeBranch == worktreeBranch;
  }

  @override
  int get hashCode => Object.hash(
        id,
        name,
        role,
        status,
        taskSummary,
        model,
        durationLabel,
        outputPreview,
        worktreeBranch,
      );
}

/// Background long-running shell/build job item (`ui-jobs`).
@immutable
class BackgroundJobRecord {
  const BackgroundJobRecord({
    required this.id,
    required this.command,
    required this.cwd,
    required this.status, // running | completed | killed
    required this.startedAtLabel,
    required this.outputLines,
    this.sessionId,
  });

  final String id;
  final String command;
  final String cwd;
  final String status;
  final String startedAtLabel;
  final List<String> outputLines;
  final String? sessionId;

  BackgroundJobRecord copyWith({
    String? status,
    List<String>? outputLines,
    String? sessionId,
  }) =>
      BackgroundJobRecord(
        id: id,
        command: command,
        cwd: cwd,
        status: status ?? this.status,
        startedAtLabel: startedAtLabel,
        outputLines: outputLines ?? this.outputLines,
        sessionId: sessionId ?? this.sessionId,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BackgroundJobRecord &&
        other.id == id &&
        other.command == command &&
        other.cwd == cwd &&
        other.status == status &&
        other.startedAtLabel == startedAtLabel &&
        other.sessionId == sessionId &&
        listEquals(other.outputLines, outputLines);
  }

  @override
  int get hashCode => Object.hash(
        id,
        command,
        cwd,
        status,
        startedAtLabel,
        sessionId,
        Object.hashAll(outputLines),
      );
}

/// Scheduled recurring automation task (`ui-schedule`).
@immutable
class ScheduleTaskRecord {
  const ScheduleTaskRecord({
    required this.id,
    required this.name,
    required this.cronExpr,
    required this.humanSchedule,
    required this.timezone,
    required this.prompt,
    required this.enabled,
    this.lastRunAt = '尚未运行',
    this.lastStatus = 'idle', // ok | error | running | idle
    this.history = const [],
    this.kind = 'cron',
    this.status = 'active', // active | paused | ended
    this.nextRunAt = '',
    this.executionActive = false,
  });

  static String _formatLocalIso(String raw) {
    final dt = DateTime.tryParse(raw.trim());
    if (dt == null) return raw.replaceFirst('T', ' ').split('.').first;
    final loc = dt.toLocal();
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${loc.year}-${p2(loc.month)}-${p2(loc.day)} ${p2(loc.hour)}:${p2(loc.minute)}';
  }

  factory ScheduleTaskRecord.fromJson(Map<String, dynamic> m) {
    final timing = m['timing'] is Map
        ? Map<String, dynamic>.from(m['timing'] as Map)
        : const <String, dynamic>{};
    final kind = (m['kind'] ?? timing['kind'] ?? 'cron').toString().toLowerCase();
    final tz = (m['timezone'] ??
            m['timeZone'] ??
            timing['timezone'] ??
            timing['timeZone'] ??
            'Asia/Shanghai')
        .toString();
    var cronExpr = (m['cronExpr'] ??
            m['expression'] ??
            timing['cron'] ??
            timing['expression'] ??
            '')
        .toString()
        .trim();
    var human = (m['humanSchedule'] ?? '').toString().trim();
    final everySecondsRaw = m['everySeconds'] ?? timing['everySeconds'] ?? timing['intervalSeconds'];
    final timeRaw = m['time'] ?? timing['time'] ?? timing['daily'];
    final afterSecondsRaw = m['afterSeconds'] ?? timing['afterSeconds'];
    final scheduledAtRaw = m['scheduledAt'] ?? timing['scheduledAt'] ?? timing['at'];
    final weekdaysRaw = m['weekdays'] ?? timing['weekdays'] ?? m['weekly'] ?? timing['weekly'] ?? timing['daysOfWeek'];
    final rruleRaw = m['rrule'] ?? timing['rrule'];
    if (cronExpr.isEmpty) {
      if (kind == 'every' && everySecondsRaw is num) {
        final sec = everySecondsRaw.toInt();
        cronExpr = 'every ${sec}s';
        if (human.isEmpty) {
          human = sec >= 3600
              ? '每 ${(sec / 3600).toStringAsFixed(sec % 3600 == 0 ? 0 : 1)} 小时'
              : (sec >= 60 ? '每 ${(sec / 60).round()} 分钟' : '每 $sec 秒');
        }
      } else if (kind == 'daily' && timeRaw != null) {
        final tStr = timeRaw.toString();
        cronExpr = 'daily $tStr';
        if (human.isEmpty) human = '每天 $tStr';
      } else if (kind == 'after' && afterSecondsRaw != null) {
        cronExpr = 'after ${afterSecondsRaw}s';
        if (human.isEmpty) human = '延迟 $afterSecondsRaw 秒后单次';
      } else if (kind == 'at' && scheduledAtRaw != null) {
        final fmt = _formatLocalIso(scheduledAtRaw.toString());
        cronExpr = fmt;
        if (human.isEmpty) human = '定时单次 · $fmt';
      } else if (kind == 'weekly') {
        final wDays = weekdaysRaw is List ? weekdaysRaw.join(',') : (weekdaysRaw?.toString() ?? '');
        final wTime = timeRaw?.toString() ?? '';
        cronExpr = 'weekly $wDays $wTime'.trim();
        if (human.isEmpty) human = '每周 ${wDays.isNotEmpty ? "$wDays " : ""}$wTime'.trim();
      } else if (kind == 'rrule' && rruleRaw != null) {
        cronExpr = rruleRaw.toString().trim();
        if (human.isEmpty) human = 'RRule · $cronExpr';
      } else {
        cronExpr = '0 9 * * *';
      }
    }
    if (human.isEmpty) {
      human = switch (cronExpr) {
        '0 9 * * *' => '每天 09:00',
        '0 9 * * 1-5' => '工作日 09:00',
        '*/30 * * * *' => '每 30 分钟',
        '0 18 * * 5' => '每周五 18:00',
        _ => 'Cron · $cronExpr',
      };
    }
    final statusStr = m['status']?.toString().toLowerCase() ?? '';
    final bool enabled;
    if (statusStr == 'ended') {
      enabled = false;
    } else if (m.containsKey('active') && m['active'] is bool) {
      enabled = m['active'] as bool;
    } else if (statusStr.isNotEmpty) {
      enabled = statusStr == 'active' || statusStr == 'running' || statusStr == 'scheduled';
    } else {
      enabled = m['enabled'] != false;
    }
    final normStatus = statusStr == 'ended'
        ? 'ended'
        : (enabled ? 'active' : 'paused');
    final nextRunAt = scheduledAtRaw != null && scheduledAtRaw.toString().trim().isNotEmpty
        ? _formatLocalIso(scheduledAtRaw.toString())
        : '';

    var lastRunAt = m['lastRunAt']?.toString() ?? '尚未运行';
    var lastStatus = m['lastStatus']?.toString() ?? 'idle';
    final lastDelivery = m['lastDelivery'];
    if (lastDelivery is Map) {
      final delivered = (lastDelivery['deliveredAt'] ?? lastDelivery['scheduledAt'])?.toString() ?? '';
      if (delivered.isNotEmpty) {
        lastRunAt = _formatLocalIso(delivered);
        final deliveryOk = lastDelivery['ok'];
        final deliveryErr = lastDelivery['error']?.toString() ?? '';
        lastStatus = (deliveryOk == false || deliveryErr.isNotEmpty) ? 'error' : 'ok';
      }
    } else if (statusStr == 'ended') {
      lastStatus = 'ok';
    } else if (statusStr == 'failed' || statusStr == 'error') {
      lastStatus = 'error';
    }

    return ScheduleTaskRecord(
      id: m['id']?.toString() ?? '',
      name: (m['name'] ?? m['title'] ?? '').toString(),
      cronExpr: cronExpr,
      humanSchedule: human,
      timezone: tz,
      prompt: m['prompt']?.toString() ?? '',
      enabled: enabled,
      lastRunAt: lastRunAt,
      lastStatus: lastStatus,
      history: (m['history'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList(growable: false) ??
          const [],
      kind: kind.isEmpty ? 'cron' : kind,
      status: normStatus,
      nextRunAt: nextRunAt,
      executionActive: m['executionActive'] == true,
    );
  }

  final String id;
  final String name;
  final String cronExpr;
  final String humanSchedule;
  final String timezone;
  final String prompt;
  final bool enabled;
  final String lastRunAt;
  final String lastStatus;
  final List<String> history;
  final String kind;
  final String status;
  final String nextRunAt;
  final bool executionActive;

  bool get isEnded => status == 'ended';

  ScheduleTaskRecord copyWith({
    String? name,
    String? cronExpr,
    String? humanSchedule,
    String? timezone,
    String? prompt,
    bool? enabled,
    String? lastRunAt,
    String? lastStatus,
    List<String>? history,
    String? kind,
    String? status,
    String? nextRunAt,
    bool? executionActive,
  }) =>
      ScheduleTaskRecord(
        id: id,
        name: name ?? this.name,
        cronExpr: cronExpr ?? this.cronExpr,
        humanSchedule: humanSchedule ?? this.humanSchedule,
        timezone: timezone ?? this.timezone,
        prompt: prompt ?? this.prompt,
        enabled: enabled ?? this.enabled,
        lastRunAt: lastRunAt ?? this.lastRunAt,
        lastStatus: lastStatus ?? this.lastStatus,
        history: history ?? this.history,
        kind: kind ?? this.kind,
        status: status ?? this.status,
        nextRunAt: nextRunAt ?? this.nextRunAt,
        executionActive: executionActive ?? this.executionActive,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'cronExpr': cronExpr,
        'humanSchedule': humanSchedule,
        'timezone': timezone,
        'prompt': prompt,
        'enabled': enabled,
        'lastRunAt': lastRunAt,
        'lastStatus': lastStatus,
        'history': history,
        'kind': kind,
        'status': status,
        'nextRunAt': nextRunAt,
        'executionActive': executionActive,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ScheduleTaskRecord &&
        other.id == id &&
        other.name == name &&
        other.cronExpr == cronExpr &&
        other.humanSchedule == humanSchedule &&
        other.timezone == timezone &&
        other.prompt == prompt &&
        other.enabled == enabled &&
        other.lastRunAt == lastRunAt &&
        other.lastStatus == lastStatus &&
        other.kind == kind &&
        other.status == status &&
        other.nextRunAt == nextRunAt &&
        other.executionActive == executionActive &&
        listEquals(other.history, history);
  }

  @override
  int get hashCode => Object.hash(
        id,
        name,
        cronExpr,
        humanSchedule,
        timezone,
        prompt,
        enabled,
        lastRunAt,
        lastStatus,
        kind,
        status,
        nextRunAt,
        executionActive,
        Object.hashAll(history),
      );
}

/// Plugin Market catalog entry with live install progress logs.
@immutable
class PluginMarketEntry {
  const PluginMarketEntry({
    required this.name,
    required this.displayName,
    required this.version,
    required this.desc,
    required this.author,
    this.installed = false,
    this.installing = false,
    this.installLogs = const [],
  });

  final String name;
  final String displayName;
  final String version;
  final String desc;
  final String author;
  final bool installed;
  final bool installing;
  final List<String> installLogs;

  PluginMarketEntry copyWith({
    bool? installed,
    bool? installing,
    List<String>? installLogs,
  }) =>
      PluginMarketEntry(
        name: name,
        displayName: displayName,
        version: version,
        desc: desc,
        author: author,
        installed: installed ?? this.installed,
        installing: installing ?? this.installing,
        installLogs: installLogs ?? this.installLogs,
      );
}

/// Dynamic Cordis runtime plugin entry (`ui-cordis`).
@immutable
class DynamicCordisEntry {
  const DynamicCordisEntry({
    required this.id,
    required this.name,
    required this.status, // running | stopped
    required this.description,
    this.capabilities = const [],
    this.agentId,
  });

  final String id;
  final String name;
  final String status;
  final String description;
  final List<String> capabilities;
  final String? agentId;

  DynamicCordisEntry copyWith({String? status}) => DynamicCordisEntry(
        id: id,
        name: name,
        status: status ?? this.status,
        description: description,
        capabilities: capabilities,
        agentId: agentId,
      );
}

/// Single question inside a `user-questions/request` interaction payload.
@immutable
class UserQuestionItem {
  const UserQuestionItem({
    required this.id,
    required this.title,
    required this.prompt,
    required this.options,
    this.optionDescriptions = const [],
    this.multiSelect = false,
    this.allowFreeText = true,
  });

  final String id;
  final String title;
  final String prompt;
  final List<String> options;
  final List<String> optionDescriptions;
  final bool multiSelect;
  final bool allowFreeText;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UserQuestionItem &&
        other.id == id &&
        other.title == title &&
        other.prompt == prompt &&
        other.multiSelect == multiSelect &&
        other.allowFreeText == allowFreeText &&
        listEquals(other.options, options) &&
        listEquals(other.optionDescriptions, optionDescriptions);
  }

  @override
  int get hashCode => Object.hash(
        id,
        title,
        prompt,
        multiSelect,
        allowFreeText,
        Object.hashAll(options),
        Object.hashAll(optionDescriptions),
      );
}

/// Interactive question prompt (`user-questions/request`) or Cordis run confirmation
/// that smoothly takes over the bottom floating composer capsule.
@immutable
class ActiveUserQuestion {
  const ActiveUserQuestion({
    required this.interactionId,
    required this.title,
    required this.prompt,
    required this.options,
    this.multiSelect = false,
    this.allowFreeText = true,
    this.questionId,
    this.sessionId,
    this.optionDescriptions = const [],
    this.questions = const [],
  });

  final String interactionId;
  final String title;
  final String prompt;
  final List<String> options;
  final bool multiSelect;
  final bool allowFreeText;
  final String? questionId;
  final String? sessionId;
  final List<String> optionDescriptions;
  final List<UserQuestionItem> questions;

  List<UserQuestionItem> get allQuestions => questions.isNotEmpty
      ? questions
      : [
          UserQuestionItem(
            id: questionId ?? 'q1',
            title: title,
            prompt: prompt,
            options: options,
            optionDescriptions: optionDescriptions,
            multiSelect: multiSelect,
            allowFreeText: allowFreeText,
          ),
        ];

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ActiveUserQuestion &&
        other.interactionId == interactionId &&
        other.title == title &&
        other.prompt == prompt &&
        other.multiSelect == multiSelect &&
        other.allowFreeText == allowFreeText &&
        other.questionId == questionId &&
        other.sessionId == sessionId &&
        listEquals(other.options, options) &&
        listEquals(other.optionDescriptions, optionDescriptions) &&
        listEquals(other.questions, questions);
  }

  @override
  int get hashCode => Object.hash(
        interactionId,
        title,
        prompt,
        multiSelect,
        allowFreeText,
        questionId,
        sessionId,
        Object.hashAll(options),
        Object.hashAll(optionDescriptions),
        Object.hashAll(questions),
      );
}

@immutable
class ActiveCordisRunRequest {
  const ActiveCordisRunRequest({
    required this.interactionId,
    required this.pluginName,
    required this.summary,
    required this.codePreview,
    this.sessionId,
  });

  final String interactionId;
  final String pluginName;
  final String summary;
  final String codePreview;
  final String? sessionId;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ActiveCordisRunRequest &&
        other.interactionId == interactionId &&
        other.pluginName == pluginName &&
        other.summary == summary &&
        other.codePreview == codePreview &&
        other.sessionId == sessionId;
  }

  @override
  int get hashCode => Object.hash(interactionId, pluginName, summary, codePreview, sessionId);
}

/// Live `@deepseek-ai/dsh@0.2.2-rc.5` Schemastery settings namespace descriptor.
@immutable
class DshSettingsNamespace {
  const DshSettingsNamespace({
    required this.ns,
    required this.title,
    required this.group,
    required this.subtitle,
    required this.schema,
    required this.value,
    this.revision = 0,
    this.writable = true,
    this.secrets = const [],
  });

  final String ns;
  final String title;
  final String group;
  final String subtitle;
  final Map<String, dynamic> schema;
  final Map<String, dynamic> value;
  final int revision;
  final bool writable;
  final List<String> secrets;

  DshSettingsNamespace copyWith({
    Map<String, dynamic>? value,
    int? revision,
    Map<String, dynamic>? schema,
  }) =>
      DshSettingsNamespace(
        ns: ns,
        title: title,
        group: group,
        subtitle: subtitle,
        schema: schema ?? this.schema,
        value: value ?? this.value,
        revision: revision ?? this.revision,
        writable: writable,
        secrets: secrets,
      );
}

/// External LLM provider & API credential entry backed by `/gbridge/v1/providers` & `/credentials`.
@immutable
class ProviderCredentialItem {
  const ProviderCredentialItem({
    required this.id,
    required this.name,
    required this.settingsNs,
    required this.envRef,
    required this.baseUrl,
    required this.configured,
    this.maskedKey = '',
    this.modelsCount = 0,
    this.description = '',
    this.isBuiltin = false,
  });

  final String id;
  final String name;
  final String settingsNs;
  final String envRef;
  final String baseUrl;
  final bool configured;
  final String maskedKey;
  final int modelsCount;
  final String description;
  final bool isBuiltin;

  ProviderCredentialItem copyWith({
    String? baseUrl,
    bool? configured,
    String? maskedKey,
    int? modelsCount,
    bool? isBuiltin,
  }) =>
      ProviderCredentialItem(
        id: id,
        name: name,
        settingsNs: settingsNs,
        envRef: envRef,
        baseUrl: baseUrl ?? this.baseUrl,
        configured: configured ?? this.configured,
        maskedKey: maskedKey ?? this.maskedKey,
        modelsCount: modelsCount ?? this.modelsCount,
        description: description,
        isBuiltin: isBuiltin ?? this.isBuiltin,
      );
}

/// Live MCP server managed by DSH `mcp-manager` (`/gbridge/v1/mcp`).
@immutable
class McpServerItem {
  const McpServerItem({
    required this.name,
    required this.transport,
    required this.status, // connected | stopped | error | probing
    required this.endpoint,
    this.toolsCount = 0,
    this.lastLatencyMs,
  });

  final String name;
  final String transport;
  final String status;
  final String endpoint;
  final int toolsCount;
  final int? lastLatencyMs;

  McpServerItem copyWith({
    String? status,
    int? toolsCount,
    int? lastLatencyMs,
  }) =>
      McpServerItem(
        name: name,
        transport: transport,
        status: status ?? this.status,
        endpoint: endpoint,
        toolsCount: toolsCount ?? this.toolsCount,
        lastLatencyMs: lastLatencyMs ?? this.lastLatencyMs,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is McpServerItem &&
        other.name == name &&
        other.transport == transport &&
        other.status == status &&
        other.endpoint == endpoint &&
        other.toolsCount == toolsCount &&
        other.lastLatencyMs == lastLatencyMs;
  }

  @override
  int get hashCode => Object.hash(name, transport, status, endpoint, toolsCount, lastLatencyMs);
}

/// On-device Ubuntu Linux container extension toolkit package.
@immutable
class ContainerToolkitItem {
  const ContainerToolkitItem({
    required this.id,
    required this.name,
    required this.desc,
    required this.packages,
    required this.sizeLabel,
    this.installed = false,
    this.installing = false,
  });

  final String id;
  final String name;
  final String desc;
  final List<String> packages;
  final String sizeLabel;
  final bool installed;
  final bool installing;

  ContainerToolkitItem copyWith({bool? installed, bool? installing}) => ContainerToolkitItem(
        id: id,
        name: name,
        desc: desc,
        packages: packages,
        sizeLabel: sizeLabel,
        installed: installed ?? this.installed,
        installing: installing ?? this.installing,
      );
}

/// Fine-grained lifecycle stage of an in-flight user message before the first token arrives.
enum SendStage {
  idle,
  creatingSession,
  uploadingAttachments,
  sending,
  awaitingFirstToken,
}

/// Pending user prompt queued while the agent is streaming (`session/updateQueue`).
@immutable
class QueuedMessageItem {
  const QueuedMessageItem({
    required this.id,
    required this.text,
    required this.mode, // queue | steer
    this.serverAcked = false,
  });

  final String id;
  final String text;
  final String mode;
  final bool serverAcked;

  QueuedMessageItem copyWith({
    String? id,
    String? text,
    String? mode,
    bool? serverAcked,
  }) =>
      QueuedMessageItem(
        id: id ?? this.id,
        text: text ?? this.text,
        mode: mode ?? this.mode,
        serverAcked: serverAcked ?? this.serverAcked,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is QueuedMessageItem &&
        other.id == id &&
        other.text == text &&
        other.mode == mode &&
        other.serverAcked == serverAcked;
  }

  @override
  int get hashCode => Object.hash(id, text, mode, serverAcked);
}

/// Real reasoning effort option from DSH `session/modelCatalog`.
@immutable
class ModelEffortOption {
  const ModelEffortOption({
    required this.id,
    required this.name,
    this.description = '',
  });

  factory ModelEffortOption.fromJson(Map<String, dynamic> m) => ModelEffortOption(
        id: m['id']?.toString() ?? 'high',
        name: m['name']?.toString() ?? m['id']?.toString() ?? 'High',
        description: m['description']?.toString() ?? '',
      );

  final String id;
  final String name;
  final String description;

  String get zhLabel => switch (id.toLowerCase()) {
        'off' || 'none' => '关闭',
        'minimal' => '极轻',
        'low' => '低',
        'medium' || 'mid' => '中',
        'high' => '高',
        'xhigh' || 'very_high' || 'very-high' => '超高',
        'max' => '极高',
        _ => name,
      };

  /// Concise Chinese description shown in iOS Liquid Glass thinking-effort menus.
  String get zhSubtitle {
    final raw = description.trim();
    if (raw.isNotEmpty) return raw;
    return switch (id.toLowerCase()) {
      'off' || 'none' => '直接输出，响应最快',
      'minimal' => '极简推理，低延迟直答',
      'low' => '轻度思考，日常对话高效',
      'medium' || 'mid' => '均衡速度与推理质量',
      'high' => '深度分析，复杂任务推荐',
      'xhigh' || 'very_high' || 'very-high' => '多步严密推演，攻克难题',
      'max' => '极限思考预算，最高精度',
      'auto' => '按问题复杂度自动调节',
      _ => '调整当前模型的思考深度',
    };
  }

  /// Normalized 0..4 visual depth level for iOS-style effort intensity bars.
  int get depthLevel => switch (id.toLowerCase()) {
        'off' || 'none' => 0,
        'minimal' || 'low' => 1,
        'medium' || 'mid' || 'auto' => 2,
        'high' => 3,
        'xhigh' || 'very_high' || 'very-high' || 'max' => 4,
        _ => 2,
      };
}

/// Real model entry from DSH `session/modelCatalog`.
@immutable
class ModelCatalogEntry {
  const ModelCatalogEntry({
    required this.id,
    required this.name,
    required this.providerId,
    required this.providerName,
    this.description = '',
    this.efforts = const [],
    this.defaultEffort = '',
    this.contextWindow,
    this.maxTokens,
    this.inputModalities = const ['text'],
  });

  final String id;
  final String name;
  final String providerId;
  final String providerName;
  final String description;
  final List<ModelEffortOption> efforts;
  final String defaultEffort;
  final int? contextWindow;
  final int? maxTokens;
  final List<String> inputModalities;

  bool get supportsReasoning => efforts.isNotEmpty;
  bool get supportsImage => inputModalities.any((m) => m.toLowerCase().contains('image'));

  String get shortLabel {
    final clean = name.trim();
    final tail = clean.contains('/') ? clean.split('/').last.trim() : clean;
    return tail.length <= 28 ? tail : '${tail.substring(0, 27)}…';
  }
}

/// Real provider group from DSH `session/modelCatalog`.
@immutable
class ModelCatalogGroup {
  const ModelCatalogGroup({
    required this.id,
    required this.name,
    required this.models,
    this.routable = true,
  });

  final String id;
  final String name;
  final List<ModelCatalogEntry> models;
  final bool routable;
}

/// Dynamic DSH Settings Section returned by `GET /gbridge/v1/settings/manifest`,
/// mirroring the live DSH host's loaded plugins & namespaces instead of a hardcoded menu.
@immutable
class DshSettingsSectionManifest {
  const DshSettingsSectionManifest({
    required this.id,
    required this.group,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.order,
    this.namespaces = const [],
  });

  factory DshSettingsSectionManifest.fromJson(Map<String, dynamic> m) =>
      DshSettingsSectionManifest(
        id: m['id']?.toString() ?? '',
        group: m['group']?.toString() ?? 'dsh',
        title: m['title']?.toString() ?? '',
        subtitle: m['subtitle']?.toString() ?? '',
        icon: m['icon']?.toString() ?? 'sliders',
        order: (m['order'] as num?)?.toInt() ?? 50,
        namespaces: (m['namespaces'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .where((s) => s.isNotEmpty)
                .toList(growable: false) ??
            const [],
      );

  final String id;
  final String group; // dsh | dsh-capabilities
  final String title;
  final String subtitle;
  final String icon;
  final int order;
  final List<String> namespaces;
}

/// Live dynamic option for a DSH schema field (from `/settings/manifest` `dynamicOptions`).
@immutable
class DshDynamicOption {
  const DshDynamicOption({
    required this.value,
    required this.label,
    this.description = '',
  });

  factory DshDynamicOption.fromJson(Map<String, dynamic> m) => DshDynamicOption(
        value: m['value']?.toString() ?? '',
        label: m['label']?.toString() ?? m['value']?.toString() ?? '',
        description: m['description']?.toString() ?? '',
      );

  final String value;
  final String label;
  final String description;
}

/// Real npm update check snapshot from `GET /gbridge/v1/system/check-update`.
@immutable
class DshUpdateCheckResult {
  const DshUpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    this.nextVersion,
    required this.recommendedVersion,
    required this.hasUpdate,
    this.checkedAt,
    this.error,
  });

  factory DshUpdateCheckResult.fromJson(Map<String, dynamic> m) {
    final cur = m['currentVersion']?.toString() ?? '';
    final lat = m['latestVersion']?.toString() ?? cur;
    return DshUpdateCheckResult(
      currentVersion: cur,
      latestVersion: lat,
      nextVersion: m['nextVersion']?.toString(),
      recommendedVersion: m['recommendedVersion']?.toString() ?? lat,
      hasUpdate: m['hasUpdate'] == true,
      checkedAt: (m['checkedAt'] as num?)?.toInt(),
      error: m['error']?.toString(),
    );
  }

  final String currentVersion;
  final String latestVersion;
  final String? nextVersion;
  final String recommendedVersion;
  final bool hasUpdate;
  final int? checkedAt;
  final String? error;
}

/// Captured real error event for tappable error detail inspection & diagnostics log.
@immutable
class AppErrorRecord {
  const AppErrorRecord({
    required this.id,
    required this.summary,
    required this.detail,
    required this.timestamp,
  });

  final int id;
  final String summary;
  final String detail;
  final DateTime timestamp;
}

/// Per-model / per-provider token usage group from DSH `projections.values.commandCodeCost.groups`.
@immutable
class ModelUsageGroup {
  const ModelUsageGroup({
    required this.provider,
    required this.model,
    this.uncachedInputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.contextTokens = 0,
  });

  factory ModelUsageGroup.fromJson(Map<String, dynamic> m) {
    final tok = m['tokens'] is Map ? Map<String, dynamic>.from(m['tokens'] as Map) : const <String, dynamic>{};
    return ModelUsageGroup(
      provider: m['provider']?.toString() ?? '',
      model: m['model']?.toString() ?? '',
      uncachedInputTokens: (tok['uncachedInputTokens'] as num?)?.toInt() ??
          (tok['inputTokens'] as num?)?.toInt() ??
          0,
      outputTokens: (tok['outputTokens'] as num?)?.toInt() ?? 0,
      cacheReadTokens: (tok['cacheReadTokens'] as num?)?.toInt() ?? 0,
      cacheWriteTokens: (tok['cacheWriteTokens'] as num?)?.toInt() ?? 0,
      contextTokens: (m['contextTokens'] as num?)?.toInt() ?? 0,
    );
  }

  final String provider;
  final String model;
  final int uncachedInputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int contextTokens;

  int get totalInputTokens => uncachedInputTokens + cacheReadTokens + cacheWriteTokens;
  int get totalTokens => totalInputTokens + outputTokens;

  double? get cacheHitRate =>
      totalInputTokens > 0 ? (cacheReadTokens / totalInputTokens).clamp(0.0, 1.0) : null;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ModelUsageGroup &&
        other.provider == provider &&
        other.model == model &&
        other.uncachedInputTokens == uncachedInputTokens &&
        other.outputTokens == outputTokens &&
        other.cacheReadTokens == cacheReadTokens &&
        other.cacheWriteTokens == cacheWriteTokens &&
        other.contextTokens == contextTokens;
  }

  @override
  int get hashCode => Object.hash(
        provider,
        model,
        uncachedInputTokens,
        outputTokens,
        cacheReadTokens,
        cacheWriteTokens,
        contextTokens,
      );
}

/// Full real-time session telemetry parsed from DSH 0.2.x `projections.values`
/// (`tokenUsage`, `sessionStats`, `contextPressure`, `contextBreakdown`,
/// `commandCodeCost`, `modelSelection`, `subagentTiming`) + live stream `activity`.
@immutable
class SessionTelemetry {
  const SessionTelemetry({
    this.uncachedInputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.turnsCount = 0,
    this.stepsCount = 0,
    this.llmMs = 0,
    this.toolMs = 0,
    this.ttftMs = 0,
    this.ttftSteps = 0,
    this.decodeMs = 0,
    this.decodeTokens = 0,
    this.liveTps,
    this.livePhase,
    this.liveElapsedMs,
    this.pressureTokens = 0,
    this.projectedTokens = 0,
    this.contextWindow = 0,
    this.systemTokens = 0,
    this.toolsTokens = 0,
    this.messageTokens = 0,
    this.modelGroups = const [],
    this.summaryInputTokens = 0,
    this.summaryOutputTokens = 0,
    this.summaryCacheReadTokens = 0,
    this.lastProvider = '',
    this.lastModel = '',
    this.lastEffort = '',
    this.workingDirectory = '',
    this.subagentSettledMs = 0,
    this.asOfSeq = 0,
  });

  final int uncachedInputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  final int turnsCount;
  final int stepsCount;
  final int llmMs;
  final int toolMs;
  final int ttftMs;
  final int ttftSteps;
  final int decodeMs;
  final int decodeTokens;

  final double? liveTps;
  final String? livePhase;
  final int? liveElapsedMs;

  final int pressureTokens;
  final int projectedTokens;
  final int contextWindow;
  final int systemTokens;
  final int toolsTokens;
  final int messageTokens;

  final List<ModelUsageGroup> modelGroups;
  final int summaryInputTokens;
  final int summaryOutputTokens;
  final int summaryCacheReadTokens;

  final String lastProvider;
  final String lastModel;
  final String lastEffort;
  final String workingDirectory;
  final int subagentSettledMs;
  final int asOfSeq;

  int get totalInputTokens => uncachedInputTokens + cacheReadTokens + cacheWriteTokens;
  int get totalTokens => totalInputTokens + outputTokens;

  /// Cache read hit ratio over total input tokens (`0.0` .. `1.0`).
  double? get cacheHitRate =>
      totalInputTokens > 0 ? (cacheReadTokens / totalInputTokens).clamp(0.0, 1.0) : null;

  /// Average decode throughput in tokens/sec from authoritative DSH `sessionStats`.
  double? get decodeTps =>
      decodeMs > 0 && decodeTokens > 0 ? decodeTokens / (decodeMs / 1000.0) : null;

  /// Active speed to highlight in KPIs: live streaming speed when streaming, else session average.
  double? get effectiveTps => liveTps ?? decodeTps;

  /// Average Time-To-First-Token in milliseconds across LLM steps.
  int? get avgTtftMs => ttftSteps > 0 && ttftMs > 0 ? (ttftMs / ttftSteps).round() : null;

  int get totalActiveMs => llmMs + toolMs;

  int get otherContextTokens {
    final known = systemTokens + toolsTokens + messageTokens;
    return pressureTokens > known ? pressureTokens - known : 0;
  }

  int get remainingContextTokens =>
      pressureTokens > 0 && contextWindow > pressureTokens ? contextWindow - pressureTokens : 0;

  bool get hasAnyData =>
      totalTokens > 0 ||
      stepsCount > 0 ||
      llmMs > 0 ||
      pressureTokens > 0 ||
      liveTps != null ||
      modelGroups.isNotEmpty;

  SessionTelemetry copyWith({
    int? uncachedInputTokens,
    int? outputTokens,
    int? cacheReadTokens,
    int? cacheWriteTokens,
    int? turnsCount,
    int? stepsCount,
    int? llmMs,
    int? toolMs,
    int? ttftMs,
    int? ttftSteps,
    int? decodeMs,
    int? decodeTokens,
    double? liveTps,
    String? livePhase,
    int? liveElapsedMs,
    bool clearLive = false,
    int? pressureTokens,
    int? projectedTokens,
    int? contextWindow,
    int? systemTokens,
    int? toolsTokens,
    int? messageTokens,
    List<ModelUsageGroup>? modelGroups,
    int? summaryInputTokens,
    int? summaryOutputTokens,
    int? summaryCacheReadTokens,
    String? lastProvider,
    String? lastModel,
    String? lastEffort,
    String? workingDirectory,
    int? subagentSettledMs,
    int? asOfSeq,
  }) {
    return SessionTelemetry(
      uncachedInputTokens: uncachedInputTokens ?? this.uncachedInputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      cacheReadTokens: cacheReadTokens ?? this.cacheReadTokens,
      cacheWriteTokens: cacheWriteTokens ?? this.cacheWriteTokens,
      turnsCount: turnsCount ?? this.turnsCount,
      stepsCount: stepsCount ?? this.stepsCount,
      llmMs: llmMs ?? this.llmMs,
      toolMs: toolMs ?? this.toolMs,
      ttftMs: ttftMs ?? this.ttftMs,
      ttftSteps: ttftSteps ?? this.ttftSteps,
      decodeMs: decodeMs ?? this.decodeMs,
      decodeTokens: decodeTokens ?? this.decodeTokens,
      liveTps: clearLive ? null : (liveTps ?? this.liveTps),
      livePhase: clearLive ? null : (livePhase ?? this.livePhase),
      liveElapsedMs: clearLive ? null : (liveElapsedMs ?? this.liveElapsedMs),
      pressureTokens: pressureTokens ?? this.pressureTokens,
      projectedTokens: projectedTokens ?? this.projectedTokens,
      contextWindow: contextWindow ?? this.contextWindow,
      systemTokens: systemTokens ?? this.systemTokens,
      toolsTokens: toolsTokens ?? this.toolsTokens,
      messageTokens: messageTokens ?? this.messageTokens,
      modelGroups: modelGroups ?? this.modelGroups,
      summaryInputTokens: summaryInputTokens ?? this.summaryInputTokens,
      summaryOutputTokens: summaryOutputTokens ?? this.summaryOutputTokens,
      summaryCacheReadTokens: summaryCacheReadTokens ?? this.summaryCacheReadTokens,
      lastProvider: lastProvider ?? this.lastProvider,
      lastModel: lastModel ?? this.lastModel,
      lastEffort: lastEffort ?? this.lastEffort,
      workingDirectory: workingDirectory ?? this.workingDirectory,
      subagentSettledMs: subagentSettledMs ?? this.subagentSettledMs,
      asOfSeq: asOfSeq ?? this.asOfSeq,
    );
  }

  /// Parse from DSH `projections` payload (either `{values: {...}, asOfSeq}` or flat `{...}`).
  static SessionTelemetry fromProjections(
    Map<String, dynamic> rawProj, {
    SessionTelemetry? base,
    List<NormalizedTurn> fallbackTurns = const [],
  }) {
    final Map<Object?, Object?> vals =
        rawProj['values'] is Map ? rawProj['values'] as Map<Object?, Object?> : rawProj;
    final asOfSeq = (rawProj['asOfSeq'] as num?)?.toInt() ?? base?.asOfSeq ?? 0;

    final tok = vals['tokenUsage'] is Map ? vals['tokenUsage'] as Map<Object?, Object?> : null;
    var uncachedIn = (tok?['uncachedInputTokens'] as num?)?.toInt() ??
        (tok?['inputTokens'] as num?)?.toInt() ??
        base?.uncachedInputTokens ??
        0;
    var outTok = (tok?['outputTokens'] as num?)?.toInt() ?? base?.outputTokens ?? 0;
    var cacheRead = (tok?['cacheReadTokens'] as num?)?.toInt() ?? base?.cacheReadTokens ?? 0;
    var cacheWrite = (tok?['cacheWriteTokens'] as num?)?.toInt() ?? base?.cacheWriteTokens ?? 0;

    if (tok == null && uncachedIn == 0 && outTok == 0 && cacheRead == 0 && fallbackTurns.isNotEmpty) {
      for (final t in fallbackTurns) {
        final u = t.usage;
        if (u == null) continue;
        uncachedIn += u.inputTokens;
        outTok += u.outputTokens;
        cacheRead += u.cacheReadTokens ?? 0;
        cacheWrite += u.cacheWriteTokens ?? 0;
      }
    }

    final stats = vals['sessionStats'] is Map ? vals['sessionStats'] as Map<Object?, Object?> : null;
    final cp = vals['contextPressure'] is Map ? vals['contextPressure'] as Map<Object?, Object?> : null;
    final cb = vals['contextBreakdown'] is Map ? vals['contextBreakdown'] as Map<Object?, Object?> : null;
    final cost = vals['commandCodeCost'] is Map ? vals['commandCodeCost'] as Map<Object?, Object?> : null;
    final ms = vals['modelSelection'] is Map ? vals['modelSelection'] as Map<Object?, Object?> : null;
    final lastUsed = ms?['lastUsed'] is Map
        ? ms!['lastUsed'] as Map<Object?, Object?>
        : (ms?['next'] is Map ? ms!['next'] as Map<Object?, Object?> : null);
    final subTiming = vals['subagentTiming'] is Map
        ? vals['subagentTiming'] as Map<Object?, Object?>
        : null;

    final groups = <ModelUsageGroup>[];
    if (cost?['groups'] is List) {
      for (final g in cost!['groups'] as List) {
        if (g is Map<String, dynamic>) {
          groups.add(ModelUsageGroup.fromJson(g));
        } else if (g is Map) {
          groups.add(ModelUsageGroup.fromJson(Map<String, dynamic>.from(g)));
        }
      }
    }
    final summaryTok = cost?['summaryTokens'] is Map
        ? cost!['summaryTokens'] as Map<Object?, Object?>
        : null;

    return (base ?? const SessionTelemetry()).copyWith(
      uncachedInputTokens: uncachedIn,
      outputTokens: outTok,
      cacheReadTokens: cacheRead,
      cacheWriteTokens: cacheWrite,
      turnsCount: (stats?['turns'] as num?)?.toInt() ??
          (fallbackTurns.isNotEmpty ? fallbackTurns.length : base?.turnsCount ?? 0),
      stepsCount: (stats?['steps'] as num?)?.toInt() ?? base?.stepsCount ?? 0,
      llmMs: (stats?['llmMs'] as num?)?.toInt() ?? base?.llmMs ?? 0,
      toolMs: (stats?['toolMs'] as num?)?.toInt() ?? base?.toolMs ?? 0,
      ttftMs: (stats?['ttftMs'] as num?)?.toInt() ?? base?.ttftMs ?? 0,
      ttftSteps: (stats?['ttftSteps'] as num?)?.toInt() ?? base?.ttftSteps ?? 0,
      decodeMs: (stats?['decodeMs'] as num?)?.toInt() ?? base?.decodeMs ?? 0,
      decodeTokens: (stats?['decodeTokens'] as num?)?.toInt() ?? base?.decodeTokens ?? 0,
      pressureTokens: (cp?['pressureTokens'] as num?)?.toInt() ?? base?.pressureTokens ?? 0,
      projectedTokens: (cp?['projectedTokens'] as num?)?.toInt() ?? base?.projectedTokens ?? 0,
      contextWindow: (cp?['contextWindow'] as num?)?.toInt() ?? base?.contextWindow ?? 0,
      systemTokens: (cb?['systemTokens'] as num?)?.toInt() ?? base?.systemTokens ?? 0,
      toolsTokens: (cb?['toolsTokens'] as num?)?.toInt() ?? base?.toolsTokens ?? 0,
      messageTokens: (cb?['messageTokens'] as num?)?.toInt() ?? base?.messageTokens ?? 0,
      modelGroups: groups.isNotEmpty ? groups : (base?.modelGroups ?? const []),
      summaryInputTokens: (summaryTok?['uncachedInputTokens'] as num?)?.toInt() ??
          base?.summaryInputTokens ??
          0,
      summaryOutputTokens: (summaryTok?['outputTokens'] as num?)?.toInt() ??
          base?.summaryOutputTokens ??
          0,
      summaryCacheReadTokens: (summaryTok?['cacheReadTokens'] as num?)?.toInt() ??
          base?.summaryCacheReadTokens ??
          0,
      lastProvider: lastUsed?['provider']?.toString() ?? base?.lastProvider ?? '',
      lastModel: lastUsed?['model']?.toString() ?? base?.lastModel ?? '',
      lastEffort: lastUsed?['reasoningEffort']?.toString() ?? base?.lastEffort ?? '',
      workingDirectory: vals['workingDirectory']?.toString() ?? base?.workingDirectory ?? '',
      subagentSettledMs: (subTiming?['settledMs'] as num?)?.toInt() ?? base?.subagentSettledMs ?? 0,
      asOfSeq: asOfSeq,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SessionTelemetry &&
        other.uncachedInputTokens == uncachedInputTokens &&
        other.outputTokens == outputTokens &&
        other.cacheReadTokens == cacheReadTokens &&
        other.cacheWriteTokens == cacheWriteTokens &&
        other.turnsCount == turnsCount &&
        other.stepsCount == stepsCount &&
        other.llmMs == llmMs &&
        other.toolMs == toolMs &&
        other.ttftMs == ttftMs &&
        other.ttftSteps == ttftSteps &&
        other.decodeMs == decodeMs &&
        other.decodeTokens == decodeTokens &&
        other.liveTps == liveTps &&
        other.livePhase == livePhase &&
        other.liveElapsedMs == liveElapsedMs &&
        other.pressureTokens == pressureTokens &&
        other.projectedTokens == projectedTokens &&
        other.contextWindow == contextWindow &&
        other.systemTokens == systemTokens &&
        other.toolsTokens == toolsTokens &&
        other.messageTokens == messageTokens &&
        listEquals(other.modelGroups, modelGroups) &&
        other.summaryInputTokens == summaryInputTokens &&
        other.summaryOutputTokens == summaryOutputTokens &&
        other.summaryCacheReadTokens == summaryCacheReadTokens &&
        other.lastProvider == lastProvider &&
        other.lastModel == lastModel &&
        other.lastEffort == lastEffort &&
        other.workingDirectory == workingDirectory &&
        other.subagentSettledMs == subagentSettledMs &&
        other.asOfSeq == asOfSeq;
  }

  @override
  int get hashCode => Object.hashAll([
        uncachedInputTokens,
        outputTokens,
        cacheReadTokens,
        cacheWriteTokens,
        turnsCount,
        stepsCount,
        llmMs,
        toolMs,
        ttftMs,
        ttftSteps,
        decodeMs,
        decodeTokens,
        liveTps,
        livePhase,
        liveElapsedMs,
        pressureTokens,
        projectedTokens,
        contextWindow,
        systemTokens,
        toolsTokens,
        messageTokens,
        Object.hashAll(modelGroups),
        summaryInputTokens,
        summaryOutputTokens,
        summaryCacheReadTokens,
        lastProvider,
        lastModel,
        lastEffort,
        workingDirectory,
        subagentSettledMs,
        asOfSeq,
      ]);
}

/// Human-friendly compact token count (`80.1M`, `299.3K`, `1,414` -> `1.4K`, `967`).
String formatCompactTokens(int tokens) {
  if (tokens >= 100000000) return '${(tokens / 1000000).toStringAsFixed(0)}M';
  if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(1)}M';
  if (tokens >= 100000) return '${(tokens / 1000).toStringAsFixed(0)}K';
  if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(1)}K';
  return '$tokens';
}

/// Exact integer formatted with thousands separators (`80,105,344`).
String formatExactInt(int n) {
  final neg = n < 0;
  final s = n.abs().toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return neg ? '-$buf' : buf.toString();
}

/// Human-friendly duration (`681ms`, `2.9s`, `1m 24s`, `1h 29m`).
String formatDurationMs(int ms) {
  if (ms <= 0) return '--';
  if (ms < 1000) return '${ms}ms';
  final secs = ms / 1000.0;
  if (secs < 60) return '${secs.toStringAsFixed(secs < 10 ? 2 : 1)}s';
  final totalSec = secs.round();
  final h = totalSec ~/ 3600;
  final m = (totalSec % 3600) ~/ 60;
  final s = totalSec % 60;
  if (h > 0) return '${h}h ${m}m';
  return s > 0 ? '${m}m ${s}s' : '${m}m';
}
