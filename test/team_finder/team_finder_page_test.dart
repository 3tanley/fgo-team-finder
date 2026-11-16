import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/modules/team_finder/team_finder_controller.dart';
import 'package:chaldea/app/modules/team_finder/team_finder_page.dart';
import 'package:chaldea/app/team_finder/battle_runner.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/quest_loader.dart';
import 'package:chaldea/generated/l10n.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

class _FakeRunner implements BattleRunner {
  @override
  Future<BattleOutcome> run(TeamSpec team, QuestSpec quest, TurnPlan plan) async => BattleOutcome(
    clearedAllWaves: true,
    turnsUsed: 3,
    totalNpDamage: 1000 * team.slots[1].servant.svtId,
    unverified: false,
    log: const ['T1 skill 0.3 -> 2'],
  );
}

void main() async {
  await initiateForTest();

  final quest = questSpecFromPhase(db.gameData.questPhases[9300040603]!);
  const ids = [100100, 504500, 500900, 100500, 200100];

  Future<TeamFinderController> pump(WidgetTester tester, {int servants = 0, bool withQuest = false}) async {
    // A ListView only builds what is on screen, so use a tall surface to see the whole page.
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = TeamFinderController(runner: _FakeRunner());
    for (final id in ids.take(servants)) {
      c.upsertServant(ServantSetup.defaults(id));
    }
    if (withQuest) c.setQuest(quest, 'Test quest');
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          S.delegate,
          DefaultMaterialLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en')],
        home: TeamFinderPage(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  FilledButton searchButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Search'));

  testWidgets('empty state: says it needs 2 servants and the Search button is disabled', (tester) async {
    await pump(tester);
    expect(find.text('Need at least 2 servants (you have 0)'), findsOneWidget);
    expect(searchButton(tester).onPressed, isNull);
    expect(find.text('NA'), findsOneWidget);
    expect(find.text('JP'), findsOneWidget);
    expect(find.text('Not selected'), findsOneWidget);
  });

  testWidgets('blank-field defaults are shown to the user in the box note and each servant row', (tester) async {
    await pump(tester, servants: 5);
    expect(find.textContaining('default to level 90, skills 10/10/10, NP level 1'), findsOneWidget);
    expect(find.textContaining('Lv90 · 10/10/10 · NP1'), findsNWidgets(5));
  });

  testWidgets('5 servants but no quest: asks for a quest and stays disabled', (tester) async {
    await pump(tester, servants: 5);
    expect(find.text('Pick a quest first'), findsOneWidget);
    expect(searchButton(tester).onPressed, isNull);
  });

  testWidgets('5 servants and a quest: Search runs and results appear best-first', (tester) async {
    await pump(tester, servants: 5, withQuest: true);
    expect(searchButton(tester).onPressed, isNotNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    final titles = tester
        .widgetList<Text>(find.textContaining('NP damage'))
        .map((t) => t.data ?? '')
        .where((s) => s.startsWith('#'))
        .toList();
    expect(titles, isNotEmpty);
    expect(titles.first.startsWith('#1'), isTrue);
    int damage(String s) => int.parse(RegExp(r'([\d,]+) NP damage').firstMatch(s)![1]!.replaceAll(',', ''));
    final damages = titles.map(damage).toList();
    expect(damages, [...damages]..sort((a, b) => b.compareTo(a)));
    expect(find.textContaining('Loop rules used'), findsOneWidget);
  });

  group('owned servants tab', () {
    setUp(() => db.curUser.servants.clear());
    tearDown(() => db.curUser.servants.clear());

    void own(int collectionNo, {void Function(SvtPlan cur)? edit}) {
      final cur = db.gameData.servantsNoDup[collectionNo]!.status.cur..favorite = true;
      edit?.call(cur);
    }

    Future<TeamFinderController> openOwnedTab(WidgetTester tester) async {
      final c = await pump(tester);
      await tester.tap(find.text('Owned servants'));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('the page has two tabs, Find teams first', (tester) async {
      await pump(tester);
      expect(find.widgetWithText(Tab, 'Find teams'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Owned servants'), findsOneWidget);
      expect(find.text('Need at least 2 servants (you have 0)'), findsOneWidget); // the Find teams tab is showing
    });

    testWidgets('with nothing marked as owned it says so instead of asking for servants one by one', (tester) async {
      await openOwnedTab(tester);
      expect(find.textContaining('No owned servants yet'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('owned 4-5 star servants are listed with their Chaldea stats; tapping selects and unselects', (
      tester,
    ) async {
      own(
        284,
        edit: (c) {
          c.ascension = 4;
          c.skills = [10, 9, 8];
          c.npLv = 3;
        },
      );
      own(355, edit: (c) => c.ascension = 4);
      final c = await openOwnedTab(tester);
      expect(find.byType(Checkbox), findsNWidgets(2));
      expect(find.text('Altria Caster (Caster)'), findsOneWidget);
      expect(find.textContaining('Lv90 · 10/9/8 · NP3'), findsOneWidget);

      await tester.tap(find.text('Altria Caster (Caster)'));
      await tester.pumpAndSettle();
      final s = c.box[504500]!;
      expect(s.skillLevels, [10, 9, 8]);
      expect(s.npLevel, 3);
      expect(tester.widgetList<Checkbox>(find.byType(Checkbox)).where((e) => e.value == true).length, 1);

      await tester.tap(find.text('Altria Caster (Caster)'));
      await tester.pumpAndSettle();
      expect(c.box.containsKey(504500), isFalse);
    });

    testWidgets('selected servants show up in the Find teams tab and count towards the minimum', (tester) async {
      own(284);
      own(355);
      final c = await openOwnedTab(tester);
      await tester.tap(find.text('Altria Caster (Caster)'));
      await tester.tap(find.text('Ibuki-Douji (Berserker)'));
      await tester.pumpAndSettle();
      expect(c.box.length, 2);
      await tester.tap(find.text('Find teams'));
      await tester.pumpAndSettle();
      expect(find.text('Pick a quest first'), findsOneWidget); // 2 servants are enough; only the quest is missing
      expect(find.textContaining('Servants used (2)'), findsOneWidget);
    });
  });

  testWidgets('the edit dialog has five append fields that default to 0 and save what the user types', (tester) async {
    final c = await pump(tester, servants: 5);
    await tester.tap(find.text('Altria Pendragon (Saber)'));
    await tester.pumpAndSettle();
    for (var n = 1; n <= 5; n++) {
      expect(find.widgetWithText(TextField, 'Append $n'), findsOneWidget);
      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Append $n')).controller?.text, '0');
    }
    await tester.enterText(find.widgetWithText(TextField, 'Append 3'), '10');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(c.box[100100]!.appendLevels, [0, 0, 10, 0, 0]);
    expect(find.textContaining('append 0/0/10/0/0'), findsOneWidget); // shown in the row once any append is set
  });

  testWidgets('a blank append field means 0 and an append above 10 is refused', (tester) async {
    final c = await pump(tester, servants: 5);
    await tester.tap(find.text('Altria Pendragon (Saber)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Append 1'), '');
    await tester.enterText(find.widgetWithText(TextField, 'Append 2'), '11');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.textContaining('append'), findsWidgets); // the error text names the append range
    expect(c.box[100100]!.appendLevels, [0, 0, 0, 0, 0]); // nothing saved
    await tester.enterText(find.widgetWithText(TextField, 'Append 2'), '');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(c.box[100100]!.appendLevels, [0, 0, 0, 0, 0]);
  });

  testWidgets('expanding a result shows how the team clears', (tester) async {
    await pump(tester, servants: 5, withQuest: true);
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ExpansionTile).first);
    await tester.pumpAndSettle();
    // the engine's "T1 skill 0.3 -> 2" is shown with servant names, not slot numbers
    expect(find.textContaining('skill 3 →'), findsWidgets);
    expect(find.text('T1 skill 0.3 -> 2'), findsNothing);
  });
}
