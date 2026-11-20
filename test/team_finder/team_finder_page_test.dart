import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/modules/battle/simulation/recorder.dart';
import 'package:chaldea/app/modules/team_finder/team_finder_controller.dart';
import 'package:chaldea/app/team_finder/solver.dart';
import 'package:chaldea/app/modules/team_finder/team_finder_page.dart';
import 'package:chaldea/app/team_finder/battle_runner.dart';
import 'package:chaldea/app/team_finder/defaults.dart';
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

  Future<TeamFinderController> pump(
    WidgetTester tester, {
    int servants = 0,
    bool withQuest = false,
    int longSearchTeams = kLongSearchTeams,
  }) async {
    // A ListView only builds what is on screen, so use a tall surface to see the whole page.
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = TeamFinderController(runner: _FakeRunner(), longSearchTeams: longSearchTeams);
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

  testWidgets('a big box asks before searching: Cancel does not search, Search anyway does', (tester) async {
    final c = await pump(tester, servants: 5, withQuest: true, longSearchTeams: 1); // any box counts as big
    expect(c.teamCount(), greaterThan(1));
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    expect(find.text('This search may take a while'), findsOneWidget);
    expect(find.textContaining('at most ${kSolveTimeBudget.inMinutes} minutes'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.progress, isNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search anyway'));
    await tester.pumpAndSettle();
    expect(c.progress, isNotNull);
  });

  testWidgets('a small box searches straight away, without asking', (tester) async {
    final c = await pump(tester, servants: 5, withQuest: true);
    expect(c.teamCount(), lessThanOrEqualTo(kLongSearchTeams));
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    expect(find.text('This search may take a while'), findsNothing);
    expect(c.progress, isNotNull);
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

  group('friend support tab', () {
    Future<void> openFriendTab(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(Tab, 'Friend support'));
      await tester.pumpAndSettle();
    }

    testWidgets('a third tab, Friend support; with none chosen both tabs say the usual supports are used', (
      tester,
    ) async {
      await pump(tester);
      expect(find.widgetWithText(Tab, 'Friend support'), findsOneWidget);
      expect(find.textContaining('Automatic'), findsOneWidget); // Find teams tab summary
      await openFriendTab(tester);
      expect(find.textContaining('No friend support chosen'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Add support'), findsOneWidget);
    });

    testWidgets('a chosen friend is listed in both tabs, can be changed and can be removed', (tester) async {
      final c = await pump(tester, servants: 2, withQuest: true);
      c.upsertFriend(ServantSetup(svtId: 504500, level: 100, skillLevels: [10, 10, 10]));
      await tester.pumpAndSettle();
      expect(find.text('Friend support: Altria Caster (Caster)'), findsOneWidget); // Find teams tab
      expect(find.textContaining('Automatic'), findsNothing);
      await openFriendTab(tester);
      expect(find.text('Altria Caster (Caster)'), findsOneWidget);
      expect(find.textContaining('Lv100 · 10/10/10'), findsOneWidget);

      await tester.tap(find.text('Altria Caster (Caster)')); // tap = change its stats
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Level'), '90');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(c.friends[504500]!.level, 90);

      await openFriendTab(tester);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(c.friends, isEmpty);
      expect(find.textContaining('No friend support chosen'), findsOneWidget);
    });

    testWidgets('pressing OK in a friend\'s stats dialog goes to Find teams and checks the team compositions', (
      tester,
    ) async {
      final c = await pump(tester, servants: 2, withQuest: true);
      c.upsertFriend(ServantSetup.defaults(504500)); // what the picker does before the stats dialog
      await tester.pumpAndSettle();
      await openFriendTab(tester);
      await tester.tap(find.text('Altria Caster (Caster)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(c.progress?.finished, isTrue); // the search ran
      expect(find.textContaining('Teams checked'), findsOneWidget); // and the Find teams tab is showing
      expect(find.text('Friend support: Altria Caster (Caster)'), findsOneWidget);
    });

    testWidgets('OK without a quest picked keeps the friend and says the quest is missing', (tester) async {
      final c = await pump(tester, servants: 2);
      c.upsertFriend(ServantSetup.defaults(504500));
      await tester.pumpAndSettle();
      expect(c.blocker, 'Pick a quest first');
      await openFriendTab(tester);
      await tester.tap(find.text('Altria Caster (Caster)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(c.progress, isNull); // nothing to search yet
      expect(find.text('Pick a quest first'), findsOneWidget); // shown in the Find teams tab
    });
  });

  group('craft essences tab', () {
    Future<void> openCeTab(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(Tab, 'Craft essences'));
      await tester.pumpAndSettle();
    }

    final eventQuest = questSpecFromPhase(
      QuestPhase.fromJson(jsonDecode(File('test/team_finder/fixtures/quest_94138610_jp.json').readAsStringSync())),
    );

    testWidgets('a fourth tab lists the default Black Grail; the Find teams tab summarises it', (tester) async {
      await pump(tester);
      expect(find.widgetWithText(Tab, 'Craft essences'), findsOneWidget);
      expect(find.text('Craft essences: The Black Grail ×1'), findsOneWidget);
      await openCeTab(tester);
      expect(find.text('The Black Grail'), findsOneWidget);
      expect(find.text('Lv100 · limit broken'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Add CE'), findsOneWidget);
    });

    testWidgets('Add CE offers Black Grail, event damage CE and event drop CE', (tester) async {
      await pump(tester);
      await openCeTab(tester);
      await tester.tap(find.text('Add CE'));
      await tester.pumpAndSettle();
      expect(find.text('The Black Grail'), findsOneWidget); // the row
      expect(find.text('Black Grail'), findsOneWidget); // the option
      expect(find.text('Event damage CE'), findsOneWidget);
      expect(find.text('Event drop CE'), findsOneWidget);
    });

    testWidgets('Black Grail with level, limit break and quantity chosen in the dialog', (tester) async {
      final c = await pump(tester);
      c.removeCe(kBlackGrailCeId);
      await tester.pumpAndSettle();
      await openCeTab(tester);
      await tester.tap(find.text('Add CE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Black Grail'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Level'), '50');
      await tester.enterText(find.widgetWithText(TextField, 'Quantity'), '2');
      await tester.tap(find.byType(Switch)); // limit broken: on -> off
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      final ce = c.ces.single;
      expect([ce.ceId, ce.level, ce.limitBreak, ce.quantity], [kBlackGrailCeId, 50, false, 2]);
      expect(find.text('Lv50 · not limit broken · ×2'), findsOneWidget);
    });

    testWidgets('an event CE needs a quest, and then lists that event\'s CEs of the chosen kind', (tester) async {
      final c = await pump(tester);
      await openCeTab(tester);
      await tester.tap(find.text('Add CE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Event damage CE'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pick a quest first'), findsOneWidget);
      expect(find.text('OK'), findsNothing); // no stats dialog opened
      await tester.pump(const Duration(seconds: 5)); // let that snack bar go before the next one
      await tester.pumpAndSettle();

      c.setQuest(eventQuest, 'Event node');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add CE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Event damage CE'));
      await tester.pumpAndSettle();
      expect(find.textContaining('no event damage ce'), findsOneWidget); // this event only has drop CEs
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add CE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Event drop CE'));
      await tester.pumpAndSettle();
      expect(find.text('Lamp in Hand'), findsOneWidget);
      expect(find.text('December 23rd'), findsOneWidget);
      await tester.tap(find.text('December 23rd'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(c.ces.map((e) => e.ceId), [kBlackGrailCeId, 9408210]);
      // four icons were listed and the icon loader allows 3 a second on the real clock: let it finish
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pump(const Duration(seconds: 30));
    });

    testWidgets('a level above 100 or a quantity above 5 is refused with a message', (tester) async {
      final c = await pump(tester);
      await openCeTab(tester);
      await tester.tap(find.text('The Black Grail')); // tap a row = change it
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Level'), '101');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.textContaining('level must be 1..100'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Level'), '100');
      await tester.enterText(find.widgetWithText(TextField, 'Quantity'), '6');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.textContaining('quantity must be 1..5'), findsOneWidget);
      expect(c.ces.single.quantity, 1);
    });

    testWidgets('the X removes a CE', (tester) async {
      final c = await pump(tester);
      await openCeTab(tester);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(c.ces, isEmpty);
      expect(find.textContaining('No craft essences'), findsOneWidget);
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

  testWidgets('tapping a result opens the simulator Records panel', (tester) async {
    await pump(tester, servants: 5, withQuest: true);
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .byWidgetPredicate((w) => w is ListTile && w.title is Text && (w.title as Text).data!.startsWith('#1 '))
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(BattleRecorderPanel), findsOneWidget);
  });
}
