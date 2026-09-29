/// Defines a container security profile per ADR-012.
class SecurityProfile {
  /// Stable identifier used in logs and configuration.
  final String id;

  /// Human-readable label for the profile.
  final String displayName;

  /// Bind mounts applied when the profile is selected.
  final List<String> workspaceMounts;

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
    ],
  );

  /// Restricted profile with no workspace mounts.
  static const restricted = SecurityProfile(id: 'restricted', displayName: 'Restricted');

  @override
  String toString() => 'SecurityProfile(id: $id, displayName: $displayName)';
}
