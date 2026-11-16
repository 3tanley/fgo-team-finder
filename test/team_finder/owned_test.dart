// Team Finder reads the servants the user owns, and their stats, from Chaldea's own user data
// (the heart on a servant page = owned; Plan tab = ascension, skills, append skills, NP level, fou, grails).
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/owned.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  final castoria = db.gameData.servantsNoDup[284]!; // 5★, max level 90
  final urdr = db.gameData.servantsNoDup[470]!; // JP-only
  final threeStar = db.gameData.servantsNoDup.values.firstWhere((s) => s.rarity == 3 && s.collectionNo > 0);

  setUp(() => db.curUser.servants.clear());
  tearDown(() => db.curUser.servants.clear());

  void own(Servant svt, {void Function(SvtPlan cur)? edit}) {
    final cur = svt.status.cur..favorite = true;
    edit?.call(cur);
  }

  test('only servants marked owned (heart) with 4 or 5 stars are listed', () {
    own(castoria);
    own(urdr);
    own(threeStar);
    final notOwned = db.gameData.servantsNoDup[316]!; // Oberon
    expect(notOwned.status.favorite, isFalse);
    final ids = ownedServants(Region.jp).map((s) => s.id).toSet();
    expect(ids, {castoria.id, urdr.id});
  });

  test('in NA a servant that is not released there is not offered', () {
    own(castoria);
    own(urdr);
    expect(ownedServants(Region.na).map((s) => s.id), [castoria.id]);
  });

  test('ownedSetupFor is null for a servant that is not owned', () {
    expect(ownedSetupFor(castoria.id), isNull);
    expect(ownedSetupFor(-1), isNull);
  });

  test('stats come from the Plan data: skills, append skills, NP level, fou', () {
    own(
      castoria,
      edit: (c) {
        c.ascension = 4;
        c.skills = [10, 9, 8];
        c.appendSkills = [0, 5, 0, 0, 10];
        c.npLv = 3;
        c.fouAtk4 = 50; // ★4 fou-kun: 1000 + 50 * 20
        c.fouHp4 = 25; // 1000 + 25 * 20
      },
    );
    final s = ownedSetupFor(castoria.id)!;
    expect(s.svtId, castoria.id);
    expect(s.skillLevels, [10, 9, 8]);
    expect(s.appendLevels, [0, 5, 0, 0, 10]);
    expect(s.npLevel, 3);
    expect(s.atkFou, 2000);
    expect(s.hpFou, 1500);
  });

  test('a servant with untouched plan data gets the plan defaults: skills 1/1/1, no appends, NP 1', () {
    own(castoria);
    final s = ownedSetupFor(castoria.id)!;
    expect(s.skillLevels, [1, 1, 1]);
    expect(s.appendLevels, [0, 0, 0, 0, 0]);
    expect(s.npLevel, 1);
  });

  test("attack fou does not borrow the HP fou fallback (Chaldea's getFouAtk reads fouHp3 for it)", () {
    own(
      castoria,
      edit: (c) {
        c.fouAtk5 = 0;
        c.fouAtk4 = 0;
        c.fouHp4 = 0;
        c.fouAtk3 = 10; // 3-star fou-kun: 10 * 50 = 500
        c.fouHp3 = 20; // 20 * 50 = 1000
      },
    );
    final s = ownedSetupFor(castoria.id)!;
    expect(s.atkFou, 500);
    expect(s.hpFou, 1000);
  });

  test('5-star fou-kun count when present: 2000 + 100 each', () {
    own(
      castoria,
      edit: (c) {
        c.fouAtk5 = 10;
        c.fouHp5 = 3;
      },
    );
    final s = ownedSetupFor(castoria.id)!;
    expect(s.atkFou, 3000);
    expect(s.hpFou, 2300);
  });

  test('level is the maximum for the ascension, plus grails at ascension 4', () {
    own(castoria, edit: (c) => c.ascension = 4);
    expect(ownedSetupFor(castoria.id)!.level, castoria.lvMax); // 90
    own(castoria, edit: (c) => c.ascension = 2);
    expect(ownedSetupFor(castoria.id)!.level, castoria.lvMax - 20); // 70
    own(
      castoria,
      edit: (c) {
        c.ascension = 4;
        c.grail = 10;
      },
    );
    expect(ownedSetupFor(castoria.id)!.level, castoria.grailedLv(10));
    expect(castoria.grailedLv(10), greaterThan(castoria.lvMax));
  });

  test('common supports for the selector row: Skadi, Castoria, Koyanskaya of Light, Oberon, Summer Skadi, Urðr', () {
    int idOf(int no) => db.gameData.servantsNoDup[no]!.id;
    expect(commonSupportIds(Region.jp), [215, 284, 314, 316, 357, 470].map(idOf).toList());
  });

  test('NA does not list the JP-only Urðr in that row', () {
    expect(commonSupportIds(Region.na), isNot(contains(urdr.id)));
    expect(commonSupportIds(Region.na).length, 5);
  });
}
