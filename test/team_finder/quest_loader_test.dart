import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/quest_loader.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  final phases = db.gameData.questPhases.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  int waveCount(QuestPhase q) => q.stages.map((s) => s.wave).toSet().length;
  Iterable<QuestEnemy> enemies(QuestPhase q) => q.stages.expand((s) => s.enemies);
  bool hasEnemyScript(QuestPhase q, bool Function(EnemyScript) test) => enemies(q).any((e) => test(e.enemyScript));

  test('3-wave quest without gimmicks: waves and per-wave enemy HP match the source data', () {
    final q = phases.firstWhere(
      (q) =>
          waveCount(q) == 3 &&
          q.stages.every((s) => s.call.isEmpty) &&
          !hasEnemyScript(
            q,
            (s) =>
                s.shift?.isNotEmpty == true ||
                s.call?.isNotEmpty == true ||
                s.change?.isNotEmpty == true ||
                s.raid != null,
          ),
    );
    final spec = questSpecFromPhase(q);
    expect(spec.waves.length, 3);
    final waveNos = (q.stages.map((s) => s.wave).toSet().toList()..sort());
    for (var i = 0; i < 3; i++) {
      final expected = q.stages
          .where((s) => s.wave == waveNos[i])
          .expand((s) => s.enemies)
          .fold<int>(0, (a, e) => a + e.hp);
      expect(
        spec.waves[i].enemies.fold<int>(0, (a, e) => a + e.hp),
        expected,
        reason: 'wave ${i + 1} of quest ${q.id}',
      );
    }
    expect(spec.unsupportedGimmicks, isEmpty);
  });

  test('a single-wave quest gives one wave, not padded to 3', () {
    final q = phases.firstWhere((q) => waveCount(q) == 1);
    expect(questSpecFromPhase(q).waves.length, 1);
  });

  // The bundled dataset is a small subset with no shifts, calls or 4-wave quests (event quests come
  // from Atlas at runtime), so these tests add the mechanic to a JSON clone of a real 3-wave quest.
  final base = phases.firstWhere((q) => waveCount(q) == 3 && q.stages.every((s) => s.enemies.isNotEmpty));
  QuestPhase clone(void Function(Map<String, dynamic> json) edit) {
    final json = jsonDecode(jsonEncode(base.toJson())) as Map<String, dynamic>;
    edit(json);
    return QuestPhase.fromJson(json);
  }

  Map<String, dynamic> firstEnemy(Map<String, dynamic> json) => (json['stages'] as List).first['enemies'][0];

  test('a quest with more than 3 waves keeps all of them so the solver can reject it', () {
    final q = clone((json) {
      final stages = json['stages'] as List;
      stages.add({...jsonDecode(jsonEncode(stages.last)) as Map<String, dynamic>, 'wave': 4});
    });
    expect(waveCount(q), 4);
    expect(questSpecFromPhase(q).waves.length, 4);
  });

  test('enemy shift is reported as an unsupported gimmick', () {
    // Atlas returns the parsed script and the raw one; Chaldea builds the script from the raw one.
    final q = clone((json) {
      firstEnemy(json)['enemyScript'] = {
        'shift': [123],
      };
      firstEnemy(json)['originalEnemyScript'] = {
        'shift': [123],
      };
    });
    expect(questSpecFromPhase(q).unsupportedGimmicks, contains(kGimmickShift));
  });

  test('enemy call (summon) is reported as an unsupported gimmick', () {
    final q = clone((json) => (json['stages'] as List).first['call'] = [123]);
    expect(questSpecFromPhase(q).unsupportedGimmicks, contains(kGimmickCall));
  });

  test('the unmodified quest reports no gimmicks (the clone helper adds nothing by itself)', () {
    expect(questSpecFromPhase(clone((_) {})).unsupportedGimmicks, isEmpty);
  });

  test('loadQuest throws for an unknown quest instead of returning an empty quest', () {
    expect(loadQuest(Region.jp, 0, 1), throwsStateError);
  });
}
