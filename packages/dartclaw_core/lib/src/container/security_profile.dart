/// Defines a container security profile per ADR-012.
class SecurityProfile {
  final String id;
  final String displayName;
  final List<String> workspaceMounts;

  const SecurityProfile({required this.id, required this.displayName, this.workspaceMounts = const []});

  static SecurityProfile workspace({required String workspaceDir, required String projectDir}) => SecurityProfile(
    id: 'workspace',
    displayName: 'Workspace',
    workspaceMounts: ['$workspaceDir:/workspace:rw', '$projectDir:/project:ro'],
  );

  static const restricted = SecurityProfile(id: 'restricted', displayName: 'Restricted');

  @override
  String toString() => 'SecurityProfile(id: $id, displayName: $displayName)';
}
