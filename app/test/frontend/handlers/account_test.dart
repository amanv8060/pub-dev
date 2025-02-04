// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:pub_dev/frontend/static_files.dart';
import 'package:test/test.dart';

import '../../shared/test_models.dart';
import '../../shared/test_services.dart';
import '_utils.dart';

void main() {
  group('bad authorization header', () {
    testWithProfile('bad format', fn: () async {
      await expectHtmlResponse(
        await issueGet(
          '/packages/oxygen',
          headers: {'authorization': 'bad value'},
        ),
        status: 401,
        present: ['Authentication failed.'],
        absent: ['/packages/oxygen'],
      );
    });
  });

  group('account handlers tests', () {
    // TODO: add test for /consent page
    // TODO: add test for GET /api/account/consent/<consentId> API calls
    // TODO: add test for PUT /api/account/consent/<consentId> API calls

    testWithProfile('/my-packages', fn: () async {
      final cookie = await acquireSessionCookie(adminAtPubDevAuthToken);
      await expectHtmlResponse(
        await issueGet(
          '/my-packages',
          headers: {'cookie': cookie},
        ),
        present: ['/packages/flutter_titanium'],
      );
    });

    testWithProfile('/my-packages?next=o', fn: () async {
      final cookie = await acquireSessionCookie(adminAtPubDevAuthToken);
      await expectHtmlResponse(
        await issueGet(
          '/my-packages?next=o',
          headers: {'cookie': cookie},
        ),
        present: ['/packages/oxygen'],
        absent: ['/packages/flutter_titanium'],
      );
    });
  });

  group('pub client authorization landing page', () {
    setUpAll(() => updateLocalBuiltFilesIfNeeded());

    testWithProfile('/authorized', fn: () async {
      await expectHtmlResponse(await issueGet('/authorized'));
    });
  });
}
