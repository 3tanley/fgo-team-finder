import 'package:chaldea/models/models.dart';

import 'defaults.dart';
import 'models.dart';

/// The craft essences the Team Finder offers. Event CEs are the ones the battle simulator pins for the quest's
/// event (a CE with an event-only skill for it); the event's reward CE is the "damage" one (it is earned by
/// playing the event and carries the attack / NP damage bonus), the limited ones are the "drop" ones.
enum CeKind { blackGrail, eventDamage, eventDrop }

/// The CEs of [kind] the user can pick for [quest], newest first. Event kinds are empty without a quest in an event.
List<CraftEssence> ceChoices(CeKind kind, QuestSpec? quest) {
  switch (kind) {
    case CeKind.blackGrail:
      return [?db.gameData.craftEssencesById[kBlackGrailCeId]];
    case CeKind.eventDamage || CeKind.eventDrop:
      final event = quest?.phase.war?.event;
      if (event == null) return [];
      final flag = kind == CeKind.eventDamage ? SvtFlag.svtEquipEventReward : SvtFlag.svtEquipEvent;
      return [
        for (final ce in db.gameData.craftEssences.values)
          if (ce.flags.contains(flag) && ce.eventSkills(event.id).isNotEmpty) ce,
      ]..sort((a, b) => b.collectionNo.compareTo(a.collectionNo));
  }
}
