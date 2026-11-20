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
  /// It holds only DartClaw-owned mounts: [workspaceDir] at `/workspace`,
  /// [projectsClonesDir] as the owner's read-only `/projects` collection, and
  /// the package cache. Operator-chosen directories, such as the repository at
  /// `/project`, are not part of the profile.
  static SecurityProfile workspace({required String? workspaceDir, String? projectsClonesDir}) => SecurityProfile(
    id: 'workspace',
    displayName: 'Workspace',
    workspaceMounts: [
      if (workspaceDir != null) '$workspaceDir:/workspace:rw',
      if (projectsClonesDir != null) '$projectsClonesDir:/projects:ro',
      packageCachePath,
    ],
  );

  /// Restricted profile with no workspace mounts.
  static const restricted = SecurityProfile(id: 'restricted', displayName: 'Restricted');

  @override
  String toString() => 'SecurityProfile(id: $id, displayName: $displayName)';
}
