import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/defaults.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/support_list.dart';
import 'package:chaldea/app/team_finder/team_generator.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int altria = 100100; // damaging NP
const int castoria = 504500; // buff NP only
const int daVinci = 500900;
const int nero = 100500; // damaging NP
const int emiya = 200100;

List<ServantSetup> box(List<int> ids) => ids.map(ServantSetup.defaults).toList();

void main() async {
  await initiateForTest();

  final fiveBox = box([altria, castoria, daVinci, nero, emiya]);

  test('Black Grail is CE 48 and isDamageDealer separates damage NPs from buff NPs', () {
    expect(db.gameData.craftEssencesById[kBlackGrailCeId]?.collectionNo, 48);
    expect(isDamageDealer(altria), isTrue);
    expect(isDamageDealer(nero), isTrue);
    expect(isDamageDealer(castoria), isFalse);
  });

  test('slot 0 is a support from the region list with its bond CE; slots 1-2 come from the box', () {
    final supports = {for (final e in supportList(Region.na)) e.svtId: e.bondCeId};
    final boxIds = fiveBox.map((e) => e.svtId).toSet();
    final teams = generateTeams(fiveBox, Region.na).toList();
    expect(teams, isNotEmpty);
    for (final t in teams) {
      expect(t.slots.length, 3);
      expect(supports.containsKey(t.slots[0].servant.svtId), isTrue);
      expect(t.slots[0].ce?.ceId, supports[t.slots[0].servant.svtId]);
      expect(boxIds, containsAll([t.slots[1].servant.svtId, t.slots[2].servant.svtId]));
    }
  });

  test('Black Grail is on exactly one box servant with a damaging NP, never on the support', () {
    for (final t in generateTeams(fiveBox, Region.na)) {
      final holders = t.slots.where((s) => s.ce?.ceId == kBlackGrailCeId).toList();
      expect(holders.length, 1);
      expect(isDamageDealer(holders.single.servant.svtId), isTrue);
      expect(identical(holders.single, t.slots[0]), isFalse);
      expect(t.slots[0].ce?.ceId, isNot(kBlackGrailCeId));
    }
  });

  test('two damage dealers in the pair give two teams, one per Black Grail holder', () {
    final teams = generateTeams(box([altria, nero, castoria, castoria, castoria]), Region.na)
        .where(
          (t) =>
              t.slots[0].servant.svtId == castoria &&
              t.slots[1].servant.svtId == altria &&
              t.slots[2].servant.svtId == nero,
        )
        .toList();
    expect(teams.length, 2);
    expect(teams.map((t) => t.slots.indexWhere((s) => s.ce?.ceId == kBlackGrailCeId)).toSet(), {1, 2});
  });

  test('a box with no damage dealer makes no teams', () {
    expect(generateTeams(box([castoria, castoria, castoria, castoria, castoria]), Region.na), isEmpty);
  });

  test('the support may duplicate a box servant (double Castoria)', () {
    final teams = generateTeams(
      fiveBox,
      Region.na,
    ).where((t) => t.slots[0].servant.svtId == castoria && t.slots.skip(1).any((s) => s.servant.svtId == castoria));
    expect(teams, isNotEmpty);
  });

  test('NA never offers JP-only Urðr as support; JP does', () {
    final urdr = db.gameData.servantsNoDup[470]!.id;
    expect(generateTeams(fiveBox, Region.na).any((t) => t.slots[0].servant.svtId == urdr), isFalse);
    expect(generateTeams(fiveBox, Region.jp).any((t) => t.slots[0].servant.svtId == urdr), isTrue);
  });

  test('the support is a borrowed servant: level 90, skills 10/10/10', () {
    final s = generateTeams(fiveBox, Region.na).first.slots[0].servant;
    expect(s.level, 90);
    expect(s.skillLevels, [10, 10, 10]);
  });

  test('two identical box entries do not double the teams (Black Grail holder variants are equivalent)', () {
    final twinAltria = box([altria, altria, castoria, daVinci, emiya]);
    final teams = generateTeams(twinAltria, Region.na)
        .where(
          (t) =>
              t.slots[0].servant.svtId == castoria &&
              t.slots[1].servant.svtId == altria &&
              t.slots[2].servant.svtId == altria,
        )
        .toList();
    expect(teams.length, 1);
  });
}
