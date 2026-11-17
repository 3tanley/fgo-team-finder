import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/turn_planner.dart';

void main() {
  final team = TeamSpec([SlotSpec(ServantSetup.defaults(504500))]);

  test('a team has two plans: the loop (an AutoLoop on each of the 3 turns), then the search', () {
    final plans = planTurns(team).toList();
    expect(plans.length, 2);
    expect(plans[0].turns.length, 3);
    for (final turn in plans[0].turns) {
      expect(turn.length, 1);
      expect(turn.single, isA<AutoLoop>());
    }
    expect(plans[1].turns.length, 3);
    expect(plans[1].turns.first.single, isA<AutoSearch>());
    expect(plans[1].turns.skip(1).every((turn) => turn.isEmpty), isTrue);
  });

  test('the search plan carries its work cap', () {
    final search = planTurns(team, searchSims: 12).last.turns.first.single as AutoSearch;
    expect(search.maxSims, 12);
  });

  test('the turns argument sets the plan length', () {
    expect(planTurns(team, turns: 2).map((p) => p.turns.length), [2, 2]);
    expect(() => planTurns(team, turns: 0).toList(), throwsArgumentError);
  });
}
