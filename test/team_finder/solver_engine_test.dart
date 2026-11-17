// End-to-end: the real Chaldea engine through generateTeams + planTurns (AutoLoop policy) + solve.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/battle_runner.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/quest_loader.dart';
import 'package:chaldea/app/team_finder/solver.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int castoria = 504500;
const int summerIbuki = 704300;

void main() async {
  await initiateForTest();

  // Real 3-wave quest with every enemy cut to 1 HP: only the NP gauge decides whether a wave dies.
  final json = jsonDecode(jsonEncode(db.gameData.questPhases[9300040603]!.toJson())) as Map<String, dynamic>;
  for (final stage in json['stages'] as List) {
    for (final enemy in stage['enemies'] as List) {
      enemy['hp'] = 1;
    }
  }
  final quest = questSpecFromPhase(QuestPhase.fromJson(json));
  final oberon = db.gameData.servantsNoDup[316]!.id;
  final box = [castoria, summerIbuki, oberon, 100100, 100500].map(ServantSetup.defaults).toList();

  test('the solver finds the double-Castoria + Summer Ibuki + Oberon loop on its own', () async {
    final sw = Stopwatch()..start();
    final last = await solve(
      SolveRequest(region: Region.na, quest: quest, box: box, maxSims: 300),
      EngineBattleRunner(),
    ).last;
    sw.stop();
    print(
      'ENGINE_SOLVE teams ${last.teamsDone}/${last.teamsTotal} sims ${last.sims} truncated ${last.truncated} '
      'viable ${last.results.length} nonViable ${last.nonViable} in ${sw.elapsedMilliseconds} ms',
    );
    expect(last.error, isNull);
    expect(last.finished, isTrue);
    final loop = last.results.where(
      (r) =>
          r.team.slots[0].servant.svtId == castoria &&
          r.team.slots.skip(1).any((s) => s.servant.svtId == castoria) &&
          r.team.slots.any((s) => s.servant.svtId == summerIbuki) &&
          r.team.slots.length == 4 &&
          r.team.slots[3].servant.svtId == oberon,
    );
    expect(
      loop,
      isNotEmpty,
      reason: 'viable teams: ${last.results.map((r) => r.team.slots.map((s) => s.servant.svtId).toList()).toList()}',
    );
    print('LOOP dmg ${loop.first.totalNpDamage}');
  }, timeout: const Timeout(Duration(minutes: 2))); // teams the loop cannot clear also get the plan search
}
