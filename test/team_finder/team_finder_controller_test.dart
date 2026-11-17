import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chaldea/app/modules/team_finder/team_finder_controller.dart';
import 'package:chaldea/app/team_finder/battle_runner.dart';
import 'package:chaldea/app/team_finder/defaults.dart';
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

  test('with 1 servant the search is blocked and says it needs at least 2', () {
    expect(controller(servants: 1).blocker, contains('at least 2'));
    expect(controller(servants: 1).blocker, contains('1'));
  });

  test('2 servants and a quest: nothing blocks the search', () {
    expect(controller(servants: 2).blocker, isNull);
  });

  TeamFinderController ownedController(ServantSetup? Function(int svtId) ownedSetup) {
    final c = TeamFinderController(runner: _FakeRunner(), ownedSetup: ownedSetup);
    for (final id in ids) {
      c.upsertServant(ServantSetup.defaults(id));
    }
    c.setQuest(quest, 'test quest');
    return c;
  }

  test('search first re-reads owned servants from Chaldea data and leaves the others alone', () async {
    final c = ownedController((id) => id == 100100 ? ServantSetup(svtId: 100100, level: 77, npLevel: 4) : null);
    await c.search();
    expect(c.box[100100]!.level, 77);
    expect(c.box[100100]!.npLevel, 4);
    expect(c.box[504500]!.level, 90); // not owned (provider returned null): untouched
    expect(c.progress!.finished, isTrue);
  });

  test('refreshOwned says whether anything changed', () {
    var level = 80;
    final c = ownedController((id) => id == 100100 ? ServantSetup(svtId: 100100, level: level) : null);
    expect(c.refreshOwned(), isTrue); // 90 -> 80
    expect(c.refreshOwned(), isFalse); // same again
    level = 81;
    expect(c.refreshOwned(), isTrue);
    expect(c.box[100100]!.level, 81);
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
    final c = controller(servants: 1);
    await c.search();
    expect(c.error, contains('at least 2'));
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

  group('craft essences', () {
    test('the list starts as one Black Grail at level 100, limit broken', () {
      final c = controller();
      expect(c.ces.map((e) => e.ceId), [kBlackGrailCeId]);
      expect([c.ces.single.level, c.ces.single.limitBreak, c.ces.single.quantity], [100, true, 1]);
    });

    test('the search hands the CE list to the team generator (event CE x2 on both servants, no Black Grail)', () async {
      final ceIds = <List<int?>>[];
      final c = TeamFinderController(runner: _RecordingRunner({}, ceIds));
      c.upsertServant(ServantSetup.defaults(704300)); // Summer Ibuki, the only damage dealer
      c.upsertServant(ServantSetup.defaults(504500));
      c.setQuest(quest, 'test quest');
      c.removeCe(kBlackGrailCeId);
      c.upsertCe(CeSetup(9408210, quantity: 2));
      await c.search();
      expect(ceIds, isNotEmpty);
      for (final ids in ceIds) {
        expect(ids.sublist(1, 3), [9408210, 9408210]);
      }
    });

    test('by default the search uses one Black Grail on the damage dealer', () async {
      final ceIds = <List<int?>>[];
      final c = TeamFinderController(runner: _RecordingRunner({}, ceIds));
      c.upsertServant(ServantSetup.defaults(704300));
      c.upsertServant(ServantSetup.defaults(504500));
      c.setQuest(quest, 'test quest');
      await c.search();
      expect(ceIds.every((ids) => ids.sublist(1, 3).contains(kBlackGrailCeId)), isTrue);
    });

    test('an empty list means no CE at all, not the default', () async {
      final ceIds = <List<int?>>[];
      final c = TeamFinderController(runner: _RecordingRunner({}, ceIds));
      c.upsertServant(ServantSetup.defaults(704300));
      c.upsertServant(ServantSetup.defaults(504500));
      c.setQuest(quest, 'test quest');
      c.removeCe(kBlackGrailCeId);
      await c.search();
      expect(ceIds, isNotEmpty);
      expect(ceIds.every((ids) => ids.sublist(1, 3).every((e) => e == null)), isTrue);
    });

    test('adding the same CE again replaces it; adding or removing clears old results', () async {
      final c = controller(servants: 2);
      await c.search();
      expect(c.progress, isNotNull);
      c.upsertCe(CeSetup(kBlackGrailCeId, level: 50, limitBreak: false, quantity: 2));
      expect(c.ces.length, 1);
      expect([c.ces.single.level, c.ces.single.limitBreak, c.ces.single.quantity], [50, false, 2]);
      expect(c.progress, isNull);
      await c.search();
      c.removeCe(kBlackGrailCeId);
      expect(c.ces, isEmpty);
      expect(c.progress, isNull);
    });

    test('the list is saved and loaded in order, and an emptied list stays empty', () async {
      SharedPreferences.setMockInitialValues({});
      final a = TeamFinderController(persist: true);
      a.upsertCe(CeSetup(9408210, level: 80, limitBreak: false, quantity: 2));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final b = TeamFinderController(persist: true);
      await b.load();
      expect(b.ces.map((e) => e.ceId), [kBlackGrailCeId, 9408210]);
      expect([b.ces.last.level, b.ces.last.limitBreak, b.ces.last.quantity], [80, false, 2]);

      b.removeCe(kBlackGrailCeId);
      b.removeCe(9408210);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final c = TeamFinderController(persist: true);
      await c.load();
      expect(c.ces, isEmpty);
    });

    test('nothing saved means the default list; garbage or out-of-range entries are dropped, never thrown', () {
      expect(TeamFinderController.decodeCes('not json'), isEmpty);
      expect(TeamFinderController.decodeCes('{"a":1}'), isEmpty);
      expect(TeamFinderController.decodeCes('[{"id":9408210,"lv":101,"lb":true,"qty":1}]'), isEmpty);
      expect(TeamFinderController.decodeCes('[{"id":9408210,"lv":100,"lb":true,"qty":0}]'), isEmpty);
      expect(TeamFinderController.decodeCes('[{"id":9408210}]').single.level, 100); // missing fields: defaults
    });
  });

  group('friend support', () {
    test('a chosen friend is borrowed in slot 0 of every team the search tries', () async {
      final slot0 = <int>{};
      final c = TeamFinderController(runner: _RecordingRunner(slot0));
      c.upsertServant(ServantSetup.defaults(704300)); // Summer Ibuki, Arts
      c.upsertServant(ServantSetup.defaults(504500));
      c.setQuest(quest, 'test quest');
      // Urðr is not what the NP card rule would pick in NA (Castoria), so only a chosen friend explains slot 0
      c.upsertFriend(ServantSetup.defaults(205500));
      await c.search();
      expect(slot0, {205500});
      expect(c.progress!.teamsTotal, 1);
    });

    test('with no friend chosen the usual supports are tried', () async {
      final slot0 = <int>{};
      final c = TeamFinderController(runner: _RecordingRunner(slot0));
      c.upsertServant(ServantSetup.defaults(704300));
      c.upsertServant(ServantSetup.defaults(504500));
      c.setQuest(quest, 'test quest');
      await c.search();
      expect(slot0, isNotEmpty);
      expect(c.friends, isEmpty);
    });

    test('choosing the same friend again replaces it; removing drops it; either clears old results', () async {
      final c = controller(servants: 2);
      c.upsertFriend(ServantSetup.defaults(504500));
      await c.search();
      expect(c.progress, isNotNull);
      c.upsertFriend(ServantSetup(svtId: 504500, level: 100));
      expect(c.friends.length, 1);
      expect(c.friends[504500]!.level, 100);
      expect(c.progress, isNull);
      await c.search();
      c.removeFriend(504500);
      expect(c.friends, isEmpty);
      expect(c.progress, isNull);
    });

    test('friends are saved with persist on and loaded again next time', () async {
      SharedPreferences.setMockInitialValues({});
      final a = TeamFinderController(persist: true);
      a.upsertFriend(ServantSetup(svtId: 504500, level: 100, appendLevels: [0, 0, 0, 0, 5]));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final b = TeamFinderController(persist: true);
      await b.load();
      expect(b.friends.keys, [504500]);
      expect(b.friends[504500]!.level, 100);
      expect(b.friends[504500]!.appendLevels, [0, 0, 0, 0, 5]);
      expect(b.box, isEmpty); // friends are not mixed into the box
    });
  });
}

class _RecordingRunner implements BattleRunner {
  final Set<int> slot0;
  final List<List<int?>>? ceIds;
  _RecordingRunner(this.slot0, [this.ceIds]);
  @override
  Future<BattleOutcome> run(TeamSpec team, QuestSpec quest, TurnPlan plan) async {
    slot0.add(team.slots[0].servant.svtId);
    ceIds?.add([for (final s in team.slots) s.ce?.ceId]);
    return const BattleOutcome(clearedAllWaves: false, turnsUsed: 3, totalNpDamage: 0, unverified: false);
  }
}
