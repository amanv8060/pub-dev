// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:json_annotation/json_annotation.dart';

import '../shared/datastore.dart' as db;
import '../shared/utils.dart' show jsonUtf8Encoder, utf8JsonDecoder;
import 'storage_path.dart' as storage_path;

part 'models.g.dart';

/// Status values for [DartdocRun].
abstract class DartdocRunStatus {
  static const uploading = 'uploading';
  static const ready = 'ready';
  static const deleting = 'deleting';
}

@db.Kind(name: 'DartdocRun', idType: db.IdType.String)
class DartdocRun extends db.ExpandoModel<String> {
  /// Unique identifier that identifies a specific execution of dartdoc.
  String? get runId => id;

  @db.DateTimeProperty(required: true)
  DateTime? created;

  /// Indicates the status of the run, e.g. if the content is still uploading.
  /// Values are described in [DartdocRunStatus].
  @db.StringProperty(required: true, indexed: true)
  String? status;

  @db.StringProperty(required: true, indexed: true)
  String? package;

  @db.StringProperty(required: true, indexed: false)
  String? version;

  /// The package and version encoded as `<package>/<version>`.
  @db.StringProperty(required: true, indexed: true)
  String? packageVersion;

  @db.StringProperty(required: true, indexed: true)
  String? runtimeVersion;

  /// The package, version and runtime encoded as
  /// `<package>/<version>/<runtimeVersion>`.
  @db.StringProperty(required: true, indexed: true)
  String? packageVersionRuntime;

  /// Indicates whether at the time of running dartdoc the version was
  /// considered the latest stable version of the package.
  @db.BoolProperty(required: true, indexed: false)
  bool? wasLatestStable;

  /// The time spent generating the content (in seconds).
  @db.IntProperty(required: true, indexed: false)
  int? runDurationInSeconds;

  /// Indicates whether the run has a valid content and can be served.
  /// The content directory may contain the log.txt file even if there was an
  /// error while running dartdoc.
  @db.BoolProperty(required: true, indexed: false)
  bool? hasValidContent;

  /// Contains user-friendly message describing the reason if there is
  /// no content. (E.g. may be too old, dartdoc failed)
  @db.StringProperty(indexed: false)
  String? errorMessage;

  /// The size of the archive file.
  @db.IntProperty(required: true, indexed: false)
  int? archiveSize;

  /// The directory path inside the storage bucket where the content lives.
  @db.StringProperty(required: true, indexed: false)
  String? contentPath;

  /// The total size of the generated content.
  @db.IntProperty(required: true, indexed: false)
  int? contentSize;

  /// [DartdocEntry] encoded as JSON string.
  @db.StringProperty(required: true, indexed: false)
  String? entryJson;

  /// Indicates whether the content has been expired and replaced by a newer
  /// [DartdocRun] in the current runtime.
  @db.BoolProperty(required: true, indexed: true)
  bool? isExpired;

  DartdocRun();

  DartdocRun.fromEntry(
    DartdocEntry entry, {
    required this.status,
  }) {
    id = entry.uuid;
    created = entry.timestamp;
    package = entry.packageName;
    version = entry.packageVersion;
    packageVersion = '$package/$version';
    runtimeVersion = entry.runtimeVersion;
    packageVersionRuntime = '$package/$version/$runtimeVersion';
    wasLatestStable = entry.isLatest;
    hasValidContent = entry.hasContent;
    runDurationInSeconds = entry.runDuration?.inSeconds ?? 0;
    if (!hasValidContent! && entry.isObsolete!) {
      errorMessage = 'Version was too old.';
    } else if (!hasValidContent! && !entry.depsResolved!) {
      errorMessage = "Couldn't resolve dependencies.";
    }
    archiveSize = entry.archiveSize ?? 0;
    contentPath = entry.contentPrefix;
    contentSize = entry.totalSize ?? 0;
    entryJson = json.encode(entry.toJson());
    isExpired = false;
  }

  DartdocEntry? get entry => entryJson == null
      ? null
      : DartdocEntry.fromJson(json.decode(entryJson!) as Map<String, dynamic>);
}

/// Describes the details of a dartdoc-generated content.
@JsonSerializable()
class DartdocEntry {
  /// Random uuid for lookup in storage bucket, see [storage_path].
  final String uuid;
  final String packageName;
  final String packageVersion;

  /// Whether the [packageVersion] is the latest stable version of the package
  /// (at the time of the entry being created, but may be updated later).
  final bool isLatest;

  /// Whether the package version is too old. This is never set if the version
  /// is the latest stable version of the package..
  final bool? isObsolete;

  /// Whether the package version uses Flutter.
  final bool? usesFlutter;

  /// The pub site runtime version of the runtime that generated the content.
  final String runtimeVersion;

  /// The SDK version that was used to fetch dependencies.
  final String? sdkVersion;

  /// The version of `package:dartdoc` that generated the content.
  final String? dartdocVersion;

  /// The version of Flutter that was used to fetch dependencies.
  final String? flutterVersion;

  /// When the content was generated.
  final DateTime? timestamp;

  /// The time spent generating the content.
  final Duration? runDuration;

  /// Whether the dependencies were resolved successfully.
  final bool? depsResolved;

  /// Whether the dartdoc process produced valid content.
  final bool hasContent;

  /// The size of the compressed archive file.
  final int? archiveSize;

  /// The size of all the individual files, uncompressed.
  final int? totalSize;

  /// The size of the compressed blob file.
  /// If this is null or zero, the blob file is missing.
  final int? blobSize;

  /// The size of the compressed blob index file.
  /// If this is null or zero, the blob file is missing.
  final int? blobIndexSize;

  DartdocEntry({
    required this.uuid,
    required this.packageName,
    required this.packageVersion,
    this.isLatest = false,
    required this.isObsolete,
    required this.usesFlutter,
    required this.runtimeVersion,
    required this.sdkVersion,
    required this.dartdocVersion,
    required this.flutterVersion,
    required this.timestamp,
    required this.runDuration,
    required this.depsResolved,
    this.hasContent = false,
    required this.archiveSize,
    required this.totalSize,
    this.blobSize,
    this.blobIndexSize,
  });

  factory DartdocEntry.fromJson(Map<String, dynamic> json) =>
      _$DartdocEntryFromJson(json);

  factory DartdocEntry.fromBytes(List<int> bytes) => DartdocEntry.fromJson(
      utf8JsonDecoder.convert(bytes) as Map<String, dynamic>);

  static Future<DartdocEntry> fromStream(Stream<List<int>> stream) async {
    final bytes =
        await stream.fold<List<int>>([], (sum, list) => sum..addAll(list));
    return DartdocEntry.fromBytes(bytes);
  }

  /// Creates a new instance, copying fields that are not specified, overriding
  /// the ones that are.
  DartdocEntry replace({bool? isLatest}) {
    return DartdocEntry(
      uuid: uuid,
      packageName: packageName,
      packageVersion: packageVersion,
      isLatest: isLatest ?? this.isLatest,
      isObsolete: isObsolete,
      usesFlutter: usesFlutter,
      runtimeVersion: runtimeVersion,
      sdkVersion: sdkVersion,
      dartdocVersion: dartdocVersion,
      flutterVersion: flutterVersion,
      timestamp: timestamp,
      runDuration: runDuration,
      depsResolved: depsResolved,
      hasContent: hasContent,
      archiveSize: archiveSize,
      totalSize: totalSize,
      blobSize: blobSize,
      blobIndexSize: blobIndexSize,
    );
  }

  Map<String, dynamic> toJson() => _$DartdocEntryToJson(this);

  /// The path prefix where the content of this instance is stored.
  String get contentPrefix =>
      storage_path.contentPrefix(packageName, packageVersion, uuid);

  String objectName(String relativePath) {
    final isShared = !hasBlob && storage_path.isSharedAsset(relativePath);
    if (isShared) {
      return storage_path.sharedAssetObjectName(dartdocVersion!, relativePath);
    } else {
      return storage_path.contentObjectName(
          packageName, packageVersion, uuid, relativePath);
    }
  }

  bool get hasBlob =>
      blobSize != null &&
      blobSize! > 0 &&
      blobIndexSize != null &&
      blobIndexSize! > 0;

  List<int> asBytes() => jsonUtf8Encoder.convert(toJson());

  bool isRegression(DartdocEntry? oldEntry) {
    if (oldEntry == null) {
      // Old entry does not exists, new entry wins.
      return false;
    }
    if (oldEntry.runtimeVersion != runtimeVersion) {
      // Different versions - not considered as a regression.
      return false;
    }
    if (!oldEntry.hasContent) {
      // The old entry had no content, the new should be better.
      return false;
    }
    if (hasContent) {
      // Having new content wins.
      return false;
    }
    // Older entry seems to be better.
    return true;
  }

  /// The current age of the entry.
  Duration get age {
    return clock.now().toUtc().difference(timestamp!);
  }
}

@JsonSerializable()
class FileInfo {
  final DateTime lastModified;
  final String etag;
  final String? blobId;
  final int? blobOffset;
  final int? blobLength;
  final int? contentLength;

  FileInfo({
    required this.lastModified,
    required this.etag,
    this.blobId,
    this.blobOffset,
    this.blobLength,
    this.contentLength,
  });

  factory FileInfo.fromJson(Map<String, dynamic> json) =>
      _$FileInfoFromJson(json);

  factory FileInfo.fromBytes(List<int> bytes) =>
      FileInfo.fromJson(utf8JsonDecoder.convert(bytes) as Map<String, dynamic>);

  List<int> asBytes() => jsonUtf8Encoder.convert(toJson());

  Map<String, dynamic> toJson() => _$FileInfoToJson(this);
}
