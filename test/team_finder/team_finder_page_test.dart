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

  testWidgets('empty state: says it needs 5 servants and the Search button is disabled', (tester) async {
    await pump(tester);
    expect(find.text('Need at least 5 servants (you have 0)'), findsOneWidget);
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

  testWidgets('expanding a result shows how the team clears', (tester) async {
    await pump(tester, servants: 5, withQuest: true);
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ExpansionTile).first);
    await tester.pumpAndSettle();
    expect(find.text('T1 skill 0.3 -> 2'), findsWidgets);
  });
}
