import 'dart:math';

import 'package:chaldea/models/gamedata/individuality.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';

import 'models.dart';
import 'team_generator.dart' show isDamageDealer;

/// The enemy with the most HP in the whole quest, or null when the quest has none.
EnemySpec? heaviestEnemy(QuestSpec quest) {
  EnemySpec? best;
  for (final wave in quest.waves) {
    for (final e in wave.enemies) {
      if (best == null || e.hp > best.hp) best = e;
    }
  }
  return best;
}

bool _hits(EnemySpec enemy, List<int> signedTraits) =>
    signedTraits.isNotEmpty &&
    Individuality.checkSignedIndivPartialMatch(self: enemy.traits, signedTarget: signedTraits);

/// The NP's damage rate against [enemy] (1 = 100% of the card), with its trait special attack applied when the
/// enemy has the trait. 0 for a servant whose NP does no damage.
double _npRate(ServantSetup s, EnemySpec enemy) {
  final np = db.gameData.servantsById[s.svtId]?.groupedNoblePhantasms[1]?.lastOrNull;
  var rate = 0.0;
  for (final f in np?.functions ?? const <NiceFunction>[]) {
    if (!f.funcType.isDamageNp) continue;
    final v = f.svals.getOrNull(s.npLevel - 1) ?? f.svals.firstOrNull;
    if (v == null) continue;
    var special = 1.0;
    switch (f.funcType) {
      case FuncType.damageNpIndividual:
        if (v.Target != null && _hits(enemy, [v.Target!])) special = (v.Correction ?? 1000) / 1000;
      case FuncType.damageNpIndividualSum:
        final n = (v.TargetList ?? const <int>[]).where((t) => _hits(enemy, [t])).length;
        final base = v.Value2 ?? 1000;
        if (n > 0 && base > 0) special = (base + n * (v.Correction ?? 0)) / base;
      default: // other special rates read the enemy's buffs, HP or rarity, which are not known here
    }
    rate = max(rate, (v.Value ?? 0) / 1000 * special); // an NP's damage functions split the targets: not added
  }
  return rate;
}

/// The bonus (1 = +100%) from the servant's skills that raise damage only against enemies like [enemy].
double _traitBuffs(ServantSetup s, EnemySpec enemy) {
  const kinds = {
    BuffType.upDamage,
    BuffType.upNpdamage,
    BuffType.upDamageIndividuality,
    BuffType.upDamageIndividualityActiveonly,
  };
  var sum = 0.0;
  final svt = db.gameData.servantsById[s.svtId];
  for (final (n, lv) in s.skillLevels.indexed) {
    for (final f in svt?.groupedActiveSkills[n + 1]?.lastOrNull?.functions ?? const <NiceFunction>[]) {
      if (!f.buffs.any((b) => kinds.contains(b.type) && _hits(enemy, b.ckOpIndv))) continue;
      sum += ((f.svals.getOrNull(lv - 1) ?? f.svals.firstOrNull)?.Value ?? 0) / 1000;
    }
  }
  return sum;
}

/// How well the team's damage fits the heaviest enemy: each front damage dealer's NP rate against it (trait
/// special attacks included), raised by the team's skills that boost damage against it. It is only a rough ranking
/// to decide who is simulated first, not a damage estimate: ATK, cards, class and CEs are not in it.
double teamPriority(TeamSpec team, EnemySpec enemy) {
  final bonus = team.slots.fold(0.0, (sum, slot) => sum + _traitBuffs(slot.servant, enemy));
  var score = 0.0;
  for (final slot in team.slots.skip(1).take(2)) {
    if (isDamageDealer(slot.servant.svtId)) score += _npRate(slot.servant, enemy) * (1 + bonus);
  }
  return score;
}

/// [teams] with the likeliest first (highest [teamPriority] against the quest's heaviest enemy), ties in their
/// given order. Only the order changes: no team is dropped.
List<TeamSpec> prioritized(List<TeamSpec> teams, QuestSpec quest) {
  final enemy = heaviestEnemy(quest);
  if (enemy == null) return teams;
  final score = {for (final t in teams) t: teamPriority(t, enemy)};
  final order = {for (final (i, t) in teams.indexed) t: i};
  return [...teams]..sort((a, b) {
    final c = score[b]!.compareTo(score[a]!);
    return c != 0 ? c : order[a]!.compareTo(order[b]!);
  });
}
