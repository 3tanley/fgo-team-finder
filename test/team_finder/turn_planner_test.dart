import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/turn_planner.dart';

void main() {
  final team = TeamSpec([SlotSpec(ServantSetup.defaults(504500))]);

  test('a team has exactly one plan: an AutoLoop on each of the 3 turns', () {
    final plans = planTurns(team).toList();
    expect(plans.length, 1);
    expect(plans.single.turns.length, 3);
    for (final turn in plans.single.turns) {
      expect(turn.length, 1);
      expect(turn.single, isA<AutoLoop>());
    }
  });

  test('the turns argument sets the plan length', () {
    expect(planTurns(team, turns: 2).single.turns.length, 2);
    expect(() => planTurns(team, turns: 0).toList(), throwsArgumentError);
  });
}
