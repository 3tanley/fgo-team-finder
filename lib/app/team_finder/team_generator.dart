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

bool _sameSetup(ServantSetup a, ServantSetup b) =>
    a.svtId == b.svtId &&
    a.level == b.level &&
    a.npLevel == b.npLevel &&
    a.atkFou == b.atkFou &&
    a.hpFou == b.hpFou &&
    a.skillLevels.join(',') == b.skillLevels.join(',');

/// Front-row teams for option 1: the borrowed support in slot 0 (carrying its bond CE) plus every pair
/// of box servants, with Black Grail on whichever of the pair has a damaging NP (one team per holder).
/// Only the front row acts in v1, so the bench is not part of a team.
/// shortcut: one slot order (support first, box order after); other orders only change NP/skill order.
Iterable<TeamSpec> generateTeams(List<ServantSetup> box, Region region) sync* {
  for (final support in supportList(region)) {
    final supportSlot = SlotSpec(ServantSetup.defaults(support.svtId), ce: CeSetup(support.bondCeId));
    for (var i = 0; i < box.length; i++) {
      for (var j = i + 1; j < box.length; j++) {
        for (final holder in [i, j]) {
          if (!isDamageDealer(box[holder].svtId)) continue;
          if (holder == j && _sameSetup(box[i], box[j])) continue; // same team as holder == i
          yield TeamSpec([
            supportSlot,
            SlotSpec(box[i], ce: holder == i ? CeSetup(kBlackGrailCeId) : null),
            SlotSpec(box[j], ce: holder == j ? CeSetup(kBlackGrailCeId) : null),
          ]);
        }
      }
    }
  }
}
