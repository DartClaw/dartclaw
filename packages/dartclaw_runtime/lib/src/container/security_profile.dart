/// Defines a container security profile per ADR-012.
class SecurityProfile {
  /// Stable identifier used in logs and configuration.
  final String id;

  /// Human-readable label for the profile.
  final String displayName;

  /// Mounts applied when the profile is selected, as Docker `-v` specs: bind
  /// mounts, plus anonymous volumes written as a bare container path.
  final List<String> workspaceMounts;

  /// Where a `workspace` container's package cache lives: an anonymous volume,
  /// writable and executable, removed with the container (ADR-062). Image
  /// recipes point package caches here.
  static const packageCachePath = '/var/cache/dartclaw';

  /// Creates a container security profile.
  const new({required this.id, required this.displayName, this.workspaceMounts = const []});

  /// Creates the standard writable workspace profile.
  ///
  /// [projectDir] adds the selected project at the legacy `/project` alias.
  /// [projectsClonesDir] adds the owner's read-only `/projects` collection.
  static SecurityProfile workspace({
    required String? workspaceDir,
    required String? projectDir,
    String? projectsClonesDir,
  }) => SecurityProfile(
    id: 'workspace',
    displayName: 'Workspace',
    workspaceMounts: [
      if (workspaceDir != null) '$workspaceDir:/workspace:rw',
      if (projectDir != null) '$projectDir:/project:ro',
      if (projectsClonesDir != null) '$projectsClonesDir:/projects:ro',
      packageCachePath,
    ],
  );

  /// Restricted profile with no workspace mounts.
  static const restricted = SecurityProfile(id: 'restricted', displayName: 'Restricted');

  @override
  String toString() => 'SecurityProfile(id: $id, displayName: $displayName)';
}
