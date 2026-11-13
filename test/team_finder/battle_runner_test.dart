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
}
