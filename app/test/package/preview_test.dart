// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:pub_dev/tool/test_profile/import_source.dart';
import 'package:pub_dev/tool/utils/dart_sdk_version.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import 'package:pub_dev/package/backend.dart';
import 'package:pub_dev/tool/test_profile/models.dart';

import '../shared/test_models.dart';
import '../shared/test_services.dart';

Future<void> main() async {
  final current = await getDartSdkVersion();
  final currentSdkVersion = current.semanticVersion;
  final futureSdkVersion = currentSdkVersion.nextMinor.nextMinor;
  final importSource = _ImportSource(currentSdkVersion, futureSdkVersion);

  group('SDK version changing', () {
    test('verify versions', () {
      expect(currentSdkVersion.major, isNotNull);
      expect(futureSdkVersion.major, currentSdkVersion.major);
    });

    testWithProfile(
      'preview becomes stable',
      testProfile: TestProfile(
        defaultUser: adminUser.email,
        packages: [
          TestPackage(name: 'pkg', versions: ['1.0.0', '1.2.0']),
        ],
      ),
      importSource: importSource,
      fn: () async {
        final pv1 = await packageBackend.lookupPackageVersion('pkg', '1.0.0');
        expect(pv1.pubspec.isPreviewForCurrentSdk(currentSdkVersion), isFalse);
        expect(pv1.pubspec.isPreviewForCurrentSdk(futureSdkVersion), isFalse);

        final pv2 = await packageBackend.lookupPackageVersion('pkg', '1.2.0');
        expect(pv2.pubspec.isPreviewForCurrentSdk(currentSdkVersion), isTrue);
        expect(pv2.pubspec.isPreviewForCurrentSdk(futureSdkVersion), isFalse);

        final p0 = await packageBackend.lookupPackage('pkg');
        expect(p0.latestVersion, '1.0.0');
        expect(p0.latestPrereleaseVersion, '1.2.0');
        expect(p0.latestPreviewVersion, '1.2.0');
        expect(p0.showPrereleaseVersion, isFalse);
        expect(p0.showPreviewVersion, isTrue);

        final u1 = await packageBackend.updateAllPackageVersions(
            dartSdkVersion: currentSdkVersion);
        expect(u1, 0);

        // check that nothing did change
        final p1 = await packageBackend.lookupPackage('pkg');
        expect(p1.latestVersion, '1.0.0');
        expect(p1.latestPrereleaseVersion, '1.2.0');
        expect(p1.latestPreviewVersion, '1.2.0');
        expect(p1.showPrereleaseVersion, isFalse);
        expect(p1.showPreviewVersion, isTrue);

        final u2 = await packageBackend.updateAllPackageVersions(
            dartSdkVersion: futureSdkVersion);
        expect(u2, 1);

        // check changes
        final p2 = await packageBackend.lookupPackage('pkg');
        expect(p2.latestVersion, '1.2.0');
        expect(p2.latestPrereleaseVersion, '1.2.0');
        expect(p2.latestPreviewVersion, '1.2.0');
        expect(p2.showPrereleaseVersion, isFalse);
        expect(p2.showPreviewVersion, isFalse);
      },
    );
  });
}

class _ImportSource implements ImportSource {
  final Version _currentSdkVersion;
  final Version _futureSdkVersion;
  final _defaultSource = ImportSource.autoGenerated();

  _ImportSource(this._currentSdkVersion, this._futureSdkVersion);

  @override
  Future<List<ResolvedVersion>> resolveVersions(TestProfile profile) async {
    return await _defaultSource.resolveVersions(profile);
  }

  @override
  Future<List<int>> getArchiveBytes(String package, String version) async {
    final archive = ArchiveBuilder();

    final minSdk = version == '1.2.0' ? _futureSdkVersion : _currentSdkVersion;
    final pubspec = json.encode({
      'name': package,
      'version': version,
      'environment': {
        'sdk': '>=$minSdk <3.0.0',
      },
    });

    archive.addFile('pubspec.yaml', pubspec);
    archive.addFile('README.md', '# $package\n\nAwesome package.');
    archive.addFile('CHANGELOG.md', '## $version\n\n- updated');
    archive.addFile('lib/$package.dart', 'main() {\n  print(\'Hello.\');\n}\n');
    archive.addFile(
        'example/example.dart', 'main() {\n  print(\'example\');\n}\n');
    archive.addFile('LICENSE', 'All rights reserved.');

    return archive.toTarGzBytes();
  }

  @override
  Future<void> close() async {
    await _defaultSource.close();
  }
}
