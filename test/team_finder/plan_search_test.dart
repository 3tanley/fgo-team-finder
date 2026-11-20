// The plan search: thinks through skills, targets, firing order and swap timing on the real engine.
// Fixture: the real JP node 94138610 (Lv90++, 3 waves, 56k+61k / 257k / 72k+798k+65k HP), saved from Atlas.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/interactions/_delegate.dart';
import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/battle/utils/battle_logger.dart';
import 'package:chaldea/app/team_finder/battle_runner.dart';
import 'package:chaldea/app/team_finder/defaults.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/plan_search.dart';
import 'package:chaldea/app/team_finder/quest_loader.dart';
import 'package:chaldea/app/team_finder/turn_planner.dart';
import 'package:chaldea/app/team_finder/solver.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int altriaSaber = 100100;
const int altriaCaster = 504500;
const int summerIbuki = 704300;
const int eventCe = 9408210; // Pohjola's Christmas Eve reward CE, the event of node 94138610

void main() async {
  await initiateForTest();

  final node = questSpecFromPhase(
    QuestPhase.fromJson(jsonDecode(File('test/team_finder/fixtures/quest_94138610_jp.json').readAsStringSync())),
  );
  final koyanskaya = db.gameData.servantsNoDup[314]!.id;
  final oberon = db.gameData.servantsNoDup[316]!.id;
  CeSetup bond(int svtId) => CeSetup(db.gameData.servantsById[svtId]!.bondEquips.first);
  // a fully built Altria Pendragon: Lv120, NP5, gold fou, append 2
  final strongAltria = ServantSetup(
    svtId: altriaSaber,
    level: 120,
    npLevel: 5,
    atkFou: 2000,
    appendLevels: [0, 10, 0, 0, 0],
  );

  TeamSpec team(ServantSetup dealer) => TeamSpec([
    SlotSpec(ServantSetup.defaults(koyanskaya), ce: bond(koyanskaya)),
    SlotSpec(dealer, ce: CeSetup(eventCe)),
    SlotSpec(ServantSetup.defaults(altriaCaster), ce: CeSetup(eventCe)),
    SlotSpec(ServantSetup.defaults(oberon)),
  ], mysticCode: MysticCodeSetup(kDefaultMysticCodeId));
  const loop = TurnPlan([
    [AutoLoop()],
    [AutoLoop()],
    [AutoLoop()],
  ]);
  const search = TurnPlan([
    [AutoSearch()],
    [],
    [],
  ]);
  final runner = EngineBattleRunner();

  test('the search clears node 94138610 with a built Altria Saber; the fixed loop does not', () async {
    final byLoop = await runner.run(team(strongAltria), node, loop);
    expect(byLoop.clearedAllWaves, isFalse);
    final out = await runner.run(team(strongAltria), node, search);
    expect(out.failure, isNull);
    expect(out.clearedAllWaves, isTrue);
    expect(out.turnsUsed, lessThanOrEqualTo(3));
    expect(out.totalNpDamage, greaterThan(1000000)); // the 798k boss alone
    expect(out.log.where((l) => l.contains(' np ')), isNotEmpty);
    expect(out.log.any((l) => l.contains(' swap ')), isTrue); // Oberon comes in at the end
  });

  test('a clear carries the engine records the Records panel draws: skills, NPs, per-enemy damage by wave', () async {
    final out = await runner.run(team(strongAltria), node, search);
    expect(out.clearedAllWaves, isTrue);
    final r = out.records;
    expect(r.whereType<BattleSkillRecord>(), isNotEmpty);
    expect(r.whereType<BattleProgressWaveRecord>().length, 3);
    expect(r.whereType<BattleProgressTurnRecord>().length, out.turnsUsed);
    final np = r.whereType<BattleAttackRecord>().where((a) => a.card?.isTD == true);
    expect(np, isNotEmpty);
    expect(np.fold<int>(0, (s, a) => s + a.damage), out.totalNpDamage); // same numbers the result title shows
  });

  // The owner's clear of node 94138610 with Archetype: EARTH (Buster) and Sodom's Beast/Draco (Arts), found by hand:
  // Earth fires on turn 1, Draco on turn 2 (a Castoria swap for Oberon), both on turn 3. Draco's regen skills
  // and Castoria's Arts buff (on Draco) go out on turn 1, before Draco fires.
  group('node 94138610, Earth + Draco (a clear found by hand)', () {
    const earth = 2300500, draco = 3300100, flowerDoll = 9408190;
    ServantSetup built(int id) =>
        ServantSetup(svtId: id, level: 120, npLevel: 5, atkFou: 2000, hpFou: 2000, appendLevels: [0, 10, 0, 0, 10]);
    TeamSpec owner(CeSetup earthCe, {CeSetup? support, CeSetup? swapIn}) => TeamSpec([
      SlotSpec(ServantSetup.defaults(altriaCaster), ce: support),
      SlotSpec(built(earth), ce: earthCe),
      SlotSpec(built(draco), ce: CeSetup(flowerDoll, level: 80)),
      SlotSpec(ServantSetup.defaults(oberon), ce: swapIn),
    ], mysticCode: MysticCodeSetup(kDefaultMysticCodeId));
    const searchPlan = TurnPlan([
      [AutoSearch(maxSims: 3000)],
      [],
      [],
    ]);

    test('a Team Finder team (bond-CE support, bare Oberon) is solved', () async {
      final t = owner(CeSetup(eventCe), support: bond(altriaCaster));
      final out = await runner.run(t, node, searchPlan);
      expect(out.failure, isNull);
      expect(out.clearedAllWaves, isTrue);
      expect(out.turnsUsed, lessThanOrEqualTo(3));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Oberon carrying a CE does not make the team look hopeless (his NP makes the enemies invincible)', () async {
      final dec = CeSetup(eventCe, level: 1, limitBreak: false);
      final out = await runner.run(owner(dec, support: dec, swapIn: dec), node, searchPlan);
      expect(out.clearedAllWaves, isTrue, reason: out.failure ?? '');
      expect(out.searchTurns, greaterThan(3)); // not stopped by the quick check
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('choices that cannot fill the firing dealers\' gauges are dropped before any skill is used', () async {
      final battle = BattleData();
      final t = owner(CeSetup(eventCe), support: bond(altriaCaster));
      final s = PlanSearch(battle, t, node, turns: 3, maxSims: 3000);
      battle.delegate = BattleDelegate()..replaceMember = s.chooseSwap;
      final mc = MysticCodeData()
        ..mysticCode = db.gameData.mysticCodes[kDefaultMysticCodeId]!
        ..level = 10;
      await battle.init(node.phase, [for (final slot in t.slots) playerSvtDataFor(slot)], mc);
      expect(await s.run(), isTrue);
      // without the early drop this team used about 10 skill activations per turn played, with it about 4.5
      expect(s.skillUses, lessThan(s.sims * 7));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  test('the solver finds the two-dealer clear whichever order the box lists the dealers in', () async {
    final urdr = db.gameData.servantsNoDup[470]!.id;
    final strongIbuki = ServantSetup(
      svtId: summerIbuki,
      level: 120,
      npLevel: 5,
      atkFou: 2000,
      appendLevels: [0, 10, 0, 0, 0],
    );
    for (final box in [
      [strongIbuki, strongAltria, ServantSetup.defaults(oberon)],
      [strongAltria, strongIbuki, ServantSetup.defaults(oberon)],
    ]) {
      final last = await solve(
        SolveRequest(
          region: Region.jp,
          quest: node,
          box: box,
          friends: [ServantSetup.defaults(urdr)],
          ces: [CeSetup(eventCe, quantity: 2)],
        ),
        runner,
      ).last;
      expect(last.error, isNull);
      expect(
        last.results.any((r) => r.team.slots.skip(1).take(2).every((s) => s.ce?.ceId == eventCe)),
        isTrue,
        reason: 'box order ${box.map((e) => e.svtId).toList()}: ${last.results.length} viable of ${last.teamsTotal}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a team that cannot clear is reported as such, with the work spent in the message', () async {
    final out = await runner.run(team(ServantSetup.defaults(altriaSaber)), node, search);
    expect(out.clearedAllWaves, isFalse);
    expect(out.failure, contains('no clear found'));
  });

  test('the same team gives the same clear twice (deterministic)', () async {
    final a = await runner.run(team(strongAltria), node, search);
    final b = await runner.run(team(strongAltria), node, search);
    expect(a.log, b.log);
    expect(a.totalNpDamage, b.totalNpDamage);
  });

  test('the work cap is respected', () async {
    final battle = BattleData();
    final t = team(ServantSetup.defaults(altriaSaber));
    final s = PlanSearch(battle, t, node, turns: 3, maxSims: 20);
    battle.delegate = BattleDelegate()..replaceMember = s.chooseSwap;
    final mc = MysticCodeData()
      ..mysticCode = db.gameData.mysticCodes[kDefaultMysticCodeId]!
      ..level = 10;
    await battle.init(node.phase, [for (final slot in t.slots) playerSvtDataFor(slot)], mc);
    expect(await s.run(), isFalse);
    expect(s.sims, lessThanOrEqualTo(20 + 3)); // the up-front "can anything clear" check plays up to 3 turns
  });

  test('a failed search leaves the battle at its start (every choice is undone)', () async {
    final battle = BattleData();
    final t = team(ServantSetup.defaults(altriaSaber));
    final s = PlanSearch(battle, t, node, turns: 3, maxSims: 40);
    battle.delegate = BattleDelegate()..replaceMember = s.chooseSwap;
    final mc = MysticCodeData()
      ..mysticCode = db.gameData.mysticCodes[kDefaultMysticCodeId]!
      ..level = 10;
    await battle.init(node.phase, [for (final slot in t.slots) playerSvtDataFor(slot)], mc);
    final hp = battle.nonnullEnemies.map((e) => e.hp).toList();
    expect(await s.run(), isFalse);
    expect(battle.waveCount, 1);
    expect(battle.nonnullEnemies.map((e) => e.hp).toList(), hp);
    expect(s.log, isEmpty);
  });

  test('the search also finds the owner\'s loop on a quest where only the NP gauge matters', () async {
    final json = jsonDecode(jsonEncode(db.gameData.questPhases[9300040603]!.toJson())) as Map<String, dynamic>;
    for (final stage in json['stages'] as List) {
      for (final enemy in stage['enemies'] as List) {
        enemy['hp'] = 1;
      }
    }
    final easy = questSpecFromPhase(QuestPhase.fromJson(json));
    // the owner's loop team: double Castoria + Summer Ibuki, Oberon in the back
    final t = TeamSpec([
      SlotSpec(ServantSetup.defaults(altriaCaster), ce: bond(altriaCaster)),
      SlotSpec(ServantSetup.defaults(altriaCaster)),
      SlotSpec(ServantSetup.defaults(summerIbuki), ce: CeSetup(kBlackGrailCeId)),
      SlotSpec(ServantSetup.defaults(oberon)),
    ], mysticCode: MysticCodeSetup(kDefaultMysticCodeId));
    final out = await runner.run(t, easy, search);
    expect(out.clearedAllWaves, isTrue);
    expect(out.turnsUsed, 3); // 3 waves, one dies per turn
    expect(out.log.any((l) => l.contains(' swap ')), isTrue);
  });

  test('a team with several back-row servants is ruled out only when every one of them is', () async {
    ServantSetup built(int id) =>
        ServantSetup(svtId: id, level: 120, npLevel: 5, atkFou: 2000, hpFou: 2000, appendLevels: [0, 10, 0, 0, 10]);
    final front = [
      SlotSpec(ServantSetup.defaults(altriaCaster), ce: bond(altriaCaster)),
      SlotSpec(built(2300500), ce: CeSetup(eventCe, level: 1)),
      SlotSpec(built(3300100), ce: CeSetup(eventCe, level: 1)),
    ];
    final backs = [oberon, koyanskaya, altriaSaber];
    TeamSpec withBacks(List<int> ids) => TeamSpec([
      ...front,
      for (final id in ids) SlotSpec(ServantSetup.defaults(id), ce: CeSetup(eventCe, level: 1)),
    ], mysticCode: MysticCodeSetup(kDefaultMysticCodeId));
    Future<BattleOutcome> quick(TeamSpec t) => runner.run(t, node, planTurns(t, searchSims: 3).last);
    final together = await quick(withBacks(backs));
    final alone = [
      for (final b in backs) await quick(withBacks([b])),
    ];
    expect(together.searchCapped, alone.any((o) => o.searchCapped));
    expect(together.searchSlack, closeTo(alone.map((o) => o.searchSlack).reduce((a, b) => a > b ? a : b), 1e-9));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
