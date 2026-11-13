import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/team_finder/labels.dart';
import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  const saberIbuki = 104600, berserkerIbuki = 704300, castoria = 504500, altria = 100100;

  test('two servants that share a name get their class added, unique names stay plain', () {
    final a = servantLabel(saberIbuki), b = servantLabel(berserkerIbuki);
    expect(a, isNot(b));
    expect(a, contains('Saber'));
    expect(b, contains('Berserker'));
    // Altria Caster has a Berserker twin too (704700), so she is told apart as well
    expect(servantLabel(castoria), isNot(servantLabel(704700)));
    expect(servantLabel(db.gameData.servantsNoDup[316]!.id), isNot(contains('('))); // Oberon is unique
  });

  group('describeLog', () {
    final team = TeamSpec([
      SlotSpec(ServantSetup.defaults(castoria)),
      SlotSpec(ServantSetup.defaults(berserkerIbuki)),
      SlotSpec(ServantSetup.defaults(castoria)),
      SlotSpec(ServantSetup.defaults(altria)),
    ]);
    final names = [for (final s in team.slots) servantLabel(s.servant.svtId)];

    test('skills, NPs and mystic code lines read as words', () {
      final out = describeLog(['T1 skill 0.3 -> 1', 'T1 np 1', 'T3 mc 1'], team);
      expect(out[0], 'T1 ${names[0]} skill 3 → ${names[1]}');
      expect(out[1], 'T1 NP: ${names[1]}');
      expect(out[2], 'T3 mystic code skill 1');
    });

    test('after a swap, the slot that went out is the servant that came in', () {
      final out = describeLog(['T3 swap 2 <-> 3', 'T3 skill 2.1 -> 1'], team);
      expect(out[0], 'T3 mystic code swap: ${names[2]} out, ${names[3]} in');
      expect(out[1], 'T3 ${names[3]} skill 1 → ${names[1]}');
    });

    test('lines it does not know are kept as they are', () {
      expect(describeLog(['T1 attacker NP 100% on wave 1', 'weird'], team), ['T1 attacker NP 100% on wave 1', 'weird']);
    });
  });
}
