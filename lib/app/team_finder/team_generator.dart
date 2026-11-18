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
/// the damage dealer's NP card, see [kSupportCollectionNosByCard]), every pair of box servants in slots 1-2 (at
/// least one with a damaging NP), and, in slot 3, a swap-in for the final wave: a box servant from the named
/// supports that is not in the front. One team per distinct swap-in servant; with none available the team has
/// no back row. Every team carries the Decisive-Battle Chaldea Uniform at level 10.
///
/// [ces] is the user's craft essence list, each with a quantity; none given = one Black Grail. The copies are
/// handed out in list order: the damage dealers of the pair first, then the pair's other servant, then the
/// swap-in. The borrowed support never gets one. When two dealers would get different CEs (or only one gets
/// a CE), both ways round are generated; two dealers that both carry a CE are also tried in both slot orders.
///
/// With [friends] (supports the user chose) those are borrowed instead, with their own stats and bond CE, and the
/// NP card rule is not applied: the choice is the user's.
/// shortcut: one slot order (support first, box order after); when a swap-in exists, teams without it are
/// not generated (the swap only adds skills on the last wave).
Iterable<TeamSpec> generateTeams(
  List<ServantSetup> box,
  Region region, {
  List<ServantSetup> friends = const [],
  List<CeSetup>? ces,
}) sync* {
  final mysticCode = MysticCodeSetup(kDefaultMysticCodeId);
  final pool = [
    for (final ce in ces ?? [CeSetup(kBlackGrailCeId)])
      for (var n = 0; n < ce.quantity; n++) ce,
  ];
  final supports = friends.isEmpty
      ? [for (final e in supportList(region)) SlotSpec(ServantSetup.defaults(e.svtId), ce: CeSetup(e.bondCeId))]
      : [
          for (final f in friends)
            SlotSpec(
              f,
              ce: switch (db.gameData.servantsById[f.svtId]?.bondEquips.firstOrNull) {
                final ce? => CeSetup(ce),
                null => null, // no bond CE to carry
              },
            ),
        ];
  for (final supportSlot in supports) {
    for (var i = 0; i < box.length; i++) {
      for (var j = i + 1; j < box.length; j++) {
        final swapIns = <ServantSetup>[];
        for (var k = 0; k < box.length; k++) {
          if (k == i || k == j || !isSupportName(box[k].svtId)) continue;
          if (swapIns.every((s) => s.svtId != box[k].svtId)) swapIns.add(box[k]);
        }
        final dealers = [i, j].where((k) => isDamageDealer(box[k].svtId)).toList();
        if (dealers.isEmpty) continue;
        final forDealers = [for (var d = 0; d < dealers.length; d++) pool.elementAtOrNull(d)];
        final rest = pool.skip(dealers.length).toList();
        bool same(CeSetup? a, CeSetup? b) => a == null || b == null ? a == b : a.sameAs(b);
        // the other way round only when it is a different team
        final bothWays = dealers.length == 2 && !same(forDealers[0], forDealers[1]) && !box[i].sameAs(box[j]);
        for (final order in [forDealers, if (bothWays) forDealers.reversed.toList()]) {
          final ceOf = {for (final (d, k) in dealers.indexed) k: order[d]};
          // the borrowed support depends on the NP card of a dealer that carries a CE, unless the user chose it;
          // with two dealers either one's card will do (the other is carried by the plan, not the CE)
          final cards = {
            for (final k in dealers)
              if (dealers.length > 1 || ceOf[k] != null || order.every((ce) => ce == null)) npCardType(box[k].svtId),
          }.nonNulls;
          if (cards.isEmpty) continue;
          if (friends.isEmpty && !cards.any((card) => supportFitsCard(supportSlot.servant.svtId, card))) continue;
          final spare = rest.iterator;
          CeSetup? next() => spare.moveNext() ? spare.current : null;
          for (final k in [i, j]) {
            if (!dealers.contains(k)) ceOf[k] = next();
          }
          final fronts = [
            [supportSlot, SlotSpec(box[i], ce: ceOf[i]), SlotSpec(box[j], ce: ceOf[j])],
            // two dealers that both carry a CE: the plan search does not find the same clears from both slot
            // orders (the order skills are cast in and the NPs fire in), so each order is a team
            if (dealers.length == 2 && ceOf[i] != null && ceOf[j] != null && !box[i].sameAs(box[j]))
              [supportSlot, SlotSpec(box[j], ce: ceOf[j]), SlotSpec(box[i], ce: ceOf[i])],
          ];
          final swapCe = swapIns.isEmpty ? null : next();
          for (final front in fronts) {
            if (swapIns.isEmpty) {
              yield TeamSpec(front, mysticCode: mysticCode);
            } else {
              for (final swapIn in swapIns) {
                yield TeamSpec([...front, SlotSpec(swapIn, ce: swapCe)], mysticCode: mysticCode);
              }
            }
          }
        }
      }
    }
  }
}
