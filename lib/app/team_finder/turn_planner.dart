import 'models.dart';

/// The loop's plan: one [AutoLoop] per turn, because loop_policy.dart decides the skills from the live battle
/// and every skill target is the attacker. So a team has exactly one plan.
Iterable<TurnPlan> planTurns(TeamSpec team, {int turns = 3}) sync* {
  if (turns < 1) throw ArgumentError.value(turns, 'turns', 'must be >= 1');
  yield TurnPlan([
    for (var t = 0; t < turns; t++) const [AutoLoop()],
  ]);
}
