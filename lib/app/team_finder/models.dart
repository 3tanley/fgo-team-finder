import 'defaults.dart';

/// A servant as the user owns it. Blank input means the defaults in defaults.dart.
class ServantSetup {
  final int svtId;
  final int level;
  final List<int> skillLevels;
  final int npLevel;
  final int atkFou;
  final int hpFou;

  /// Throws [ArgumentError] on out-of-range input (this is the user-input boundary).
  ServantSetup({
    required this.svtId,
    this.level = kDefaultServantLevel,
    this.skillLevels = kDefaultSkillLevels,
    this.npLevel = kDefaultNpLevel,
    this.atkFou = kDefaultFou,
    this.hpFou = kDefaultFou,
  }) {
    if (skillLevels.length != 3 || skillLevels.any((e) => e < 1 || e > 10)) {
      throw ArgumentError.value(skillLevels, 'skillLevels', 'need 3 levels, each 1..10');
    }
    if (npLevel < 1 || npLevel > 5) {
      throw ArgumentError.value(npLevel, 'npLevel', 'must be 1..5');
    }
  }

  factory ServantSetup.defaults(int svtId) => ServantSetup(svtId: svtId);
}

class CeSetup {
  final int ceId;
  final int level;
  final bool limitBreak;
  CeSetup(this.ceId, {this.level = kDefaultCeLevel, this.limitBreak = true});
}

class MysticCodeSetup {
  final int id;
  final int level;
  MysticCodeSetup(this.id, {this.level = kDefaultMysticCodeLevel});
}

class EnemySpec {
  final int hp;
  final int classId;
  final String attribute;
  final List<int> traits;
  const EnemySpec({required this.hp, required this.classId, required this.attribute, required this.traits});
}

class WaveSpec {
  final List<EnemySpec> enemies;
  const WaveSpec(this.enemies);
}

/// A quest as the solver sees it. [waves] is however many the quest really has (not padded to 3);
/// [unsupportedGimmicks] are mechanics a "viable" verdict can't be trusted through.
class QuestSpec {
  final int questId;
  final List<WaveSpec> waves;
  final List<String> unsupportedGimmicks;
  const QuestSpec({required this.questId, required this.waves, required this.unsupportedGimmicks});
}

/// A servant the player may borrow, with the bond CE it carries.
class SupportEntry {
  final int svtId;
  final int bondCeId;
  const SupportEntry(this.svtId, this.bondCeId);
}
