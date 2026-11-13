import 'package:chaldea/app/battle/interactions/_delegate.dart';
import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/battle/utils/battle_logger.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';

import 'loop_policy.dart';
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
  /// Called with the finished battle, so a check can read the engine's damage records (never used by the app).
  final void Function(BattleData battle)? onFinished;
  EngineBattleRunner({this.onFinished});

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
    final policy = LoopPolicy();
    battle.delegate = BattleDelegate()..replaceMember = policy.chooseSwap;
    await battle.init(quest.phase, [for (final slot in team.slots) playerSvtDataFor(slot)], mysticCode);

    String? failure;
    final log = <String>[];
    var turnsPlayed = 0; // the engine's totalTurnCount is the *next* turn number, so count ourselves
    turns:
    for (final (turnNo, actions) in plan.turns.indexed) {
      if (battle.isBattleWin || battle.isBattleFinished) break;
      if (actions.any((a) => a is AutoLoop)) await policy.playSkills(battle, team, quest, turnNo, log);
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
        log.add('T${turnNo + 1} skill ${action.servantIndex}.${action.skillIndex + 1} -> ${action.targetIndex ?? 0}');
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
          case AutoNps() || AutoLoop():
            final ready = battle.onFieldAllyServants.whereType<BattleServantData>().where((s) => s.canNP()).toList();
            bool damaging(BattleServantData s) =>
                s.getCurrentNP()?.functions.any((f) => f.funcType.isDamageNp) ?? false;
            ready.where((s) => !damaging(s)).forEach(queue);
            ready.where(damaging).forEach(queue);
        }
      }
      for (final np in nps) {
        log.add('T${turnNo + 1} np ${battle.onFieldAllyServants.indexOf(np.actor)}');
      }
      await battle.playerTurn(nps, allowSkip: true);
      turnsPlayed += 1;
      // One wave can die per turn, so once a wave outlives the slack the plan cannot finish: stop early.
      final slack = plan.turns.length - quest.waves.length;
      if (!battle.isBattleWin && battle.waveCount < turnsPlayed + 1 - slack) break;
    }

    final npDamage = battle.recorder.records
        .whereType<BattleAttackRecord>()
        .where((r) => r.card?.isTD == true)
        .fold<int>(0, (sum, r) => sum + r.damage);
    onFinished?.call(battle);
    return BattleOutcome(
      clearedAllWaves: failure == null && battle.isBattleWin,
      turnsUsed: turnsPlayed,
      totalNpDamage: npDamage,
      unverified: quest.unsupportedGimmicks.isNotEmpty,
      failure: failure,
      log: log,
    );
  }
}
