// Spike for the team finder: can Chaldea's battle engine run headless, with a
// multi-servant party, and how fast? Results are recorded in docs/team_finder_spike.md.
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/interactions/_delegate.dart';
import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  // First quest phase with exactly 3 distinct waves.
  final quest = db.gameData.questPhases.values.firstWhere((q) => q.stages.map((s) => s.wave).toSet().length == 3);
  List<PlayerSvtData> party() => [
    for (final _ in [0, 1, 2])
      PlayerSvtData.id(100100)
        ..lv = 90
        ..tdLv = 1
        ..atkFou = 0
        ..hpFou = 0,
  ];

  int enemyHp(BattleData b) => b.nonnullEnemies.fold(0, (sum, e) => sum + e.hp);

  Future<BattleData> oneTurnOfThreeNps() async {
    final battle = BattleData();
    await battle.init(quest, party(), null);
    for (final svt in battle.nonnullPlayers) {
      svt.np = 10000;
    }
    await battle.playerTurn([for (final svt in battle.nonnullPlayers) CombatAction(svt, svt.getNPCard()!)]);
    return battle;
  }

  test('headless: three NPs in one turn damage wave 1 (kill it or lower its HP)', () async {
    final battle = BattleData();
    await battle.init(quest, party(), null);
    final before = enemyHp(battle);
    expect(battle.waveCount, 1);
    for (final svt in battle.nonnullPlayers) {
      svt.np = 10000;
    }
    await battle.playerTurn([for (final svt in battle.nonnullPlayers) CombatAction(svt, svt.getNPCard()!)]);
    print(
      'quest ${quest.id}: enemy HP $before -> ${enemyHp(battle)}, wave ${battle.waveCount}, turn ${battle.totalTurnCount}',
    );
    // HP is only comparable inside one wave: a killed wave loads the next one.
    expect(battle.waveCount > 1 || enemyHp(battle) < before, isTrue);
  });

  test('snapshot: pushSnapshot/popSnapshot restores state so a search can branch', () async {
    final battle = BattleData();
    await battle.init(quest, party(), null);
    final before = enemyHp(battle);
    battle.pushSnapshot();
    for (final svt in battle.nonnullPlayers) {
      svt.np = 10000;
    }
    await battle.playerTurn([for (final svt in battle.nonnullPlayers) CombatAction(svt, svt.getNPCard()!)]);
    battle.popSnapshot();
    expect(battle.waveCount, 1);
    expect(enemyHp(battle), before);
  });

  test('throughput: 200 branches from one initialised battle via snapshots', () async {
    const runs = 200;
    final battle = BattleData();
    await battle.init(quest, party(), null);
    final sw = Stopwatch()..start();
    for (var i = 0; i < runs; i++) {
      battle.pushSnapshot();
      for (final svt in battle.nonnullPlayers) {
        svt.np = 10000;
      }
      await battle.playerTurn([for (final svt in battle.nonnullPlayers) CombatAction(svt, svt.getNPCard()!)]);
      battle.popSnapshot();
    }
    sw.stop();
    print(
      'BRANCHES_PER_SECOND ${(runs * 1000 / sw.elapsedMilliseconds).toStringAsFixed(1)} ($runs in ${sw.elapsedMilliseconds} ms)',
    );
    expect(battle.waveCount, 1);
  });

  test('throughput: 200 full init + 3-NP turns', () async {
    const runs = 200;
    final sw = Stopwatch()..start();
    for (var i = 0; i < runs; i++) {
      await oneTurnOfThreeNps();
    }
    sw.stop();
    final perSec = runs * 1000 / sw.elapsedMilliseconds;
    print('SIMS_PER_SECOND ${perSec.toStringAsFixed(1)} ($runs runs in ${sw.elapsedMilliseconds} ms)');
    expect(perSec, greaterThan(0));
  });
}
