import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Store manifest pins Partner Center identity and least capability', () {
    final manifest = File(
      'windows/packaging/AppxManifest.xml.in',
    ).readAsStringSync();

    expect(manifest, contains('Name="George-CosminHanta.IPTVSPlayer"'));
    expect(
      manifest,
      contains('Publisher="CN=7DA809EF-3303-40F1-B760-21A6BCA24B17"'),
    );
    expect(manifest, contains('Version="@PACKAGE_VERSION@"'));
    expect(manifest, contains('ProcessorArchitecture="x64"'));
    expect(manifest, contains('Executable="iptvs.exe"'));
    expect(manifest, contains('EntryPoint="Windows.FullTrustApplication"'));
    expect(manifest, contains('<rescap:Capability Name="runFullTrust" />'));
    expect(
      RegExp(r'<(?:\w+:)?Capability\b').allMatches(manifest),
      hasLength(1),
    );
  });

  test('publishing record pins all Partner Center identifiers', () {
    final publishing = File('docs/store-publishing.md').readAsStringSync();

    expect(
      publishing,
      contains('George-CosminHanta.IPTVSPlayer_0a4z5zccam0py'),
    );
    expect(
      publishing,
      contains(
        'S-1-15-2-2604606762-3968970359-1786003176-2720169948-'
        '3773242850-1324970824-1308558992',
      ),
    );
    expect(publishing, contains('9P8KK9T379WN'));
    expect(
      RegExp(
        r'\| (Store deep link|Web Store URL) \| '
        r'Available after the product is live \|',
      ).allMatches(publishing),
      hasLength(2),
    );
  });

  test('Store workflow is isolated from direct release artifacts', () {
    final storeWorkflow = File(
      '.github/workflows/microsoft-store.yml',
    ).readAsStringSync();
    final directWorkflow = File(
      '.github/workflows/release.yml',
    ).readAsStringSync();

    expect(storeWorkflow, contains('DISTRIBUTION_CHANNEL=microsoftStore'));
    expect(storeWorkflow, isNot(contains('UPDATE_MANIFEST_PUBLIC_KEY')));
    expect(storeWorkflow, contains('package_windows_msix.ps1'));
    expect(storeWorkflow, contains('windows-store-x64.msix'));

    expect(directWorkflow, contains('DISTRIBUTION_CHANNEL=githubDirect'));
    expect(directWorkflow, isNot(contains('package_windows_msix.ps1')));
    expect(directWorkflow, isNot(contains('windows-store-x64.msix')));
  });

  test('packager reserves the fourth MSIX version component for Store', () {
    final packager = File('tool/package_windows_msix.ps1').readAsStringSync();

    expect(packager, contains(r'$PackageVersion = "$Version.0"'));
    expect(packager, contains("Version must contain exactly three numeric"));
    expect(packager, contains('non-zero major component'));
    expect(
      packager,
      contains(r"'^([1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'"),
    );
    expect(packager, contains(r'$_ -gt 65535'));
  });
}
