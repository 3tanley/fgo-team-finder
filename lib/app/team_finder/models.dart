import 'package:chaldea/models/models.dart' show QuestPhase;

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

  /// The source phase: it is what the battle engine is initialised with.
  final QuestPhase phase;
  const QuestSpec({required this.questId, required this.waves, required this.unsupportedGimmicks, required this.phase});
}

class SlotSpec {
  final ServantSetup servant;
  final CeSetup? ce;
  const SlotSpec(this.servant, {this.ce});
}

/// Up to 6 servants: indices 0-2 start on the field, 3-5 start in the back row.
class TeamSpec {
  final List<SlotSpec> slots;
  final MysticCodeSetup? mysticCode;
  TeamSpec(this.slots, {this.mysticCode}) {
    if (slots.isEmpty || slots.length > 6) throw ArgumentError.value(slots.length, 'slots', 'need 1..6 servants');
  }
}

sealed class TurnAction {
  const TurnAction();
}

/// Use servant [servantIndex]'s skill [skillIndex] (both 0-based), optionally on ally [targetIndex].
class SkillAction extends TurnAction {
  final int servantIndex;
  final int skillIndex;
  final int? targetIndex;
  const SkillAction(this.servantIndex, this.skillIndex, {this.targetIndex});
}

/// Fire servant [servantIndex]'s NP. Within a turn all skills happen first, then the NPs in list order.
class NpAction extends TurnAction {
  final int servantIndex;
  const NpAction(this.servantIndex);
}

/// Fire every NP that is charged when the NP phase starts: non-damaging (buff) NPs first, then damaging
/// ones, each group in slot order. It never fails: with nothing charged the turn just passes.
class AutoNps extends TurnAction {
  const AutoNps();
}

/// One list of actions per turn. A turn with no actions just ends the turn.
class TurnPlan {
  final List<List<TurnAction>> turns;
  const TurnPlan(this.turns);
}

class BattleOutcome {
  final bool clearedAllWaves;
  final int turnsUsed;
  final int totalNpDamage;

  /// True when the quest has gimmicks we cannot vouch for; never show such a team as plainly "viable".
  final bool unverified;

  /// Why the plan could not be carried out (for example an NP that was not charged), else null.
  final String? failure;
  const BattleOutcome({
    required this.clearedAllWaves,
    required this.turnsUsed,
    required this.totalNpDamage,
    required this.unverified,
    this.failure,
  });
}

/// A servant the player may borrow, with the bond CE it carries.
class SupportEntry {
  final int svtId;
  final int bondCeId;
  const SupportEntry(this.svtId, this.bondCeId);
}
