import 'package:chaldea/models/models.dart';

import 'models.dart';

/// Servants the user marked as owned (the heart on a servant page) in Chaldea, 4 and 5 stars only, newest first.
/// In regions other than JP, servants not released there are left out.
List<Servant> ownedServants(Region region) {
  final released = region == Region.jp ? null : db.gameData.mappingData.entityRelease.ofRegion(region);
  return [
    for (final svt in db.gameData.servantsNoDup.values)
      // read the map directly: svt.status would add an empty entry for every servant to the user's data
      if (svt.rarity >= 4 &&
          db.curUser.servants[svt.collectionNo]?.cur.favorite == true &&
          (released == null || released.contains(svt.id)))
        svt,
  ]..sort((a, b) => b.collectionNo.compareTo(a.collectionNo));
}

int _fou(int fou5, int fou4, int fou3) => fou5 > 0 ? 2000 + fou5 * 100 : (fou4 > 0 ? 1000 + fou4 * 20 : fou3 * 50);

/// The setup Chaldea's own data gives for an owned servant (Plan tab: ascension, skills, append skills, NP level,
/// fou-kun, grails), or null if the servant is not marked as owned.
/// shortcut: Chaldea does not store a level, so it is the maximum for the ascension (plus grails at ascension 4).
ServantSetup? ownedSetupFor(int svtId) {
  final svt = db.gameData.servantsById[svtId];
  final cur = svt == null ? null : db.curUser.servants[svt.collectionNo]?.cur;
  if (svt == null || cur == null || !cur.favorite) return null;
  return ServantSetup(
    svtId: svt.id,
    level: cur.ascension >= 4 ? svt.grailedLv(cur.grail) : svt.lvMax - 10 * (4 - cur.ascension),
    skillLevels: List.of(cur.skills),
    appendLevels: List.of(cur.appendSkills),
    npLevel: cur.npLv.clamp(1, 5),
    // not SvtPlan.getFouAtk: its fallback reads the HP fou count
    atkFou: _fou(cur.fouAtk5, cur.fouAtk4, cur.fouAtk3),
    hpFou: _fou(cur.fouHp5, cur.fouHp4, cur.fouHp3),
  );
}

/// The row pinned to the top of the servant selector: Skadi, Castoria, Koyanskaya of Light, Oberon, Summer Skadi
/// (the owner's pinned row) and Urðr. Servants not released in [region] are left out.
const List<int> kCommonSupportCollectionNos = [215, 284, 314, 316, 357, 470];

List<int> commonSupportIds(Region region) {
  final released = region == Region.jp ? null : db.gameData.mappingData.entityRelease.ofRegion(region);
  return [
    for (final no in kCommonSupportCollectionNos)
      if (db.gameData.servantsNoDup[no] case final svt?)
        if (released == null || released.contains(svt.id)) svt.id,
  ];
}
