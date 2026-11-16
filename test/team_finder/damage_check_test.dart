// Numbers check: every NP damage the loop produces must equal the standard FGO damage formula applied to the
// parameters the engine recorded, and the attacker's ATK must equal level-90 ATK + 1000 fou + Black Grail's ATK.
// (Checked by hand on JP quest 94136710 too: 257,913 per target for the first NP, see handoff.md.)
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/battle/utils/battle_logger.dart';
import 'package:chaldea/app/battle/utils/battle_utils.dart';
import 'package:chaldea/app/team_finder/battle_runner.dart';
import 'package:chaldea/app/team_finder/defaults.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/quest_loader.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int castoria = 504500;
const int summerIbuki = 704300;

void main() async {
  await initiateForTest();

  final oberon = db.gameData.servantsNoDup[316]!.id;
  final quest = questSpecFromPhase(db.gameData.questPhases[9300040603]!);
  final bondCe = db.gameData.servantsById[castoria]!.bondEquips.first;
  final team = TeamSpec([
    SlotSpec(ServantSetup.defaults(castoria), ce: CeSetup(bondCe)),
    SlotSpec(ServantSetup.defaults(castoria)),
    SlotSpec(ServantSetup.defaults(summerIbuki), ce: CeSetup(kBlackGrailCeId)),
    SlotSpec(ServantSetup.defaults(oberon)),
  ], mysticCode: MysticCodeSetup(kDefaultMysticCodeId));
  const plan = TurnPlan([
    [AutoLoop()],
    [AutoLoop()],
    [AutoLoop()],
  ]);

  /// Attribute advantage: sky > earth > human > sky and star <-> beast are 1.1, everything else 1.0.
  double attributeAdvantage(ServantSubAttribute a, ServantSubAttribute d) {
    const beats = {
      ServantSubAttribute.sky: ServantSubAttribute.earth,
      ServantSubAttribute.earth: ServantSubAttribute.human,
      ServantSubAttribute.human: ServantSubAttribute.sky,
      ServantSubAttribute.star: ServantSubAttribute.beast,
      ServantSubAttribute.beast: ServantSubAttribute.star,
    };
    return beats[a] == d ? 1.1 : 1.0;
  }

  /// The damage formula with Berserker's 1.1 class constant (the attacker here) and Arts' NP card modifier of 1.0.
  double expectedDamage(DamageParameters p) {
    expect(p.attackerClass, 7, reason: 'this check only knows the Berserker class constant');
    expect(p.currentCardType, 1, reason: 'this check only knows the Arts NP card modifier');
    return p.attack *
            0.23 *
            (p.damageRate / 1000) *
            (p.npSpecificAttackRate / 1000) *
            1.0 *
            ((p.cardBuff - p.cardResist + 1000) / 1000) *
            1.1 *
            (p.classAdvantage / 1000) *
            attributeAdvantage(p.attackerAttribute, p.defenderAttribute) *
            (p.random / 1000) *
            ((p.attackBuff - p.defenseBuff + 1000) / 1000) *
            ((1000 + p.damageBuff - p.damageDefBuff + p.npDamageBuff - p.npDamageDefBuff) / 1000) +
        p.damageAdditionBuff -
        p.damageReceiveAdditionBuff;
  }

  late final List<BattleAttackRecord> nps;
  setUpAll(() async {
    await EngineBattleRunner(
      onFinished: (BattleData battle) {
        nps = battle.recorder.records.whereType<BattleAttackRecord>().where((r) => r.card?.isTD == true).toList();
      },
    ).run(team, quest, plan);
  });

  test('every NP hit on every enemy equals the standard damage formula (within rounding)', () {
    expect(nps, isNotEmpty);
    var checked = 0;
    for (final r in nps) {
      for (final t in r.targets) {
        final actual = t.result.damages.fold<int>(0, (a, b) => a + b);
        expect(actual.toDouble(), closeTo(expectedDamage(t.damageParams), 5), reason: '${t.damageParams}');
        checked += 1;
      }
    }
    expect(checked, greaterThan(0));
  });

  test('the attacker ATK is level 90 + 1000 fou + Black Grail ATK, from the game data', () {
    final svt = db.gameData.servantsById[summerIbuki]!;
    final ce = db.gameData.craftEssencesById[kBlackGrailCeId]!;
    final expected = svt.atkGrowth[kDefaultServantLevel - 1] + kDefaultFou + ce.atkGrowth[kDefaultCeLevel - 1];
    expect(nps.first.targets.first.damageParams.attack, expected);
  });
}
