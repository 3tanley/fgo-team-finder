import 'package:flutter_easyloading/flutter_easyloading.dart';

import 'package:chaldea/app/api/atlas.dart';
import 'package:chaldea/app/app.dart';
import 'package:chaldea/app/modules/servant/servant.dart';
import 'package:chaldea/app/modules/servant/servant_list.dart';
import 'package:chaldea/app/team_finder/labels.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/owned.dart';
import 'package:chaldea/app/team_finder/quest_loader.dart';
import 'package:chaldea/app/team_finder/solver.dart';
import 'package:chaldea/generated/l10n.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';
import 'package:chaldea/widgets/widgets.dart';

import 'team_finder_controller.dart';

/// Pick a quest and the servants you own (from Chaldea's own servant data); find the teams that clear it in 3 turns,
/// best NP damage first.
/// Text is English only for now (shortcut: add l10n entries before shipping to other languages).
class TeamFinderPage extends StatefulWidget {
  final TeamFinderController? controller;
  const TeamFinderPage({super.key, this.controller});

  @override
  State<TeamFinderPage> createState() => _TeamFinderPageState();
}

class _TeamFinderPageState extends State<TeamFinderPage> with SingleTickerProviderStateMixin {
  late final TeamFinderController c =
      widget.controller ?? TeamFinderController(persist: true, ownedSetup: ownedSetupFor);
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void initState() {
    super.initState();
    c.addListener(_rebuild);
    if (widget.controller == null) c.load();
    // coming back to the first tab: show the servants with their current Chaldea stats
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging && _tabs.index == 0) c.refreshOwned();
    });
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_rebuild);
    _tabs.dispose();
    c.cancel();
    if (widget.controller == null) c.dispose();
    super.dispose();
  }

  static String _fmt(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  String _svtName(int id) => servantLabel(id);

  Future<void> _pickQuest() async {
    InputCancelOkDialog.number(
      title: 'Quest ID',
      validate: (v) => v > 0,
      onSubmit: (id) async {
        final meta = db.gameData.quests[id] ?? await showEasyLoading(() => AtlasApi.quest(id, region: c.region));
        if (!mounted) return;
        if (meta == null) {
          EasyLoading.showError(S.current.not_found);
          return;
        }
        final phases = meta.phases.where((p) => !meta.phasesNoBattle.contains(p)).toList();
        int? phase = phases.length == 1 ? phases.single : null;
        if (phases.length > 1) {
          phase = await router.showDialog<int>(
            builder: (context) => SimpleDialog(
              title: const Text('Quest phase'),
              children: [
                for (final p in phases)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                    title: Text('phase $p'),
                    onTap: () => Navigator.pop(context, p),
                  ),
              ],
            ),
          );
        }
        if (phase == null) return;
        try {
          final spec = await showEasyLoading(() => loadQuest(c.region, id, phase!));
          c.setQuest(spec, '${meta.lNameWithChapter} · $id/$phase');
        } on StateError {
          EasyLoading.showError(S.current.not_found);
        }
      },
    ).showDialog(context);
  }

  void _addServant() {
    router.pushPage(
      ServantListPage(
        // the most common supports pinned in a row at the top, like Laplace's servant selector
        pinged: commonSupportIds(),
        showSecondaryFilter: true,
        onSelected: (svt) {
          if (svt.rarity < 4) {
            EasyLoading.showError('Only 4★ and 5★ servants are used for now');
            return;
          }
          _editServant(c.box[svt.id] ?? ownedSetupFor(svt.id) ?? ServantSetup.defaults(svt.id));
        },
      ),
    );
  }

  static String _statLine(ServantSetup s) =>
      'Lv${s.level} · ${s.skillLevels.join('/')} · NP${s.npLevel} · fou ${s.atkFou}/${s.hpFou}'
      '${s.appendLevels.any((e) => e > 0) ? ' · append ${s.appendLevels.join('/')}' : ''}';

  /// Opens Chaldea's own servant page (Plan tab: ascension, skills, append skills, grails, fou) and re-reads the stats after.
  Future<void> _openDetail(int svtId) async {
    final svt = db.gameData.servantsById[svtId];
    if (svt == null) return;
    await router.pushPage(ServantDetailPage(id: svt.id, svt: svt), detail: true);
    if (mounted) {
      c.refreshOwned();
      setState(() {});
    }
  }

  void _toggleOwned(Servant svt) {
    if (c.box.containsKey(svt.id)) {
      c.removeServant(svt.id);
    } else {
      final setup = ownedSetupFor(svt.id);
      if (setup != null) c.upsertServant(setup);
    }
  }

  /// The servants the user marked as owned in Chaldea, to tick the ones to use.
  Widget _ownedTab() {
    return db.onUserData((context, snapshot) {
      final owned = ownedServants(c.region);
      return ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ListTile(
            title: const Text('Servants you own'),
            subtitle: const Text(
              'Servants marked as owned (heart) in Chaldea, with the stats from their Plan. '
              'Tick the ones to use; the info button opens the servant page to edit their stats.',
            ),
            trailing: OutlinedButton.icon(
              onPressed: _addServant,
              icon: const Icon(Icons.add),
              label: const Text('Add other'),
            ),
          ),
          if (owned.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'No owned servants yet. Mark servants as owned (heart) on their servant page and set their stats '
                    'in the Plan tab, or use Add other for one you want to try.',
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: () => router.pushPage(ServantListPage(), detail: true),
                    child: const Text('Open servant list'),
                  ),
                ],
              ),
            ),
          for (final svt in owned)
            ListTile(
              dense: true,
              leading: svt.iconBuilder(context: context, width: 40, jumpToDetail: false),
              title: Text(_svtName(svt.id)),
              subtitle: Text(_statLine(ownedSetupFor(svt.id)!)), // always Chaldea's current stats
              onTap: () => _toggleOwned(svt),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(value: c.box.containsKey(svt.id), onChanged: (_) => _toggleOwned(svt)),
                  IconButton(icon: const Icon(Icons.info_outline), onPressed: () => _openDetail(svt.id)),
                ],
              ),
            ),
        ],
      );
    });
  }

  Future<void> _editServant(ServantSetup current) async {
    final result = await showDialog<ServantSetup>(
      context: context,
      builder: (context) => _ServantEditDialog(current: current, name: _svtName(current.svtId)),
    );
    if (result != null) c.upsertServant(result);
  }

  @override
  Widget build(BuildContext context) {
    final p = c.progress;
    final blocker = c.blocker;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Team Finder'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Find teams'),
            Tab(text: 'Owned servants'),
          ],
        ),
      ),
      body: TabBarView(controller: _tabs, children: [_findTab(p, blocker), _ownedTab()]),
    );
  }

  Widget _findTab(SolveProgress? p, String? blocker) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: SegmentedButton<Region>(
            segments: const [
              ButtonSegment(value: Region.na, label: Text('NA')),
              ButtonSegment(value: Region.jp, label: Text('JP')),
            ],
            selected: {c.region},
            onSelectionChanged: (s) => c.setRegion(s.single),
          ),
        ),
        ListTile(
          title: const Text('Quest'),
          subtitle: Text(
            c.quest == null
                ? 'Not selected'
                : '${c.questLabel}\n${c.quest!.waves.length} waves'
                      '${c.quest!.unsupportedGimmicks.isEmpty ? '' : ' · unverified: ${c.quest!.unsupportedGimmicks.join(', ')}'}',
          ),
          trailing: TextButton(onPressed: _pickQuest, child: const Text('Choose')),
        ),
        const Divider(),
        ListTile(
          title: Text('Servants used (${c.box.length})'),
          subtitle: const Text(
            'Pick them in the Owned servants tab: their stats come from your Chaldea servant data. '
            'Servants added by hand: blank fields default to level 90, skills 10/10/10, NP level 1, fou 1000.',
          ),
          trailing: FilledButton.tonal(onPressed: () => _tabs.animateTo(1), child: const Text('Select servants')),
        ),
        for (final s in c.box.values)
          ListTile(
            dense: true,
            leading: db.gameData.servantsById[s.svtId]?.iconBuilder(context: context, width: 40, jumpToDetail: false),
            title: Text(_svtName(s.svtId)),
            subtitle: Text(_statLine(s)),
            // an owned servant is edited where Chaldea keeps its stats; one added by hand has its own dialog
            onTap: () => ownedSetupFor(s.svtId) != null ? _openDetail(s.svtId) : _editServant(s),
            trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => c.removeServant(s.svtId)),
          ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              FilledButton(onPressed: blocker == null && !c.searching ? c.search : null, child: const Text('Search')),
              const SizedBox(width: 12),
              if (c.searching) OutlinedButton(onPressed: c.cancel, child: const Text('Cancel')),
            ],
          ),
        ),
        if (blocker != null && !c.searching)
          Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Text(blocker)),
        if (c.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(c.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (p != null) ..._results(p),
      ],
    );
  }

  List<Widget> _results(SolveProgress p) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (c.searching) LinearProgressIndicator(value: p.teamsTotal == 0 ? null : p.teamsDone / p.teamsTotal),
            const SizedBox(height: 8),
            Text(
              'Teams checked ${p.teamsDone}/${p.teamsTotal} · viable ${p.results.length} · not viable ${p.nonViable}'
              '${p.cancelled ? ' · cancelled' : ''}',
            ),
            if (p.truncated)
              const Text(
                'Stopped at the search limit: results may be incomplete.',
                style: TextStyle(color: Colors.orange),
              ),
            if (p.finished && p.error == null && p.results.isEmpty && !p.truncated && !p.cancelled)
              const Text(
                'Not viable: no team found that clears this quest in 3 turns. '
                'This search only tries the Castoria-style loop (see below), so other loops are not covered.',
              ),
          ],
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          'Loop rules used: turn 1 buffs first (Castoria skill 3 on the attacker), then charge the attacker only as '
          'much as needed each turn, and on the final wave swap a Castoria for a back-row support with the '
          'Decisive-Battle Chaldea Uniform. Black Grail goes on the attacker; the support carries its bond CE. '
          'The slot order is fixed: support first.',
          style: TextStyle(fontSize: 12),
        ),
      ),
      for (final (i, r) in p.results.take(50).indexed)
        ExpansionTile(
          title: Text(
            '#${i + 1}  ${_fmt(r.totalNpDamage)} NP damage (overkill included)${r.unverified ? '  (unverified)' : ''}',
          ),
          subtitle: Text(r.team.slots.map((s) => _svtName(s.servant.svtId)).join(' / ')),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(describeLog(r.log, r.team).join('\n')),
              ),
            ),
          ],
        ),
    ];
  }
}

class _ServantEditDialog extends StatefulWidget {
  final ServantSetup current;
  final String name;
  const _ServantEditDialog({required this.current, required this.name});

  @override
  State<_ServantEditDialog> createState() => _ServantEditDialogState();
}

class _ServantEditDialogState extends State<_ServantEditDialog> {
  late final _level = TextEditingController(text: '${widget.current.level}');
  late final _skills = [for (final s in widget.current.skillLevels) TextEditingController(text: '$s')];
  late final _appends = [for (final a in widget.current.appendLevels) TextEditingController(text: '$a')];
  late final _np = TextEditingController(text: '${widget.current.npLevel}');
  late final _atk = TextEditingController(text: '${widget.current.atkFou}');
  late final _hp = TextEditingController(text: '${widget.current.hpFou}');
  String? _error;

  @override
  void dispose() {
    for (final c in [_level, ..._skills, ..._appends, _np, _atk, _hp]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Blank fields fall back to the defaults; anything else must be a valid number in range.
  void _save() {
    int read(TextEditingController c, int fallback) => c.text.trim().isEmpty ? fallback : int.parse(c.text.trim());
    try {
      final level = read(_level, widget.current.level);
      if (level < 1 || level > 120) throw ArgumentError('level must be 1..120');
      // blank = 0 (append not unlocked)
      final appends = [for (final c in _appends) read(c, 0)];
      if (appends.any((e) => e < 0 || e > 10)) throw ArgumentError('append levels must be 0..10 (0 = not unlocked)');
      final setup = ServantSetup(
        svtId: widget.current.svtId,
        level: level,
        skillLevels: [for (var i = 0; i < 3; i++) read(_skills[i], ServantSetup.defaults(0).skillLevels[i])],
        appendLevels: appends,
        npLevel: read(_np, ServantSetup.defaults(0).npLevel),
        atkFou: read(_atk, ServantSetup.defaults(0).atkFou),
        hpFou: read(_hp, ServantSetup.defaults(0).hpFou),
      );
      Navigator.pop(context, setup);
    } on FormatException {
      setState(() => _error = 'Numbers only');
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
    }
  }

  Widget _field(String label, TextEditingController c) => SizedBox(
    width: 84,
    child: TextField(
      controller: c,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.name),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              children: [
                _field('Level', _level),
                _field('NP', _np),
                _field('Skill 1', _skills[0]),
                _field('Skill 2', _skills[1]),
                _field('Skill 3', _skills[2]),
                for (final (i, c) in _appends.indexed) _field('Append ${i + 1}', c),
                _field('ATK fou', _atk),
                _field('HP fou', _hp),
              ],
            ),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(S.current.cancel)),
        TextButton(onPressed: _save, child: Text(S.current.ok)),
      ],
    );
  }
}
