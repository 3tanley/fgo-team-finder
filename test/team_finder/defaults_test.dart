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
