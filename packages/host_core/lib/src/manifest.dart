// 文件职责：manifest 1.2 的数据模型与校验，是加载器的第一道关卡
// 说明：当前为 demo 级校验，覆盖 schema 的结构约束与加载器要求的语义约束；
//       "用 JSON Schema 官方校验器跑 schema 文件" 留作后续补齐（见 README 的已知缺口）

import 'errors.dart';

/// 插件运行时的入口声明：UI（WebView）与 Worker（WASM）至少声明一项
class RuntimeSpec {
  final String? uiEntry;                 // 形如 ui/index.html，声明 runtime.ui 时必填
  final String? uiCsp;                   // 插件自带 CSP，只能比宿主下限更严
  final String? workerEntry;             // 形如 worker/component.wasm
  final int? workerMemoryMiB;            // Worker 内存预算，超出则拒绝激活

  const RuntimeSpec({this.uiEntry, this.uiCsp, this.workerEntry, this.workerMemoryMiB});

  bool get hasUi => uiEntry != null;     // 是否提供 WebView 界面
  bool get hasWorker => workerEntry != null; // 是否提供 WASM 计算
}

/// 版本与能力约束：描述该包能在什么宿主上运行
class EngineSpec {
  final String platform;                 // 宿主平台版本范围，例如 >=1.0.0 <2.0.0
  final String? uiBridge;                // UI Bridge 协议版本，声明 UI 时必填
  final String? wit;                     // Worker 接口版本，声明 Worker 时必填

  const EngineSpec({required this.platform, this.uiBridge, this.wit});
}

/// 包依赖：指向不可替代的具体插件，非"一类能力"
class DependencySpec {
  final String id;                       // 被依赖插件 ID
  final String versionRange;             // SemVer 范围
  final bool optional;                   // 缺省 false，表示缺失即阻止激活

  const DependencySpec({required this.id, required this.versionRange, this.optional = false});
}

/// 提供的服务：必须带参数/结果 schema，声明不代替运行时授权
class ProvidedService {
  final String id;                       // 服务 ID，例如 document.convert
  final String version;                  // 接口版本，与插件自身版本独立
  final String? inputSchemaPath;         // 包内相对路径，加载器校验其存在且不出包
  final String? outputSchemaPath;        // 同上
  final List<String> effects;            // read/write/network/send/delete/install
  final bool agentCallable;              // 是否可被 Agent 会话调用（仍需用户授权）
  final bool requiresUI;                 // 是否必须有插件页面交互才能执行

  const ProvidedService({
    required this.id,
    required this.version,
    this.inputSchemaPath,
    this.outputSchemaPath,
    this.effects = const [],
    this.agentCallable = false,
    this.requiresUI = false,
  });
}

/// 消费的服务：只声明所需能力与版本范围，不指定具体提供者
class ConsumedService {
  final String id;                       // 服务 ID
  final String versionRange;             // 可接受的接口版本范围
  final bool optional;                   // 可选能力缺失时只禁用相关入口

  const ConsumedService({required this.id, required this.versionRange, this.optional = false});
}

/// 通知类别：插件必须先登记，才能按该类别发提醒
class NotificationCategory {
  final String id;                       // 类别 ID，同一插件内唯一
  final String label;                    // 展示名
  final String description;              // 用途说明
  final String defaultLevel;             // 默认等级，不得高于 requestedMaxLevel
  final String requestedMaxLevel;        // 请求的等级上限，用户策略决定实际允许值

  const NotificationCategory({
    required this.id,
    required this.label,
    required this.description,
    required this.defaultLevel,
    required this.requestedMaxLevel,
  });
}

/// 通知等级枚举，顺序即强度，便于比较与降级计算
class NotifyLevel {
  static const passive = 'passive';      // 静默：不打断
  static const normal = 'normal';        // 普通：角标或轻量横幅
  static const important = 'important';  // 重要：醒目横幅
  static const critical = 'critical';    // 紧急：前台紧急弹窗

  static const ordered = [passive, normal, important, critical];

  /// 返回不高于 cap 的最高等级，用于按用户策略降级
  static String clamp(String requested, String cap) =>
      ordered.indexOf(requested) <= ordered.indexOf(cap) ? requested : cap;

  static bool isValid(String level) => ordered.contains(level);
}

/// 宿主已知权限目录；清单里出现表外权限一律拒绝激活，不接受展示缩写
const Set<String> knownPermissions = {
  'workspace.read',
  'storage.plugin.read',
  'storage.plugin.write',
  'file.pick',
  'file.read',
  'file.save',
  'chat.search',
  'chat.export',
  'resource.create',
  'object.ref.read',
  'attachment.metadata.read',
  'command.register',
  'command.execute',
  'service.call',
  'event.subscribe',
  'event.publish',
  'task.create',
  'task.update',
  'task.cancel',
  'network.allowlisted',
  'audit.append',
  'notification.publish',
  'notification.read',
  'notification.critical',
  'notification.acknowledge',
};

/// 宿主已知运行时能力，manifest 的 hostCapabilities 只能取自该集合
const Set<String> knownHostCapabilities = {'ui.webview', 'worker.wasm', 'notifications.foreground', 'agent.stdio'};

/// 插件清单模型，字段与 plugin-manifest.schema.json（1.2 草案）对应
class PluginManifest {
  final String manifestVersion;          // 固定 "1.2"
  final String id;                       // 作者自述命名空间，用于依赖解析而非权限判断
  final String version;                  // 插件版本，SemVer
  final String displayName;              // 展示名
  final String? description;             // 功能描述
  final String? publisher;               // 可选自述作者，不构成认证身份
  final String? license;                 // 开源分发时的许可证标识
  final String apiVersion;               // 固定 "platform.v1"
  final EngineSpec engines;              // 平台与协议版本约束
  final RuntimeSpec runtime;             // 运行时入口
  final List<String> platforms;          // 声明适配目标平台
  final String connectivity;             // offline / network
  final List<String> permissions;        // 请求的数据权限，须逐项在已知目录内
  final List<String> hostCapabilities;   // 必需运行时能力
  final List<DependencySpec> dependencies;      // 包依赖
  final List<ProvidedService> provides;         // 提供的服务
  final List<ConsumedService> consumes;         // 消费的服务
  final List<NotificationCategory> categories;  // 登记的通知类别

  const PluginManifest({
    required this.manifestVersion,
    required this.id,
    required this.version,
    required this.displayName,
    required this.apiVersion,
    required this.engines,
    required this.runtime,
    required this.platforms,
    required this.connectivity,
    required this.permissions,
    this.description,
    this.publisher,
    this.license,
    this.hostCapabilities = const [],
    this.dependencies = const [],
    this.provides = const [],
    this.consumes = const [],
    this.categories = const [],
  });

  /// 该插件是否声明为离线包；M1 只激活离线包
  bool get offlineOnly => connectivity == 'offline';

  /// 校验并构造清单；任何一项不合规都抛 HostException，错误信息需可直接定位
  factory PluginManifest.parse(Map<String, Object?> json) {
    String reqString(String key, {String? pattern, int? maxLength}) {
      final v = json[key];
      if (v is! String || v.isEmpty) throw HostException(ErrorCode.contractMismatch, '清单缺少字段 $key 或类型不是非空字符串');
      if (maxLength != null && v.length > maxLength) {
        throw HostException(ErrorCode.contractMismatch, '清单字段 $key 超长（${v.length} > $maxLength）');
      }
      if (pattern != null && !RegExp(pattern).hasMatch(v)) {
        throw HostException(ErrorCode.contractMismatch, '清单字段 $key 不符合格式：$v');
      }
      return v;
    }

    // 基础标识与版本：id 与 version 的格式直接决定依赖解析能否工作
    final manifestVersion = reqString('manifestVersion');
    if (manifestVersion != '1.2') {
      throw HostException(ErrorCode.contractMismatch, '不支持的 manifestVersion：$manifestVersion，加载器只接受 1.2');
    }
    final id = reqString('id', pattern: r'^[a-z0-9][a-z0-9.-]{2,127}$');
    final version = reqString('version', pattern: r'^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$');
    final apiVersion = reqString('apiVersion');
    if (apiVersion != 'platform.v1') {
      throw HostException(ErrorCode.contractMismatch, '不支持的 apiVersion：$apiVersion');
    }

    // 运行时：ui 与 worker 至少一项，且入口路径与格式必须匹配
    final runtimeJson = json['runtime'];
    if (runtimeJson is! Map) throw const HostException(ErrorCode.contractMismatch, '清单缺少 runtime');
    final uiJson = runtimeJson['ui'];
    final workerJson = runtimeJson['worker'];
    if (uiJson == null && workerJson == null) {
      throw const HostException(ErrorCode.contractMismatch, 'runtime 必须至少声明 ui 或 worker 之一');
    }
    String? uiEntry, uiCsp, workerEntry;
    int? workerMemory;
    if (uiJson is Map) {
      uiEntry = '${uiJson['entry']}';
      if (!RegExp(r'^ui/.+\.html$').hasMatch(uiEntry)) {
        throw HostException(ErrorCode.contractMismatch, 'runtime.ui.entry 必须形如 ui/xxx.html：$uiEntry');
      }
      uiCsp = uiJson['csp'] as String?;
    }
    if (workerJson is Map) {
      workerEntry = '${workerJson['entry']}';
      workerMemory = (workerJson['memoryMiB'] as num?)?.toInt();
    }

    // engines：声明 UI 必须有 uiBridge，声明 Worker 必须有 wit
    final enginesJson = json['engines'];
    if (enginesJson is! Map) throw const HostException(ErrorCode.contractMismatch, '清单缺少 engines');
    final engines = EngineSpec(
      platform: '${enginesJson['platform']}',
      uiBridge: enginesJson['uiBridge'] as String?,
      wit: enginesJson['wit'] as String?,
    );
    if (uiEntry != null && engines.uiBridge == null) {
      throw const HostException(ErrorCode.contractMismatch, '声明 runtime.ui 时必须提供 engines.uiBridge');
    }
    if (workerEntry != null && engines.wit == null) {
      throw const HostException(ErrorCode.contractMismatch, '声明 runtime.worker 时必须提供 engines.wit');
    }

    // 平台与联网：M1 只激活离线包，联网包在此直接拒绝
    final platforms = (json['platforms'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    if (platforms.isEmpty) throw const HostException(ErrorCode.contractMismatch, '清单缺少 platforms');
    final connectivity = reqString('connectivity');
    if (connectivity != 'offline' && connectivity != 'network') {
      throw HostException(ErrorCode.contractMismatch, 'connectivity 只能为 offline 或 network：$connectivity');
    }

    // 权限：逐项校验，拒绝未知权限与展示缩写（例如 storage.plugin.read/write）
    final permissions = (json['permissions'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    if (permissions.isEmpty) throw const HostException(ErrorCode.contractMismatch, '清单必须声明 permissions（可为空数组）');
    for (final p in permissions) {
      if (!knownPermissions.contains(p)) {
        throw HostException(ErrorCode.contractMismatch, '未知权限，拒绝激活：$p（权限须逐项声明，不能使用展示缩写）');
      }
    }

    // 必需运行时能力：与权限分别检查，两组不得重叠
    final capsJson = json['hostCapabilities'];
    final required = (capsJson is Map ? capsJson['required'] as List? : null)?.map((e) => '$e').toList() ?? const <String>[];
    for (final c in required) {
      if (!knownHostCapabilities.contains(c)) {
        throw HostException(ErrorCode.contractMismatch, '未知必需能力，拒绝激活：$c');
      }
      if (permissions.contains(c)) {
        throw HostException(ErrorCode.contractMismatch, 'hostCapabilities 与 permissions 不得重叠：$c');
      }
    }

    // 依赖：包依赖与能力消费分别表达，ID 不得自引用
    final deps = <DependencySpec>[];
    for (final d in (json['dependencies'] as List?) ?? const []) {
      if (d is! Map) throw const HostException(ErrorCode.contractMismatch, 'dependencies 元素必须是对象');
      final depId = '${d['id']}';
      if (depId == id) throw HostException(ErrorCode.contractMismatch, '依赖自引用：$depId');
      deps.add(DependencySpec(id: depId, versionRange: '${d['versionRange']}', optional: d['optional'] == true));
    }

    // 服务声明：提供方必须给出参数/结果 schema 路径，且不得与消费声明同 ID
    final servicesJson = json['services'];
    final provides = <ProvidedService>[];
    final seenServiceIds = <String>{};
    for (final s in (servicesJson is Map ? servicesJson['provides'] as List? : null) ?? const []) {
      if (s is! Map) throw const HostException(ErrorCode.contractMismatch, 'services.provides 元素必须是对象');
      final sid = '${s['id']}';
      final sver = '${s['version']}';
      if (!seenServiceIds.add('$sid@$sver')) {
        throw HostException(ErrorCode.contractMismatch, '同一插件内重复的服务 ID/版本：$sid@$sver');
      }
      final inPath = s['inputSchema'] as String?;
      final outPath = s['outputSchema'] as String?;
      if (inPath == null || outPath == null) {
        throw HostException(ErrorCode.contractMismatch, '服务 $sid 必须声明 inputSchema 与 outputSchema');
      }
      provides.add(ProvidedService(
        id: sid,
        version: sver,
        inputSchemaPath: inPath,
        outputSchemaPath: outPath,
        effects: ((s['effects'] as List?) ?? const []).map((e) => '$e').toList(),
        agentCallable: s['agentCallable'] == true,
        requiresUI: s['requiresUI'] == true,
      ));
    }
    final consumes = <ConsumedService>[];
    for (final c in (servicesJson is Map ? servicesJson['consumes'] as List? : null) ?? const []) {
      if (c is! Map) throw const HostException(ErrorCode.contractMismatch, 'services.consumes 元素必须是对象');
      consumes.add(ConsumedService(
        id: '${c['id']}',
        versionRange: '${c['versionRange']}',
        optional: c['optional'] == true,
      ));
    }

    // 通知类别：默认等级不得高于请求上限；请求 critical 必须声明通知发布权限
    final categories = <NotificationCategory>[];
    final categoryIds = <String>{};
    for (final c in (json['notifications'] is Map ? (json['notifications'] as Map)['categories'] as List? : null) ?? const []) {
      if (c is! Map) throw const HostException(ErrorCode.contractMismatch, 'notifications.categories 元素必须是对象');
      final cid = '${c['id']}';
      final defLevel = '${c['defaultLevel']}';
      final maxLevel = '${c['requestedMaxLevel']}';
      if (!categoryIds.add(cid)) throw HostException(ErrorCode.contractMismatch, '通知类别重复：$cid');
      if (!NotifyLevel.isValid(defLevel) || !NotifyLevel.isValid(maxLevel)) {
        throw HostException(ErrorCode.contractMismatch, '通知类别 $cid 的等级取值非法');
      }
      if (NotifyLevel.ordered.indexOf(defLevel) > NotifyLevel.ordered.indexOf(maxLevel)) {
        throw HostException(ErrorCode.contractMismatch, '通知类别 $cid 的 defaultLevel 高于 requestedMaxLevel');
      }
      if (maxLevel == NotifyLevel.critical) {
        if (!permissions.contains('notification.publish') || !permissions.contains('notification.critical')) {
          throw HostException(
            ErrorCode.contractMismatch,
            '通知类别 $cid 请求 critical，必须同时声明 notification.publish 与 notification.critical',
          );
        }
      }
      categories.add(NotificationCategory(
        id: cid,
        label: '${c['label']}',
        description: '${c['description']}',
        defaultLevel: defLevel,
        requestedMaxLevel: maxLevel,
      ));
    }

    return PluginManifest(
      manifestVersion: manifestVersion,
      id: id,
      version: version,
      displayName: json['displayName'] as String? ?? id,
      description: json['description'] as String?,
      publisher: json['publisher'] as String?,
      license: json['license'] as String?,
      apiVersion: apiVersion,
      engines: engines,
      runtime: RuntimeSpec(uiEntry: uiEntry, uiCsp: uiCsp, workerEntry: workerEntry, workerMemoryMiB: workerMemory),
      platforms: platforms,
      connectivity: connectivity,
      permissions: permissions,
      hostCapabilities: required,
      dependencies: deps,
      provides: provides,
      consumes: consumes,
      categories: categories,
    );
  }
}
