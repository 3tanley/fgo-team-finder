import 'package:chaldea/models/models.dart';

import 'defaults.dart';
import 'models.dart';
import 'support_list.dart';

/// True if the servant's NP deals damage (a buff-only NP like Castoria's is not a damage dealer).
bool isDamageDealer(int svtId) =>
    db.gameData.servantsById[svtId]?.groupedNoblePhantasms[1]?.lastOrNull?.functions.any(
      (f) => f.funcType.isDamageNp,
    ) ??
    false;

/// The NP card of a servant's first noble phantasm as Arts / Buster / Quick, or null for anything else.
CardType? npCardType(int svtId) {
  final card = db.gameData.servantsById[svtId]?.groupedNoblePhantasms[1]?.lastOrNull?.card;
  if (card == null) return null;
  if (CardType.isArts(card)) return CardType.arts;
  if (CardType.isBuster(card)) return CardType.buster;
  if (CardType.isQuick(card)) return CardType.quick;
  return null;
}

/// Teams for the owner's loop: the borrowed support in slot 0 (carrying its bond CE; which support depends on
/// the damage dealer's NP card, see [kSupportCollectionNosByCard]), every pair of box
/// servants in slots 1-2 with Black Grail on whichever of the pair has a damaging NP (one team per holder),
/// and, in slot 3, a swap-in for the final wave: a box servant from the named supports that is not in the
/// front. One team per distinct swap-in servant; with none available the team has no back row. Every team
/// carries the Decisive-Battle Chaldea Uniform at level 10.
/// shortcut: one slot order (support first, box order after); when a swap-in exists, teams without it are
/// not generated (the swap only adds skills on the last wave).
Iterable<TeamSpec> generateTeams(List<ServantSetup> box, Region region) sync* {
  final mysticCode = MysticCodeSetup(kDefaultMysticCodeId);
  for (final support in supportList(region)) {
    final supportSlot = SlotSpec(ServantSetup.defaults(support.svtId), ce: CeSetup(support.bondCeId));
    for (var i = 0; i < box.length; i++) {
      for (var j = i + 1; j < box.length; j++) {
        final swapIns = <ServantSetup>[];
        for (var k = 0; k < box.length; k++) {
          if (k == i || k == j || !isSupportName(box[k].svtId)) continue;
          if (swapIns.every((s) => s.svtId != box[k].svtId)) swapIns.add(box[k]);
        }
        for (final holder in [i, j]) {
          if (!isDamageDealer(box[holder].svtId)) continue;
          final card = npCardType(box[holder].svtId);
          if (card == null || !supportFitsCard(support.svtId, card)) continue; // support depends on the NP card
          if (holder == j && box[i].sameAs(box[j])) continue; // same team as holder == i
          final front = [
            supportSlot,
            SlotSpec(box[i], ce: holder == i ? CeSetup(kBlackGrailCeId) : null),
            SlotSpec(box[j], ce: holder == j ? CeSetup(kBlackGrailCeId) : null),
          ];
          if (swapIns.isEmpty) {
            yield TeamSpec(front, mysticCode: mysticCode);
          } else {
            for (final swapIn in swapIns) {
              yield TeamSpec([...front, SlotSpec(swapIn)], mysticCode: mysticCode);
            }
          }
        }
      }
    }
  }
}
