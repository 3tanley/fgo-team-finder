import 'package:chaldea/models/models.dart';

import 'models.dart';

/// True if skill [skillIndex] (0-based) of servant [svtId] makes the player pick one ally. Same rule
/// as the engine's `needNormalOneTarget`.
bool skillNeedsTarget(int svtId, int skillIndex) {
  final skill = db.gameData.servantsById[svtId]?.groupedActiveSkills[skillIndex + 1]?.lastOrNull;
  return skill != null && skill.functions.any((f) => f.funcTargetType.needNormalOneTarget);
}

/// Candidate plans for [team] under "option 1" (owner-approved v1):
/// turn 1 uses every skill of the front-row servants (slots 0-2) in slot order, then fires charged NPs;
/// later turns only fire charged NPs. One plan per way of choosing the ally each targeted skill hits.
/// shortcut: no staggered skill timing, no order change, back row never acts; add both when v2 is wanted.
Iterable<TurnPlan> planTurns(TeamSpec team, {int turns = 3}) sync* {
  if (turns < 1) throw ArgumentError.value(turns, 'turns', 'must be >= 1');
  final front = team.slots.length < 3 ? team.slots.length : 3;
  final skills = [
    for (var svt = 0; svt < front; svt++)
      for (var skill = 0; skill < 3; skill++)
        if (db.gameData.servantsById[team.slots[svt].servant.svtId]?.groupedActiveSkills[skill + 1]?.isNotEmpty == true)
          (svt, skill),
  ];
  final targeted = {
    for (final (svt, skill) in skills)
      if (skillNeedsTarget(team.slots[svt].servant.svtId, skill)) (svt, skill),
  };
  var total = 1;
  for (var i = 0; i < targeted.length; i++) {
    total *= front;
  }
  for (var n = 0; n < total; n++) {
    var rest = n;
    final turn1 = <TurnAction>[];
    for (final (svt, skill) in skills) {
      int? target;
      if (targeted.contains((svt, skill))) {
        target = rest % front;
        rest ~/= front;
      }
      turn1.add(SkillAction(svt, skill, targetIndex: target));
    }
    turn1.add(const AutoNps());
    yield TurnPlan([
      turn1,
      for (var t = 1; t < turns; t++) const [AutoNps()],
    ]);
  }
}
