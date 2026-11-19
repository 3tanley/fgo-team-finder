import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/battle_runner.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/quest_loader.dart';
import 'package:chaldea/app/team_finder/solver.dart';
import 'package:chaldea/app/team_finder/team_generator.dart';
import 'package:chaldea/app/team_finder/team_priority.dart';
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

  test('fewer than 2 box servants is an error, not an empty answer', () {
    final stream = solve(request(b: box([altria])), FakeRunner((_, _) => failed()));
    expect(stream, emitsError(isA<NeedMoreServants>()));
  });

  test('2 box servants are enough: the search runs and finishes without an error', () async {
    final last = await solve(request(b: box([altria, castoria])), FakeRunner((_, _) => cleared(1))).last;
    expect(last.finished, isTrue);
    expect(last.error, isNull);
    expect(last.teamsTotal, greaterThan(0)); // Artoria (Buster) is paired with a Koyanskaya support
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

  test('a result keeps the action log of its best plan so the UI can show how the team clears', () async {
    final runner = FakeRunner(
      (_, _) => const BattleOutcome(
        clearedAllWaves: true,
        turnsUsed: 3,
        totalNpDamage: 7,
        unverified: false,
        log: ['T1 skill 0.3 -> 2'],
      ),
    );
    final last = await solve(request(), runner).last;
    expect(last.results.first.log, ['T1 skill 0.3 -> 2']);
  });

  group('quick pass, then the search in order of margin', () {
    bool isSearch(TurnPlan p) => p.turns.first.any((a) => a is AutoSearch);
    int capOf(TurnPlan p) => p.turns.first.whereType<AutoSearch>().first.maxSims;
    BattleOutcome stuck(double slack, int turns) => BattleOutcome(
      clearedAllWaves: false,
      turnsUsed: 0,
      totalNpDamage: 0,
      unverified: false,
      searchTurns: turns,
      searchCapped: true,
      searchSlack: slack,
    );

    test('a team the quick check rules out is never searched', () async {
      final runner = FakeRunner((_, _) => failed()); // searchCapped false = ruled out
      final last = await solve(request(), runner).last;
      expect(runner.calls, last.teamsTotal * 2); // the loop and the quick check, nothing more
      expect(last.nonViable, last.teamsTotal);
      expect(last.truncated, isFalse);
    });

    test('teams are searched likeliest first and the time budget stops the rest', () async {
      final slack = Map<TeamSpec, double>.identity();
      final searched = <double>[];
      var clock = DateTime(2026);
      final runner = FakeRunner((team, plan) {
        if (!isSearch(plan)) return failed();
        final s = slack.putIfAbsent(team, () => slack.length.toDouble()); // a different margin per team
        if (capOf(plan) == kQuickCheckTurns) return stuck(s, kQuickCheckTurns);
        searched.add(s);
        clock = clock.add(const Duration(minutes: 1)); // every search takes a minute
        return stuck(s, 400);
      });
      final req = SolveRequest(
        region: Region.na,
        quest: quest3,
        box: fiveBox,
        maxSims: 100000,
        timeBudget: const Duration(minutes: 2),
        now: () => clock,
      );
      final last = await solve(req, runner).last;
      expect(searched.length, 2); // two searches spend the two minutes
      expect(searched, [...searched]..sort((a, b) => b.compareTo(a)));
      expect(searched.first, slack.length - 1); // the biggest margin went first
      expect(last.truncated, isTrue);
      expect(last.unresolved, 0);
      expect(last.results.length + last.nonViable, last.teamsTotal);
    });

    test('teams are checked in priority order, every team still once', () async {
      final seen = <String>[];
      final runner = FakeRunner((team, plan) {
        if (seen.isEmpty || seen.last != team.key) seen.add(team.key);
        return failed();
      });
      await solve(request(), runner).last;
      final expected = prioritized(generateTeams(fiveBox, Region.na).toList(), quest3).map((t) => t.key).toList();
      expect(seen, expected);
    });

    test('the quick pass stops at a quarter of the time; the search still gets the rest', () async {
      var clock = DateTime(2026);
      var searches = 0;
      final runner = FakeRunner((team, plan) {
        clock = clock.add(const Duration(minutes: 1)); // every run takes a minute
        if (!isSearch(plan)) return failed();
        if (capOf(plan) == kQuickCheckTurns) return stuck(1, kQuickCheckTurns);
        searches++;
        return stuck(1, 400);
      });
      final req = SolveRequest(
        region: Region.na,
        quest: quest3,
        box: fiveBox,
        maxSims: 100000,
        timeBudget: const Duration(minutes: 10),
        now: () => clock,
      );
      final last = await solve(req, runner).last;
      expect(last.teamsDone, lessThan(last.teamsTotal)); // not every team was reached
      expect(last.truncated, isTrue);
      expect(searches, greaterThan(0)); // the teams found by then were still searched
      expect(clock.difference(DateTime(2026)).inMinutes, lessThanOrEqualTo(11)); // ended about on time
    });

    test('too many teams for the full cap: a short round first, then the full cap for the teams that hit it', () async {
      var clock = DateTime(2026);
      final caps = <int>[];
      final runner = FakeRunner((team, plan) {
        if (!isSearch(plan)) {
          clock = clock.add(const Duration(seconds: 1)); // only the quick pass takes time
          return failed();
        }
        if (capOf(plan) == kQuickCheckTurns) {
          clock = clock.add(const Duration(seconds: 1));
          return stuck(1, kQuickCheckTurns);
        }
        caps.add(capOf(plan));
        if (capOf(plan) == kSearchTurnsPerTeam && caps.length > 3) {
          return const BattleOutcome(
            clearedAllWaves: true,
            turnsUsed: 3,
            totalNpDamage: 5,
            unverified: false,
            searchTurns: 100,
          );
        }
        return stuck(1, capOf(plan));
      });
      final req = SolveRequest(
        region: Region.na,
        quest: quest3,
        box: fiveBox,
        maxSims: 100000,
        timeBudget: const Duration(minutes: 5),
        now: () => clock,
      );
      final last = await solve(req, runner).last;
      final firstRound = caps.takeWhile((c) => c == kFirstSearchTurns).length;
      expect(firstRound, greaterThan(1));
      expect(caps.skip(firstRound), everyElement(kSearchTurnsPerTeam)); // the full cap only after every short one
      expect(caps.where((c) => c == kSearchTurnsPerTeam).length, firstRound); // each short one is retried once
      expect(last.results, isNotEmpty); // a clear that needs the full cap is still found
    });

    test('few teams, so every one gets the full cap straight away', () async {
      final caps = <int>[];
      final runner = FakeRunner((team, plan) {
        if (!isSearch(plan)) return failed();
        if (capOf(plan) == kQuickCheckTurns) return stuck(1, kQuickCheckTurns);
        caps.add(capOf(plan));
        return stuck(1, 5);
      });
      await solve(request(), runner).last; // the clock does not move: the quick pass looked free
      expect(caps, everyElement(kSearchTurnsPerTeam));
    });

    test('a clear found in the search pass is reported, with its damage', () async {
      final runner = FakeRunner((team, plan) {
        if (!isSearch(plan)) return failed();
        if (capOf(plan) == kQuickCheckTurns) return stuck(1, kQuickCheckTurns);
        return const BattleOutcome(
          clearedAllWaves: true,
          turnsUsed: 3,
          totalNpDamage: 777,
          unverified: false,
          searchTurns: 10,
        );
      });
      final last = await solve(request(), runner).last;
      expect(last.results, isNotEmpty);
      expect(last.results.first.totalNpDamage, 777);
      expect(last.nonViable, 0);
    });
  });
}
