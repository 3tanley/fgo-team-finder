import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/models.dart';

void main() {
  test('ServantSetup.defaults is level 90, skills 10/10/10, NP1, Chaldea-default fou', () {
    final s = ServantSetup.defaults(504500);
    expect(s.svtId, 504500);
    expect(s.level, 90);
    expect(s.skillLevels, [10, 10, 10]);
    expect(s.npLevel, 1);
    expect(s.atkFou, 1000);
    expect(s.hpFou, 1000);
  });

  test('append skills default to 0 (not unlocked) for all five unless the user sets them', () {
    expect(ServantSetup.defaults(504500).appendLevels, [0, 0, 0, 0, 0]);
    expect(ServantSetup(svtId: 1).appendLevels, [0, 0, 0, 0, 0]);
    expect(ServantSetup(svtId: 1, appendLevels: [10, 0, 5, 0, 1]).appendLevels, [10, 0, 5, 0, 1]);
  });

  test('ServantSetup rejects append lists that are not 5 levels of 0..10', () {
    expect(() => ServantSetup(svtId: 1, appendLevels: [0, 0, 0, 0]), throwsArgumentError);
    expect(() => ServantSetup(svtId: 1, appendLevels: [0, 0, 0, 0, 11]), throwsArgumentError);
    expect(() => ServantSetup(svtId: 1, appendLevels: [-1, 0, 0, 0, 0]), throwsArgumentError);
  });

  test('CeSetup defaults to level 100 and max limit break', () {
    final ce = CeSetup(9400340);
    expect(ce.level, 100);
    expect(ce.limitBreak, isTrue);
  });

  test('MysticCodeSetup defaults to level 10', () {
    expect(MysticCodeSetup(20).level, 10);
  });

  test('ServantSetup rejects skill lists that are not 3 levels of 1..10', () {
    expect(() => ServantSetup(svtId: 1, skillLevels: [10, 10]), throwsArgumentError);
    expect(() => ServantSetup(svtId: 1, skillLevels: [10, 10, 11]), throwsArgumentError);
    expect(() => ServantSetup(svtId: 1, skillLevels: [0, 10, 10]), throwsArgumentError);
  });

  test('ServantSetup rejects NP level outside 1..5', () {
    expect(() => ServantSetup(svtId: 1, npLevel: 0), throwsArgumentError);
    expect(() => ServantSetup(svtId: 1, npLevel: 6), throwsArgumentError);
  });
}
