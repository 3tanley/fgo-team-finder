import 'package:chaldea/app/api/atlas.dart';
import 'package:chaldea/models/models.dart';

import 'models.dart';

// Mechanics that change the fight mid-battle; a "viable" verdict through them is "unverified".
// shortcut: only these four script flags are detected; add more as real quests show new ones.
const String kGimmickShift = 'enemy shift (changes form)';
const String kGimmickCall = 'enemy call (summons reinforcements)';
const String kGimmickChange = 'enemy change';
const String kGimmickRaid = 'raid';

QuestSpec questSpecFromPhase(QuestPhase q) {
  final byWave = <int, List<QuestEnemy>>{};
  final gimmicks = <String>{};
  for (final stage in q.stages) {
    byWave.putIfAbsent(stage.wave, () => []).addAll(stage.enemies);
    if (stage.call.isNotEmpty) gimmicks.add(kGimmickCall);
    for (final script in stage.enemies.map((e) => e.enemyScript)) {
      if (script.shift?.isNotEmpty == true) gimmicks.add(kGimmickShift);
      if (script.call?.isNotEmpty == true) gimmicks.add(kGimmickCall);
      if (script.change?.isNotEmpty == true) gimmicks.add(kGimmickChange);
      if (script.raid != null) gimmicks.add(kGimmickRaid);
    }
  }
  final waveNos = byWave.keys.toList()..sort();
  return QuestSpec(
    questId: q.id,
    waves: [
      for (final w in waveNos)
        WaveSpec([
          for (final e in byWave[w]!)
            EnemySpec(hp: e.hp, classId: e.svt.classId, attribute: e.svt.attribute.name, traits: e.traits),
        ]),
    ],
    unsupportedGimmicks: gimmicks.toList()..sort(),
    phase: q,
  );
}

/// JP reads the bundled game data; other regions ask Atlas Academy (needs network).
/// Throws [StateError] if the quest phase does not exist.
Future<QuestSpec> loadQuest(Region region, int questId, int phase) async {
  final local = region == Region.jp ? db.gameData.questPhases[questId * 100 + phase] : null;
  final q = local ?? await AtlasApi.questPhase(questId, phase, region: region);
  if (q == null) throw StateError('quest $questId phase $phase not found for $region');
  return questSpecFromPhase(q);
}
