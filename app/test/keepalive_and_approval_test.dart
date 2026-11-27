import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassbag/services/native_bridge.dart';
import 'package:grassbag/state/app_state.dart';
import 'package:grassbag/theme/grassbag_theme.dart';
import 'package:grassbag/ui/common/grassbag_sheets.dart';
import 'package:grassbag/ui/onboarding/launch_splash_overlay.dart';

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

  group('GrassBagAppGate startup readiness & adaptive splash hold', () {
    test('holds splash until initialized Android local container finishes booting, connecting, and hydrating', () {
      const unhydrated = GrassBagAppState(
        nativeStatusHydrated: false,
        nativeRuntimeStatus: NativeRuntimeStatus(initialized: true, engineState: 'stopped'),
      );
      expect(
        GrassBagAppGate.isStartupHydrationSettled(unhydrated, isAndroidOverride: true),
        isFalse,
      );
      // Unhydrated native channel stays on safe 3.6s fallback budget so broken binder never hangs 20s
      expect(
        GrassBagAppGate.computeMaxHoldDuration(unhydrated, isAndroidOverride: true),
        const Duration(milliseconds: 3600),
      );

      // Even before `prewarmInBackground` flips `stopped -> starting`, splash MUST stay up & extend to 20s!
      const prewarmRace = GrassBagAppState(
        nativeStatusHydrated: true,
        connectionPhase: ConnectionPhase.disconnected,
        nativeRuntimeStatus: NativeRuntimeStatus(
          initialized: true,
          engineState: 'stopped',
          engineRunning: false,
        ),
      );
      expect(
        GrassBagAppGate.isStartupHydrationSettled(prewarmRace, isAndroidOverride: true),
        isFalse,
      );
      expect(
        GrassBagAppGate.computeMaxHoldDuration(prewarmRace, isAndroidOverride: true),
        const Duration(seconds: 20),
      );

      // Container starting -> still holds splash
      const starting = GrassBagAppState(
        nativeStatusHydrated: true,
        connectionPhase: ConnectionPhase.connecting,
        loadingSessions: true,
        nativeRuntimeStatus: NativeRuntimeStatus(
          initialized: true,
          engineState: 'starting',
          engineRunning: false,
        ),
      );
      expect(
        GrassBagAppGate.isStartupHydrationSettled(starting, isAndroidOverride: true),
        isFalse,
      );

      // Connected but still hydrating domains/sessions -> still holds splash
      const connectingHydrating = GrassBagAppState(
        nativeStatusHydrated: true,
        connectionPhase: ConnectionPhase.connected,
        hydratingDomains: true,
        loadingSessions: false,
        nativeRuntimeStatus: NativeRuntimeStatus(
          initialized: true,
          engineState: 'running',
          engineRunning: true,
        ),
      );
      expect(
        GrassBagAppGate.isStartupHydrationSettled(connectingHydrating, isAndroidOverride: true),
        isFalse,
      );

      // Engine running + connected + sessions & models hydrated -> settles IMMEDIATELY!
      const fullyReady = GrassBagAppState(
        nativeStatusHydrated: true,
        connectionPhase: ConnectionPhase.connected,
        hydratingDomains: false,
        loadingSessions: false,
        modelGroups: [
          ModelCatalogGroup(
            id: 'deepseek-account',
            name: 'DeepSeek',
            models: [
              ModelCatalogEntry(
                id: 'deepseek-chat',
                name: 'DeepSeek Chat',
                providerId: 'deepseek-account',
                providerName: 'DeepSeek',
              ),
            ],
          ),
        ],
        nativeRuntimeStatus: NativeRuntimeStatus(
          initialized: true,
          engineState: 'running',
          engineRunning: true,
        ),
      );
      expect(
        GrassBagAppGate.isStartupHydrationSettled(fullyReady, isAndroidOverride: true),
        isTrue,
      );

      // Explicit user stop or engine error settles gracefully so user is never trapped on splash
      const engineError = GrassBagAppState(
        nativeStatusHydrated: true,
        connectionPhase: ConnectionPhase.error,
        nativeRuntimeStatus: NativeRuntimeStatus(
          initialized: true,
          engineState: 'error',
          engineRunning: false,
        ),
      );
      expect(
        GrassBagAppGate.isStartupHydrationSettled(engineError, isAndroidOverride: true),
        isTrue,
      );
      expect(
        GrassBagAppGate.isStartupHydrationSettled(
          prewarmRace,
          isAndroidOverride: true,
          userStoppedLocalEngine: true,
        ),
        isTrue,
      );
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
