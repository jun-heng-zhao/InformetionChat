// 文件职责：最小可用的 SemVer 解析与范围匹配，供依赖锁定与服务接口版本过滤使用
// 说明：demo 只支持精确版本、^x.y.z、~x.y.z 与 ">=a <b" 组合，复杂范围留待后续补齐

import 'errors.dart';

/// 解析后的语义化版本，比较时忽略构建元数据
class SemVer implements Comparable<SemVer> {
  final int major;                       // 主版本，接口不兼容变化时提升
  final int minor;                       // 次版本，向后兼容的新增
  final int patch;                       // 修订号，向后兼容的修复
  final String? prerelease;              // 预发布标识，存在时优先级低于同版本正式版
  final String raw;                      // 原始字符串，便于回显

  const SemVer(this.major, this.minor, this.patch, {this.prerelease, required this.raw});

  /// 解析版本串，格式非法时抛 HostException
  factory SemVer.parse(String text) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$').firstMatch(text.trim());
    if (m == null) throw HostException(ErrorCode.contractMismatch, '非法版本号：$text');
    return SemVer(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      prerelease: m.group(4),
      raw: text.trim(),
    );
  }

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major - other.major;
    if (minor != other.minor) return minor - other.minor;
    if (patch != other.patch) return patch - other.patch;
    if (prerelease == null && other.prerelease == null) return 0;
    if (prerelease == null) return 1;            // 正式版高于预发布版
    if (other.prerelease == null) return -1;
    return prerelease!.compareTo(other.prerelease!);
  }

  bool operator >=(SemVer other) => compareTo(other) >= 0;
  bool operator <(SemVer other) => compareTo(other) < 0;

  @override
  String toString() => raw;
}

/// 版本范围：支持精确、^、~ 与比较符组合，用于依赖锁定和消费者声明
class VersionRange {
  final String raw;                      // 原始范围串
  final List<String> _terms;             // 拆分后的比较项，例如 '>=1.0.0'

  VersionRange._(this.raw, this._terms);

  /// 解析范围串；空串按"任意版本"处理
  factory VersionRange.parse(String text) {
    final t = text.trim();
    if (t.isEmpty || t == '*') return VersionRange._(t, const []);
    // 把 >=1.0.0 <2.0.0 这类组合按空格拆开，逐项判断
    return VersionRange._(t, t.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList());
  }

  /// 判断给定版本是否落在范围内
  bool allows(String versionText) {
    if (_terms.isEmpty) return true;
    final v = SemVer.parse(versionText);
    for (final term in _terms) {
      if (term.startsWith('^')) {
        // 插入号：主版本非 0 时锁定主版本，0.x 时锁定次版本
        final base = SemVer.parse(term.substring(1));
        final upper = base.major > 0
            ? SemVer(base.major + 1, 0, 0, raw: '${base.major + 1}.0.0')
            : SemVer(0, base.minor + 1, 0, raw: '0.${base.minor + 1}.0');
        if (v < base || !(v < upper)) return false;
      } else if (term.startsWith('~')) {
        final base = SemVer.parse(term.substring(1));
        final upper = SemVer(base.major, base.minor + 1, 0, raw: '${base.major}.${base.minor + 1}.0');
        if (v < base || !(v < upper)) return false;
      } else if (term.startsWith('>=')) {
        if (!(v >= SemVer.parse(term.substring(2)))) return false;
      } else if (term.startsWith('<=')) {
        if (SemVer.parse(term.substring(2)).compareTo(v) < 0) return false;
      } else if (term.startsWith('>')) {
        if (SemVer.parse(term.substring(1)).compareTo(v) >= 0) return false;
      } else if (term.startsWith('<')) {
        if (!(v < SemVer.parse(term.substring(1)))) return false;
      } else {
        // 精确版本：允许 1.2.3-dev.1 命中 1.2.3-dev.1
        if (SemVer.parse(term).compareTo(v) != 0) return false;
      }
    }
    return true;
  }

  @override
  String toString() => raw;
}
