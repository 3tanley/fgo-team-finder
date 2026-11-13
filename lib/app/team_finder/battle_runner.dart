import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/battle/utils/battle_logger.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';

import 'models.dart';

abstract class BattleRunner {
  Future<BattleOutcome> run(TeamSpec team, QuestSpec quest, TurnPlan plan);
}

/// Builds the engine's servant input. Uses the latest (strengthened) skill and NP versions.
/// Throws [ArgumentError] for unknown servant or CE ids.
PlayerSvtData playerSvtDataFor(SlotSpec slot) {
  final s = slot.servant;
  final svt = db.gameData.servantsById[s.svtId];
  if (svt == null) throw ArgumentError.value(s.svtId, 'svtId', 'unknown servant');
  final data = PlayerSvtData.svt(svt)
    ..lv = s.level
    ..skills = [for (final n in kActiveSkillNums) svt.groupedActiveSkills[n]?.last]
    ..skillLvs = List.of(s.skillLevels)
    ..td = svt.groupedNoblePhantasms[1]?.last
    ..tdLv = s.npLevel
    ..atkFou = s.atkFou
    ..hpFou = s.hpFou;
  final ce = slot.ce;
  if (ce != null) {
    final entity = db.gameData.craftEssencesById[ce.ceId];
    if (entity == null) throw ArgumentError.value(ce.ceId, 'ceId', 'unknown craft essence');
    data.equip1 = SvtEquipData(ce: entity, lv: ce.level, limitBreak: ce.limitBreak);
  }
  return data;
}

/// Runs a plan on Chaldea's own battle engine. The engine's default damage roll is the minimum roll,
/// which is what the spec wants ("viable" = guaranteed); battle_runner_test.dart pins that.
class EngineBattleRunner implements BattleRunner {
  @override
  Future<BattleOutcome> run(TeamSpec team, QuestSpec quest, TurnPlan plan) async {
    final battle = BattleData();
    final mcSetup = team.mysticCode;
    MysticCodeData? mysticCode;
    if (mcSetup != null) {
      final code = db.gameData.mysticCodes[mcSetup.id];
      if (code == null) throw ArgumentError.value(mcSetup.id, 'mysticCode', 'unknown mystic code');
      mysticCode = MysticCodeData()
        ..mysticCode = code
        ..level = mcSetup.level;
    }
    await battle.init(quest.phase, [for (final slot in team.slots) playerSvtDataFor(slot)], mysticCode);

    String? failure;
    var turnsPlayed = 0; // the engine's totalTurnCount is the *next* turn number, so count ourselves
    turns:
    for (final (turnNo, actions) in plan.turns.indexed) {
      if (battle.isBattleWin || battle.isBattleFinished) break;
      for (final action in actions.whereType<SkillAction>()) {
        final svt = battle.onFieldAllyServants.getOrNull(action.servantIndex);
        if (svt == null ||
            svt.skillInfoList.length <= action.skillIndex ||
            svt.skillInfoList[action.skillIndex].chargeTurn > 0 ||
            !battle.canUseSvtSkillIgnoreCoolDown(action.servantIndex, action.skillIndex)) {
          failure = 'turn ${turnNo + 1}: servant ${action.servantIndex} cannot use skill ${action.skillIndex}';
          break turns;
        }
        battle.playerTargetIndex = action.targetIndex ?? 0;
        await battle.activateSvtSkill(action.servantIndex, action.skillIndex);
      }
      final queued = <BattleServantData>{};
      final nps = <CombatAction>[];
      void queue(BattleServantData svt) {
        if (queued.add(svt)) nps.add(CombatAction(svt, svt.getNPCard()!));
      }

      for (final action in actions) {
        switch (action) {
          case SkillAction():
            break; // already done above
          case NpAction():
            final svt = battle.onFieldAllyServants.getOrNull(action.servantIndex);
            if (svt == null || !svt.canNP()) {
              failure = 'turn ${turnNo + 1}: servant ${action.servantIndex} cannot NP (not charged or unavailable)';
              break turns;
            }
            queue(svt);
          case AutoNps():
            final ready = battle.onFieldAllyServants.whereType<BattleServantData>().where((s) => s.canNP()).toList();
            bool damaging(BattleServantData s) =>
                s.getCurrentNP()?.functions.any((f) => f.funcType.isDamageNp) ?? false;
            ready.where((s) => !damaging(s)).forEach(queue);
            ready.where(damaging).forEach(queue);
        }
      }
      await battle.playerTurn(nps, allowSkip: true);
      turnsPlayed += 1;
    }

    final npDamage = battle.recorder.records
        .whereType<BattleAttackRecord>()
        .where((r) => r.card?.isTD == true)
        .fold<int>(0, (sum, r) => sum + r.damage);
    return BattleOutcome(
      clearedAllWaves: failure == null && battle.isBattleWin,
      turnsUsed: turnsPlayed,
      totalNpDamage: npDamage,
      unverified: quest.unsupportedGimmicks.isNotEmpty,
      failure: failure,
    );
  }
}
