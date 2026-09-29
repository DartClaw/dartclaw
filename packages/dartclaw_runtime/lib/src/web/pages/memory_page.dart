import 'package:shelf/shelf.dart';

import '../../api/api_helpers.dart';
import '../../memory/memory_admin_service.dart';
import '../../memory/memory_prune_service.dart';
import '../../memory/memory_status_service.dart';
import '../../templates/memory_dashboard.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

class MemoryPage extends DashboardPage {
  new({this.memoryStatusServiceGetter, this.memoryPruneServiceGetter, this.memoryAdminServiceGetter});
  final MemoryStatusService? Function()? memoryStatusServiceGetter;
  final MemoryPruneService? Function()? memoryPruneServiceGetter;
  final MemoryAdminService? Function()? memoryAdminServiceGetter;
  @override
  String get route => '/memory';
  @override
  String get title => 'Memory';
  @override
  String? get icon => 'memory';
  @override
  String get navGroup => 'system';
  @override
  List<PageRouteDeclaration> get declaredRoutes => const [
    (method: 'POST', path: '/memory/prune'),
    (method: 'POST', path: '/memory/edit'),
    (method: 'POST', path: '/memory/remove'),
  ];
  @override
  Future<Response> handler(Request request, PageContext context) async {
    final memService = memoryStatusServiceGetter?.call();
    if (memService == null) {
      return Response.internalServerError(
        body: 'Memory dashboard not available — workspace not configured',
        headers: htmlHeaders,
      );
    }
    if (request.method == 'POST' && request.url.path == 'memory/prune') {
      return _prune(memService, context);
    }
    if (request.method == 'POST') return _mutate(request, context, memService);
    return _render(request, context, memService);
  }

  Future<Response> _render(
    Request request,
    PageContext context,
    MemoryStatusService memService, {
    String? selectorOverride,
    String? entryOverride,
    String? notice,
    int statusCode = 200,
  }) async {
    final admin = memoryAdminServiceGetter?.call();
    final selector = selectorOverride ?? request.url.queryParameters['corpus'];
    final query = request.url.queryParameters['q'] ?? '';
    final pageNumber = int.tryParse(request.url.queryParameters['page'] ?? '') ?? 1;
    Map<String, dynamic>? administration;
    if (admin != null) {
      final inventory = await admin.inventory();
      try {
        administration = Map<String, dynamic>.from(
          await admin.list(selector: selector, query: query, page: pageNumber),
        );
        administration['corpora'] = inventory['corpora'];
        administration['notice'] = notice;
        final entryId = entryOverride ?? request.url.queryParameters['entry'];
        if (entryId != null && entryId.isNotEmpty) {
          final detail = await admin.detail(selector: selector, id: entryId);
          if (detail['collectionRevision'] != administration['collectionRevision']) {
            administration['state'] = 'staleResult';
            administration['entries'] = const <Object>[];
            administration['notice'] = 'The selected corpus changed while loading. Reload its current entries.';
          } else {
            administration['detail'] = detail['entry'];
          }
          if (detail['entry'] == null && administration['state'] != 'staleResult') {
            administration['notice'] = 'That entry changed or is unavailable. Refresh this selected corpus.';
          }
        }
      } on MemoryAdminUnavailable {
        administration = {
          'corpora': inventory['corpora'],
          'selected': const {'selector': '', 'label': 'Unavailable corpus', 'kind': ''},
          'state': 'unavailable',
          'notice': 'The selected corpus is unavailable. Choose an available agent.',
        };
        statusCode = 200;
      } on ArgumentError {
        return Response(400, body: 'Invalid memory request', headers: htmlHeaders);
      } on Object {
        final selected = (inventory['corpora'] as List).cast<Map<String, Object?>>().firstWhere(
          (item) => item['selector'] == (selector ?? 'owner'),
          orElse: () => {'selector': '', 'label': 'Unavailable corpus', 'kind': ''},
        );
        administration = {
          'corpora': inventory['corpora'],
          'selected': selected,
          'state': 'unavailable',
          'notice': 'The selected corpus could not be read. Choose an available agent.',
        };
        statusCode = 503;
      }
    }
    final sidebarData = await context.sidebar.build();
    final selectedIsOwner = administration == null || (administration['selected'] as Map?)?['selector'] == 'owner';
    final status = selectedIsOwner ? await memService.getStatus() : <String, dynamic>{};
    final page = memoryDashboardTemplate(
      status: status,
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      workspacePath: context.config?.workspaceDir ?? '~/.dartclaw/workspace/',
      administration: administration,
      restartBannerHtml: context.restartBannerHtml(),
      appName: context.appName,
    );
    return Response(statusCode, body: page, headers: htmlHeaders);
  }

  Future<Response> _mutate(Request request, PageContext context, MemoryStatusService memService) async {
    final admin = memoryAdminServiceGetter?.call();
    if (admin == null) return Response(503, body: 'Memory administration unavailable', headers: htmlHeaders);
    final body = await readRequestBody(request, maxBytes: 16 * 1024);
    if (body.error != null) return body.error!;
    final Map<String, String> form;
    try {
      form = Uri.splitQueryString(body.body!);
    } on FormatException {
      return Response(400, body: 'Invalid memory form', headers: htmlHeaders);
    } on ArgumentError {
      return Response(400, body: 'Invalid memory form', headers: htmlHeaders);
    }
    final selector = form['corpus'];
    final id = form['id'] ?? '';
    final collectionRevision = int.tryParse(form['expectedCollectionRevision'] ?? '');
    final entryRevision = int.tryParse(form['expectedEntryRevision'] ?? '');
    if (selector == null || selector.isEmpty || id.isEmpty || collectionRevision == null || entryRevision == null) {
      return Response(400, body: 'Invalid memory revision', headers: htmlHeaders);
    }
    try {
      final result = await admin.apply(
        selector: selector,
        id: id,
        expectedCollectionRevision: collectionRevision,
        expectedEntryRevision: entryRevision,
        kind: request.url.path == 'memory/edit' ? 'revise' : 'remove',
        topic: form['topic'],
        content: form['content'],
        state: form['state'],
        reason: form['reason'],
      );
      final committed = result['canonicalOutcome'] == 'committed';
      final unchanged = result['canonicalOutcome'] == 'unchanged';
      final indexDegraded = result['indexOutcome'] == 'degraded';
      final notice = unchanged
          ? 'The selected canonical entry is already current; no changes were needed.'
          : committed
          ? request.url.path == 'memory/remove'
                ? 'Curated entry removed. ${MemoryAdminService.removalDisclosure}'
                : indexDegraded
                ? 'Canonical edit saved. Derived search index is degraded.'
                : 'Canonical edit saved and search index is current.'
          : 'This entry or collection changed. Refresh its current revision before trying again.';
      return await _render(
        request,
        context,
        memService,
        selectorOverride: selector,
        entryOverride: committed && request.url.path == 'memory/remove' ? null : id,
        notice: notice,
        statusCode: committed || unchanged ? 200 : 409,
      );
    } on MemoryAdminUnavailable {
      return Response(404, body: 'Selected corpus unavailable', headers: htmlHeaders);
    } on ArgumentError {
      return Response(400, body: 'Invalid memory operation', headers: htmlHeaders);
    }
  }

  Future<Response> _prune(MemoryStatusService statusService, PageContext context) async {
    final result = await memoryPruneServiceGetter?.call()?.prune();
    final type = result == null ? 'error' : 'success';
    final message = result == null
        ? 'Memory pruner not configured'
        : 'Archived ${result.entriesArchived}; de-duplicated ${result.duplicatesRemoved}; '
              '${result.entriesRemaining} entries remain';
    final fragment = memoryDashboardContentFragment(
      status: await statusService.getStatus(),
      workspacePath: context.config?.workspaceDir ?? '',
    );
    return Response.ok(fragment, headers: {...htmlHeaders, ...toastTriggerHeader(type, message)});
  }
}
