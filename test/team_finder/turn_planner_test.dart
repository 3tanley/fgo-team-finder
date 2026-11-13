import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/turn_planner.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int castoria = 504500; // Altria Caster
const int daVinci = 500900;

SlotSpec slot(int id) => SlotSpec(ServantSetup.defaults(id));

void main() async {
  await initiateForTest();

  final team = TeamSpec([slot(castoria), slot(castoria), slot(daVinci)]);
  final plans = planTurns(team).toList();
  final needsTarget = [
    for (final id in [castoria, castoria, daVinci])
      for (final s in [0, 1, 2]) skillNeedsTarget(id, s),
  ].where((e) => e).length;

  test('skillNeedsTarget agrees with the engine for Castoria skill 1 (ATK up + NP gain on one ally)', () {
    final skill = db.gameData.servantsById[castoria]!.groupedActiveSkills[1]!.last;
    expect(skillNeedsTarget(castoria, 0), skill.functions.any((f) => f.funcTargetType.needNormalOneTarget));
  });

  test('one plan per assignment of targets to the skills that need one', () {
    expect(needsTarget, greaterThan(0), reason: 'the test team must actually have targeted skills');
    expect(plans.length, pow(3, needsTarget));
  });

  test('every plan has 3 turns: all skills then auto NPs on turn 1, auto NPs only after', () {
    for (final p in plans) {
      expect(p.turns.length, 3);
      expect(p.turns[0].whereType<SkillAction>().length, 9);
      expect(p.turns[0].last, isA<AutoNps>());
      for (final later in p.turns.skip(1)) {
        expect(later.length, 1);
        expect(later.single, isA<AutoNps>());
      }
    }
  });

  test('targets are on-field allies 0..2 for targeted skills and null for the rest', () {
    for (final p in plans) {
      for (final a in p.turns[0].whereType<SkillAction>()) {
        final id = [castoria, castoria, daVinci][a.servantIndex];
        if (skillNeedsTarget(id, a.skillIndex)) {
          expect(a.targetIndex, inInclusiveRange(0, 2));
        } else {
          expect(a.targetIndex, isNull);
        }
      }
    }
  });

  test('the plans are all different from each other', () {
    final keys = plans.map((p) => p.turns[0].whereType<SkillAction>().map((a) => a.targetIndex).join(',')).toSet();
    expect(keys.length, plans.length);
  });

  test('the back row never acts (option 1: no order change)', () {
    final six = TeamSpec([
      slot(castoria),
      slot(castoria),
      slot(daVinci),
      slot(castoria),
      slot(castoria),
      slot(daVinci),
    ]);
    final first = planTurns(six).first;
    expect(first.turns[0].whereType<SkillAction>().every((a) => a.servantIndex < 3), isTrue);
    expect(planTurns(six).length, plans.length);
  });

  test('a one-servant team only targets itself', () {
    final solo = planTurns(TeamSpec([slot(castoria)])).toList();
    for (final p in solo) {
      expect(p.turns[0].whereType<SkillAction>().every((a) => a.targetIndex == null || a.targetIndex == 0), isTrue);
    }
  });

  test('the turns argument sets the plan length', () {
    expect(planTurns(team, turns: 2).first.turns.length, 2);
    expect(() => planTurns(team, turns: 0).toList(), throwsArgumentError);
  });
}
