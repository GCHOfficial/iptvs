import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/profile_pick_screen.dart';

void main() {
  test('profile hint follows the platform navigation mode', () {
    expect(
      profileSelectionHint(NavigationMode.directional),
      'Use D-pad to choose a profile',
    );
    expect(
      profileSelectionHint(NavigationMode.traditional),
      'Choose a profile to continue',
    );
  });
}
