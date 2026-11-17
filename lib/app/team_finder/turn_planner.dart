import 'models.dart';

/// Two plans per team, in this order:
/// 1. the owner's loop: one [AutoLoop] per turn (loop_policy.dart decides the skills from the live battle);
/// 2. the search: [AutoSearch] (plan_search.dart) tries other skill orders, targets, firing orders and swap
///    timings, with at most [searchSims] simulated turns.
Iterable<TurnPlan> planTurns(TeamSpec team, {int turns = 3, int searchSims = 150}) sync* {
  if (turns < 1) throw ArgumentError.value(turns, 'turns', 'must be >= 1');
  yield TurnPlan([
    for (var t = 0; t < turns; t++) const [AutoLoop()],
  ]);
  yield TurnPlan([
    [AutoSearch(maxSims: searchSims)],
    for (var t = 1; t < turns; t++) const [],
  ]);
}
