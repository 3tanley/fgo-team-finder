import 'package:tuple/tuple.dart';

import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';

import 'defaults.dart';
import 'models.dart';
import 'team_generator.dart';

/// The owner's loop, played turn by turn against the live battle state (see handoff.md):
/// 1. Turn 1: every non-attacker's non-charging skills (Castoria S3) on the attacker, then the attacker's own
///    non-charging buffs.
/// 2. Then charge the attacker with skills, only until its NP is full, so the rest are kept for later turns.
///    Priority: the attacker's own charge skills, then the others' targeted charge skills (Castoria S2),
///    then their party-wide ones (Castoria S1), each in slot order.
/// 3. Final wave: swap the non-attacker with the fewest ready skills for the first back-row servant with the
///    mystic code, use the swap-in's skills 1, 2, 3, then the mystic code's attack/NP-damage buff.
/// The attacker is the Black Grail holder. Targets are always the attacker.
/// shortcut: one fixed rule set (no search over alternatives); add alternatives when more loops are known.
class LoopPolicy {
  /// The pair the engine's order-change callback should pick; set just before using the swap skill.
  Tuple2<BattleServantData, BattleServantData>? pendingSwap;

  Future<Tuple2<BattleServantData, BattleServantData>?> chooseSwap(
    List<BattleServantData?> onField,
    List<BattleServantData?> backup,
  ) async => pendingSwap;

  static int attackerIndex(TeamSpec team) {
    final holder = team.slots.indexWhere((s) => s.ce?.ceId == kBlackGrailCeId);
    return holder >= 0 ? holder : team.slots.indexWhere((s) => isDamageDealer(s.servant.svtId));
  }

  Future<void> playSkills(BattleData battle, TeamSpec team, QuestSpec quest, int turnNo, List<String> log) async {
    final t = turnNo + 1;
    final attacker = attackerIndex(team);
    if (attacker < 0 || attacker >= 3) return; // only front-row attackers are handled
    const front = [0, 1, 2];
    final others = front.where((i) => i != attacker).toList();

    BattleServantData? svt(int i) => battle.onFieldAllyServants.getOrNull(i);
    bool ready(int i, int s) {
      final x = svt(i);
      return x != null &&
          s < x.skillInfoList.length &&
          x.skillInfoList[s].chargeTurn == 0 &&
          battle.canUseSvtSkillIgnoreCoolDown(i, s);
    }

    bool charges(int i, int s) =>
        svt(i)?.skillInfoList[s].skill?.functions.any((f) => f.funcType == FuncType.gainNp) ?? false;
    bool targeted(int i, int s) =>
        svt(i)?.skillInfoList[s].skill?.functions.any((f) => f.funcTargetType.needNormalOneTarget) ?? false;
    bool full() => (svt(attacker)?.np ?? 0) >= 10000;
    Future<void> use(int i, int s) async {
      battle.playerTargetIndex = attacker;
      await battle.activateSvtSkill(i, s);
      log.add('T$t skill $i.${s + 1} -> $attacker');
    }

    if (turnNo == 0) {
      for (final i in [...others, attacker]) {
        for (var s = 0; s < 3; s++) {
          if (ready(i, s) && !charges(i, s)) await use(i, s);
        }
      }
    }

    final mc = battle.mysticCode;
    int mcSkill(bool Function(NiceSkill) test) => mc?.skills.indexWhere(test) ?? -1;
    bool mcReady(int i) =>
        i >= 0 &&
        i < battle.masterSkillInfo.length &&
        battle.masterSkillInfo[i].chargeTurn == 0 &&
        battle.canUseMysticCodeSkillIgnoreCoolDown(i);
    final finalWave = battle.waveCount >= quest.waves.length;
    final swapSkill = mcSkill((s) => s.functions.any((f) => f.funcType == FuncType.replaceMember));

    if (finalWave && mcReady(swapSkill)) {
      final swapIn = battle.backupAllyServants
          .whereType<BattleServantData>()
          .where((s) => s.canOrderChange())
          .firstOrNull;
      final candidates = others.where((i) => svt(i)?.canOrderChange() == true).toList();
      if (swapIn != null && candidates.isNotEmpty) {
        int readySkills(int i) => [0, 1, 2].where((s) => ready(i, s)).length;
        // fewest ready skills goes out; on a tie the later slot
        final outIdx = candidates.reduce((a, b) => readySkills(b) <= readySkills(a) ? b : a);
        final inSlot = 3 + battle.backupAllyServants.indexOf(swapIn);
        pendingSwap = Tuple2(svt(outIdx)!, swapIn);
        await battle.activateMysticCodeSkill(swapSkill);
        pendingSwap = null;
        log.add('T$t swap $outIdx <-> $inSlot');
        for (var s = 0; s < 3; s++) {
          if (ready(outIdx, s)) await use(outIdx, s);
        }
      }
    }

    if (!full()) {
      final order = <(int, int)>[
        for (var s = 0; s < 3; s++)
          if (charges(attacker, s)) (attacker, s),
        for (final i in others)
          for (var s = 0; s < 3; s++)
            if (charges(i, s) && targeted(i, s)) (i, s),
        for (final i in others)
          for (var s = 0; s < 3; s++)
            if (charges(i, s) && !targeted(i, s)) (i, s),
      ];
      for (final (i, s) in order) {
        if (full()) break;
        if (ready(i, s)) await use(i, s);
      }
    }

    if (finalWave) {
      final buffSkill = mcSkill(
        (s) => s.functions.any((f) => f.buffs.any((b) => b.type == BuffType.upAtk || b.type == BuffType.upNpdamage)),
      );
      if (mcReady(buffSkill)) {
        await battle.activateMysticCodeSkill(buffSkill);
        log.add('T$t mc ${buffSkill + 1}');
      }
    }
    log.add('T$t attacker NP ${(svt(attacker)?.np ?? 0) ~/ 100}% on wave ${battle.waveCount}');
  }
}
