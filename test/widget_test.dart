import 'package:flutter_test/flutter_test.dart';
import 'package:splice/main.dart';
import 'package:splice/src/core/save.dart';

void main() {
  testWidgets('app boots to the title screen', (tester) async {
    await tester.pumpWidget(SpliceApp(save: SaveData()));
    await tester.pump();
    expect(find.text('SPLICE'), findsOneWidget);
    expect(find.text('BEGIN'), findsOneWidget);
  });
}
