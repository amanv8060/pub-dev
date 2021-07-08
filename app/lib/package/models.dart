// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub_dartlang_org.appengine_repository.models;

import 'dart:convert';
import 'dart:math';

import 'package:json_annotation/json_annotation.dart';
import 'package:pub_semver/pub_semver.dart';

import '../analyzer/analyzer_client.dart' show AnalysisView;
import '../package/model_properties.dart';
import '../scorecard/models.dart';
import '../search/search_service.dart' show ApiPageRef;
import '../shared/datastore.dart' as db;
import '../shared/exceptions.dart';
import '../shared/model_properties.dart';
import '../shared/tags.dart';
import '../shared/urls.dart' as urls;
import '../shared/utils.dart';

export '../package/model_properties.dart' show FileObject;

part 'models.g.dart';

/// The age of package (the last version published) after it is hidden in
/// `robots.txt`.
const robotsVisibilityMaxAge = Duration(days: 365 * 2);

/// The age of package (the first version published) after it is shown in
/// `sitemap.txt`. During this time, the package is marked as `noindex`.
///
/// This gives administrators time to detect and remove spam packages, reducing
/// their attractiveness to spammers.
const robotsVisibilityMinAge = Duration(days: 3);

/// Pub package metdata.
///
/// The main property used is `uploaders` for determining who is allowed
/// to upload packages.
@db.Kind(name: 'Package', idType: db.IdType.String)
class Package extends db.ExpandoModel<String> {
  @db.StringProperty(required: true)
  String? name; // Same as id

  @db.DateTimeProperty(required: true)
  DateTime? created;

  @db.DateTimeProperty(required: true)
  DateTime? updated;

  /// Number of `User`s for which a `Like` entity of this package exists.
  ///
  /// Should be set zero when [Package] is created, and always updated in a
  /// transaction with a `Like` entity being created or removed, or by a
  /// background job correcting `Like` counts.
  @db.IntProperty(required: true)
  int likes = 0;

  /// [DateTime] when the most recently uploaded [PackageVersion] was published.
  @db.DateTimeProperty(required: true)
  DateTime? lastVersionPublished;

  /// Key referencing the [PackageVersion] for the latest version of this package, ordered by priority order of
  /// semantic versioning, hence, deprioritizing prereleases.
  @db.ModelKeyProperty(propertyName: 'latest_version', required: true)
  db.Key? latestVersionKey;

  /// [DateTime] when the [PackageVersion] in [latestVersionKey] was published.
  @db.DateTimeProperty()
  DateTime? latestPublished;

  /// Reference to latest version of this package ordered by semantic versioning, including
  /// prerelease versions of this package.
  ///
  /// Note. This is **not** the _latest prerelease version_, it is the _latest version_ without deprioritization of
  /// prereleases. Hence, this might not be a prerelease version, if a newer non-prerelease exists.
  @db.ModelKeyProperty(propertyName: 'latest_dev_version')
  db.Key? latestPrereleaseVersionKey;

  /// DateTime at which point the `PackageVersion` referenced in [latestPrereleaseVersionKey] was published.
  @db.DateTimeProperty()
  DateTime? latestPrereleasePublished;

  /// Reference to latest version of this package ordered by semantic versioning,
  /// filtered for versions that depend on an SDK that will be published in the
  /// future.
  ///
  /// Note: the version may be stable or prerelease.
  @db.ModelKeyProperty()
  db.Key? latestPreviewVersionKey;

  /// DateTime at which point the `PackageVersion` referenced in [latestPreviewVersionKey] was published.
  @db.DateTimeProperty()
  DateTime? latestPreviewPublished;

  /// The publisher id (null, if the package does not have a publisher).
  @db.StringProperty()
  String? publisherId;

  /// List of User.userId
  @db.StringListProperty()
  List<String>? uploaders;

  /// Set to `true` if package is discontinued, may otherwise be `false`.
  @db.BoolProperty(required: true)
  bool isDiscontinued = false;

  /// The package that should be used instead of the current package.
  /// May have a value only if [isDiscontinued] is set.
  @db.StringProperty()
  String? replacedBy;

  /// Set to `true` if package should not be advertised on the front page, not
  /// be found through default package search; may otherwise be `false`.
  @db.BoolProperty(required: true)
  bool isUnlisted = false;

  /// Set to `true` if package should not be displayed anywhere, because of
  /// pending review or deletion.
  @db.BoolProperty(required: true)
  bool isWithheld = false;

  /// The reason why the package was withheld.
  @db.StringProperty()
  String? withheldReason;

  /// Tags that are assigned to this package.
  ///
  /// The permissions required to assign a tag typically depends on the tag.
  /// A package owner might be able to assign `'is:discontinued'` while a tag
  /// like `'is:not-advertized'` might only be managed by pub-administrators.
  @db.StringListProperty()
  List<String>? assignedTags;

  Package();

  /// Creates a new [Package] and populates all of it's fields from [version].
  factory Package.fromVersion(PackageVersion version) {
    final now = DateTime.now().toUtc();
    return Package()
      ..parentKey = version.packageKey!.parent
      ..id = version.pubspec!.name
      ..name = version.pubspec!.name
      ..created = now
      ..updated = now
      ..latestVersionKey = version.key
      ..latestPublished = now
      ..latestPrereleaseVersionKey = version.key
      ..latestPrereleasePublished = now
      ..uploaders = [version.uploader!]
      ..likes = 0
      ..isDiscontinued = false
      ..isUnlisted = false
      ..isWithheld = false
      ..assignedTags = [];
  }

  // Convenience Fields:

  bool get isVisible => !isWithheld;
  bool get isNotVisible => !isVisible;

  bool get isIncludedInRobots {
    final now = DateTime.now();
    return isVisible &&
        !isDiscontinued &&
        !isUnlisted &&
        now.difference(created!) > robotsVisibilityMinAge &&
        now.difference(latestPublished!) < robotsVisibilityMaxAge;
  }

  bool get isExcludedInRobots => !isIncludedInRobots;

  String? get latestVersion => latestVersionKey!.id as String?;

  Version get latestSemanticVersion =>
      Version.parse(latestVersionKey!.id as String);

  String? get latestPrereleaseVersion =>
      latestPrereleaseVersionKey?.id as String?;

  String? get latestPreviewVersion => latestPreviewVersionKey?.id as String?;

  Version? get latestPrereleaseSemanticVersion =>
      latestPrereleaseVersionKey == null
          ? null
          : Version.parse(latestPrereleaseVersion!);

  Version? get latestPreviewSemanticVersion => latestPreviewVersionKey == null
      ? null
      : Version.parse(latestPreviewVersion!);

  bool get showPrereleaseVersion {
    if (latestPrereleaseVersion == null) return false;
    return latestSemanticVersion < latestPrereleaseSemanticVersion! &&
        (latestPreviewSemanticVersion == null ||
            latestPreviewSemanticVersion! < latestPrereleaseSemanticVersion!);
  }

  bool get showPreviewVersion {
    if (latestPreviewVersion == null) return false;
    return latestSemanticVersion < latestPreviewSemanticVersion!;
  }

  // Check if a [userId] is in the list of [uploaders].
  bool containsUploader(String? userId) {
    return userId != null && uploaders!.contains(userId);
  }

  int get uploaderCount => uploaders!.length;

  /// Add the [userId] to the list of [uploaders].
  void addUploader(String? userId) {
    if (publisherId != null) {
      throw OperationForbiddenException.publisherOwnedPackageNoUploader(
          name!, publisherId!);
    }
    if (userId != null && !uploaders!.contains(userId)) {
      uploaders!.add(userId);
    }
  }

  // Remove the [userId] from the list of [uploaders].
  void removeUploader(String? userId) {
    if (publisherId != null) {
      throw OperationForbiddenException.publisherOwnedPackageNoUploader(
          name!, publisherId!);
    }
    uploaders!.remove(userId);
  }

  /// Updates latest stable, prerelease and preview versions and published
  /// timestamp with the new version.
  void updateVersion(
    PackageVersion pv, {
    required Version dartSdkVersion,
  }) {
    final newVersion = pv.semanticVersion;
    final isOnStableSdk = !pv.pubspec!.isPreviewForCurrentSdk(dartSdkVersion);

    if (latestVersionKey == null ||
        (isNewer(latestSemanticVersion, newVersion, pubSorted: true) &&
            (latestSemanticVersion.isPreRelease || isOnStableSdk))) {
      latestVersionKey = pv.key;
      latestPublished = pv.created;
    }

    if (latestPreviewVersionKey == null ||
        isNewer(latestPreviewSemanticVersion!, newVersion, pubSorted: true)) {
      latestPreviewVersionKey = pv.key;
      latestPreviewPublished = pv.created;
    }

    if (latestPrereleaseVersionKey == null ||
        isNewer(latestPrereleaseSemanticVersion!, newVersion,
            pubSorted: false)) {
      latestPrereleaseVersionKey = pv.key;
      latestPrereleasePublished = pv.created;
    }

    if (lastVersionPublished == null ||
        lastVersionPublished!.isBefore(pv.created!)) {
      lastVersionPublished = pv.created;
    }
  }

  bool isNewPackage() => created!.difference(DateTime.now()).abs().inDays <= 30;

  /// List of tags from the flags on the current [Package] entity.
  List<String> getTags() {
    return <String>[
      // TODO(jonasfj): Remove the if (assignedTags != null) condition, we only
      //                need this until we've done backfill_package_fields.dart
      if (assignedTags != null) ...assignedTags!,
      if (isDiscontinued) PackageTags.isDiscontinued,
      if (isNewPackage()) PackageTags.isRecent,
      if (isUnlisted) PackageTags.isUnlisted,
      if (publisherId != null) PackageTags.publisherTag(publisherId!),
      // TODO: uploader:<...>
    ];
  }

  LatestReleases get latestReleases {
    return LatestReleases(
      stable: Release(
        version: latestVersion!,
        published: latestPublished!,
      ),
      prerelease: showPrereleaseVersion
          ? Release(
              version: latestPrereleaseVersion!,
              published: latestPrereleasePublished!,
            )
          : null,
      preview: showPreviewVersion
          ? Release(
              version: latestPreviewVersion!,
              published: latestPreviewPublished!,
            )
          : null,
    );
  }
}

/// Describes the various categories of latest releases.
@JsonSerializable()
class LatestReleases {
  final Release stable;
  final Release? prerelease;
  final Release? preview;

  LatestReleases({
    required this.stable,
    this.prerelease,
    this.preview,
  });

  factory LatestReleases.fromJson(Map<String, dynamic> json) =>
      _$LatestReleasesFromJson(json);

  Map<String, dynamic> toJson() => _$LatestReleasesToJson(this);

  bool get showPrerelease =>
      prerelease != null && stable.version != prerelease!.version;
  bool get showPreview => preview != null && stable.version != preview!.version;
}

@JsonSerializable()
class Release {
  final String version;
  final DateTime published;

  Release({
    required this.version,
    required this.published,
  });

  factory Release.fromJson(Map<String, dynamic> json) =>
      _$ReleaseFromJson(json);

  Map<String, dynamic> toJson() => _$ReleaseToJson(this);

  String get shortPublished => shortDateFormat.format(published);
}

/// Pub package metadata for a specific uploaded version.
///
/// Metadata such as changelog/readme/libraries are used for rendering HTML
/// pages.
@db.Kind(name: 'PackageVersion', idType: db.IdType.String)
class PackageVersion extends db.ExpandoModel<String> {
  @db.StringProperty(required: true)
  String? version; // Same as id

  String get package => packageKey!.id as String;

  @db.ModelKeyProperty(required: true, propertyName: 'package')
  db.Key? packageKey;

  /// [DateTime] when [version] of [package] was published.
  @db.DateTimeProperty(required: true)
  DateTime? created;

  // Extracted data from the uploaded package.

  @PubspecProperty(required: true)
  Pubspec? pubspec;

  @CompatibleStringListProperty()
  List<String>? libraries;

  // Metadata about the package version.

  @db.StringProperty(required: true)
  String? uploader;

  /// The publisher id at the time of the upload.
  @db.StringProperty()
  String? publisherId;

  // Convenience Fields:

  Version get semanticVersion => Version.parse(version!);

  String? get ellipsizedDescription {
    final String? description = pubspec!.description;
    if (description == null) return null;
    return description.substring(0, min(description.length, 200));
  }

  String get shortCreated {
    return shortDateFormat.format(created!);
  }

  PackageLinks get packageLinks {
    return PackageLinks.infer(
      homepageUrl: pubspec!.homepage,
      documentationUrl: pubspec!.documentation,
      repositoryUrl: pubspec!.repository,
      issueTrackerUrl: pubspec!.issueTracker,
    );
  }

  QualifiedVersionKey get qualifiedVersionKey {
    return QualifiedVersionKey(
      package: package,
      version: version,
    );
  }

  /// List of tags from the flags on the current [PackageVersion] entity.
  List<String> getTags() {
    return <String>[
      if (pubspec!.hasFlutterPlugin) PackageVersionTags.isFlutterPlugin,
      if (pubspec!.supportsOnlyLegacySdk) PackageVersionTags.isLegacy,
    ];
  }
}

/// A derived entity that holds derived/cleaned content of [PackageVersion].
@db.Kind(name: 'PackageVersionInfo', idType: db.IdType.String)
class PackageVersionInfo extends db.ExpandoModel<String> {
  @db.StringProperty(required: true)
  String? package;

  @db.StringProperty(required: true)
  String? version;

  /// The created timestamp of the [PackageVersion] (the time of publishing).
  @db.DateTimeProperty(required: true)
  DateTime? versionCreated;

  @db.DateTimeProperty(required: true)
  DateTime? updated;

  @db.StringListProperty()
  List<String>? libraries = <String>[];

  @db.IntProperty(required: true)
  int? libraryCount;

  /// The [AssetKind] identifier of assets extracted from the archive.
  @db.StringListProperty()
  List<String> assets = <String>[];

  @db.IntProperty()
  int? assetCount;

  PackageVersionInfo();

  /// Updates the current instance with the newly [derived] data.
  /// Returns true if the current instance changed.
  bool updateIfChanged(PackageVersionInfo derived) {
    var changed = false;
    if (versionCreated != derived.versionCreated) {
      versionCreated = derived.versionCreated;
      changed = true;
    }
    // TODO: implement more efficient difference check
    if (json.encode(libraries) != json.encode(derived.libraries)) {
      libraries = derived.libraries;
      changed = true;
    }
    if (libraryCount != (libraries?.length ?? 0)) {
      libraryCount = libraries?.length ?? 0;
      changed = true;
    }
    // TODO: implement more efficient difference check
    if (json.encode(assets) != json.encode(derived.assets)) {
      assets = derived.assets;
      changed = true;
    }
    if (assetCount != (assets.length)) {
      assetCount = assets.length;
      changed = true;
    }
    if (changed) {
      updated = DateTime.now().toUtc();
    }
    return changed;
  }

  void initFromKey(QualifiedVersionKey key) {
    id = key.qualifiedVersion;
    package = key.package;
    version = key.version;
  }

  QualifiedVersionKey get qualifiedVersionKey {
    return QualifiedVersionKey(
      package: package,
      version: version,
    );
  }

  bool get hasLicense => assets.contains(AssetKind.license);
}

/// The kind classifier of the extracted [PackageVersionAsset].
abstract class AssetKind {
  static const pubspec = 'pubspec';
  static const readme = 'readme';
  static const changelog = 'changelog';
  static const example = 'example';
  static const license = 'license';
}

/// A derived entity that holds extracted asset of a [PackageVersion] archive.
@db.Kind(name: 'PackageVersionAsset', idType: db.IdType.String)
class PackageVersionAsset extends db.ExpandoModel {
  /// ID format: an URI path with <package>/<version>/<kind>
  String get assetId => id as String;

  /// The name of the package.
  @db.StringProperty(required: true)
  String? package;

  /// The version of the package (e.g. `1.0.0`)
  @db.StringProperty(required: true)
  String? version;

  /// The combined name and version of the package (e.g. `package/1.0.0`).
  /// Can be used for version-specific listing.
  @db.StringProperty(required: true)
  String? packageVersion;

  /// One of the values in [AssetKind].
  @db.StringProperty(required: true)
  String? kind;

  /// The created timestamp of the [PackageVersion] (the time of publishing).
  @db.DateTimeProperty(required: true)
  DateTime? versionCreated;

  @db.DateTimeProperty(required: true)
  DateTime? updated;

  @db.StringProperty(required: true, indexed: false)
  String? path;

  @db.StringProperty(required: true, indexed: false)
  String? textContent;

  PackageVersionAsset();

  PackageVersionAsset.init({
    required this.package,
    required this.version,
    required this.kind,
    required this.versionCreated,
    DateTime? updated,
    required this.path,
    required this.textContent,
  }) {
    id = Uri(pathSegments: [package!, version!, kind!]).path;
    packageVersion = Uri(pathSegments: [package!, version!]).path;
    this.updated = updated ?? DateTime.now().toUtc();
  }

  /// Updates the current instance with the newly [derived] data.
  /// Returns true if the current instance changed.
  bool updateIfChanged(PackageVersionAsset derived) {
    var changed = false;
    if (versionCreated != derived.versionCreated) {
      versionCreated = derived.versionCreated;
      changed = true;
    }
    if (path != derived.path) {
      path = derived.path;
      changed = true;
    }
    if (textContent != derived.textContent) {
      textContent = derived.textContent;
      changed = true;
    }
    if (changed) {
      updated = DateTime.now().toUtc();
    }
    return changed;
  }

  QualifiedVersionKey get qualifiedVersionKey {
    return QualifiedVersionKey(
      package: package,
      version: version,
    );
  }

  FileObject toFileObject() => FileObject(path!, textContent!);
}

/// Entity representing a package that has been removed.
@db.Kind(name: 'ModeratedPackage', idType: db.IdType.String)
class ModeratedPackage extends db.ExpandoModel<String> {
  @db.StringProperty(required: true)
  String? name;

  @db.DateTimeProperty()
  late DateTime moderated;

  /// The previous publisher id (null, if the package did not have a publisher).
  @db.StringProperty()
  String? publisherId;

  /// List of User.userId of previous uploaders.
  @db.StringListProperty()
  List<String>? uploaders;

  /// List of previous versions.
  @db.StringListProperty()
  List<String>? versions;
}

/// An identifier to point to a specific [package] and [version].
class QualifiedVersionKey {
  final String? package;
  final String? version;

  QualifiedVersionKey({
    required this.package,
    required this.version,
  });

  /// The qualified key in `<package>/<version>` format.
  String get qualifiedVersion => Uri(pathSegments: [package!, version!]).path;

  String assetId(String kind) =>
      Uri(pathSegments: [package!, version!, kind]).path;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QualifiedVersionKey &&
          runtimeType == other.runtimeType &&
          package == other.package &&
          version == other.version;

  @override
  int get hashCode => package.hashCode ^ version.hashCode;

  @override
  String toString() => qualifiedVersion;
}

/// An extract of [Package] and [PackageVersion], for
/// display-only uses.
@JsonSerializable(includeIfNull: false)
class PackageView extends Object with FlagMixin {
  final String? name;
  final String? version;

  // Not null only if there is a difference compared to the [version] or [previewVersion].
  final String? prereleaseVersion;
  // Not null only if there is a difference compared to the [version].
  final String? previewVersion;
  final String? ellipsizedDescription;

  /// The date when the package was first published.
  final DateTime? created;
  final DateTime? updated;
  @override
  final List<String>? flags;
  final String? publisherId;
  final bool? isAwaiting;

  final int? likes;

  /// The package's granted points from pana and dartdoc analysis.
  /// May be `null` if the analysis is not available yet.
  final int? grantedPubPoints;

  /// The package's max points from pana and dartdoc analysis.
  /// May be `null` if the analysis is not available yet.
  final int? maxPubPoints;

  /// The package's popularity score value (on the scale of 0-100).
  /// May be `null` if the score is not available yet.
  final int? popularity;

  final List<String> tags;
  final List<ApiPageRef>? apiPages;

  PackageView({
    this.name,
    this.version,
    this.prereleaseVersion,
    this.previewVersion,
    this.ellipsizedDescription,
    this.created,
    this.updated,
    this.flags,
    this.publisherId,
    this.isAwaiting = false,
    this.likes,
    this.grantedPubPoints,
    this.maxPubPoints,
    this.popularity,
    List<String>? tags,
    this.apiPages,
  }) : tags = tags ?? <String>[];

  factory PackageView.fromJson(Map<String, dynamic> json) =>
      _$PackageViewFromJson(json);

  factory PackageView.fromModel({
    required Package package,
    PackageVersion? version,
    ScoreCardData? scoreCard,
    List<ApiPageRef>? apiPages,
  }) {
    final prereleaseVersion =
        package.showPrereleaseVersion ? package.latestPrereleaseVersion : null;
    final previewVersion =
        package.showPreviewVersion ? package.latestPreviewVersion : null;
    final hasPanaReport = scoreCard?.reportTypes != null &&
        scoreCard!.reportTypes!.contains(ReportType.pana);
    final isAwaiting =
        // Job processing has not created any card yet.
        (scoreCard == null) ||
            // The uploader has recently removed the "discontinued" flag, but the
            // analysis did not complete yet.
            (scoreCard.isDiscontinued && !package.isDiscontinued) ||
            // No blocker for analysis, but no results yet.
            (!scoreCard.isSkipped && !hasPanaReport);
    return PackageView(
      name: version?.package ?? package.name,
      version: version?.version ?? package.latestVersion,
      prereleaseVersion: prereleaseVersion,
      previewVersion: previewVersion,
      ellipsizedDescription: version?.ellipsizedDescription,
      created: package.created,
      updated: package.lastVersionPublished,
      flags: scoreCard?.flags,
      publisherId: package.publisherId,
      isAwaiting: isAwaiting,
      likes: package.likes,
      grantedPubPoints: scoreCard?.grantedPubPoints,
      maxPubPoints: scoreCard?.maxPubPoints,
      popularity: scoreCard?.popularityScore == null
          ? null
          : (100.0 * scoreCard!.popularityScore!).round(),
      tags: <String>[
        ...(package.getTags()),
        ...(version?.getTags() ?? <String>[]),
        ...(scoreCard?.derivedTags ?? <String>[]),
      ],
      apiPages: apiPages,
    );
  }

  PackageView change({List<ApiPageRef>? apiPages}) {
    return PackageView(
      name: name,
      version: version,
      prereleaseVersion: prereleaseVersion,
      previewVersion: previewVersion,
      ellipsizedDescription: ellipsizedDescription,
      created: created,
      updated: updated,
      flags: flags,
      publisherId: publisherId,
      isAwaiting: isAwaiting,
      likes: likes,
      grantedPubPoints: grantedPubPoints,
      maxPubPoints: maxPubPoints,
      popularity: popularity,
      tags: tags,
      apiPages: apiPages ?? this.apiPages,
    );
  }

  Map<String, dynamic> toJson() => _$PackageViewToJson(this);
}

/// Sorts [versions] according to the semantic versioning specification.
///
/// If [pubSorting] is `true` then pub's priorization ordering is used, which
/// will rank pre-release versions lower than stable versions (e.g. it will
/// order "0.9.0-dev.1 < 0.8.0").  Otherwise it will use semantic version
/// sorting (e.g. it will order "0.8.0 < 0.9.0-dev.1").
void sortPackageVersionsDesc(List<PackageVersion> versions,
    {bool decreasing = true, bool pubSorting = true}) {
  versions.sort((PackageVersion a, PackageVersion b) =>
      compareSemanticVersionsDesc(
          a.semanticVersion, b.semanticVersion, decreasing, pubSorting));
}

/// The URLs provided by the package's pubspec or inferred from the homepage.
class PackageLinks {
  /// `homepage` property in `pubspec.yaml`
  final String? homepageUrl;

  /// `documentation` property in `pubspec.yaml`
  final String? documentationUrl;

  /// `repository` property in `pubspec.yaml`, or if not specified, an inferred
  /// URL from [homepageUrl].
  final String? repositoryUrl;

  /// `issue_tracker` property in `pubspec.yaml`, or if not specified, an
  /// inferred URL from [repositoryUrl].
  final String? issueTrackerUrl;

  /// The inferred base URL that can be used to link files from.
  final String? baseUrl;

  PackageLinks._({
    this.homepageUrl,
    this.documentationUrl,
    this.repositoryUrl,
    this.issueTrackerUrl,
    this.baseUrl,
  });

  factory PackageLinks.infer({
    String? homepageUrl,
    String? documentationUrl,
    String? repositoryUrl,
    String? issueTrackerUrl,
  }) {
    repositoryUrl ??= urls.inferRepositoryUrl(homepageUrl);
    issueTrackerUrl ??= urls.inferIssueTrackerUrl(repositoryUrl);
    final baseUrl = urls.inferBaseUrl(
      homepageUrl: homepageUrl,
      repositoryUrl: repositoryUrl,
    );
    return PackageLinks._(
      homepageUrl: homepageUrl,
      documentationUrl: documentationUrl,
      repositoryUrl: repositoryUrl,
      issueTrackerUrl: issueTrackerUrl,
      baseUrl: baseUrl,
    );
  }
}

/// Common data structure shared between package pages.
class PackagePageData {
  final Package? package;
  final LatestReleases? latestReleases;
  final ModeratedPackage? moderatedPackage;
  final PackageVersion? version;
  final PackageVersionInfo? versionInfo;
  final PackageVersionAsset? asset;
  final AnalysisView? analysis;
  final bool? isAdmin;
  final bool? isLiked;
  PackageView? _view;

  PackagePageData({
    required this.package,
    LatestReleases? latestReleases,
    required this.version,
    required this.versionInfo,
    required this.asset,
    required this.analysis,
    required this.isAdmin,
    required this.isLiked,
  })  : latestReleases = latestReleases ?? package!.latestReleases,
        moderatedPackage = null;

  PackagePageData.missing({
    required this.package,
    required this.latestReleases,
    this.moderatedPackage,
  })  : version = null,
        versionInfo = null,
        asset = null,
        analysis = null,
        isAdmin = null,
        isLiked = null;

  bool get hasReadme => versionInfo!.assets.contains(AssetKind.readme);
  bool get hasChangelog => versionInfo!.assets.contains(AssetKind.changelog);
  bool get hasExample => versionInfo!.assets.contains(AssetKind.example);
  bool get hasLicense => versionInfo!.assets.contains(AssetKind.license);
  bool get hasPubspec => versionInfo!.assets.contains(AssetKind.pubspec);

  bool get isLatestStable => version!.version == package!.latestVersion;

  PackageView toPackageView() {
    return _view ??= PackageView.fromModel(
      package: package!,
      version: version,
      scoreCard: analysis?.card,
    );
  }
}
