import 'package:chaldea/models/models.dart';

import 'models.dart';

/// Owner's loop-support list, by collection no: Castoria (Altria Caster), Koyanskaya of
/// Light / of Dark, Oberon, Miss Crane, Scáthach-Skadi, Scáthach-Skadi (Ruler), Urðr.
/// shortcut: only the owner's named supports; add others once each is checked against a real loop.
const List<int> kSupportCollectionNos = [284, 314, 334, 316, 307, 215, 357, 470];

/// Which borrowed support goes with a damage dealer's NP card (the owner's rule): Arts -> Castoria or Urðr,
/// Quick -> Scáthach-Skadi or Scáthach-Skadi (Ruler, "Summer Skadi"), Buster -> Koyanskaya of Light or of Dark.
/// Oberon and Miss Crane are in [kSupportCollectionNos] but fit no card, so they are never the borrowed support
/// (Oberon is still the final-wave swap-in).
/// shortcut: "Koyanskaya" is read as both Light and Dark; narrow it here if only one is meant.
const Map<CardType, List<int>> kSupportCollectionNosByCard = {
  CardType.arts: [284, 470],
  CardType.quick: [215, 357],
  CardType.buster: [314, 334],
};

/// True if [supportSvtId] is a borrowed support the owner pairs with a damage dealer whose NP card is [card].
bool supportFitsCard(int supportSvtId, CardType card) =>
    kSupportCollectionNosByCard[card]?.any((no) => db.gameData.servantsNoDup[no]?.id == supportSvtId) ?? false;

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

/// True if [svtId] is one of the owner's named loop supports (in any region's data).
bool isSupportName(int svtId) => kSupportCollectionNos.any((no) => db.gameData.servantsNoDup[no]?.id == svtId);
