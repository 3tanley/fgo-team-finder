import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/modules/team_finder/team_finder_controller.dart';
import 'package:chaldea/app/team_finder/battle_runner.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/quest_loader.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

class _FakeRunner implements BattleRunner {
  @override
  Future<BattleOutcome> run(TeamSpec team, QuestSpec quest, TurnPlan plan) async =>
      BattleOutcome(clearedAllWaves: true, turnsUsed: 3, totalNpDamage: team.slots[1].servant.svtId, unverified: false);
}

void main() async {
  await initiateForTest();

  final quest = questSpecFromPhase(db.gameData.questPhases[9300040603]!);
  const ids = [100100, 504500, 500900, 100500, 200100];

  TeamFinderController controller({int servants = 5, bool withQuest = true}) {
    final c = TeamFinderController(runner: _FakeRunner());
    for (final id in ids.take(servants)) {
      c.upsertServant(ServantSetup.defaults(id));
    }
    if (withQuest) c.setQuest(quest, 'test quest');
    return c;
  }

  test('with 4 servants the search is blocked and says it needs at least 5', () {
    expect(controller(servants: 4).blocker, contains('at least 5'));
    expect(controller(servants: 4).blocker, contains('4'));
  });

  test('without a quest the search is blocked and asks for one', () {
    expect(controller(withQuest: false).blocker, contains('quest'));
  });

  test('5 servants and a quest: nothing blocks the search', () {
    expect(controller().blocker, isNull);
  });

  test('adding the same servant again replaces its setup, and remove drops it', () {
    final c = controller();
    c.upsertServant(ServantSetup(svtId: 100100, level: 100, npLevel: 5));
    expect(c.box.length, 5);
    expect(c.box[100100]!.level, 100);
    expect(c.box[100100]!.npLevel, 5);
    c.removeServant(100100);
    expect(c.box.length, 4);
  });

  test('search reports viable teams best-first and finishes', () async {
    final c = controller();
    await c.search();
    final p = c.progress!;
    expect(p.finished, isTrue);
    expect(c.error, isNull);
    expect(p.results, isNotEmpty);
    final damages = p.results.map((r) => r.totalNpDamage).toList();
    expect(damages, [...damages]..sort((a, b) => b.compareTo(a)));
    expect(c.searching, isFalse);
  });

  test('a blocked search sets the error instead of running', () async {
    final c = controller(servants: 3);
    await c.search();
    expect(c.error, contains('at least 5'));
    expect(c.progress, isNull);
  });

  test('changing the region or quest clears old results', () async {
    final c = controller();
    await c.search();
    expect(c.progress, isNotNull);
    c.setRegion(Region.jp);
    expect(c.progress, isNull);
    await c.search();
    c.setQuest(quest, 'another');
    expect(c.progress, isNull);
  });

  test('cancel stops a running search', () async {
    final c = controller();
    final running = c.search();
    c.cancel();
    await running;
    expect(c.searching, isFalse);
    expect(c.progress?.cancelled, isTrue);
  });

  test('the box survives encode and decode with its custom values', () {
    final c = controller();
    c.upsertServant(ServantSetup(svtId: 100100, level: 100, skillLevels: [6, 7, 8], npLevel: 3, atkFou: 500, hpFou: 0));
    final back = TeamFinderController.decodeBox(TeamFinderController.encodeBox(c.box.values));
    expect(back.length, 5);
    final s = back.firstWhere((e) => e.svtId == 100100);
    expect(s.level, 100);
    expect(s.npLevel, 3);
    expect(s.atkFou, 500);
    expect(s.hpFou, 0);
    expect(s.skillLevels, [6, 7, 8]);
  });

  test('append levels survive encode and decode, and a box saved before they existed loads with all zeros', () {
    final c = controller();
    c.upsertServant(ServantSetup(svtId: 100100, appendLevels: [10, 0, 3, 0, 1]));
    final back = TeamFinderController.decodeBox(TeamFinderController.encodeBox(c.box.values));
    expect(back.firstWhere((e) => e.svtId == 100100).appendLevels, [10, 0, 3, 0, 1]);
    final old = TeamFinderController.decodeBox(
      '[{"id":100100,"lv":90,"skills":[10,10,10],"np":1,"atk":1000,"hp":1000}]',
    );
    expect(old.single.appendLevels, [0, 0, 0, 0, 0]);
    expect(TeamFinderController.decodeBox('[{"id":100100,"append":[0,0,0,0,11]}]'), isEmpty); // out of range dropped
  });

  test('decoding garbage or out-of-range saved data gives an empty or cleaned box, never a crash', () {
    expect(TeamFinderController.decodeBox('not json'), isEmpty);
    expect(TeamFinderController.decodeBox('{"a":1}'), isEmpty);
    expect(TeamFinderController.decodeBox('[{"id":100100,"np":9}]'), isEmpty); // invalid NP level dropped
  });
}
