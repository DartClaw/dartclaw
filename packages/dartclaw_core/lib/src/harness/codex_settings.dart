/// Translates DartClaw config values into Codex-native request settings.
class CodexSettings {
  static const Map<String, String> _sandboxTranslations = {
    'workspace-write': 'workspaceWrite',
    'danger-full-access': 'dangerFullAccess',
  };

  static const Map<String, String> _approvalTranslations = {
    'on-request': 'on-request',
    'unless-allow-listed': 'granular',
    'never': 'never',
  };

  static String? translateSandbox(String? yamlValue) {
    return _translate(_sandboxTranslations, yamlValue);
  }

  static String? translateApproval(String? yamlValue) {
    return _translate(_approvalTranslations, yamlValue);
  }

  static Map<String, dynamic> buildDynamicSettings({String? model, String? cwd, String? sandbox, String? approval}) {
    final translatedSandbox = translateSandbox(sandbox);
    final translatedApproval = translateApproval(approval);
    final trimmedModel = _trimToNull(model);
    final trimmedCwd = _trimToNull(cwd);

    return {
      'model': ?trimmedModel,
      'cwd': ?trimmedCwd,
      'sandbox': ?translatedSandbox,
      'approval_policy': ?translatedApproval,
    };
  }

  static String? _translate(Map<String, String> translations, String? yamlValue) {
    if (!_hasContent(yamlValue)) {
      return null;
    }

    return translations[yamlValue!.trim()];
  }

  static String? _trimToNull(String? value) {
    if (!_hasContent(value)) {
      return null;
    }

    return value!.trim();
  }

  static bool _hasContent(String? value) {
    return value != null && value.trim().isNotEmpty;
  }
}
