// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:_discoveryapis_commons/_discoveryapis_commons.dart'
    show DetailedApiRequestError;
import 'package:clock/clock.dart';
import 'package:gcloud/storage.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:pool/pool.dart';
import 'package:retry/retry.dart';

import 'utils.dart' show contentType, jsonUtf8Encoder, retryAsync, DeleteCounts;
import 'versions.dart' as versions;

final _gzip = GZipCodec();
final _logger = Logger('shared.storage');

const _retryStatusCodes = <int>{502, 503, 504};

/// Additional methods on buckets.
extension BucketExt on Bucket {
  /// Returns an [ObjectInfo] if [name] exists, `null` otherwise.
  Future<ObjectInfo?> tryInfo(String name) async {
    try {
      return await info(name);
    } on DetailedApiRequestError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future uploadPublic(String objectName, int length,
      Stream<List<int>> Function() openStream, String contentType) {
    final publicRead = AclEntry(AllUsersScope(), AclPermission.READ);
    final acl = Acl([publicRead]);
    final metadata = ObjectMetadata(acl: acl, contentType: contentType);
    return uploadWithRetry(this, objectName, length, openStream,
        metadata: metadata);
  }

  /// Reads file content as bytes.
  Future<Uint8List> readAsBytes(
    String objectName, {
    int? offset,
    int? length,
  }) async {
    return retry(
      () async {
        final builder = BytesBuilder(copy: false);
        await for (final chunk
            in read(objectName, offset: offset, length: length)) {
          builder.add(chunk);
        }
        return builder.toBytes();
      },
      retryIf: (e) {
        return e is DetailedApiRequestError &&
            e.status != null &&
            e.status! >= 500;
      },
    );
  }
}

/// Returns a valid `gs://` URI for a given [bucket] + [path] combination.
String bucketUri(Bucket bucket, String path) =>
    'gs://${bucket.bucketName}/$path';

Future<Bucket> getOrCreateBucket(Storage storage, String name) async {
  if (!await storage.bucketExists(name)) {
    await storage.createBucket(name);
  }
  return storage.bucket(name);
}

/// Deletes a single object from the [bucket].
///
/// Returns `true` if the object was deleted by this operation, `false` if it
/// didn't exist at the time of the operation.
Future<bool> deleteFromBucket(Bucket bucket, String objectName) async {
  Future<bool> delete() async {
    try {
      await bucket.delete(objectName);
      return true;
    } on DetailedApiRequestError catch (e) {
      if (e.status != 404) {
        rethrow;
      }
      return false;
    }
  }

  return await retry(
    delete,
    delayFactor: Duration(seconds: 10),
    maxAttempts: 3,
    retryIf: (e) =>
        e is DetailedApiRequestError && _retryStatusCodes.contains(e.status),
  );
}

/// Deletes a [folder] in a [bucket], recursively listing all of its subfolders.
///
/// Returns the number of objects deleted.
Future<int> deleteBucketFolderRecursively(
  Bucket bucket,
  String folder, {
  int? concurrency,
}) async {
  if (!folder.endsWith('/')) {
    throw ArgumentError('Folder path must end with `/`: "$folder"');
  }
  var count = 0;
  Page<BucketEntry>? page;
  while (page == null || !page.isLast) {
    page = await retry(
      () async {
        return page == null
            ? await bucket.page(prefix: folder, delimiter: '', pageSize: 100)
            : await page.next(pageSize: 100);
      },
      delayFactor: Duration(seconds: 10),
      maxAttempts: 3,
      retryIf: (e) =>
          e is DetailedApiRequestError && _retryStatusCodes.contains(e.status),
    );
    final futures = <Future>[];
    final pool = Pool(concurrency ?? 1);
    for (final entry in page!.items) {
      final f = pool.withResource(() async {
        final deleted = await deleteFromBucket(bucket, entry.name);
        if (deleted) count++;
      });
      futures.add(f);
    }
    await Future.wait(futures);
    await pool.close();
  }
  return count;
}

/// Uploads content from [openStream] to the [bucket] as [objectName].
Future uploadWithRetry(Bucket bucket, String objectName, int length,
    Stream<List<int>> Function() openStream,
    {ObjectMetadata? metadata}) async {
  await retryAsync(
    () async {
      final sink = bucket.write(objectName,
          length: length,
          contentType: metadata?.contentType ?? contentType(objectName),
          metadata: metadata);
      await sink.addStream(openStream());
      await sink.close();
    },
    description: 'Upload to $objectName',
    shouldRetryOnError: (e) {
      if (e is DetailedApiRequestError) {
        return _retryStatusCodes.contains(e.status);
      }
      return false;
    },
    sleep: Duration(seconds: 10),
  );
}

/// Uploads content from [bytes] to the [bucket] as [objectName].
Future uploadBytesWithRetry(
        Bucket bucket, String objectName, List<int> bytes) =>
    uploadWithRetry(
        bucket, objectName, bytes.length, () => Stream.fromIterable([bytes]));

/// Utility class to access versioned JSON data that follows the name pattern:
/// "/path-prefix/runtime-version.json.gz".
class VersionedJsonStorage {
  final Bucket _bucket;
  final String _prefix;
  final String _extension = '.json.gz';
  Timer? _oldGcTimer;

  VersionedJsonStorage(Bucket bucket, String prefix)
      : _bucket = bucket,
        _prefix = prefix {
    if (!_prefix.endsWith('/')) {
      throw ArgumentError('Directory prefix must end with `/`.');
    }
  }

  /// Whether the storage bucket has a data file for the current runtime version.
  Future<bool> hasCurrentData({Duration? maxAge}) async {
    final info = await _bucket.tryInfo(_objectName());
    if (info == null) {
      return false;
    }
    final now = clock.now();
    if (maxAge != null && now.difference(info.updated) > maxAge) {
      return false;
    }
    return true;
  }

  /// Upload the current data to the storage bucket.
  Future<void> uploadDataAsJsonMap(Map<String, dynamic> map) async {
    final objectName = _objectName();
    final bytes = _gzip.encode(jsonUtf8Encoder.convert(map));
    try {
      await uploadBytesWithRetry(_bucket, objectName, bytes);
    } catch (e, st) {
      _logger.warning('Unable to upload data file: $objectName', e, st);
    }
  }

  /// Gets the content of the data file decoded as JSON Map.
  Future<Map<String, dynamic>> getContentAsJsonMap([String? version]) async {
    version ??= versions.runtimeVersion;
    final objectName = _objectName(version);
    _logger.info('Loading snapshot: $objectName');
    final map = await _bucket
        .read(objectName)
        .transform(_gzip.decoder)
        .transform(utf8.decoder)
        .transform(json.decoder)
        .single;
    return map as Map<String, dynamic>;
  }

  /// Returns the latest version of the data file matching the current version
  /// or created earlier.
  Future<String?> detectLatestVersion() async {
    final currentPath = _objectName();
    final list = await _bucket
        .list(prefix: _prefix)
        .map((entry) => entry.name)
        .where((name) => name.endsWith(_extension))
        .where((name) => name.compareTo(currentPath) <= 0)
        .map((name) =>
            name.substring(_prefix.length, name.length - _extension.length))
        .where((version) => versions.runtimeVersionPattern.hasMatch(version))
        .toList();
    if (list.isEmpty) {
      return null;
    }
    if (list.length == 1) {
      return list.single;
    }
    return list.fold<String>(list.first, (a, b) => a.compareTo(b) < 0 ? b : a);
  }

  /// Deletes the old entries that predate [versions.gcBeforeRuntimeVersion].
  ///
  /// When [minAgeThreshold] is specified, only older files will be deleted. The
  /// process assumes that if an old runtimeVersion is still active, it will
  /// update it periodically, and a cleanup should preserve such files.
  Future<DeleteCounts> deleteOldData({Duration? minAgeThreshold}) async {
    var found = 0;
    var deleted = 0;
    await for (BucketEntry entry in _bucket.list(prefix: _prefix)) {
      if (entry.isDirectory) {
        continue;
      }
      final name = p.basename(entry.name);
      if (!name.endsWith(_extension)) {
        continue;
      }
      final version = name.substring(0, name.length - _extension.length);
      final matchesPattern = version.length == 10 &&
          versions.runtimeVersionPattern.hasMatch(version);
      if (!matchesPattern) {
        continue;
      }
      found++;
      if (versions.shouldGCVersion(version)) {
        final info = await _bucket.info(entry.name);
        final age = clock.now().difference(info.updated);
        if (minAgeThreshold == null || age > minAgeThreshold) {
          deleted++;
          await deleteFromBucket(_bucket, entry.name);
        }
      }
    }
    return DeleteCounts(found, deleted);
  }

  String getBucketUri([String? version]) =>
      bucketUri(_bucket, _objectName(version ?? versions.runtimeVersion));

  String _objectName([String? version]) {
    version ??= versions.runtimeVersion;
    return '$_prefix$version$_extension';
  }

  void close() {
    _oldGcTimer?.cancel();
    _oldGcTimer = null;
  }
}
