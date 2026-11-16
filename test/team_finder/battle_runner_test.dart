import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/battle/utils/battle_logger.dart';
import 'package:chaldea/app/team_finder/battle_runner.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/quest_loader.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int altria = 100100;
const int kaleidoscope = 9400340; // starts the servant at 100% NP

void main() async {
  await initiateForTest();

  final runner = EngineBattleRunner();
  // The quest Chaldea's own battle_test uses; wave 1 has a sky caster at enemy index 1.
  final chaldeaQuest = db.gameData.questPhases[9300040603]!;
  final quest = questSpecFromPhase(chaldeaQuest);

  TeamSpec soloAltria({CeSetup? ce}) => TeamSpec([SlotSpec(ServantSetup(svtId: altria, atkFou: 0, hpFou: 0), ce: ce)]);
  final charged = CeSetup(kaleidoscope);

  test('playerSvtDataFor uses the latest skill and NP versions, the user levels, and the CE', () {
    final svt = db.gameData.servantsById[altria]!;
    final data = playerSvtDataFor(
      SlotSpec(
        ServantSetup(svtId: altria, level: 80, skillLevels: [6, 7, 8], npLevel: 3),
        ce: charged,
      ),
    );
    expect(data.td, svt.groupedNoblePhantasms[1]!.last);
    expect(data.skills, [for (final n in kActiveSkillNums) svt.groupedActiveSkills[n]!.last]);
    expect(data.lv, 80);
    expect(data.skillLvs, [6, 7, 8]);
    expect(data.tdLv, 3);
    expect(data.equip1.ce?.id, kaleidoscope);
    expect(data.equip1.lv, 100);
    expect(data.equip1.limitBreak, isTrue);
  });

  test('playerSvtDataFor passes the append skill levels to the engine, 0 meaning not unlocked', () {
    expect(playerSvtDataFor(SlotSpec(ServantSetup(svtId: altria))).appendLvs, [0, 0, 0, 0, 0]);
    final data = playerSvtDataFor(SlotSpec(ServantSetup(svtId: altria, appendLevels: [10, 0, 0, 5, 0])));
    expect(data.appendLvs, [10, 0, 0, 5, 0]);
  });

  test('append levels above 0 really give the servant their append passives in battle', () async {
    Future<int> buffCount(List<int> appends) async {
      final b = BattleData();
      await b.init(chaldeaQuest, [
        playerSvtDataFor(SlotSpec(ServantSetup(svtId: altria, appendLevels: appends))),
      ], null);
      return b.nonnullPlayers.first.getAllBuffs(b).length;
    }

    final none = await buffCount([0, 0, 0, 0, 0]);
    final all = await buffCount([10, 10, 10, 10, 10]);
    expect(all, greaterThan(none));
  });

  test('an NP that is not charged ends the run uncleared with zero damage', () async {
    final out = await runner.run(
      soloAltria(),
      quest,
      const TurnPlan([
        [NpAction(0)],
      ]),
    );
    expect(out.clearedAllWaves, isFalse);
    expect(out.totalNpDamage, 0);
    expect(out.failure, contains('cannot NP'));
  });

  test('a charged NP damages the enemies and the recorded damage matches the engine HP loss', () async {
    // Reference run straight on the engine, exactly as Chaldea's own test does it.
    final ref = BattleData();
    await ref.init(chaldeaQuest, [playerSvtDataFor(soloAltria(ce: charged).slots.first)], null);
    final hpBefore = {for (final e in ref.nonnullEnemies) e.uniqueId: e.hp};
    final altriaRef = ref.nonnullPlayers.first;
    expect(altriaRef.canNP(), isTrue);
    await ref.playerTurn([CombatAction(altriaRef, altriaRef.getNPCard()!)]);
    final hpLoss = ref.nonnullEnemies.fold<int>(0, (sum, e) => sum + (hpBefore[e.uniqueId] ?? e.hp) - e.hp);

    final out = await runner.run(
      soloAltria(ce: charged),
      quest,
      const TurnPlan([
        [NpAction(0)],
      ]),
    );
    expect(out.totalNpDamage, greaterThan(0));
    expect(out.totalNpDamage, hpLoss); // nothing died in wave 1, so no overkill to tell them apart
    expect(out.turnsUsed, 1);
  });

  test('a quest with an unsupported gimmick marks the outcome unverified', () async {
    final flagged = QuestSpec(
      questId: quest.questId,
      waves: quest.waves,
      unsupportedGimmicks: const [kGimmickShift],
      phase: quest.phase,
    );
    final out = await runner.run(
      soloAltria(ce: charged),
      flagged,
      const TurnPlan([
        [NpAction(0)],
      ]),
    );
    expect(out.unverified, isTrue);
    final clean = await runner.run(
      soloAltria(ce: charged),
      quest,
      const TurnPlan([
        [NpAction(0)],
      ]),
    );
    expect(clean.unverified, isFalse);
  });

  test('clearing a quest stops the run early and reports the turns used', () async {
    // Real one-wave quest with every enemy cut to 1 HP, so one NP surely clears it.
    final base = db.gameData.questPhases.values.firstWhere((q) => q.stages.map((s) => s.wave).toSet().length == 1);
    final json = jsonDecode(jsonEncode(base.toJson())) as Map<String, dynamic>;
    for (final stage in json['stages'] as List) {
      for (final enemy in stage['enemies'] as List) {
        enemy['hp'] = 1;
      }
    }
    final out = await runner.run(
      soloAltria(ce: charged),
      questSpecFromPhase(QuestPhase.fromJson(json)),
      const TurnPlan([
        [NpAction(0)],
        [],
        [],
      ]),
    );
    expect(out.clearedAllWaves, isTrue);
    expect(out.turnsUsed, 1);
  });

  test('uses the minimum damage roll, so "viable" means guaranteed', () async {
    Future<int> directNpDamage(int random) async {
      final b = BattleData();
      await b.init(chaldeaQuest, [playerSvtDataFor(soloAltria(ce: charged).slots.first)], null);
      b.options.random = random;
      final a = b.nonnullPlayers.first;
      await b.playerTurn([CombatAction(a, a.getNPCard()!)]);
      return b.recorder.records
          .whereType<BattleAttackRecord>()
          .where((r) => r.card?.isTD == true)
          .fold<int>(0, (sum, r) => sum + r.damage);
    }

    final min = await directNpDamage(ConstData.constants.attackRateRandomMin);
    final max = await directNpDamage(ConstData.constants.attackRateRandomMax - 1);
    expect(min, lessThan(max), reason: 'the roll must actually change the damage for this test to mean anything');
    final out = await runner.run(
      soloAltria(ce: charged),
      quest,
      const TurnPlan([
        [NpAction(0)],
      ]),
    );
    expect(out.totalNpDamage, min);
  });

  test('an unknown mystic code id is rejected, not silently ignored', () async {
    final team = TeamSpec(soloAltria(ce: charged).slots, mysticCode: MysticCodeSetup(-1));
    expect(
      runner.run(
        team,
        quest,
        const TurnPlan([
          [NpAction(0)],
        ]),
      ),
      throwsArgumentError,
    );
  });

  test('a valid mystic code (Chaldea default 210) is applied without changing NP-only damage', () async {
    final plain = await runner.run(
      soloAltria(ce: charged),
      quest,
      const TurnPlan([
        [NpAction(0)],
      ]),
    );
    final team = TeamSpec(soloAltria(ce: charged).slots, mysticCode: MysticCodeSetup(210));
    final withMc = await runner.run(
      team,
      quest,
      const TurnPlan([
        [NpAction(0)],
      ]),
    );
    expect(withMc.totalNpDamage, plain.totalNpDamage);
  });

  test('AutoNps fires every charged NP: same result as naming it', () async {
    final named = await runner.run(
      soloAltria(ce: charged),
      quest,
      const TurnPlan([
        [NpAction(0)],
      ]),
    );
    final auto = await runner.run(
      soloAltria(ce: charged),
      quest,
      const TurnPlan([
        [AutoNps()],
      ]),
    );
    expect(auto.totalNpDamage, greaterThan(0));
    expect(auto.totalNpDamage, named.totalNpDamage);
  });

  test('AutoNps with nothing charged just passes the turn, it is not a failure', () async {
    final out = await runner.run(
      soloAltria(),
      quest,
      const TurnPlan([
        [AutoNps()],
      ]),
    );
    expect(out.failure, isNull);
    expect(out.clearedAllWaves, isFalse);
    expect(out.turnsUsed, 1);
    expect(out.totalNpDamage, 0);
  });

  test('AutoNps fires buff NPs (Castoria) before damage NPs (Altria)', () async {
    final team = TeamSpec([
      SlotSpec(ServantSetup(svtId: altria, atkFou: 0, hpFou: 0), ce: charged),
      SlotSpec(ServantSetup.defaults(504500), ce: charged), // Castoria: buff NP, no damage
    ]);
    Future<int> damage(List<TurnAction> actions) async =>
        (await runner.run(team, quest, TurnPlan([actions]))).totalNpDamage;
    final damageFirst = await damage(const [NpAction(0), NpAction(1)]);
    final buffFirst = await damage(const [NpAction(1), NpAction(0)]);
    expect(buffFirst, isNot(damageFirst), reason: 'order must change the damage or this test proves nothing');
    expect(await damage(const [AutoNps()]), buffFirst);
  });

  test('a plan is abandoned as soon as a wave survives its turn (3 waves, 3 turns leaves no slack)', () async {
    expect(quest.waves.length, 3);
    final out = await runner.run(
      soloAltria(ce: charged),
      quest,
      const TurnPlan([
        [AutoNps()],
        [AutoNps()],
        [AutoNps()],
      ]),
    );
    expect(out.clearedAllWaves, isFalse);
    expect(out.turnsUsed, 1, reason: 'wave 1 survived turn 1, so turns 2 and 3 cannot be enough');
  });

  test('with one turn of slack (4 turns for 3 waves) it gives up one turn later', () async {
    final out = await runner.run(
      soloAltria(ce: charged),
      quest,
      const TurnPlan([
        [AutoNps()],
        [AutoNps()],
        [AutoNps()],
        [AutoNps()],
      ]),
    );
    expect(out.turnsUsed, 2);
  });
}
