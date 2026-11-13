import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/support_list.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  int idOf(int collectionNo) => db.gameData.servantsNoDup[collectionNo]!.id;

  test('NA list has Castoria (284) and Miss Crane (307) but not JP-only Urðr (470)', () {
    final ids = supportList(Region.na).map((e) => e.svtId).toSet();
    expect(ids, contains(idOf(284)));
    expect(ids, contains(idOf(307)));
    expect(ids, isNot(contains(idOf(470))));
  });

  test('JP list has Urðr (470)', () {
    expect(supportList(Region.jp).map((e) => e.svtId), contains(idOf(470)));
  });

  test('JP keeps every servant on the owner list (none silently dropped for lacking a bond CE)', () {
    expect(supportList(Region.jp).length, kSupportCollectionNos.length);
  });

  test('every entry carries a bond CE', () {
    for (final region in [Region.na, Region.jp]) {
      for (final e in supportList(region)) {
        expect(e.bondCeId, greaterThan(0), reason: 'svt ${e.svtId} in $region');
      }
    }
  });
}
