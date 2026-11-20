import 'package:chaldea/app/battle/utils/battle_logger.dart' show BattleRecord;
import 'package:chaldea/models/models.dart' show Region;

import 'battle_runner.dart';
import 'ce_options.dart';
import 'models.dart';
import 'team_generator.dart';
import 'team_priority.dart';
import 'turn_planner.dart';

/// Smallest box that can make a team: the borrowed support plus two box servants (the damage dealer and a partner).
const int kMinBoxServants = 2;

/// Wall-clock time a whole request may take (about 10 minutes; the quick pass below gets at most the first quarter).
/// Every team first gets the loop plan and the
/// search's quick optimistic check, which also rates how likely the team is to hide a clear (the margin). The
/// teams the check cannot rule out are then searched best-ranked first, each with up to
/// [kSearchTurnsPerTeam] turns (more for the top ranks), until the time is spent. No search starts after that, so a request ends at most
/// one team's search (a few tens of seconds) late. A team whose search finished is final; one that hit its cap
/// or was never reached is reported as not settled (the request is [SolveProgress.truncated]).
const Duration kSolveTimeBudget = Duration(minutes: 10);

/// A search over more teams than this will probably use the whole budget (the quick check costs about half a second
/// a team in the browser, and most teams then need a search of a few seconds), so the page asks before starting it.
const int kLongSearchTeams = 100;
const int kSearchTurnsPerTeam = 400;

/// A team whose search hits its cap is searched again with a bigger one once the others have had a go, and the best
/// ranked [kTopRankedTeams] (see team_priority.dart) go on to [kTopSearchTurns]: they are the likeliest to hide a
/// clear, and a clear can need a long search (the owner's Earth + Draco loop needs about 500 turns).
const int kTopRankedTeams = 40;
const int kTopSearchTurns = 1500;

/// The share of the time left after the quick pass that the broad first search round may use; what is left goes to
/// searching the best-ranked teams that hit their cap again, with bigger caps. 1 = the broad round may use all of it,
/// so the deeper rounds only run once every team has had its first search. Measured on a 24-servant box for 10
/// minutes: 0.4 found 4 clears, 1.0 found 8, so the broad round comes first.
const double kBroadSearchShare = 1.0;

/// A clear that deals at least this many times the quest's total HP has damage to spare: it is tried again with a drop
/// CE on everyone and no damage CE (Black Grail, event damage CE), and that version replaces it if it clears too.
const int kOverkillFactor = 2;

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

  /// How many of the best-ranked teams get the big search cap ([kTopSearchTurns]).
  final int topRanked;

  /// The share of the time left after the quick pass that the broad first search round may use.
  final double broadShare;

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
    this.topRanked = kTopRankedTeams,
    this.broadShare = kBroadSearchShare,
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

/// A team with several back-row servants, cut down to the one the clear swapped in (the first when it never swapped),
/// and the log with the swap's slot number following. A team with at most one back-row servant comes back as it is.
(TeamSpec, List<String>) withUsedBackup(TeamSpec team, List<String> log) {
  if (team.slots.length <= 4) return (team, log);
  final swap = RegExp(r'^(T\d+) swap (\d+) <-> (\d+)$');
  var keep = 3;
  final out = <String>[];
  for (final line in log) {
    final m = swap.firstMatch(line);
    if (m == null) {
      out.add(line);
    } else {
      keep = int.parse(m[3]!).clamp(3, team.slots.length - 1);
      out.add('${m[1]} swap ${m[2]} <-> 3');
    }
  }
  return (TeamSpec([...team.slots.take(3), team.slots[keep]], mysticCode: team.mysticCode), out);
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
  final rankOf = {for (final (i, t) in teams.indexed) t: i};
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
  TeamResult resultOf(TeamSpec team, TurnPlan plan, BattleOutcome out) {
    final (used, log) = withUsedBackup(team, out.log);
    return TeamResult(
      team: used,
      plan: plan,
      unverified: out.unverified,
      totalNpDamage: out.totalNpDamage,
      log: log,
      records: out.records,
    );
  }

  final totalHp = req.quest.waves.expand((w) => w.enemies).fold<int>(0, (sum, e) => sum + e.hp);
  final dropCes = [
    for (final ce in req.ces ?? const <CeSetup>[])
      if (raisesDropsId(ce.ceId))
        for (var n = 0; n < ce.quantity; n++) ce,
  ];

  /// The same team with a drop CE on every servant after the support and no damage CE, when [r] cleared with damage
  /// to spare and carried a damage CE; null when there is nothing to take away, no time, or that team does not clear.
  Future<TeamResult?> withoutDamageCes(TeamResult r) async {
    final slots = r.team.slots;
    final hasDamageCe = slots.skip(1).any((s) => s.ce != null && !raisesDropsId(s.ce!.ceId));
    if (r.totalNpDamage < kOverkillFactor * totalHp || dropCes.isEmpty || !hasDamageCe) return null;
    if (req.cancelled || sims >= req.maxSims || req.now().difference(started) >= req.timeBudget) return null;
    var next = 0;
    final variant = TeamSpec([
      slots.first,
      for (final s in slots.skip(1)) SlotSpec(s.servant, ce: next < dropCes.length ? dropCes[next++] : null),
    ], mysticCode: r.team.mysticCode);
    final plan = planTurns(variant, searchSims: kSearchTurnsPerTeam).last;
    final out = await runner.run(variant, req.quest, plan);
    sims++;
    return out.clearedAllWaves ? resultOf(variant, plan, out) : null;
  }

  Future<void> addResult(TeamResult r) async {
    final better = await withoutDamageCes(r);
    results
      ..add(better ?? r)
      ..sort((a, b) => b.totalNpDamage.compareTo(a.totalNpDamage));
  }

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
        if (best != null) await addResult(best);
        break screening;
      }
      final out = await runner.run(team, req.quest, plan);
      sims++;
      if (out.clearedAllWaves) {
        if (best == null || out.totalNpDamage > best.totalNpDamage) best = resultOf(team, plan, out);
      } else if (out.searchCapped) {
        capped = true;
      }
    }
    done++;
    if (best != null) {
      await addResult(best);
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
    // the best-ranked first: they are the likeliest to hide a clear (the optimistic margin did not predict clears)
    unresolved.sort((a, b) => rankOf[a]!.compareTo(rankOf[b]!));
    // too many teams for the full cap each in the time left (judged from how fast the quick pass went): two rounds
    final spent = req.now().difference(started);
    final perCheck = done == 0 ? Duration.zero : spent ~/ done;
    final twoRounds = perCheck * kFullSearchInQuickChecks * unresolved.length > req.timeBudget - spent;
    // a team that hits its cap without a verdict is searched again with the next cap; only the top ranks get the
    // last, big one. The broad first round may be limited to [kBroadSearchShare] of the time, so that the deeper rounds
    // are reached; the teams it did not get to wait until those are done.
    final ladder = [if (twoRounds) kFirstSearchTurns, kSearchTurnsPerTeam, kTopSearchTurns];
    final step = <TeamSpec, int>{};
    final broadEnd = spent + (req.timeBudget - spent) * req.broadShare;
    while ((unresolved.isNotEmpty || later.isNotEmpty) && !req.cancelled) {
      if (req.now().difference(started) >= req.timeBudget || sims >= req.maxSims) {
        truncated = true;
        nonViable += unresolved.length + later.length; // none of them settled: reported as hitting the search limit
        unresolved.clear();
        later.clear();
        break;
      }
      final broad = unresolved.isNotEmpty && (later.isEmpty || req.now().difference(started) < broadEnd);
      final TeamSpec team;
      if (broad) {
        team = unresolved.removeAt(0);
      } else {
        // the smaller cap first, the best-ranked first within a cap
        team = later.reduce((a, b) {
          final c = step[a]!.compareTo(step[b]!);
          return (c != 0 ? c : rankOf[a]!.compareTo(rankOf[b]!)) <= 0 ? a : b;
        });
        later.remove(team);
      }
      final at = step[team] ?? 0;
      final cap = ladder[at];
      final plan = planTurns(team, searchSims: cap).last; // the search plan
      final out = await runner.run(team, req.quest, plan);
      sims++;
      if (out.clearedAllWaves) {
        await addResult(resultOf(team, plan, out));
      } else if (out.searchCapped &&
          at + 1 < ladder.length &&
          (at + 2 < ladder.length || rankOf[team]! < req.topRanked)) {
        step[team] = at + 1;
        later.add(team);
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
