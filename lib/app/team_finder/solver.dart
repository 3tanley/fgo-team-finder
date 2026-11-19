import 'package:chaldea/app/battle/utils/battle_logger.dart' show BattleRecord;
import 'package:chaldea/models/models.dart' show Region;

import 'battle_runner.dart';
import 'models.dart';
import 'team_generator.dart';
import 'team_priority.dart';
import 'turn_planner.dart';

/// Smallest box that can make a team: the borrowed support plus two box servants (the damage dealer and a partner).
const int kMinBoxServants = 2;

/// Wall-clock time a whole request may take (about 6 minutes; the quick pass below gets at most the first quarter).
/// Every team first gets the loop plan and the
/// search's quick optimistic check, which also rates how likely the team is to hide a clear (the margin). The
/// teams the check cannot rule out are then searched in order of that margin, each with up to
/// [kSearchTurnsPerTeam] turns, until the time is spent. No search starts after that, so a request ends at most
/// one team's search (a few tens of seconds) late. A team whose search finished is final; one that hit its cap
/// or was never reached is reported as not settled (the request is [SolveProgress.truncated]).
const Duration kSolveTimeBudget = Duration(minutes: 6);
const int kSearchTurnsPerTeam = 400;

/// The quick pass stops after 1/[kQuickTimeDivisor] of the time. A big box has more teams than it can check; the
/// teams the priority order puts first are the ones worth checking, and the search needs the rest of the time.
const int kQuickTimeDivisor = 4;

/// When there are too many teams to give each the full [kSearchTurnsPerTeam] in the time left, every team is first
/// searched for only [kFirstSearchTurns] turns (a clear usually turns up within them: 14 of the 18 clears on the
/// test node did), and only the teams that hit that cap are searched again with the full cap, in the same order.
/// A team's result is the same either way if time allows; the rounds only decide who is reached first.
const int kFirstSearchTurns = 60;

/// How much one full search costs, in quick checks (about 118 search turns against 8 turns' worth of time for a
/// quick check on the test node), to guess from the quick pass's speed whether the full cap fits every team.
/// A wrong guess only changes the order, never a result.
const int kFullSearchInQuickChecks = 15;

/// The search's own optimistic check costs 3 turns; capped here the search does nothing else.
const int kQuickCheckTurns = 3;

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

  /// The best plan's engine records, for the Records panel.
  final List<BattleRecord> records;
  const TeamResult({
    required this.team,
    required this.plan,
    required this.unverified,
    required this.totalNpDamage,
    this.log = const [],
    this.records = const [],
  });
}

class SolveRequest {
  final Region region;
  final QuestSpec quest;
  final List<ServantSetup> box;

  /// Supports the user chose to borrow; empty = the usual supports for the damage dealer's NP card.
  final List<ServantSetup> friends;

  /// The user's craft essences with their quantities, in the order they are handed out; null = one Black Grail.
  final List<CeSetup>? ces;

  /// Work cap: at most this many battle simulations, then the search stops and says it was truncated.
  final int maxSims;

  /// When the search pass stops starting new team searches, counted from the start of [solve].
  final Duration timeBudget;

  /// The clock behind [timeBudget] (tests replace it).
  final DateTime Function() now;
  bool _cancelled = false;
  SolveRequest({
    required this.region,
    required this.quest,
    required this.box,
    this.friends = const [],
    this.ces,
    this.maxSims = 20000,
    this.timeBudget = kSolveTimeBudget,
    this.now = DateTime.now,
  });

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

  /// Teams the quick check could not rule out that are still waiting for the search.
  final int unresolved;
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
    this.unresolved = 0,
  });
}

/// Every team from [generateTeams], every plan from [planTurns] (the loop, then the plan search), keeping each
/// team's best clearing plan. Throws [NeedMoreServants] (as a stream error) for fewer than [kMinBoxServants] box servants.
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

  final started = req.now();
  // likeliest first (see teamPriority), so a big box that runs out of time has checked the best fits
  final teams = prioritized(generateTeams(req.box, req.region, friends: req.friends, ces: req.ces).toList(), req.quest);
  final results = <TeamResult>[];
  final unresolved = <TeamSpec>[];
  final later = <TeamSpec>[]; // searched at the short cap without a verdict, waiting for the full cap
  final slackOf = <TeamSpec, double>{};
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
    unresolved: unresolved.length + later.length,
  );
  TeamResult resultOf(TeamSpec team, TurnPlan plan, BattleOutcome out) => TeamResult(
    team: team,
    plan: plan,
    unverified: out.unverified,
    totalNpDamage: out.totalNpDamage,
    log: out.log,
    records: out.records,
  );
  void addResult(TeamResult r) => results
    ..add(r)
    ..sort((a, b) => b.totalNpDamage.compareTo(a.totalNpDamage));

  // Quick pass: every team gets the loop and the optimistic check (no search yet), for at most a quarter of the time.
  // A big box that does not fit stops here (teams left unchecked, reported as truncated) and the search pass
  // still gets the rest of the time for the teams found so far.
  var screenTimedOut = false;
  screening:
  for (final team in teams) {
    if (req.cancelled) break;
    if (req.now().difference(started) >= req.timeBudget ~/ kQuickTimeDivisor) {
      screenTimedOut = true;
      truncated = true;
      break;
    }
    TeamResult? best;
    var capped = false;
    for (final plan in planTurns(team, searchSims: kQuickCheckTurns)) {
      if (req.cancelled) break screening;
      if (sims >= req.maxSims) {
        truncated = true;
        if (best != null) addResult(best);
        break screening;
      }
      final out = await runner.run(team, req.quest, plan);
      sims++;
      if (out.clearedAllWaves) {
        if (best == null || out.totalNpDamage > best.totalNpDamage) best = resultOf(team, plan, out);
      } else if (out.searchCapped) {
        capped = true;
        slackOf[team] = out.searchSlack;
      }
    }
    done++;
    if (best != null) {
      addResult(best);
    } else if (capped) {
      unresolved.add(team); // not ruled out: the search ran out of its cap before it had tried everything
    } else {
      nonViable++;
    }
    await Future<void>.delayed(Duration.zero); // keep the UI responsive
    if (best != null || done % 20 == 0) yield snapshot();
  }

  // Search pass: the teams the quick check could not rule out, likeliest first, out of a shared budget.
  if (done == teams.length || screenTimedOut) {
    yield snapshot();
    // the teams with the most optimistic margin first: they are the likeliest to hide a clear
    unresolved.sort((a, b) => (slackOf[b] ?? 0).compareTo(slackOf[a] ?? 0));
    // too many teams for the full cap each in the time left (judged from how fast the quick pass went): two rounds
    final spent = req.now().difference(started);
    final perCheck = done == 0 ? Duration.zero : spent ~/ done;
    final twoRounds = perCheck * kFullSearchInQuickChecks * unresolved.length > req.timeBudget - spent;
    final retried = <TeamSpec>{};
    while ((unresolved.isNotEmpty || later.isNotEmpty) && !req.cancelled) {
      if (unresolved.isEmpty) {
        unresolved.addAll(later);
        later.clear();
      }
      if (req.now().difference(started) >= req.timeBudget || sims >= req.maxSims) {
        truncated = true;
        nonViable += unresolved.length;
        unresolved.clear();
        break;
      }
      final team = unresolved.removeAt(0);
      final cap = twoRounds && !retried.contains(team) ? kFirstSearchTurns : kSearchTurnsPerTeam;
      final plan = planTurns(team, searchSims: cap).last; // the search plan
      final out = await runner.run(team, req.quest, plan);
      sims++;
      if (out.clearedAllWaves) {
        addResult(resultOf(team, plan, out));
      } else if (cap < kSearchTurnsPerTeam && out.searchCapped) {
        retried.add(team);
        later.add(team); // not settled at the short cap: again with the full cap once the others have had a go
      } else {
        nonViable++;
        if (out.searchCapped) truncated = true;
      }
      await Future<void>.delayed(Duration.zero);
      yield snapshot();
    }
  }
  results.sort((a, b) => b.totalNpDamage.compareTo(a.totalNpDamage));
  yield snapshot(finished: true);
}
