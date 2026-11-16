import 'package:chaldea/models/models.dart' show Region;

import 'battle_runner.dart';
import 'models.dart';
import 'team_generator.dart';
import 'turn_planner.dart';

/// Smallest box that can make a team: the borrowed support plus two box servants (the damage dealer and a partner).
const int kMinBoxServants = 2;

class NeedMoreServants implements Exception {
  final int have;
  const NeedMoreServants(this.have);
  @override
  String toString() => 'need at least $kMinBoxServants servants, got $have';
}

class TeamResult {
  final TeamSpec team;
  final TurnPlan plan;
  final bool unverified;
  final int totalNpDamage;

  /// What the best plan did, one line per action (see [BattleOutcome.log]).
  final List<String> log;
  const TeamResult({
    required this.team,
    required this.plan,
    required this.unverified,
    required this.totalNpDamage,
    this.log = const [],
  });
}

class SolveRequest {
  final Region region;
  final QuestSpec quest;
  final List<ServantSetup> box;

  /// Work cap: at most this many battle simulations, then the search stops and says it was truncated.
  final int maxSims;
  bool _cancelled = false;
  SolveRequest({required this.region, required this.quest, required this.box, this.maxSims = 20000});

  void cancel() => _cancelled = true;
  bool get cancelled => _cancelled;
}

class SolveProgress {
  final int teamsDone;
  final int teamsTotal;
  final int sims;

  /// Viable teams so far (clear every wave within 3 turns), best total NP damage first. Teams that
  /// cannot clear are only counted in [nonViable].
  final List<TeamResult> results;
  final int nonViable;
  final bool truncated;
  final bool cancelled;
  final bool finished;
  final String? error;
  const SolveProgress({
    required this.teamsDone,
    required this.teamsTotal,
    required this.sims,
    required this.results,
    required this.nonViable,
    required this.truncated,
    required this.cancelled,
    required this.finished,
    this.error,
  });
}

/// Option-1 search: every team from [generateTeams], every plan from [planTurns], keeping each team's
/// best clearing plan. Throws [NeedMoreServants] (as a stream error) for fewer than [kMinBoxServants] box servants.
/// shortcut: runs on the calling isolate and yields to the event loop between teams; move the engine
/// into worker isolates if searches are too slow.
Stream<SolveProgress> solve(SolveRequest req, BattleRunner runner) async* {
  if (req.box.length < kMinBoxServants) throw NeedMoreServants(req.box.length);
  final waves = req.quest.waves.length;
  if (waves > 3) {
    yield SolveProgress(
      teamsDone: 0,
      teamsTotal: 0,
      sims: 0,
      results: const [],
      nonViable: 0,
      truncated: false,
      cancelled: false,
      finished: true,
      error: 'this quest has $waves waves, so it cannot be cleared in 3 turns',
    );
    return;
  }

  final teams = generateTeams(req.box, req.region).toList();
  final results = <TeamResult>[];
  var nonViable = 0, sims = 0, done = 0;
  var truncated = false;
  SolveProgress snapshot({bool finished = false}) => SolveProgress(
    teamsDone: done,
    teamsTotal: teams.length,
    sims: sims,
    results: List.unmodifiable(results),
    nonViable: nonViable,
    truncated: truncated,
    cancelled: req.cancelled,
    finished: finished,
  );

  search:
  for (final team in teams) {
    if (req.cancelled) break;
    TeamResult? best;
    for (final plan in planTurns(team)) {
      if (req.cancelled) break search;
      if (sims >= req.maxSims) {
        truncated = true;
        if (best != null) results.add(best);
        break search;
      }
      final out = await runner.run(team, req.quest, plan);
      sims++;
      if (out.clearedAllWaves && (best == null || out.totalNpDamage > best.totalNpDamage)) {
        best = TeamResult(
          team: team,
          plan: plan,
          unverified: out.unverified,
          totalNpDamage: out.totalNpDamage,
          log: out.log,
        );
      }
    }
    done++;
    if (best == null) {
      nonViable++;
    } else {
      results
        ..add(best)
        ..sort((a, b) => b.totalNpDamage.compareTo(a.totalNpDamage));
    }
    await Future<void>.delayed(Duration.zero); // keep the UI responsive
    if (best != null || done % 20 == 0) yield snapshot();
  }
  results.sort((a, b) => b.totalNpDamage.compareTo(a.totalNpDamage));
  yield snapshot(finished: true);
}
