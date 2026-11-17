import 'package:chaldea/app/team_finder/models.dart';
import 'package:chaldea/models/models.dart';

/// Display name of a servant. Servants that share a name (the two Ibuki-Douji) get their class added.
String servantLabel(int svtId) {
  final svt = db.gameData.servantsById[svtId];
  if (svt == null) return '#$svtId';
  final name = svt.lName.l;
  final shared = db.gameData.servantsNoDup.values.where((s) => s.lName.l == name).length > 1;
  if (!shared) return name;
  final cls = svt.className.name;
  return '$name (${cls[0].toUpperCase()}${cls.substring(1)})';
}

/// Turns the engine's slot-number log (`T1 skill 0.3 -> 2`) into one that names the servants.
/// Slot numbers follow the team order; after a mystic-code swap the slot holds the servant that came in.
List<String> describeLog(List<String> log, TeamSpec team) {
  final slots = [for (final s in team.slots) servantLabel(s.servant.svtId)];
  String name(String i) => slots.elementAtOrNull(int.parse(i)) ?? 'slot $i';
  final out = <String>[];
  for (final line in log) {
    final swap = RegExp(r'^(T\d+) swap (\d+) <-> (\d+)$').firstMatch(line);
    final skill = RegExp(r'^(T\d+) skill (\d+)\.(\d+) -> (\d+)$').firstMatch(line);
    final np = RegExp(r'^(T\d+) np (\d+)$').firstMatch(line);
    final mc = RegExp(r'^(T\d+) mc (\d+)$').firstMatch(line);
    if (swap != null) {
      out.add('${swap[1]} mystic code swap: ${name(swap[2]!)} out, ${name(swap[3]!)} in');
      final a = int.parse(swap[2]!), b = int.parse(swap[3]!);
      if (a < slots.length && b < slots.length) {
        final t = slots[a];
        slots[a] = slots[b];
        slots[b] = t;
      }
    } else if (skill != null) {
      out.add('${skill[1]} ${name(skill[2]!)} skill ${skill[3]} → ${name(skill[4]!)}');
    } else if (np != null) {
      out.add('${np[1]} NP: ${name(np[2]!)}');
    } else if (mc != null) {
      out.add('${mc[1]} mystic code skill ${mc[2]}');
    } else {
      out.add(line);
    }
  }
  return out;
}

/// Display name of a craft essence.
String ceLabel(int ceId) => db.gameData.craftEssencesById[ceId]?.lName.l ?? '#$ceId';

/// `Lv100 · limit broken` and, for more than one copy, `· ×2`.
String ceLine(CeSetup ce) =>
    'Lv${ce.level} · ${ce.limitBreak ? 'limit broken' : 'not limit broken'}${ce.quantity > 1 ? ' · ×${ce.quantity}' : ''}';
