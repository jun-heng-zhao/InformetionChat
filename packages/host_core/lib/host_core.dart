// 文件职责：host_core 对外导出面——宿主外壳与开发工具只依赖本文件列出的符号

export 'src/bridge.dart' show BridgeDispatcher, CallerSession;
export 'src/errors.dart' show ErrorCode, HostException, MethodNotFoundException;
export 'src/host.dart' show LocalHost, PickedInput, InputPicker, SaveHandler, RuntimeFactory;
export 'src/jsonrpc.dart' show RpcError, RpcErrorCode, RpcRequest, RpcResponse;
export 'src/loader.dart' show PackageLoader, StagedFile, StagedPackage;
export 'src/manifest.dart' show NotifyLevel, NotificationCategory, PluginManifest, ProvidedService, knownPermissions;
export 'src/notifications.dart' show HostNotification, NotificationEngine, NotificationPolicy, NotifyRequest, NotifyState;
export 'src/resources.dart' show ResourceDraft, ResourceHandle, ResourceKind, ResourceRegistry;
export 'src/runtime.dart' show HostCallHandler, PluginRuntime, PluginRuntimeConfig, SubprocessPluginRuntime;
export 'src/services.dart' show ProviderEntry, ServiceBinding, ServiceRegistry;
export 'src/tasks.dart' show LocalTask, SideEffectStatus, TaskManager, TaskState;
export 'src/version.dart' show SemVer, VersionRange;
export 'src/workspace.dart' show InstallState, PermissionBroker, PermissionGrant, PluginInstallation;
