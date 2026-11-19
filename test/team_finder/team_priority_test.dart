import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/team_generator.dart';
import 'package:chaldea/app/team_finder/team_priority.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int altria = 100100;
const int castoria = 504500;

void main() async {
  await initiateForTest();

  /// A damage dealer whose NP hits one trait harder (damageNpIndividual), and that trait with its multiplier.
  (int svtId, int trait, int correction) specialDealer() {
    for (final svt in db.gameData.servantsNoDup.values) {
      if (svt.rarity < 4) continue;
      for (final f in svt.groupedNoblePhantasms[1]?.lastOrNull?.functions ?? const <NiceFunction>[]) {
        if (f.funcType != FuncType.damageNpIndividual) continue;
        final v = f.svals.first;
        if (v.Target != null && v.Target! > 0 && (v.Correction ?? 0) >= 1500) return (svt.id, v.Target!, v.Correction!);
      }
    }
    throw StateError('no special-attack NP in the data');
  }

  EnemySpec enemy(List<int> traits, {int hp = 1000}) =>
      EnemySpec(hp: hp, classId: 1, attribute: 'earth', traits: traits);
  TeamSpec team(int dealer) => TeamSpec([
    SlotSpec(ServantSetup.defaults(castoria)),
    SlotSpec(ServantSetup.defaults(dealer)),
    SlotSpec(ServantSetup.defaults(castoria)),
  ]);
  QuestSpec quest(List<EnemySpec> enemies) => QuestSpec(
    questId: 1,
    waves: [
      for (final e in enemies) WaveSpec([e]),
    ],
    unsupportedGimmicks: const [],
    phase: db.gameData.questPhases.values.first,
  );

  test('the heaviest enemy is the one with the most HP over all waves', () {
    final q = quest([
      enemy([1], hp: 10),
      enemy([2], hp: 99),
      enemy([3], hp: 50),
    ]);
    expect(heaviestEnemy(q)!.traits, [2]);
    expect(heaviestEnemy(quest(const [])), isNull);
  });

  test('an NP with a special attack scores higher against an enemy that has the trait', () {
    final (svt, trait, correction) = specialDealer();
    final hit = teamPriority(team(svt), enemy([trait]));
    final miss = teamPriority(team(svt), enemy([999999]));
    // at least the special attack; more when the servant's own skills also boost damage against that trait
    expect(hit / miss, greaterThanOrEqualTo(correction / 1000 - 0.001));
  });

  test('a buff-only NP scores zero', () {
    expect(isDamageDealer(castoria), isFalse);
    expect(teamPriority(team(castoria), enemy(const [])), 0);
  });

  test('prioritized puts the trait-matching team first and drops nothing', () {
    final (svt, trait, _) = specialDealer();
    final teams = [team(altria), team(castoria), team(svt)];
    final q = quest([
      enemy([trait], hp: 5000),
      enemy(const [], hp: 10),
    ]);
    final sorted = prioritized(teams, q);
    expect(sorted.first, same(teams[2]));
    expect(sorted.toSet(), teams.toSet());
    expect(sorted.length, teams.length);
    // no enemy: the order is untouched
    expect(prioritized(teams, quest(const [])), teams);
  });
}
