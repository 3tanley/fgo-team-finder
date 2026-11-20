import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:chaldea/app/team_finder/battle_runner.dart';
import 'package:chaldea/app/team_finder/defaults.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/solver.dart';
import 'package:chaldea/app/team_finder/team_generator.dart';
import 'package:chaldea/models/models.dart' show Region;

/// State and actions behind the Team Finder page. No widgets in here so it can be tested and reused by a website.
class TeamFinderController extends ChangeNotifier {
  TeamFinderController({
    BattleRunner? runner,
    this.persist = false,
    this.ownedSetup,
    this.longSearchTeams = kLongSearchTeams,
  }) : runner = runner ?? EngineBattleRunner();

  static const _prefsKey = 'team_finder_box_v1';
  static const _friendsKey = 'team_finder_friends_v1';
  static const _cesKey = 'team_finder_ces_v1';

  final BattleRunner runner;

  /// A search over more teams than this is asked about first (see [kLongSearchTeams]).
  final int longSearchTeams;

  /// What Chaldea's own data says about an owned servant (its Plan stats), or null if it is not owned.
  /// Box servants that are owned are re-read from it before every search, so edits made in Chaldea count.
  final ServantSetup? Function(int svtId)? ownedSetup;

  /// Save the box to local storage on every change (the page turns this on; tests leave it off).
  final bool persist;

  Region region = Region.na;
  QuestSpec? quest;
  String? questLabel;

  /// Owned servants, one setup per servant id.
  final Map<int, ServantSetup> box = {};

  /// Supports chosen to be borrowed, one setup per servant id. Empty = the usual supports for the NP card.
  final Map<int, ServantSetup> friends = {};

  /// Craft essences to hand out, one entry per CE id with its quantity, in the order they were added.
  /// Starts as one Black Grail; an empty list means no CE at all.
  final List<CeSetup> ces = [CeSetup(kBlackGrailCeId)];
  SolveProgress? progress;
  String? error;
  SolveRequest? _request;

  bool get searching => _request != null;

  /// Why the search cannot start yet, or null.
  String? get blocker {
    if (box.length < kMinBoxServants) return 'Need at least $kMinBoxServants servants (you have ${box.length})';
    if (quest == null) return 'Pick a quest first';
    return null;
  }

  void setRegion(Region r) {
    region = r;
    _reset();
  }

  void setQuest(QuestSpec q, String label) {
    quest = q;
    questLabel = label;
    _reset();
  }

  void upsertServant(ServantSetup s) {
    box[s.svtId] = s;
    _changedBox();
  }

  void removeServant(int svtId) {
    box.remove(svtId);
    _changedBox();
  }

  void upsertFriend(ServantSetup s) {
    friends[s.svtId] = s;
    _reset();
    if (persist) _saveFriends();
  }

  void removeFriend(int svtId) {
    friends.remove(svtId);
    _reset();
    if (persist) _saveFriends();
  }

  void upsertCe(CeSetup ce) {
    final i = ces.indexWhere((e) => e.ceId == ce.ceId);
    if (i >= 0) {
      ces[i] = ce;
    } else {
      ces.add(ce);
    }
    _reset();
    if (persist) _saveCes();
  }

  void removeCe(int ceId) {
    ces.removeWhere((e) => e.ceId == ceId);
    _reset();
    if (persist) _saveCes();
  }

  /// Re-reads every owned servant in the box from Chaldea's data; others (added by hand) are left alone.
  /// Returns true if any setup changed.
  bool refreshOwned() {
    final provider = ownedSetup;
    if (provider == null) return false;
    var changed = false;
    for (final id in box.keys.toList()) {
      final fresh = provider(id);
      if (fresh != null && !fresh.sameAs(box[id]!)) {
        box[id] = fresh;
        changed = true;
      }
    }
    if (changed) {
      if (persist) _save();
      notifyListeners();
    }
    return changed;
  }

  /// How many teams a search with the current box, friends and CEs would go through.
  int teamCount() {
    refreshOwned();
    return generateTeams(box.values.toList(), region, friends: friends.values.toList(), ces: ces.toList()).length;
  }

  Future<void> search() async {
    refreshOwned();
    final b = blocker;
    if (b != null) {
      error = b;
      notifyListeners();
      return;
    }
    cancel();
    error = null;
    progress = null;
    final request = SolveRequest(
      region: region,
      quest: quest!,
      box: box.values.toList(),
      friends: friends.values.toList(),
      ces: ces.toList(),
    );
    _request = request;
    notifyListeners();
    try {
      await for (final p in solve(request, runner)) {
        if (_request != request) return; // a newer search or a reset took over
        progress = p;
        error = p.error;
        notifyListeners();
      }
    } on NeedMoreServants catch (e) {
      error = e.toString();
    } finally {
      if (_request == request) _request = null;
      notifyListeners();
    }
  }

  void cancel() => _request?.cancel();

  void _reset() {
    cancel();
    _request = null;
    progress = null;
    error = null;
    notifyListeners();
  }

  void _changedBox() {
    _reset();
    if (persist) _save();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      final savedFriends = prefs.getString(_friendsKey);
      final savedCes = prefs.getString(_cesKey);
      if (saved == null && savedFriends == null && savedCes == null) return;
      for (final s in decodeBox(saved ?? '[]')) {
        box[s.svtId] = s;
      }
      for (final s in decodeBox(savedFriends ?? '[]')) {
        friends[s.svtId] = s;
      }
      if (savedCes != null) {
        ces
          ..clear()
          ..addAll(decodeCes(savedCes));
      }
      notifyListeners();
    } catch (e) {
      debugPrint('team finder: could not load saved box: $e');
    }
  }

  Future<void> _save() async {
    try {
      await (await SharedPreferences.getInstance()).setString(_prefsKey, encodeBox(box.values));
    } catch (e) {
      debugPrint('team finder: could not save box: $e');
    }
  }

  Future<void> _saveFriends() async {
    try {
      await (await SharedPreferences.getInstance()).setString(_friendsKey, encodeBox(friends.values));
    } catch (e) {
      debugPrint('team finder: could not save friend supports: $e');
    }
  }

  Future<void> _saveCes() async {
    try {
      await (await SharedPreferences.getInstance()).setString(_cesKey, encodeCes(ces));
    } catch (e) {
      debugPrint('team finder: could not save craft essences: $e');
    }
  }

  static String encodeCes(Iterable<CeSetup> ces) => jsonEncode([
    for (final e in ces) {'id': e.ceId, 'lv': e.level, 'lb': e.limitBreak, 'qty': e.quantity},
  ]);

  /// Reads a saved CE list. Anything unreadable or out of range is dropped, never thrown.
  static List<CeSetup> decodeCes(String text) {
    final Object? data;
    try {
      data = jsonDecode(text);
    } on FormatException {
      return [];
    }
    if (data is! List) return [];
    final out = <CeSetup>[];
    for (final e in data) {
      try {
        final m = e as Map<String, dynamic>;
        out.add(
          CeSetup(
            m['id'] as int,
            level: (m['lv'] as int?) ?? kDefaultCeLevel,
            limitBreak: (m['lb'] as bool?) ?? true,
            quantity: (m['qty'] as int?) ?? 1,
          ),
        );
      } on ArgumentError {
        continue;
      } on TypeError {
        continue;
      }
    }
    return out;
  }

  static String encodeBox(Iterable<ServantSetup> box) => jsonEncode([
    for (final s in box)
      {
        'id': s.svtId,
        'lv': s.level,
        'skills': s.skillLevels,
        'append': s.appendLevels,
        'np': s.npLevel,
        'atk': s.atkFou,
        'hp': s.hpFou,
      },
  ]);

  /// Reads a saved box. Anything unreadable or out of range is dropped, never thrown.
  static List<ServantSetup> decodeBox(String text) {
    final Object? data;
    try {
      data = jsonDecode(text);
    } on FormatException {
      return [];
    }
    if (data is! List) return [];
    final out = <ServantSetup>[];
    for (final e in data) {
      try {
        final m = e as Map<String, dynamic>;
        final d = ServantSetup.defaults(m['id'] as int);
        out.add(
          ServantSetup(
            svtId: d.svtId,
            level: (m['lv'] as int?) ?? d.level,
            skillLevels: (m['skills'] as List?)?.cast<int>() ?? d.skillLevels,
            appendLevels: (m['append'] as List?)?.cast<int>() ?? d.appendLevels, // boxes saved before appends have none
            npLevel: (m['np'] as int?) ?? d.npLevel,
            atkFou: (m['atk'] as int?) ?? d.atkFou,
            hpFou: (m['hp'] as int?) ?? d.hpFou,
          ),
        );
      } on ArgumentError {
        continue;
      } on TypeError {
        continue;
      }
    }
    return out;
  }
}
