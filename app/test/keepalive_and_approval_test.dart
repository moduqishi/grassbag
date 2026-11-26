import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassbag/services/native_bridge.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/theme/grassbag_theme.dart';
import 'package:grassbag/ui/common/grassbag_sheets.dart';

const _runningJob1 = BackgroundJobRecord(
  id: 'job-1',
  command: 'npm test',
  cwd: '/workspace',
  status: 'running',
  startedAtLabel: '20:00',
  outputLines: <String>[],
);

const _runningJob2 = BackgroundJobRecord(
  id: 'job-2',
  command: 'flutter build',
  cwd: '/workspace',
  status: 'running',
  startedAtLabel: '20:01',
  outputLines: <String>[],
);

void main() {
  group('GrassBagController.computeAndroidKeepalivePlan', () {
    test('prioritizes active phone control with WakeLock + WifiLock', () {
      const base = GrassBagAppState(
        phoneLiveActive: true,
        phoneLiveSteps: 3,
        phoneLiveApp: '计算器',
        isStreaming: true,
        jobs: [_runningJob1, _runningJob2],
      );
      final plan = GrassBagController.computeAndroidKeepalivePlan(
        base,
        runningSessionsCount: 1,
      );
      expect(plan.managedByBootstrap, isFalse);
      expect(plan.shouldRun, isTrue);
      expect(plan.needsWakeLock, isTrue);
      expect(plan.title, contains('操控手机'));
      expect(plan.detail, contains('第 3 步'));
      expect(plan.detail, contains('计算器'));
    });

    test('holds active WakeLock during streaming replies even on remote host', () {
      const base = GrassBagAppState(
        isStreaming: true,
        nativeRuntimeStatus: NativeRuntimeStatus(engineRunning: false),
      );
      final plan = GrassBagController.computeAndroidKeepalivePlan(
        base,
        runningSessionsCount: 0,
      );
      expect(plan.shouldRun, isTrue);
      expect(plan.needsWakeLock, isTrue);
      expect(plan.title, contains('生成回复'));
    });

    test('holds active WakeLock when awaiting user approval or question', () {
      const base = GrassBagAppState(
        pendingApprovalInteractionId: 'int-1',
        pendingApprovalCommand: 'ls -la',
      );
      final plan = GrassBagController.computeAndroidKeepalivePlan(
        base,
        runningSessionsCount: 0,
      );
      expect(plan.shouldRun, isTrue);
      expect(plan.needsWakeLock, isTrue);
      expect(plan.title, contains('授权确认'));
    });

    test('holds active WakeLock when background jobs or sessions are running', () {
      const base = GrassBagAppState(jobs: [_runningJob1, _runningJob2]);
      final plan = GrassBagController.computeAndroidKeepalivePlan(
        base,
        runningSessionsCount: 1,
      );
      expect(plan.shouldRun, isTrue);
      expect(plan.needsWakeLock, isTrue);
      expect(plan.title, contains('后台任务'));
      expect(plan.detail, contains('3'));
    });

    test('holds active WakeLock during APK update download', () {
      const base = GrassBagAppState(appUpdateDownloading: true);
      final plan = GrassBagController.computeAndroidKeepalivePlan(
        base,
        runningSessionsCount: 0,
      );
      expect(plan.shouldRun, isTrue);
      expect(plan.needsWakeLock, isTrue);
      expect(plan.title, contains('下载应用更新'));
    });

    test('keeps passive foreground service without WakeLock when only local engine is idle', () {
      const base = GrassBagAppState(
        nativeRuntimeStatus: NativeRuntimeStatus(
          engineRunning: true,
          dshVersion: '0.2.2-rc.5',
        ),
      );
      final plan = GrassBagController.computeAndroidKeepalivePlan(
        base,
        runningSessionsCount: 0,
      );
      expect(plan.shouldRun, isTrue);
      expect(plan.needsWakeLock, isFalse);
      expect(plan.title, contains('本机引擎运行中'));
    });

    test('stops foreground service when completely idle and local engine is stopped', () {
      const base = GrassBagAppState(
        nativeRuntimeStatus: NativeRuntimeStatus(engineRunning: false),
      );
      final plan = GrassBagController.computeAndroidKeepalivePlan(
        base,
        runningSessionsCount: 0,
      );
      expect(plan.managedByBootstrap, isFalse);
      expect(plan.shouldRun, isFalse);
      expect(plan.needsWakeLock, isFalse);
    });

    test('defers notification ownership while runtime bootstrapper is active', () {
      const base = GrassBagAppState(
        nativeRuntimeStatus: NativeRuntimeStatus(bootstrapActive: true),
      );
      final plan = GrassBagController.computeAndroidKeepalivePlan(
        base,
        runningSessionsCount: 0,
      );
      expect(plan.managedByBootstrap, isTrue);
      expect(plan.shouldRun, isTrue);
    });
  });

  testWidgets('showGrassBagConfirmDialog renders sculpted icon badge and returns user choice', (tester) async {
    bool? choice;
    final theme = GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light).toMaterialTheme();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: theme,
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: CupertinoButton(
                  onPressed: () async {
                    choice = await showGrassBagConfirmDialog(
                      ctx,
                      title: '确认高危操作',
                      message: '该操作将清理当前会话缓存。',
                      confirmLabel: '确认清理',
                      isDestructive: true,
                    );
                  },
                  child: const Text('打开弹窗'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开弹窗'));
    await tester.pumpAndSettle();

    expect(find.text('确认高危操作'), findsOneWidget);
    expect(find.text('该操作将清理当前会话缓存。'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.exclamationmark_shield_fill), findsOneWidget);

    await tester.tap(find.text('确认清理'));
    await tester.pumpAndSettle();
    expect(choice, isTrue);
  });
}
