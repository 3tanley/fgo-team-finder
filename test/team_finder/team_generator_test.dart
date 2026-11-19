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
const int summerIbuki = 704300; // damaging Arts NP

List<ServantSetup> box(List<int> ids) => ids.map(ServantSetup.defaults).toList();

void main() async {
  await initiateForTest();

  final fiveBox = box([altria, castoria, daVinci, nero, summerIbuki]);

  int idOf(int collectionNo) => db.gameData.servantsNoDup[collectionNo]!.id;
  // owner's rule: Arts dealer -> Castoria / Urðr, Quick -> Skadi / Summer Skadi, Buster -> Koyanskaya (Light / Dark)
  final artsSupports = {idOf(284), idOf(470)};
  final quickSupports = {idOf(215), idOf(357)};
  final busterSupports = {idOf(314), idOf(334)};

  /// First 4-5 star servant (by collection no) whose damaging NP has [card]; the quick one is not pinned by id.
  int dealerWith(CardType card) {
    for (final no in db.gameData.servantsNoDup.keys.toList()..sort()) {
      final svt = db.gameData.servantsNoDup[no]!;
      if (svt.rarity >= 4 && isDamageDealer(svt.id) && npCardType(svt.id) == card) return svt.id;
    }
    throw StateError('no $card damage dealer in the data');
  }

  Set<int> supportsOf(Iterable<TeamSpec> teams) => teams.map((t) => t.slots[0].servant.svtId).toSet();

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
      expect(t.slots.length, inInclusiveRange(3, 4)); // 4 when a swap-in exists
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
    expect(npCardType(altria), CardType.buster);
    expect(npCardType(emiya), CardType.buster);
    final koyanskayaLight = idOf(314);
    final teams = generateTeams(box([altria, emiya, castoria, castoria, castoria]), Region.jp)
        .where(
          (t) =>
              t.slots[0].servant.svtId == koyanskayaLight &&
              t.slots[1].servant.svtId == altria &&
              t.slots[2].servant.svtId == emiya,
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
    expect(teams, isNotEmpty); // Castoria is the Arts dealer's (Summer Ibuki's) support
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
    final teams = generateTeams(twinAltria, Region.jp)
        .where(
          (t) =>
              t.slots[0].servant.svtId == idOf(314) &&
              t.slots[1].servant.svtId == altria &&
              t.slots[2].servant.svtId == altria,
        )
        .toList();
    expect(teams.length, 1);
  });

  test('the same servant with different append levels counts as a different team', () {
    List<ServantSetup> pair(List<int> appendOfSecond) => [
      ServantSetup(svtId: altria),
      ServantSetup(svtId: altria, appendLevels: appendOfSecond),
      ServantSetup.defaults(castoria),
      ServantSetup.defaults(castoria),
      ServantSetup.defaults(castoria),
    ];
    int pairTeams(List<ServantSetup> b) => generateTeams(b, Region.jp)
        .where(
          (t) =>
              t.slots[0].servant.svtId == idOf(314) &&
              t.slots[1].servant.svtId == altria &&
              t.slots[2].servant.svtId == altria,
        )
        .length;
    expect(pairTeams(pair([0, 0, 0, 0, 0])), 1); // identical entries: one team
    expect(pairTeams(pair([10, 0, 0, 0, 0])), 2); // different entries: one team per Black Grail holder
  });

  test('every team carries the Decisive-Battle Chaldea Uniform (mystic code 210) at level 10', () {
    for (final t in generateTeams(fiveBox, Region.na)) {
      expect(t.mysticCode?.id, kDefaultMysticCodeId);
      expect(t.mysticCode?.level, 10);
    }
    expect(kDefaultMysticCodeId, 210);
  });

  test('a box servant from the support names that is not in the front row becomes the back-row swap-in', () {
    final oberon = db.gameData.servantsNoDup[316]!.id;
    final teams = generateTeams(box([altria, castoria, nero, oberon, emiya]), Region.jp).toList();
    final withOberon = teams.where((t) => t.slots.length == 4 && t.slots[3].servant.svtId == oberon);
    expect(withOberon, isNotEmpty);
    for (final t in teams.where((t) => t.slots.length == 4)) {
      final frontIds = t.slots.take(3).map((s) => s.servant.svtId).toList();
      expect(t.slots[3].ce, isNull);
      expect(isSupportName(t.slots[3].servant.svtId), isTrue);
      // the swap-in is a different box entry from the two box servants in front
      final boxIdsInFront = frontIds.skip(1).toList();
      expect(boxIdsInFront.contains(oberon) && t.slots[3].servant.svtId == oberon, isFalse);
    }
  });

  test('a box with no support-name servant outside the front row has plain 3-servant teams', () {
    final plain = generateTeams(box([altria, nero, daVinci, emiya, altria]), Region.jp).toList();
    expect(plain, isNotEmpty);
    expect(plain.every((t) => t.slots.length == 3), isTrue);
  });

  group('the support depends on the damage dealer\'s NP card', () {
    test('npCardType reads the NP card (Summer Ibuki Arts, Altria Buster)', () {
      expect(npCardType(summerIbuki), CardType.arts);
      expect(npCardType(altria), CardType.buster);
    });

    test('an Arts dealer is only paired with Castoria or Urðr', () {
      expect(isDamageDealer(castoria), isFalse); // the fillers below must not be dealers themselves
      final teams = generateTeams(box([summerIbuki, castoria, castoria, castoria, castoria]), Region.jp);
      expect(supportsOf(teams), artsSupports);
    });

    test('a Quick dealer is only paired with Skadi or Summer Skadi', () {
      final quick = dealerWith(CardType.quick);
      final teams = generateTeams(box([quick, castoria, castoria, castoria, castoria]), Region.jp);
      expect(supportsOf(teams), quickSupports);
    });

    test('a Buster dealer is only paired with Koyanskaya (Light or Dark)', () {
      final teams = generateTeams(box([altria, castoria, castoria, castoria, castoria]), Region.jp);
      expect(supportsOf(teams), busterSupports);
    });

    test('with dealers of different cards the support may fit either dealer, whichever holds the CE', () {
      final teams = generateTeams(box([altria, summerIbuki, castoria, castoria, castoria]), Region.jp).toList();
      final allowed = {CardType.arts: artsSupports, CardType.quick: quickSupports, CardType.buster: busterSupports};
      final dealerCards = [altria, summerIbuki].map(npCardType).toSet();
      for (final t in teams) {
        expect(dealerCards.any((card) => allowed[card]!.contains(t.slots[0].servant.svtId)), isTrue);
      }
      expect(supportsOf(teams), {for (final card in dealerCards) ...allowed[card]!});
      // one Black Grail holder, yet the support for the other dealer's card is borrowed too
      final holderCard = npCardType(teams.first.slots.firstWhere((s) => s.ce?.ceId == kBlackGrailCeId).servant.svtId);
      expect(
        teams.any(
          (t) => !allowed[npCardType(t.slots.firstWhere((s) => s.ce?.ceId == kBlackGrailCeId).servant.svtId)]!.contains(
            t.slots[0].servant.svtId,
          ),
        ),
        isTrue,
        reason: 'holder card $holderCard',
      );
    });

    test('Oberon and Miss Crane are never the borrowed support (Oberon is only the final-wave swap-in)', () {
      final teams = generateTeams(
        box([altria, summerIbuki, dealerWith(CardType.quick), castoria, castoria]),
        Region.jp,
      );
      expect(supportsOf(teams), isNot(contains(idOf(316))));
      expect(supportsOf(teams), isNot(contains(idOf(307))));
    });
  });

  group('friend support chosen by the user', () {
    test('only the chosen friends are borrowed, with their own stats and their bond CE', () {
      final friend = ServantSetup(svtId: castoria, level: 100, skillLevels: [10, 10, 10]);
      final teams = generateTeams(box([summerIbuki, castoria]), Region.na, friends: [friend]).toList();
      expect(teams, isNotEmpty);
      for (final t in teams) {
        expect(t.slots[0].servant, same(friend)); // not the default stats
        expect(t.slots[0].ce?.ceId, db.gameData.servantsById[castoria]!.bondEquips.first);
      }
    });

    test('the friend may be the same servant as one in the box (a second Altria Caster)', () {
      final teams = generateTeams(
        box([summerIbuki, castoria]),
        Region.na,
        friends: [ServantSetup.defaults(castoria)],
      ).toList();
      expect(teams.length, 1); // Ibuki + own Castoria in front, friend Castoria borrowed
      expect(teams.single.slots.map((s) => s.servant.svtId), [castoria, summerIbuki, castoria]);
    });

    test('the NP card rule is not applied to a friend the user picked', () {
      final busterDealer = dealerWith(CardType.buster);
      expect(supportFitsCard(castoria, CardType.buster), isFalse);
      final teams = generateTeams(
        box([busterDealer, daVinci]),
        Region.na,
        friends: [ServantSetup.defaults(castoria)],
      ).toList();
      expect(teams, isNotEmpty);
      expect(supportsOf(teams), {castoria});
    });

    test('several friends: every one is tried as the borrowed support', () {
      final teams = generateTeams(
        box([summerIbuki, castoria]),
        Region.na,
        friends: [ServantSetup.defaults(castoria), ServantSetup.defaults(idOf(470))],
      ).toList();
      expect(supportsOf(teams), {castoria, idOf(470)});
    });

    test('a friend from a servant that has no bond CE is borrowed without one', () {
      final noBond = db.gameData.servantsNoDup.values.firstWhere((s) => s.rarity >= 4 && s.bondEquips.isEmpty);
      final teams = generateTeams(
        box([summerIbuki, castoria]),
        Region.na,
        friends: [ServantSetup.defaults(noBond.id)],
      ).toList();
      expect(teams, isNotEmpty);
      expect(teams.every((t) => t.slots[0].ce == null), isTrue);
    });

    test('with no friends chosen the usual card-based supports are used', () {
      final auto = generateTeams(box([summerIbuki, castoria]), Region.na).toList();
      expect(supportsOf(auto), {castoria}); // Arts dealer: Castoria (Urðr is not released in NA)
      expect(generateTeams(box([summerIbuki, castoria]), Region.na, friends: const []).length, auto.length);
    });
  });

  group('craft essences chosen by the user', () {
    const eventCe = 9408210; // an event CE (Pohjola's Christmas Eve reward CE)
    List<int?> ceIds(TeamSpec t) => t.slots.map((s) => s.ce?.ceId).toList();

    test('quantity 2 puts the CE on both damage dealers of the pair', () {
      final teams = generateTeams(
        box([altria, emiya, castoria]),
        Region.jp,
        ces: [CeSetup(eventCe, quantity: 2)],
      ).where((t) => t.slots[1].servant.svtId == altria && t.slots[2].servant.svtId == emiya).toList();
      expect(teams, isNotEmpty);
      for (final t in teams) {
        expect(ceIds(t).sublist(1, 3), [eventCe, eventCe]);
        expect(ceIds(t), isNot(contains(kBlackGrailCeId)));
      }
      // both dealers carry the same CE: no 'one team per holder' doubling, only the two slot orders below
      final keys = teams.map((t) => t.slots.map((s) => s.servant.svtId).join('/')).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('two dealers that both carry a CE are tried in both slot orders; one CE holder is not doubled', () {
      List<String> orders(List<CeSetup> ces) => generateTeams(box([altria, emiya, castoria]), Region.jp, ces: ces)
          .where((t) => t.slots[0].servant.svtId == idOf(314) && t.slots.length == 4)
          .map((t) => '${t.slots[1].servant.svtId}/${t.slots[2].servant.svtId}')
          .toList();
      expect(orders([CeSetup(eventCe, quantity: 2)]).toSet(), {'$altria/$emiya', '$emiya/$altria'});
      expect(orders([CeSetup(eventCe, quantity: 2)]).length, 2);
      // one Black Grail: only one dealer carries a CE, so the slot order is not multiplied
      expect(orders([CeSetup(kBlackGrailCeId)]).length, 2); // the two holders
    });

    test('level and limit break are carried to the servant that holds the CE', () {
      final teams = generateTeams(
        box([summerIbuki, castoria]),
        Region.jp,
        ces: [CeSetup(kBlackGrailCeId, level: 20, limitBreak: false)],
      ).toList();
      expect(teams, isNotEmpty);
      for (final t in teams) {
        final held = t.slots.singleWhere((s) => s.ce?.ceId == kBlackGrailCeId);
        expect(held.servant.svtId, summerIbuki);
        expect(held.ce!.level, 20);
        expect(held.ce!.limitBreak, isFalse);
      }
    });

    test('copies left after the damage dealers go to the other box servants, never to the support', () {
      final oberon = db.gameData.servantsNoDup[316]!.id;
      final teams = generateTeams(
        box([summerIbuki, castoria, oberon]),
        Region.jp,
        ces: [CeSetup(eventCe, quantity: 3)],
      ).where((t) => t.slots[1].servant.svtId == summerIbuki && t.slots[2].servant.svtId == castoria).toList();
      expect(teams, isNotEmpty);
      for (final t in teams) {
        expect(t.slots.length, 4);
        expect(ceIds(t).sublist(1), [eventCe, eventCe, eventCe]);
        expect(t.slots[0].ce?.ceId, isNot(eventCe)); // the borrowed support keeps its bond CE
      }
    });

    test('with two kinds, the list order decides: the first kind goes to the dealers first, both ways round', () {
      final teams = generateTeams(
        box([altria, emiya, castoria]),
        Region.jp,
        ces: [CeSetup(eventCe), CeSetup(kBlackGrailCeId)],
      ).where((t) => t.slots[1].servant.svtId == altria && t.slots[2].servant.svtId == emiya).toList();
      expect(teams.map((t) => ceIds(t).sublist(1, 3).join('/')).toSet(), {
        '$eventCe/$kBlackGrailCeId',
        '$kBlackGrailCeId/$eventCe',
      });
    });

    test('an empty list means no CE on the box servants; the support still carries its bond CE', () {
      final teams = generateTeams(box([summerIbuki, castoria]), Region.jp, ces: const []).toList();
      expect(teams, isNotEmpty);
      for (final t in teams) {
        expect(ceIds(t).sublist(1), everyElement(isNull));
        expect(t.slots[0].ce, isNotNull);
      }
    });

    test('no list given is the old rule: one Black Grail, max limit break, level 100', () {
      final old = generateTeams(fiveBox, Region.na).toList();
      final same = generateTeams(fiveBox, Region.na, ces: [CeSetup(kBlackGrailCeId)]).toList();
      expect(same.map(ceIds).toList(), old.map(ceIds).toList());
      final held = old.first.slots.firstWhere((s) => s.ce?.ceId == kBlackGrailCeId).ce!;
      expect([held.level, held.limitBreak], [100, true]);
    });

    test('a quantity below 1 is refused', () {
      expect(() => CeSetup(eventCe, quantity: 0), throwsArgumentError);
    });
  });

  test('a servant listed twice with the same stats makes no repeated team', () {
    final twice = box([altria, castoria, altria]);
    final teams = generateTeams(twice, Region.na).toList();
    expect(teams.map((t) => t.key).toSet().length, teams.length);
    // the same teams as the box without the repeat, plus none of its own (it only adds the Altria + Altria pair)
    final once = generateTeams(box([altria, castoria]), Region.na).map((t) => t.key).toSet();
    expect(teams.map((t) => t.key).toSet().containsAll(once), isTrue);
  });

  test('the same servant at different stats is a different team', () {
    final other = ServantSetup(svtId: altria, level: 80);
    final teams = generateTeams([ServantSetup.defaults(altria), other, ServantSetup.defaults(castoria)], Region.na);
    expect(teams.map((t) => t.key).toSet().length, teams.length);
    expect(teams.any((t) => t.slots.any((s) => s.servant.level == 80)), isTrue);
  });
}
