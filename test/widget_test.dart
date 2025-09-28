// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:japanodict/main.dart';

void main() {
  testWidgets('JapanoDict app smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const JapanoDictApp());

    // Verify that the app title is displayed.
    expect(find.text('JapanoDict'), findsOneWidget);
    
    // Verify that the welcome message is displayed.
    expect(find.textContaining('Welcome to JapanoDict'), findsOneWidget);
    
    // Verify that the search field is present.
    expect(find.byType(TextField), findsOneWidget);
  });
}
