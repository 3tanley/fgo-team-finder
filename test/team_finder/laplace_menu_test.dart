import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/modules/battle/battle_home.dart';
import 'package:chaldea/generated/l10n.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  testWidgets('the Laplace menu has a Team Finder entry next to the simulator and NP damage entries', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          S.delegate,
          DefaultMaterialLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en')],
        home: BattleHomePage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('3T Simulator'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Team Finder'), findsOneWidget);
    // the page's random-image widget starts a delayed future (< 48 s) that cannot be cancelled: unmount, then let
    // fake time pass it (it returns at once because the widget is gone) so the test does not end with it pending
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
