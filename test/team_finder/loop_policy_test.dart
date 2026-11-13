// The owner's loop rules, run on the real engine (see handoff.md, "Owner's loop rules").
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/battle_runner.dart';
import 'package:chaldea/app/team_finder/defaults.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/quest_loader.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int castoria = 504500;
const int summerIbuki = 704300; // Ibuki-Douji (Berserker), collection no. 355, the alignmentSummer one
const int decisiveBattleUniform = 210;

void main() async {
  await initiateForTest();

  final oberon = db.gameData.servantsNoDup[316]!.id;
  // Real 3-wave quest with every enemy cut to 1 HP: only the NP gauge decides whether a wave dies.
  final json = jsonDecode(jsonEncode(db.gameData.questPhases[9300040603]!.toJson())) as Map<String, dynamic>;
  for (final stage in json['stages'] as List) {
    for (final enemy in stage['enemies'] as List) {
      enemy['hp'] = 1;
    }
  }
  final quest = questSpecFromPhase(QuestPhase.fromJson(json));
  final bondCe = db.gameData.servantsById[castoria]!.bondEquips.first;

  TeamSpec loopTeam({bool backRow = true, bool mysticCode = true}) => TeamSpec([
    SlotSpec(ServantSetup.defaults(castoria), ce: CeSetup(bondCe)),
    SlotSpec(ServantSetup.defaults(castoria)),
    SlotSpec(ServantSetup.defaults(summerIbuki), ce: CeSetup(kBlackGrailCeId)),
    if (backRow) SlotSpec(ServantSetup.defaults(oberon)),
  ], mysticCode: mysticCode ? MysticCodeSetup(decisiveBattleUniform) : null);
  const plan = TurnPlan([
    [AutoLoop()],
    [AutoLoop()],
    [AutoLoop()],
  ]);

  final runner = EngineBattleRunner();
  late final BattleOutcome out;
  setUpAll(() async => out = await runner.run(loopTeam(), quest, plan));

  bool chargesNp(int svtId, int skillNo) => db
      .gameData
      .servantsById[svtId]!
      .groupedActiveSkills[skillNo]!
      .last
      .functions
      .any((f) => f.funcType == FuncType.gainNp);

  test('Summer Ibuki is collection no. 355 and Castoria S3 is not a charge skill while S1 and S2 are', () {
    expect(db.gameData.servantsNoDup[355]!.id, summerIbuki);
    expect(chargesNp(castoria, 1), isTrue);
    expect(chargesNp(castoria, 2), isTrue);
    expect(chargesNp(castoria, 3), isFalse);
  });

  test('turn 1 opens with both Castorias\' skill 3 on the attacker, before any charge skill', () {
    expect(out.log.take(2).toList(), ['T1 skill 0.3 -> 2', 'T1 skill 1.3 -> 2']);
  });

  test('charge skills go to the attacker only until it is full, so at least one is kept for later', () {
    const ids = [castoria, castoria, summerIbuki];
    int chargeSkillsIn(Iterable<String> lines) => lines.where((l) {
      final m = RegExp(r'skill (\d)\.(\d)').firstMatch(l);
      return m != null && chargesNp(ids[int.parse(m[1]!)], int.parse(m[2]!));
    }).length;
    final available = ids.fold<int>(0, (sum, id) => sum + [1, 2, 3].where((n) => chargesNp(id, n)).length);
    final usedT1 = chargeSkillsIn(out.log.where((l) => l.startsWith('T1 ')));
    expect(usedT1, lessThan(available), reason: 'log: ${out.log}');
  });

  test('on the final wave the mystic code swaps a Castoria for Oberon, then Oberon uses skills 1, 2, 3', () {
    final swapAt = out.log.indexWhere((l) => RegExp(r'^T3 swap [01] <-> 3$').hasMatch(l));
    expect(swapAt, greaterThanOrEqualTo(0), reason: 'log: ${out.log}');
    final outIdx = out.log[swapAt][8];
    final after = out.log.skip(swapAt + 1).where((l) => l.startsWith('T3 skill $outIdx.')).toList();
    expect(after, ['T3 skill $outIdx.1 -> 2', 'T3 skill $outIdx.2 -> 2', 'T3 skill $outIdx.3 -> 2']);
  });

  test('the loop clears 3 waves in 3 turns and fires the attacker each turn', () {
    expect(out.failure, isNull);
    expect(out.clearedAllWaves, isTrue, reason: 'log: ${out.log}');
    expect(out.turnsUsed, 3);
    for (final t in [1, 2, 3]) {
      expect(out.log, contains('T$t np 2'));
    }
  });

  test('without a back-row servant or mystic code there is no swap and the run still works', () async {
    for (final team in [loopTeam(backRow: false), loopTeam(mysticCode: false)]) {
      final o = await runner.run(team, quest, plan);
      expect(o.failure, isNull);
      expect(o.log.any((l) => l.contains('swap')), isFalse);
    }
  });

  test('the sim is deterministic: the same run twice gives the same log and damage', () async {
    final again = await runner.run(loopTeam(), quest, plan);
    expect(again.log, out.log);
    expect(again.totalNpDamage, out.totalNpDamage);
  });
}
