import 'dart:math';

import 'package:chaldea/models/gamedata/individuality.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';

import 'models.dart';
import 'team_generator.dart' show isDamageDealer, npCardType;

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

/// True if the servant's NP hits every enemy.
bool _isAoe(ServantSetup s) =>
    db.gameData.servantsById[s.svtId]?.groupedNoblePhantasms[1]?.lastOrNull?.functions.any(
      (f) => f.funcType.isDamageNp && f.funcTargetType == FuncTargetType.enemyAll,
    ) ??
    false;

/// The servant's ATK at its level with its ATK fou, times its class's damage rate (Berserker hits harder than Archer).
double _atk(ServantSetup s) {
  final svt = db.gameData.servantsById[s.svtId];
  if (svt == null) return 0;
  final rate = (ConstData.classInfo[svt.classId]?.attackRate ?? 1000) / 1000;
  return ((svt.atkGrowth.getOrNull(s.level - 1) ?? 0) + s.atkFou) * rate;
}

const _cardTrait = {CardType.arts: 4001, CardType.buster: 4002, CardType.quick: 4003};

/// NP card multiplier on damage: Buster 1.5, Arts 1, Quick 0.8.
const _cardDamage = {CardType.buster: 1.5, CardType.arts: 1.0, CardType.quick: 0.8};

/// What the skills of [from] add for a dealer whose NP card is [card] against [enemy], in the game's three groups
/// that multiply each other (1 = +100%): attack up, card-type up, and NP / plain damage up (trait-gated ones when the
/// enemy has the trait). A skill that targets only its caster counts only when [from] is the dealer itself.
({double atk, double card, double power}) _buffsFor(ServantSetup from, bool isDealer, CardType? card, EnemySpec enemy) {
  var atk = 0.0, cardUp = 0.0, power = 0.0;
  final svt = db.gameData.servantsById[from.svtId];
  for (final (n, lv) in from.skillLevels.indexed) {
    for (final f in svt?.groupedActiveSkills[n + 1]?.lastOrNull?.functions ?? const <NiceFunction>[]) {
      if (f.funcTargetType.isEnemy || (f.funcTargetType == FuncTargetType.self && !isDealer)) continue;
      final value = ((f.svals.getOrNull(lv - 1) ?? f.svals.firstOrNull)?.Value ?? 0) / 1000;
      for (final b in f.buffs) {
        final gated = b.ckOpIndv.isEmpty || _hits(enemy, b.ckOpIndv);
        switch (b.type) {
          case BuffType.upAtk:
            atk += value;
          case BuffType.upCommandall:
            cardUp += value;
          case BuffType.upCommandatk:
            if (b.ckSelfIndv.isEmpty || b.ckSelfIndv.contains(_cardTrait[card])) cardUp += value;
          case BuffType.upDamage ||
              BuffType.upNpdamage ||
              BuffType.upDamageIndividuality ||
              BuffType.upDamageIndividualityActiveonly:
            if (gated) power += value;
          default:
        }
      }
    }
  }
  return (atk: atk, card: cardUp, power: power);
}

/// How likely the team is to clear the quest with one NP round per wave, as a rough number to rank teams by (higher
/// = tried first), not a damage estimate. Each of the two front dealers fires once per wave with every skill of the
/// team on it (an upper-end guess, like the quick check); an area NP hits every enemy, a single-target one the
/// enemy with the most HP still standing. A wave is worth how well its weakest enemy is covered (capped, since
/// overkill buys nothing); the team's score is the sum over waves. Class advantage and CEs are not in it.
double teamPotential(TeamSpec team, QuestSpec quest) {
  final dealers = [
    for (final slot in team.slots.skip(1).take(2))
      if (isDamageDealer(slot.servant.svtId)) slot.servant,
  ];
  var score = 0.0;
  for (final wave in quest.waves) {
    if (wave.enemies.isEmpty) continue;
    final dealt = List<double>.filled(wave.enemies.length, 0);
    final single = <List<double>>[]; // per single-target dealer: its damage on each enemy
    for (final s in dealers) {
      final card = npCardType(s.svtId);
      final onEach = [
        for (final e in wave.enemies)
          () {
            final all = [for (final x in team.slots) _buffsFor(x.servant, identical(x.servant, s), card, e)];
            double sum(double Function(({double atk, double card, double power})) f) =>
                all.fold(0.0, (a, b) => a + f(b));
            return _atk(s) *
                0.23 *
                (_cardDamage[card] ?? 1) *
                _npRate(s, e) *
                (1 + sum((b) => b.atk)) *
                (1 + sum((b) => b.card)) *
                (1 + sum((b) => b.power));
          }(),
      ];
      if (_isAoe(s)) {
        for (final (i, d) in onEach.indexed) {
          dealt[i] += d;
        }
      } else {
        single.add(onEach);
      }
    }
    for (final hit in single) {
      var target = 0; // the enemy with the most HP left
      for (final (i, e) in wave.enemies.indexed) {
        if (e.hp - dealt[i] > wave.enemies[target].hp - dealt[target]) target = i;
      }
      dealt[target] += hit[target];
    }
    final cover = [for (final (i, e) in wave.enemies.indexed) dealt[i] / max(1, e.hp)];
    score += cover.map((c) => min(c, 1.5)).reduce(min) + 0.001 * cover.fold(0.0, (a, c) => a + min(c, 5));
  }
  return score;
}

/// [teams] with the likeliest first (highest [teamPotential] on the quest), ties in their given order. Only the order
/// changes: no team is dropped.
List<TeamSpec> prioritized(List<TeamSpec> teams, QuestSpec quest) {
  if (quest.waves.every((w) => w.enemies.isEmpty)) return teams;
  final score = {for (final t in teams) t: teamPotential(t, quest)};
  final order = {for (final (i, t) in teams.indexed) t: i};
  return [...teams]..sort((a, b) {
    final c = score[b]!.compareTo(score[a]!);
    return c != 0 ? c : order[a]!.compareTo(order[b]!);
  });
}
