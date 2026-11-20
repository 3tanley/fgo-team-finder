import 'package:chaldea/models/models.dart';

import 'defaults.dart';
import 'models.dart';

/// The craft essences the Team Finder offers. Event CEs are the ones the battle simulator pins for the quest's
/// event (a CE with an event-only skill for it). They are told apart by what their skills do: a CE that raises
/// the event's drop count is a "drop" CE (whatever its stat bonuses, and whether it is the reward CE or a limited
/// one); the others (e.g. a CE with an event-only attack boost) are "damage" CEs. Many events have no damage CE.
enum CeKind { blackGrail, eventDamage, eventDrop }

/// The CEs of [kind] the user can pick for [quest], newest first. Event kinds are empty without a quest in an event.
List<CraftEssence> ceChoices(CeKind kind, QuestSpec? quest) {
  switch (kind) {
    case CeKind.blackGrail:
      return [?db.gameData.craftEssencesById[kBlackGrailCeId]];
    case CeKind.eventDamage || CeKind.eventDrop:
      final event = quest?.phase.war?.event;
      if (event == null) return [];
      return [
        for (final ce in db.gameData.craftEssences.values)
          if (ce.eventSkills(event.id).isNotEmpty && raisesDrops(ce) == (kind == CeKind.eventDrop)) ce,
      ]..sort((a, b) => b.collectionNo.compareTo(a.collectionNo));
  }
}

const _dropFuncs = {FuncType.eventDropUp, FuncType.eventDropRateUp};

/// True if the CE raises an event's drop count (see [CeKind]).
bool raisesDrops(CraftEssence ce) => ce.skills.any((s) => s.functions.any((f) => _dropFuncs.contains(f.funcType)));

/// [raisesDrops] by CE id (false for an unknown id).
bool raisesDropsId(int ceId) {
  final ce = db.gameData.craftEssencesById[ceId];
  return ce != null && raisesDrops(ce);
}
