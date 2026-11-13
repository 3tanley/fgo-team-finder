import 'package:chaldea/models/models.dart';

import 'models.dart';

/// Owner's loop-support list, by collection no: Castoria (Altria Caster), Koyanskaya of
/// Light / of Dark, Oberon, Miss Crane, Scáthach-Skadi, Scáthach-Skadi (Ruler), Urðr.
/// shortcut: only the owner's named supports; add others once each is checked against a real loop.
const List<int> kSupportCollectionNos = [284, 314, 334, 316, 307, 215, 357, 470];

/// Supports available in [region]: JP has everything, other regions only released servants.
/// Servants without a bond CE are skipped, because the support must carry one.
List<SupportEntry> supportList(Region region) {
  final released = region == Region.jp ? null : db.gameData.mappingData.entityRelease.ofRegion(region);
  return [
    for (final no in kSupportCollectionNos)
      if (db.gameData.servantsNoDup[no] case final svt?)
        if ((released == null || released.contains(svt.id)) && svt.bondEquips.isNotEmpty)
          SupportEntry(svt.id, svt.bondEquips.first),
  ];
}
