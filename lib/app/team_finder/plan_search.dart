import 'package:tuple/tuple.dart';

import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/battle/utils/battle_logger.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';

import 'models.dart';
import 'support_list.dart';
import 'team_generator.dart';

/// A skill that can be used right now: [src] is a front slot 0..2, or -1 for the mystic code.
typedef _Skill = ({int src, int idx});

/// Thinks a clear through instead of following one fixed loop: it plays the battle on the engine, and at
/// every turn tries the choices below, undoing (engine snapshots) and trying the next one whenever a wave
/// survives or a later turn cannot be cleared.
///
/// Choices per turn, in the order tried:
/// - swap: no swap first (on the last turn a swap first): the mystic code's order change, a non-dealer out
///   (it uses its ready skills before leaving) for a back-row servant;
/// - who fires, and in which order: every group of the main damage dealers on the field, small groups first
///   (on the last turn big groups first). Dealers not chosen keep their gauge;
/// - who gets the single-target buffs: each firing dealer in turn;
/// - which charge skills fill the firing dealers, only until they are full: their own first, or the
///   party-wide ones first.
/// Skills that lose nothing by being used now (no instant effect, every buff lasts to the last turn) are
/// always used. Short buffs are saved: one more is added each time the wave survives. The last turn uses
/// everything that is ready.
///
/// Main damage dealers: box servants with a damaging NP that carry a CE, plus a borrowed servant with a
/// damaging NP that is not one of the named loop supports; if there are none, every servant with a
/// damaging NP. Other charged NPs (Castoria, Oberon) fire whenever they are ready.
/// shortcut: single-target buffs of one turn all go to the same dealer, and a dealer is never swapped out;
/// widen the choices here if a known clear needs them.
class PlanSearch {
  PlanSearch(this.battle, this.team, this.quest, {required this.turns, this.maxSims = 150});

  final BattleData battle;
  final TeamSpec team;
  final QuestSpec quest;
  final int turns;

  /// Work cap: at most this many simulated turns, then the search gives up.
  final int maxSims;
  int sims = 0;

  /// How far the quick optimistic play got: NP damage of that play over the quest's total HP. Teams with a
  /// bigger margin are likelier to have a clear, so the solver searches them first.
  double slack = 0;

  /// True if the search stopped because it ran out of its work cap (not because every choice was tried).
  bool get capped => !_hopeless && sims >= maxSims;
  bool _hopeless = false;
  int turnsPlayed = 0;

  /// The actions of the clear that was found (same line format as the loop, see [BattleOutcome.log]).
  final List<String> log = [];

  Tuple2<BattleServantData, BattleServantData>? _pendingSwap;
  late final Set<int> _main;

  /// The engine's order-change callback: the pair chosen by the search.
  Future<Tuple2<BattleServantData, BattleServantData>?> chooseSwap(
    List<BattleServantData?> onField,
    List<BattleServantData?> backup,
  ) async => _pendingSwap;

  /// True if a clear was found; the battle is then left in its won state. Otherwise it is back at the start.
  Future<bool> run() async {
    final all = [...battle.onFieldAllyServants, ...battle.backupAllyServants];
    final dealers = [
      for (final (k, slot) in team.slots.indexed)
        if (all.getOrNull(k) != null && isDamageDealer(slot.servant.svtId)) k,
    ];
    final chosen = dealers.where(
      (k) =>
          !_blocksAllies(team.slots[k].servant.svtId) &&
          (k == 0 ? !isSupportName(team.slots[k].servant.svtId) : team.slots[k].ce != null),
    );
    _main = {for (final k in chosen.isEmpty ? dealers : chosen) all[k]!.uniqueId};
    final mark = _mark();
    final possible = await _clearsWithEverything();
    final dealt = battle.recorder.records
        .whereType<BattleAttackRecord>()
        .where((a) => a.card?.isTD == true)
        .fold<int>(0, (sum, a) => sum + a.damage);
    final totalHp = quest.waves.expand((w) => w.enemies).fold<int>(0, (sum, e) => sum + e.hp);
    slack = totalHp == 0 ? 0 : dealt / totalHp;
    _restore(mark);
    _hopeless = !possible;
    return possible && await _turn(0);
  }

  /// True if the servant's NP makes the enemies invincible or puts them to sleep: fired before the others it
  /// leaves them nothing to hit (Oberon), so it is never a main dealer and always fires last.
  static bool _blocksAllies(int svtId) =>
      db.gameData.servantsById[svtId]?.groupedNoblePhantasms[1]?.lastOrNull?.functions.any(
        (f) => f.funcTargetType.isEnemy && (f.buff?.type == BuffType.invincible || f.buff?.type == BuffType.donotAct),
      ) ??
      false;

  /// Quick way out for hopeless teams: plays the battle with every skill off cooldown every turn (single-target
  /// ones on every main dealer), every gauge full and the back row swapped in on the last turn. No real plan
  /// can do better, so a wave that survives this means there is no clear.
  Future<bool> _clearsWithEverything() async {
    for (var t = 0; t < turns && !battle.isBattleWin; t++) {
      final mustClear = quest.waves.length - battle.waveCount + 1 >= turns - t;
      void refresh() {
        for (final info in [...battle.masterSkillInfo, for (var i = 0; i < 3; i++) ...?_svt(i)?.skillInfoList]) {
          info.chargeTurn = 0;
        }
      }

      Future<void> useAll(Iterable<int> sources) async {
        for (final k in _ready().where((k) => sources.contains(k.src))) {
          final mains = [0, 1, 2].where((i) => _main.contains(_svt(i)?.uniqueId)).toList();
          for (final target in _targeted(k) && mains.isNotEmpty ? mains : [mains.firstOrNull ?? 0]) {
            refresh();
            if (_isReady(k)) await _use(k, target, t + 1);
          }
        }
      }

      refresh();
      final swap = t == turns - 1 ? _swapOptions().firstOrNull : null;
      if (swap != null) {
        await useAll([swap.$1]);
        refresh();
        final incoming = battle.backupAllyServants.firstWhereOrNull((s) => s?.uniqueId == swap.$2);
        _pendingSwap = Tuple2(_svt(swap.$1)!, incoming!);
        await battle.activateMysticCodeSkill(_swapSkill()!.idx);
        _pendingSwap = null;
      }
      await useAll([-1, 0, 1, 2]);
      for (var i = 0; i < 3; i++) {
        _svt(i)?.np = 30000; // the most any gauge can hold, so the check stays optimistic (overcharge)
      }
      final all = [0, 1, 2].where((i) => _main.contains(_svt(i)?.uniqueId)).toList();
      if (!await _fire(t + 1, all, mustClear)) return false;
    }
    return battle.isBattleWin;
  }

  BattleServantData? _svt(int i) => battle.onFieldAllyServants.getOrNull(i);

  int _slotOf(int? uniqueId) =>
      uniqueId == null ? -1 : battle.onFieldAllyServants.indexWhere((s) => s?.uniqueId == uniqueId);

  BattleSkillInfoData? _info(_Skill k) =>
      k.src < 0 ? battle.masterSkillInfo.getOrNull(k.idx) : _svt(k.src)?.skillInfoList.getOrNull(k.idx);

  /// What the skill does to the team: functions aimed at enemies (curses, debuffs, an enemy NP gain) are left out.
  Iterable<NiceFunction> _functions(_Skill k) =>
      _info(k)?.skill?.functions.where((f) => f.funcTargetTeam != FuncApplyTarget.enemy && !f.funcTargetType.isEnemy) ??
      const [];

  bool _isSwap(_Skill k) => _functions(k).any((f) => f.funcType == FuncType.replaceMember);
  bool _charges(_Skill k) => _functions(k).any((f) => f.funcType == FuncType.gainNp);
  bool _targeted(_Skill k) => _functions(k).any((f) => f.funcTargetType.needNormalOneTarget);

  bool _isReady(_Skill k) {
    final info = _info(k);
    if (info == null || info.chargeTurn > 0) return false;
    return k.src < 0
        ? battle.canUseMysticCodeSkillIgnoreCoolDown(k.idx)
        : battle.canUseSvtSkillIgnoreCoolDown(k.src, k.idx);
  }

  /// Ready skills in slot order, the mystic code last; the order change is handled on its own.
  List<_Skill> _ready() => [
    for (var i = 0; i < 3; i++)
      for (var s = 0; s < 3; s++)
        if (_isReady((src: i, idx: s))) (src: i, idx: s),
    for (var m = 0; m < battle.masterSkillInfo.length; m++)
      if (_isReady((src: -1, idx: m)) && !_isSwap((src: -1, idx: m))) (src: -1, idx: m),
  ];

  /// Buffs that never change damage or gauge, so spending the skill early costs nothing for them.
  static const _defensive = {
    BuffType.invincible,
    BuffType.avoidance,
    BuffType.guts,
    BuffType.upDefence,
    BuffType.upToleranceSubstate,
    BuffType.avoidState,
    BuffType.subSelfdamage,
    BuffType.upGainHp,
    BuffType.regainHp,
    BuffType.upDamagedropnp,
  };

  /// True if using the skill now loses nothing: its effects are buffs that last through the last turn (a buff
  /// with a use count is only spent by its holder's own attacks, so it counts while the holder is not in
  /// [firing]), plus instant effects that cannot hurt (stars, NP-turn haste) and buffs that are defensive only.
  bool _lasting(_Skill k, int turnsLeft, List<int> firing) {
    final info = _info(k);
    if (info?.skill == null) return false;
    for (final f in _functions(k)) {
      if (f.funcType == FuncType.hastenNpturn || f.funcType == FuncType.gainStar) continue;
      if (f.funcType != FuncType.addState && f.funcType != FuncType.addStateShort) return false;
      if (_defensive.contains(f.buff?.type)) continue;
      final vals = f.svals.getOrNull(info!.skillLv - 1) ?? f.svals.firstOrNull;
      if ((vals?.Count ?? -1) > 0 && (f.funcTargetType != FuncTargetType.self || firing.contains(k.src))) return false;
      final turn = vals?.Turn ?? -1;
      if (turn > 0 && turn < turnsLeft) return false;
    }
    return true;
  }

  /// True if the charge skill would fill one of the [needy] slots.
  bool _chargeReaches(_Skill k, List<int> needy) {
    for (final f in _functions(k).where((f) => f.funcType == FuncType.gainNp)) {
      final ok = switch (f.funcTargetType) {
        FuncTargetType.self => needy.contains(k.src),
        FuncTargetType.ptOther || FuncTargetType.ptAnother || FuncTargetType.ptOneOther => needy.any((i) => i != k.src),
        _ => true,
      };
      if (ok) return true;
    }
    return false;
  }

  Future<void> _use(_Skill k, int target, int tn) async {
    battle.playerTargetIndex = target;
    if (k.src < 0) {
      await battle.activateMysticCodeSkill(k.idx);
      log.add('T$tn mc ${k.idx + 1}');
    } else {
      await battle.activateSvtSkill(k.src, k.idx);
      log.add('T$tn skill ${k.src}.${k.idx + 1} -> $target');
    }
  }

  (int, int) _mark() {
    battle.pushSnapshot();
    return (battle.snapshots.length, log.length);
  }

  void _restore((int, int) mark) {
    battle.snapshots.length = mark.$1; // drop the engine's own undo points made since
    battle.popSnapshot();
    log.length = mark.$2;
  }

  _Skill? _swapSkill() =>
      [for (var i = 0; i < battle.masterSkillInfo.length; i++) (src: -1, idx: i)]
          .firstWhereOrNull((k) => _isSwap(k) && _isReady(k));

  /// Order changes worth trying: (front slot going out, unique id of the back-row servant coming in).
  /// The servant with the fewest ready skills goes out first (it loses the least); on a tie the later slot.
  List<(int, int)> _swapOptions() {
    if (_swapSkill() == null) return [];
    int readySkills(int i) => [0, 1, 2].where((s) => _isReady((src: i, idx: s))).length;
    final outs = [
      for (var i = 2; i >= 0; i--)
        if (_svt(i)?.canOrderChange() == true && !_main.contains(_svt(i)!.uniqueId)) i,
    ];
    final byFewest = [for (var n = 0; n <= 3; n++) ...outs.where((i) => readySkills(i) == n)];
    return [
      for (final s in battle.backupAllyServants)
        if (s != null && s.canOrderChange())
          for (final out in byFewest) (out, s.uniqueId),
    ];
  }

  /// Every non-empty set of dealers in every firing order, small sets first (or big first).
  static List<List<int>> _groups(List<int> ids, {required bool bigFirst}) {
    final subsets = [
      for (var mask = 1; mask < 1 << ids.length; mask++)
        [
          for (var i = 0; i < ids.length; i++)
            if (mask & (1 << i) != 0) ids[i],
        ],
    ];
    List<List<int>> orders(List<int> g) => g.length <= 1
        ? [g]
        : [
            for (final (i, first) in g.indexed)
              for (final rest in orders([...g.sublist(0, i), ...g.sublist(i + 1)])) [first, ...rest],
          ];
    final sizes = [for (var n = 1; n <= ids.length; n++) n];
    return [
      for (final n in bigFirst ? sizes.reversed : sizes)
        for (final g in subsets.where((g) => g.length == n)) ...orders(g),
    ];
  }

  /// States (at the start of a turn) that were already searched without finding a clear.
  final Set<String> _deadEnds = {};

  /// Everything the rest of the battle depends on, as text: two different choices that lead to the same state
  /// are searched once. Enemy state is left out: a turn always starts on a fresh wave or with the turn's slack.
  String _stateKey(int t) {
    String svt(BattleServantData? s) => s == null
        ? '-'
        : '${s.uniqueId}:${s.np}:${s.hp}:${s.skillInfoList.map((i) => i.chargeTurn).join('.')}:'
              '${s.battleBuff.getAllBuffs().map((b) => '${b.buff.id}/${b.param}/${b.logicTurn}/${b.count}').join('.')}';
    return [
      t,
      battle.waveCount,
      battle.nonnullEnemies.map((e) => e.hp).join('.'),
      battle.masterSkillInfo.map((i) => i.chargeTurn).join('.'),
      ...battle.onFieldAllyServants.map(svt),
      ...battle.backupAllyServants.map(svt),
    ].join('|');
  }

  Future<bool> _turn(int t) async {
    if (battle.isBattleWin) {
      turnsPlayed = t;
      return true;
    }
    if (t >= turns || sims >= maxSims) return false;
    final key = _stateKey(t);
    if (_deadEnds.contains(key)) return false;
    final last = t == turns - 1;
    // with fewer waves than turns a turn may end without a kill
    final mustClear = quest.waves.length - battle.waveCount + 1 >= turns - t;
    final tried = <String>{};
    for (final swap in <(int, int)?>[if (!last) null, ..._swapOptions(), if (last) null]) {
      final field = [for (final s in battle.onFieldAllyServants) s?.uniqueId];
      if (swap != null) field[swap.$1] = swap.$2;
      final dealers = field.nonNulls.where(_main.contains).toList();
      final groups = _groups(dealers, bigFirst: last);
      if (!mustClear || groups.isEmpty) groups.add([]);
      // last turn: groups that fired with everything, per primary; a smaller group cannot do more
      final fired = <int?, List<List<int>>>{};
      for (final firing in groups) {
        // single-target buffs go to a firing dealer first, then to the other main dealers on the field (an Arts
        // buff cast on the turn the Buster dealer fires belongs to the Arts dealer that fires later)
        for (final primary
            in firing.isEmpty ? [dealers.firstOrNull] : [...firing, ...dealers.where((d) => !firing.contains(d))]) {
          final dominated = (fired[primary] ?? const []).any(
            (g) => g.length > firing.length && firing.every(g.contains),
          );
          if (last && dominated) continue;
          for (final ownChargesFirst in [true, false]) {
            if (sims >= maxSims) return false;
            final mark = _mark();
            final before = sims;
            if (await _play(t, swap, firing, primary, ownChargesFirst, mustClear, tried)) return true;
            _restore(mark);
            if (sims > before) fired.putIfAbsent(primary, () => []).add(firing);
          }
        }
      }
    }
    if (sims < maxSims) _deadEnds.add(key); // only a finished search proves a dead end
    return false;
  }

  Future<bool> _play(
    int t,
    (int, int)? swap,
    List<int> firing,
    int? primary,
    bool ownChargesFirst,
    bool mustClear,
    Set<String> tried,
  ) async {
    final tn = t + 1;
    final last = t == turns - 1;
    final start = log.length;
    // single-target skills go to the primary dealer; before it is on the field, to another main dealer
    int target() {
      final p = _slotOf(primary);
      if (p >= 0) return p;
      return [0, 1, 2].firstWhereOrNull((i) => _main.contains(_svt(i)?.uniqueId)) ?? 0;
    }

    if (swap != null) {
      final (out, inId) = swap;
      for (var s = 0; s < 3; s++) {
        if (_isReady((src: out, idx: s))) await _use((src: out, idx: s), target(), tn);
      }
      final outgoing = _svt(out);
      final incoming = battle.backupAllyServants.firstWhereOrNull((s) => s?.uniqueId == inId);
      final skill = _swapSkill();
      if (outgoing == null || incoming == null || skill == null) return false;
      final inSlot = 3 + battle.backupAllyServants.indexOf(incoming);
      _pendingSwap = Tuple2(outgoing, incoming);
      await battle.activateMysticCodeSkill(skill.idx);
      _pendingSwap = null;
      log.add('T$tn swap $out <-> $inSlot');
    }
    final firingSlots = firing.map(_slotOf).toList();
    if (firingSlots.contains(-1)) return false;

    for (final k in _ready()) {
      if (!_charges(k) && (last || _lasting(k, turns - t, firingSlots)) && _isReady(k)) await _use(k, target(), tn);
    }

    bool full(int i) => (_svt(i)?.np ?? 0) >= 10000;
    // own charge skills, then single-target ones from the others, then party-wide ones; or the reverse
    int rank(_Skill k) => firingSlots.contains(k.src) ? 0 : (_targeted(k) ? 1 : 2);
    final ready = _ready().where(_charges).toList();
    final charges = [
      for (final r in ownChargesFirst ? [0, 1, 2] : [2, 1, 0]) ...ready.where((k) => rank(k) == r),
    ];
    for (final k in charges) {
      final needy = firingSlots.where((i) => !full(i)).toList()
        ..sort((a, b) => (_svt(a)?.np ?? 0) - (_svt(b)?.np ?? 0));
      if (needy.isEmpty) break;
      if (!_isReady(k) || !_chargeReaches(k, needy)) continue;
      await _use(k, _targeted(k) ? needy.firstWhere((i) => i != k.src, orElse: () => needy.first) : target(), tn);
    }
    if (firingSlots.any((i) => !full(i))) return false;
    if (last) {
      for (final k in _ready().where(_charges)) {
        await _use(k, target(), tn);
      }
    }
    // another choice already led to exactly these actions this turn
    final signature = '$swap|$firing|${(log.sublist(start)..sort()).join(',')}';
    if (!tried.add(signature)) return false;

    final shorts = _ready().where((k) => !_charges(k)).toList();
    var probed = false;
    while (true) {
      if (sims >= maxSims) return false;
      final mark = _mark();
      final cleared = await _fire(tn, firingSlots, mustClear);
      if (cleared && await _turn(t + 1)) return true;
      _restore(mark);
      if (cleared || shorts.isEmpty) return false;
      if (!probed) {
        // one probe with every short skill used: if the wave still survives, no smaller set clears it either
        probed = true;
        final probe = _mark();
        for (final k in shorts) {
          if (_isReady(k)) await _use(k, target(), tn);
        }
        final possible = await _fire(tn, firingSlots, mustClear);
        _restore(probe);
        if (!possible) return false;
      }
      await _use(shorts.removeAt(0), target(), tn);
    }
  }

  /// Plays the turn: charged non-damaging NPs first, then the damaging NPs of [firingSlots] and of any
  /// charged servant that is not a main dealer. True if the wave died (or it did not have to).
  Future<bool> _fire(int tn, List<int> firingSlots, bool mustClear) async {
    sims++;
    if (sims % 8 == 0) await Future<void>.delayed(Duration.zero); // keep the UI responsive
    final wave = battle.waveCount;
    // single-target NPs go for the enemy with the most HP
    var toughest = -1;
    for (final (i, e) in battle.onFieldEnemies.indexed) {
      if (e != null && (toughest < 0 || e.hp > battle.onFieldEnemies[toughest]!.hp)) toughest = i;
    }
    if (toughest >= 0) battle.enemyTargetIndex = toughest;
    bool damaging(int i) => _svt(i)!.getCurrentNP()?.functions.any((f) => f.funcType.isDamageNp) ?? false;
    final ready = [0, 1, 2].where((i) => _svt(i)?.canNP() == true).toList();
    final nps = [
      ...ready.where((i) => !damaging(i)),
      ...firingSlots.where(ready.contains), // the chosen dealers, in the chosen order
      ...ready.where((i) => damaging(i) && !_main.contains(_svt(i)!.uniqueId)),
    ];
    for (final i in nps) {
      log.add('T$tn np $i');
    }
    await battle.playerTurn([for (final i in nps) CombatAction(_svt(i)!, _svt(i)!.getNPCard()!)], allowSkip: true);
    return battle.isBattleWin || battle.waveCount > wave || !mustClear;
  }
}
