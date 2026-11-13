// End-to-end smoke test: the real Chaldea engine through generateTeams + planTurns + solve.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/battle_runner.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/quest_loader.dart';
import 'package:chaldea/app/team_finder/solver.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  // Positive control: a real one-wave quest with every enemy cut to 1 HP. A single charged damage NP in any
  // of the 3 turns clears it, so a correct solver must find viable teams here.
  final base = db.gameData.questPhases.values.firstWhere((q) => q.stages.map((s) => s.wave).toSet().length == 1);
  final json = jsonDecode(jsonEncode(base.toJson())) as Map<String, dynamic>;
  for (final stage in json['stages'] as List) {
    for (final enemy in stage['enemies'] as List) {
      enemy['hp'] = 1;
    }
  }
  final weakQuest = questSpecFromPhase(QuestPhase.fromJson(json));
  final box = [100100, 504500, 500900, 100500, 200100].map(ServantSetup.defaults).toList();

  test('the real engine solves a one-wave 1-HP quest end to end and finds viable teams', () async {
    final sw = Stopwatch()..start();
    final last = await solve(
      SolveRequest(region: Region.na, quest: weakQuest, box: box, maxSims: 400),
      EngineBattleRunner(),
    ).last;
    sw.stop();
    print(
      'ENGINE_SOLVE teams ${last.teamsDone}/${last.teamsTotal} sims ${last.sims} truncated ${last.truncated} '
      'viable ${last.results.length} nonViable ${last.nonViable} in ${sw.elapsedMilliseconds} ms '
      '(${(last.sims * 1000 / sw.elapsedMilliseconds).toStringAsFixed(0)} sims/s)',
    );
    if (last.results.isNotEmpty) {
      final best = last.results.first;
      print('BEST dmg ${best.totalNpDamage} team ${best.team.slots.map((s) => s.servant.svtId).toList()}');
    }
    expect(last.error, isNull);
    expect(last.finished, isTrue);
    expect(last.sims, greaterThan(0));
    expect(last.results, isNotEmpty, reason: 'a single charged damage NP clears a 1-HP one-wave quest');
  });
}
