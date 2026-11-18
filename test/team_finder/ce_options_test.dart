// Which craft essences the user can pick: Black Grail, or the quest's event CEs as the battle simulator pins them.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/ce_options.dart';
import 'package:chaldea/app/team_finder/defaults.dart';
import 'package:chaldea/app/team_finder/labels.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/app/team_finder/quest_loader.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  // node 94138610 belongs to "Pohjola's Christmas Eve" (event 80506): one reward CE and three limited CEs
  final eventQuest = questSpecFromPhase(
    QuestPhase.fromJson(jsonDecode(File('test/team_finder/fixtures/quest_94138610_jp.json').readAsStringSync())),
  );
  final plainQuest = questSpecFromPhase(db.gameData.questPhases[9300040603]!); // a free quest, no event

  Set<int> ids(CeKind kind, QuestSpec? q) => ceChoices(kind, q).map((e) => e.id).toSet();

  test('Black Grail is always the one choice, whatever the quest', () {
    expect(ids(CeKind.blackGrail, null), {kBlackGrailCeId});
    expect(ids(CeKind.blackGrail, eventQuest), {kBlackGrailCeId});
  });

  test('event with only drop CEs: the reward CE December 23rd is a drop CE too, and no damage CE exists', () {
    expect(ids(CeKind.eventDamage, eventQuest), isEmpty);
    expect(ids(CeKind.eventDrop, eventQuest), {9408210, 9408180, 9408190, 9408200});
  });

  test('a CE is a drop CE by what its skills do: the reward CE December 23rd is one, an attack-boost CE is not', () {
    expect(raisesDrops(db.gameData.craftEssencesById[9408210]!), isTrue); // December 23rd
    expect(raisesDrops(db.gameData.craftEssencesById[9408180]!), isTrue); // Lamp in Hand
    expect(raisesDrops(db.gameData.craftEssencesById[9405600]!), isFalse); // Dancing Like a Flower: event attack boost
    expect(raisesDrops(db.gameData.craftEssencesById[kBlackGrailCeId]!), isFalse);
  });

  test('no quest, or a quest outside an event, has no event CEs', () {
    for (final kind in [CeKind.eventDamage, CeKind.eventDrop]) {
      expect(ceChoices(kind, null), isEmpty);
      expect(ceChoices(kind, plainQuest), isEmpty);
    }
  });

  test('event choices are newest first, like the simulator list', () {
    final list = ceChoices(CeKind.eventDrop, eventQuest).map((e) => e.collectionNo).toList();
    expect(list, [...list]..sort((a, b) => b.compareTo(a)));
  });

  test('labels: the CE name, and its level, limit break and quantity', () {
    expect(ceLabel(kBlackGrailCeId), 'The Black Grail');
    expect(ceLine(CeSetup(kBlackGrailCeId)), 'Lv100 · limit broken');
    expect(ceLine(CeSetup(9408210, level: 80, limitBreak: false, quantity: 2)), 'Lv80 · not limit broken · ×2');
  });
}
