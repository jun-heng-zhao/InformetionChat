// 文件职责：本地插件包加载器——暂存、路径安全、配额、内容摘要与包内校验
// 依据：docs/contracts/plugin-package-format.md 第 "本地加载校验" 节

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'manifest.dart';

/// 快照中的单个文件记录：路径已归一化并排序，摘要以文件内容计算
class StagedFile {
  final String relativePath;             // 相对包根的 POSIX 风格路径
  final int size;                        // 字节数
  final String sha256;                   // 文件内容 SHA-256（十六进制）

  const StagedFile(this.relativePath, this.size, this.sha256);
}

/// 已校验的只读快照：安装与激活都以它为准，源目录后续变化不影响已授权代码
class StagedPackage {
  final PluginManifest manifest;         // 已通过结构与语义校验的清单
  final String stagingDirPath;           // 宿主管辖的暂存目录绝对路径
  final List<StagedFile> files;          // 按路径排序的内容清单
  final String digest;                   // 整体摘要，写入安装记录用于判断内容是否变化

  const StagedPackage({
    required this.manifest,
    required this.stagingDirPath,
    required this.files,
    required this.digest,
  });

  /// 读取暂存快照内的文件（只读用途，例如加载插件自带 CSP 或 schema）
  File file(String relativePath) => File(p.join(stagingDirPath, relativePath));
}

/// 包加载器：把开发目录或解包结果转成可信快照
class PackageLoader {
  static const maxFileBytes = 32 * 1024 * 1024;    // 单文件上限 32 MiB
  static const maxTotalBytes = 200 * 1024 * 1024;  // 解压总量上限 200 MiB
  static const maxFileCount = 5000;                // 文件数量上限

  final Directory stagingRoot;           // 宿主管理的暂存区根目录

  PackageLoader(this.stagingRoot);

  /// 把 sourceDir 复制为宿主管理的只读快照并完成全部加载校验
  Future<StagedPackage> stage(Directory sourceDir) async {
    // 1. 源目录必须存在且不是链接，避免通过软链把包根指向包外
    if (sourceDir is! Directory || !await sourceDir.exists()) {
      throw HostException(ErrorCode.notFound, '插件源目录不存在：${sourceDir.path}');
    }
    if (FileSystemEntity.isLinkSync(sourceDir.path)) {
      throw const HostException(ErrorCode.contractMismatch, '拒绝加载符号链接形式的包根目录');
    }

    // 2. 遍历并逐项拒绝特殊文件，同时累计配额
    final entries = <String, File>{};              // 归一化路径 → 源文件
    var totalBytes = 0;
    final lowerCased = <String>{};
    await for (final entity in sourceDir.list(recursive: true, followLinks: false)) {
      final rel = p.posix.joinAll(p.split(p.relative(entity.path, from: sourceDir.path)));
      if (FileSystemEntity.isLinkSync(entity.path)) {
        throw HostException(ErrorCode.contractMismatch, '拒绝加载链接条目：$rel');
      }
      if (entity is! File) continue;               // 目录无需入清单
      if (rel.startsWith('..') || p.posix.isAbsolute(rel)) {
        throw HostException(ErrorCode.contractMismatch, '路径逃逸包根，拒绝加载：$rel');
      }
      if (!lowerCased.add(rel.toLowerCase())) {
        throw HostException(ErrorCode.contractMismatch, '存在重复或大小写冲突路径：$rel');
      }
      final size = await entity.length();
      if (size > maxFileBytes) {
        throw HostException(ErrorCode.resourceLimit, '单文件超过 32 MiB 上限：$rel（$size 字节）');
      }
      totalBytes += size;
      if (totalBytes > maxTotalBytes) {
        throw const HostException(ErrorCode.resourceLimit, '包体总量超过 200 MiB 上限');
      }
      if (entries.length >= maxFileCount) {
        throw const HostException(ErrorCode.resourceLimit, '文件数量超过 5000 上限');
      }
      entries[rel] = File(entity.path);
    }

    // 3. 先解析清单，后续校验都以清单为准
    final manifestFile = entries['manifest.json'];
    if (manifestFile == null) throw const HostException(ErrorCode.contractMismatch, '包根缺少 manifest.json');
    final manifest = PluginManifest.parse(
      (jsonDecode(await manifestFile.readAsString()) as Map).cast<String, Object?>(),
    );

    // 4. 入口与 schema 必须存在，且 schema 引用不得指向包外或远程地址
    final required = <String>{
      if (manifest.runtime.uiEntry != null) manifest.runtime.uiEntry!,
      if (manifest.runtime.workerEntry != null) manifest.runtime.workerEntry!,
      for (final s in manifest.provides) ...[s.inputSchemaPath!, s.outputSchemaPath!],
    };
    for (final path in required) {
      if (!entries.containsKey(path)) {
        throw HostException(ErrorCode.contractMismatch, '清单声明的文件不存在：$path');
      }
    }
    for (final s in manifest.provides) {
      for (final schemaPath in [s.inputSchemaPath!, s.outputSchemaPath!]) {
        final text = await entries[schemaPath]!.readAsString();
        if (RegExp(r'"\$ref"\s*:\s*"(https?:|//)').hasMatch(text)) {
          throw HostException(ErrorCode.contractMismatch, 'schema 含远程 \$ref，加载器不联网解析：$schemaPath');
        }
      }
    }

    // 5. 复制到暂存区，按实际打开的文件建立内容清单
    final stagingDir = Directory(
      p.join(stagingRoot.path, '${manifest.id}-${manifest.version}-${_shortHash(manifest.id + manifest.version)}'),
    );
    await stagingDir.create(recursive: true);
    final sortedPaths = entries.keys.toList()..sort();
    final stagedFiles = <StagedFile>[];
    for (final rel in sortedPaths) {
      final bytes = await entries[rel]!.readAsBytes();
      final target = File(p.join(stagingDir.path, rel));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes, flush: false);
      await Process.run('chmod', ['444', target.path]); // 只读快照：已授权代码不允许就地被改写
      stagedFiles.add(StagedFile(rel, bytes.length, sha256.convert(bytes).toString()));
    }

    return StagedPackage(
      manifest: manifest,
      stagingDirPath: stagingDir.path,
      files: stagedFiles,
      digest: _contentDigest(stagedFiles),
    );
  }

  /// 对排序后的路径、字节数与每文件摘要求整体摘要
  static String _contentDigest(List<StagedFile> files) {
    final builder = BytesBuilder();
    for (final f in files) {
      builder.add(utf8.encode('${f.relativePath}\u0000${f.size}\u0000${f.sha256}\n'));
    }
    return sha256.convert(builder.takeBytes()).toString();
  }

  static String _shortHash(String input) => sha256.convert(utf8.encode(input)).toString().substring(0, 12);
}
