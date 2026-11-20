import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/team_generator.dart';
import 'package:chaldea/app/team_finder/team_priority.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int altria = 100100;
const int castoria = 504500;
const int earth = 2300500; // Archetype: EARTH, a Buster area NP

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
  TeamSpec team(ServantSetup dealer) => TeamSpec([
    SlotSpec(ServantSetup.defaults(castoria)),
    SlotSpec(dealer),
    SlotSpec(ServantSetup.defaults(castoria)),
  ]);
  QuestSpec quest(List<List<EnemySpec>> waves) => QuestSpec(
    questId: 1,
    waves: [for (final w in waves) WaveSpec(w)],
    unsupportedGimmicks: const [],
    phase: db.gameData.questPhases.values.first,
  );
  // HP far above any estimate, so the score is not capped and shows the damage
  const huge = 100000000;
  ServantSetup built(int id) => ServantSetup(svtId: id, level: 120, npLevel: 5, atkFou: 2000, hpFou: 2000);

  test('an NP with a special attack scores higher against an enemy that has the trait', () {
    final (svt, trait, correction) = specialDealer();
    final hit = teamPotential(
      team(ServantSetup.defaults(svt)),
      quest([
        [
          enemy([trait], hp: huge),
        ],
      ]),
    );
    final miss = teamPotential(
      team(ServantSetup.defaults(svt)),
      quest([
        [
          enemy([999999], hp: huge),
        ],
      ]),
    );
    // at least the special attack; more when the servant's own skills also boost damage against that trait
    expect(hit / miss, greaterThanOrEqualTo(correction / 1000 - 0.001));
  });

  test('a buff-only team scores zero', () {
    expect(isDamageDealer(castoria), isFalse);
    final q = quest([
      [enemy(const [], hp: huge)],
    ]);
    expect(teamPotential(team(ServantSetup.defaults(castoria)), q), 0);
  });

  test('the same servant scores higher when built up (level, NP level, fou)', () {
    final q = quest([
      [enemy(const [], hp: huge)],
    ]);
    expect(teamPotential(team(built(altria)), q), greaterThan(teamPotential(team(ServantSetup.defaults(altria)), q)));
  });

  test('an area NP kills a wave of two enemies as easily as a wave of one', () {
    final two = quest([
      [enemy(const [], hp: 60000), enemy(const [], hp: 60000)],
    ]);
    final one = quest([
      [enemy(const [], hp: 60000)],
    ]);
    expect(teamPotential(team(built(earth)), two), closeTo(teamPotential(team(built(earth)), one), 0.01));
  });

  test('prioritized puts the strongest build first and drops nothing', () {
    final q = quest([
      [enemy(const [], hp: huge)],
    ]);
    final weak = team(ServantSetup(svtId: altria, level: 1, atkFou: 0, hpFou: 0));
    final none = team(ServantSetup.defaults(castoria));
    final strong = team(built(altria));
    final teams = [weak, none, strong];
    final sorted = prioritized(teams, q);
    expect(sorted.first, same(strong));
    expect(sorted.last, same(none));
    expect(sorted.toSet(), teams.toSet());
    expect(sorted.length, teams.length);
    // no enemy: the order is untouched
    expect(prioritized(teams, quest(const [])), teams);
  });
}
