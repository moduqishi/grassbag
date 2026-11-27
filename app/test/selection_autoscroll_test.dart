import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassbag/theme/grassbag_glass.dart';
import 'package:grassbag/theme/grassbag_theme.dart';

void main() {
  testWidgets(
    'GrassBagSelectionAutoScrollScope auto-scrolls CustomScrollView down & up inside floating-bar insets and selects off-screen text',
    (tester) async {
      final scrollCtrl = ScrollController();
      addTearDown(scrollCtrl.dispose);

      String selectedText = '';
      bool autoScrollSeen = false;
      final tokens = GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light);

      await tester.pumpWidget(
        MaterialApp(
          theme: tokens.toMaterialTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  SelectionArea(
                    onSelectionChanged: (content) {
                      selectedText = content?.plainText ?? '';
                    },
                    child: GrassBagSelectionAutoScrollScope(
                      scrollController: scrollCtrl,
                      topEdgeInset: 80,
                      bottomEdgeInset: 110,
                      hotZoneExtent: 56,
                      onAutoScrollActiveChanged: (active) {
                        if (active) autoScrollSeen = true;
                      },
                      child: CustomScrollView(
                        controller: scrollCtrl,
                        slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 84, 16, 120),
                            sliver: SliverList.builder(
                              itemCount: 45,
                              itemBuilder: (_, idx) => Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: GrassBagSelectableScope(
                                  child: Text(
                                    'LINE_${idx.toString().padLeft(2, '0')} long selectable message paragraph content',
                                    style: const TextStyle(fontSize: 16, height: 1.5),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify GrassBagSelectableScope did NOT mount nested inner SelectionAreas!
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(scrollCtrl.offset, 0.0);

      // Long-press on the left side of LINE_02 and drag downward into the floating-composer hot zone
      // (y = 515 is STILL well inside the 600px CustomScrollView, where Flutter's default
      // EdgeDraggingAutoScroller alone would NOT scroll!).
      final line02Box = tester.getRect(find.textContaining('LINE_02'));
      final startPoint = Offset(line02Box.left + 12, line02Box.top + 10);
      final gesture = await tester.startGesture(startPoint);
      await tester.pump(const Duration(milliseconds: 650));

      // Record which line is currently off-screen below the visible 600px viewport before scrolling.
      expect(find.textContaining('LINE_15'), findsNothing);

      // Drag down into the bottom hot zone (above/over the 110px floating composer inset)
      await gesture.moveTo(const Offset(260, 515));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(autoScrollSeen, isTrue, reason: 'bottom edge drag must trigger auto-scroll');
      final scrolledDownOffset = scrollCtrl.offset;
      expect(
        scrolledDownOffset,
        greaterThan(220.0),
        reason: 'dragging selection to bottom hot zone must scroll off-screen lines into view',
      );

      // Lift finger so SelectableRegion finalizes and emits onSelectionChanged
      await gesture.up();
      await tester.pump();
      final offsetAfterLift = scrollCtrl.offset;
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect((scrollCtrl.offset - offsetAfterLift).abs(), lessThan(1.0));

      expect(selectedText, contains('LINE_02'));
      final reachedOffscreenLine = List.generate(25, (i) => i + 8)
          .any((idx) => selectedText.contains('LINE_${idx.toString().padLeft(2, '0')}'));
      expect(
        reachedOffscreenLine,
        isTrue,
        reason: 'selection must extend into lines originally off-screen below the viewport; got:\n$selectedText',
      );

      // Now verify upward edge auto-scroll when dragging into the top hot zone (below 80px header)
      final visibleMidFinder = find.textContaining('LINE_09');
      expect(visibleMidFinder, findsOneWidget);
      final upStart = tester.getCenter(visibleMidFinder);
      final upGesture = await tester.startGesture(upStart);
      await tester.pump(const Duration(milliseconds: 650));
      await upGesture.moveTo(const Offset(120, 75));
      for (var i = 0; i < 28; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        scrollCtrl.offset,
        lessThan(offsetAfterLift - 80.0),
        reason: 'dragging selection to top hot zone must auto-scroll upward',
      );
      await upGesture.up();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Android teardrop end-handle drag auto-scrolls CustomScrollView past floating composer',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      final scrollCtrl = ScrollController();
    addTearDown(scrollCtrl.dispose);
    final hasSelection = ValueNotifier<bool>(false);
    addTearDown(hasSelection.dispose);
    String selectedText = '';
    final tokens = GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.dark);

    await tester.pumpWidget(
      MaterialApp(
        theme: tokens.toMaterialTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: SelectionArea(
              contextMenuBuilder: buildGrassBagSelectableContextMenu,
              onSelectionChanged: (content) {
                selectedText = content?.plainText ?? '';
                hasSelection.value = selectedText.isNotEmpty;
              },
              child: GrassBagSelectionAutoScrollScope(
                scrollController: scrollCtrl,
                topEdgeInset: 80,
                bottomEdgeInset: 110,
                hotZoneExtent: 56,
                child: CustomScrollView(
                  controller: scrollCtrl,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 84, 16, 120),
                      sliver: SliverList.builder(
                        itemCount: 40,
                        itemBuilder: (_, idx) => GrassBagSelectionKeepAlive(
                          keepAliveListenable: hasSelection,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: GrassBagSelectableScope(
                              child: Text(
                                'ANDROID_ITEM_${idx.toString().padLeft(2, '0')} selectable text content',
                                style: const TextStyle(fontSize: 16, height: 1.5),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Long-press LINE 01 and lift finger so Android selection handles appear
    final item01Rect = tester.getRect(find.textContaining('ANDROID_ITEM_01'));
    await tester.longPressAt(Offset(item01Rect.left + 16, item01Rect.top + 10));
    await tester.pumpAndSettle();
    expect(selectedText, contains('ANDROID_ITEM_01'));

    // 2. Locate the right/end teardrop selection handle (`RawGestureDetector` inside handle overlay)
    //    and drag it smoothly downward into the bottom hot zone!
    final handleDetectors = find.byWidgetPredicate(
      (w) => w is RawGestureDetector && w.gestures.containsKey(PanGestureRecognizer),
    );
    expect(handleDetectors, findsNWidgets(2));
    final firstCenter = tester.getCenter(handleDetectors.at(0));
    final secondCenter = tester.getCenter(handleDetectors.at(1));
    final endHandleCenter = firstCenter.dx >= secondCenter.dx ? firstCenter : secondCenter;

    // Confirm ANDROID_ITEM_11 is completely off-screen below the 600px viewport before dragging
    expect(find.textContaining('ANDROID_ITEM_11'), findsNothing);

    final handleDrag = await tester.startGesture(endHandleCenter);
    await tester.pump(const Duration(milliseconds: 16));
    // Move past touchSlop smoothly into the bottom hot zone (y = 520, still inside 600px viewport)
    for (var step = 1; step <= 10; step++) {
      final t = step / 10.0;
      await handleDrag.moveTo(Offset(
        endHandleCenter.dx,
        endHandleCenter.dy + (520.0 - endHandleCenter.dy) * t,
      ));
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await handleDrag.up();
    await tester.pumpAndSettle();

    expect(scrollCtrl.offset, greaterThan(420.0));
    expect(selectedText, contains('ANDROID_ITEM_01'));
    final reachedOffscreen = List.generate(25, (i) => i + 11)
        .any((idx) => selectedText.contains('ANDROID_ITEM_${idx.toString().padLeft(2, '0')}'));
    expect(
      reachedOffscreen,
      isTrue,
      reason: 'teardrop handle drag must select lines originally off-screen; got:\n$selectedText',
    );
  });

  testWidgets('GrassBagSelectableScope mounts standalone SelectionArea when no ancestor exists', (
    tester,
  ) async {
    final tokens = GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: tokens.toMaterialTheme(),
        home: const Scaffold(
          body: GrassBagSelectableScope(
            child: Text('Standalone selectable content'),
          ),
        ),
      ),
    );
    expect(find.byType(SelectionArea), findsOneWidget);
  });
}
