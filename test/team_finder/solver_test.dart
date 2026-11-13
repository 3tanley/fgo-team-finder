import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/battle_runner.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/quest_loader.dart';
import 'package:chaldea/app/team_finder/solver.dart';
import 'package:chaldea/app/team_finder/turn_planner.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int altria = 100100;
const int castoria = 504500;
const int daVinci = 500900;
const int nero = 100500;
const int emiya = 200100;

class FakeRunner implements BattleRunner {
  final BattleOutcome Function(TeamSpec team, TurnPlan plan) fn;
  int calls = 0;
  FakeRunner(this.fn);
  @override
  Future<BattleOutcome> run(TeamSpec team, QuestSpec quest, TurnPlan plan) async {
    calls++;
    return fn(team, plan);
  }
}

BattleOutcome cleared(int damage, {bool unverified = false}) =>
    BattleOutcome(clearedAllWaves: true, turnsUsed: 3, totalNpDamage: damage, unverified: unverified);
BattleOutcome failed() =>
    const BattleOutcome(clearedAllWaves: false, turnsUsed: 1, totalNpDamage: 0, unverified: false);

void main() async {
  await initiateForTest();

  final quest3 = questSpecFromPhase(db.gameData.questPhases[9300040603]!);
  List<ServantSetup> box(List<int> ids) => ids.map(ServantSetup.defaults).toList();
  final fiveBox = box([altria, castoria, daVinci, nero, emiya]);
  SolveRequest request({List<ServantSetup>? b, QuestSpec? quest, int maxSims = 100000}) =>
      SolveRequest(region: Region.na, quest: quest ?? quest3, box: b ?? fiveBox, maxSims: maxSims);

  test('fewer than 5 box servants is an error, not an empty answer', () {
    final stream = solve(request(b: box([altria, castoria, daVinci, nero])), FakeRunner((_, _) => failed()));
    expect(stream, emitsError(isA<NeedMoreServants>()));
  });

  test('viable teams are ranked by total NP damage; failures are only counted', () async {
    final runner = FakeRunner(
      (team, _) => team.slots[2].servant.svtId == emiya ? failed() : cleared(team.slots[1].servant.svtId),
    );
    final last = await solve(request(), runner).last;
    expect(last.finished, isTrue);
    expect(last.error, isNull);
    expect(last.teamsDone, last.teamsTotal);
    expect(last.results, isNotEmpty);
    expect(last.nonViable, greaterThan(0));
    expect(last.results.length + last.nonViable, last.teamsTotal);
    final damages = last.results.map((r) => r.totalNpDamage).toList();
    expect(damages, [...damages]..sort((a, b) => b.compareTo(a)));
  });

  test('each team is scored by its best clearing plan', () async {
    final perTeam = Map<TeamSpec, int>.identity();
    final runner = FakeRunner((team, _) => cleared((perTeam[team] = (perTeam[team] ?? 0) + 1) * 100));
    final last = await solve(request(), runner).last;
    for (final r in last.results) {
      expect(r.totalNpDamage, planTurns(r.team).length * 100);
    }
  });

  test('the work cap stops the search and says it was truncated', () async {
    final runner = FakeRunner((_, _) => failed());
    final last = await solve(request(maxSims: 5), runner).last;
    expect(last.truncated, isTrue);
    expect(runner.calls, 5);
    expect(last.sims, 5);
    expect(last.finished, isTrue);
  });

  test('cancel stops the search before every team is done', () async {
    final req = request();
    final runner = FakeRunner((_, _) => cleared(1));
    SolveProgress? lastSeen;
    await for (final p in solve(req, runner)) {
      lastSeen = p;
      req.cancel();
    }
    expect(lastSeen!.cancelled, isTrue);
    expect(lastSeen.teamsDone, lessThan(lastSeen.teamsTotal));
  });

  test('a quest with more than 3 waves is rejected with no simulations', () async {
    final base = db.gameData.questPhases[9300040603]!;
    final json = jsonDecode(jsonEncode(base.toJson())) as Map<String, dynamic>;
    final stages = json['stages'] as List;
    stages.add({...jsonDecode(jsonEncode(stages.last)) as Map<String, dynamic>, 'wave': stages.length + 1});
    final runner = FakeRunner((_, _) => cleared(1));
    final last = await solve(request(quest: questSpecFromPhase(QuestPhase.fromJson(json))), runner).last;
    expect(last.error, contains('waves'));
    expect(last.results, isEmpty);
    expect(runner.calls, 0);
  });

  test('a one-wave quest is allowed (clearing within 3 turns)', () async {
    final oneWave = db.gameData.questPhases.values.firstWhere((q) => q.stages.map((s) => s.wave).toSet().length == 1);
    final last = await solve(request(quest: questSpecFromPhase(oneWave)), FakeRunner((_, _) => cleared(1))).last;
    expect(last.error, isNull);
    expect(last.results, isNotEmpty);
  });

  test('unverified outcomes stay marked unverified in the results', () async {
    final last = await solve(request(), FakeRunner((_, _) => cleared(1, unverified: true))).last;
    expect(last.results.every((r) => r.unverified), isTrue);
  });
}
