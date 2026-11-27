import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

/// Unified file kind classification shared across Workspace File Preview,
/// Deliverable Preview, Uploaded Attachment Preview, and Workbench Files tab.
enum PreviewFileKind {
  rasterImage,
  svg,
  markdown,
  json,
  csv,
  html,
  code,
  text,
  binary,
}

/// Parsed `#L123` / `#L123-L145` / `:123` / `:123-145` anchor from a file path or URI.
class ParsedFileAnchor {
  const ParsedFileAnchor({
    required this.path,
    this.startLine,
    this.endLine,
  });

  final String path;
  final int? startLine;
  final int? endLine;
}

/// Parses optional line-number anchors (`#L12`, `#L12-L34`, `#12-34`, `:12`, `:12-34`)
/// from a workspace path or `file://` URL path.
ParsedFileAnchor parseFilePathAnchor(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return const ParsedFileAnchor(path: '');

  int? startLine;
  int? endLine;

  // Fragment style: foo.dart#L12-L34 or foo.dart#L12 or foo.dart#12-34
  final hashIdx = s.lastIndexOf('#');
  if (hashIdx > 0) {
    final frag = s.substring(hashIdx + 1).trim();
    final fragMatch =
        RegExp(r'^L?(\d+)(?:\s*[-–:]\s*L?(\d+))?$', caseSensitive: false).firstMatch(frag);
    if (fragMatch != null) {
      startLine = int.tryParse(fragMatch.group(1) ?? '');
      endLine = int.tryParse(fragMatch.group(2) ?? '') ?? startLine;
      s = s.substring(0, hashIdx);
    }
  }

  // Colon style: foo.dart:12:5 or foo.dart:12-34 (avoid stripping Windows drive `C:\`).
  if (startLine == null) {
    final colonMatch = RegExp(r':(\d+)(?:-(\d+)|:\d+)?$').firstMatch(s);
    if (colonMatch != null && colonMatch.start > 1) {
      startLine = int.tryParse(colonMatch.group(1) ?? '');
      endLine = int.tryParse(colonMatch.group(2) ?? '') ?? startLine;
      s = s.substring(0, colonMatch.start);
    }
  }

  if (startLine != null && endLine != null && endLine < startLine) {
    final tmp = startLine;
    startLine = endLine;
    endLine = tmp;
  }
  return ParsedFileAnchor(path: s, startLine: startLine, endLine: endLine);
}

String _extractLowerExt(String nameOrPath) {
  final clean = parseFilePathAnchor(nameOrPath).path;
  final slash = math.max(clean.lastIndexOf('/'), clean.lastIndexOf('\\'));
  final base = slash >= 0 ? clean.substring(slash + 1) : clean;
  final lower = base.toLowerCase();
  if (lower == 'dockerfile' || lower.startsWith('dockerfile.')) return 'dockerfile';
  if (lower == 'makefile' || lower == 'gnumakefile') return 'makefile';
  if (lower == 'cmakelists.txt') return 'cmake';
  if (lower == '.gitignore' || lower == '.dockerignore' || lower == '.env' || lower.startsWith('.env.')) {
    return lower.startsWith('.env') ? 'env' : 'gitignore';
  }
  final dot = lower.lastIndexOf('.');
  if (dot <= 0 || dot == lower.length - 1) return '';
  return lower.substring(dot + 1);
}

const Set<String> _rasterImageExts = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'wbmp',
  'ico',
  'avif',
  'heic',
  'heif',
};

const Set<String> _markdownExts = {'md', 'markdown', 'mdx', 'mkd', 'mdown'};
const Set<String> _jsonExts = {'json', 'jsonc', 'json5', 'jsonl', 'geojson', 'arb'};
const Set<String> _csvExts = {'csv', 'tsv'};
const Set<String> _htmlExts = {'html', 'htm', 'xhtml'};
const Set<String> _textExts = {'txt', 'log', 'out', 'rtf', 'readme', 'license'};

const Set<String> _binaryExts = {
  'pdf',
  'zip',
  'tar',
  'gz',
  'tgz',
  'bz2',
  'xz',
  '7z',
  'rar',
  'apk',
  'ipa',
  'aab',
  'dmg',
  'pkg',
  'exe',
  'msi',
  'dll',
  'so',
  'dylib',
  'wasm',
  'class',
  'jar',
  'o',
  'a',
  'mp3',
  'wav',
  'flac',
  'aac',
  'ogg',
  'm4a',
  'mp4',
  'mov',
  'mkv',
  'avi',
  'webm',
  'ttf',
  'otf',
  'woff',
  'woff2',
  'sqlite',
  'sqlite3',
  'db',
  'bin',
  'dat',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
};

const Map<String, String> _extToLang = {
  'dart': 'dart',
  'js': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'jsx': 'javascript',
  'ts': 'typescript',
  'mts': 'typescript',
  'cts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'pyi': 'python',
  'pyw': 'python',
  'rb': 'ruby',
  'go': 'go',
  'rs': 'rust',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'java': 'java',
  'swift': 'swift',
  'm': 'swift',
  'mm': 'cpp',
  'c': 'cpp',
  'h': 'cpp',
  'cc': 'cpp',
  'cpp': 'cpp',
  'cxx': 'cpp',
  'hpp': 'cpp',
  'cs': 'csharp',
  'php': 'php',
  'sh': 'bash',
  'bash': 'bash',
  'zsh': 'bash',
  'fish': 'bash',
  'ps1': 'bash',
  'sql': 'sql',
  'json': 'json',
  'jsonc': 'json',
  'json5': 'json',
  'jsonl': 'json',
  'geojson': 'json',
  'arb': 'json',
  'yaml': 'yaml',
  'yml': 'yaml',
  'toml': 'toml',
  'ini': 'toml',
  'cfg': 'toml',
  'conf': 'toml',
  'env': 'bash',
  'properties': 'toml',
  'xml': 'xml',
  'svg': 'xml',
  'plist': 'xml',
  'xaml': 'xml',
  'html': 'html',
  'htm': 'html',
  'xhtml': 'html',
  'css': 'css',
  'scss': 'css',
  'sass': 'css',
  'less': 'css',
  'vue': 'html',
  'svelte': 'html',
  'astro': 'html',
  'md': 'markdown',
  'markdown': 'markdown',
  'mdx': 'markdown',
  'csv': 'csv',
  'tsv': 'csv',
  'diff': 'diff',
  'patch': 'diff',
  'dockerfile': 'dockerfile',
  'makefile': 'makefile',
  'cmake': 'cmake',
  'gradle': 'kotlin',
  'groovy': 'java',
  'proto': 'cpp',
  'graphql': 'graphql',
  'gql': 'graphql',
  'frag': 'glsl',
  'vert': 'glsl',
  'glsl': 'glsl',
  'wgsl': 'rust',
  'lua': 'lua',
  'r': 'python',
  'ex': 'ruby',
  'exs': 'ruby',
  'zig': 'rust',
  'nix': 'bash',
  'tf': 'toml',
  'hcl': 'toml',
  'gitignore': 'bash',
  'editorconfig': 'toml',
  'lock': 'yaml',
};

/// Classifies a file into its primary preview category.
/// Explicitly separates `.svg` / `image/svg+xml` from raster images so SVG files
/// never fail decoding in `Image.memory`.
PreviewFileKind classifyPreviewFile(String nameOrPath, {String? mimeType}) {
  final ext = _extractLowerExt(nameOrPath);
  final mime = (mimeType ?? '').toLowerCase().trim();

  if (ext == 'svg' || mime == 'image/svg+xml') return PreviewFileKind.svg;
  if (_rasterImageExts.contains(ext) ||
      (mime.startsWith('image/') && !mime.contains('svg'))) {
    return PreviewFileKind.rasterImage;
  }
  if (_markdownExts.contains(ext) || mime == 'text/markdown') {
    return PreviewFileKind.markdown;
  }
  if (_jsonExts.contains(ext) ||
      mime == 'application/json' ||
      mime.endsWith('+json')) {
    return PreviewFileKind.json;
  }
  if (_csvExts.contains(ext) ||
      mime == 'text/csv' ||
      mime == 'text/tab-separated-values') {
    return PreviewFileKind.csv;
  }
  if (_htmlExts.contains(ext) || mime == 'text/html') {
    return PreviewFileKind.html;
  }
  if (_extToLang.containsKey(ext)) return PreviewFileKind.code;
  if (_binaryExts.contains(ext)) return PreviewFileKind.binary;
  if (_textExts.contains(ext) || mime.startsWith('text/')) {
    return PreviewFileKind.text;
  }
  if (mime.isNotEmpty &&
      !mime.startsWith('text/') &&
      !mime.contains('json') &&
      !mime.contains('xml') &&
      !mime.contains('javascript') &&
      !mime.contains('yaml') &&
      mime != 'application/octet-stream') {
    return PreviewFileKind.binary;
  }
  return PreviewFileKind.text;
}

/// Maps a filename or path to a normalized syntax highlighting language token.
String languageFromFilename(String nameOrPath, {String? mimeType}) {
  final ext = _extractLowerExt(nameOrPath);
  if (ext.isNotEmpty && _extToLang.containsKey(ext)) {
    return _extToLang[ext]!;
  }
  final mime = (mimeType ?? '').toLowerCase();
  if (mime.contains('json')) return 'json';
  if (mime.contains('html')) return 'html';
  if (mime.contains('xml') || mime.contains('svg')) return 'xml';
  if (mime.contains('markdown')) return 'markdown';
  if (mime.contains('javascript')) return 'javascript';
  if (mime.contains('typescript')) return 'typescript';
  if (mime.contains('python')) return 'python';
  if (mime.contains('yaml')) return 'yaml';
  if (mime.contains('css')) return 'css';
  if (mime.contains('sql')) return 'sql';
  if (mime.contains('shell') || mime.contains('bash')) return 'bash';
  return ext.isEmpty ? 'plaintext' : ext;
}

/// Returns a crisp semantic Cupertino icon matching a file's extension or MIME type.
IconData previewFileIcon(String nameOrPath, {String? mimeType}) {
  final kind = classifyPreviewFile(nameOrPath, mimeType: mimeType);
  switch (kind) {
    case PreviewFileKind.rasterImage:
      return CupertinoIcons.photo;
    case PreviewFileKind.svg:
      return CupertinoIcons.sparkles;
    case PreviewFileKind.markdown:
      return CupertinoIcons.doc_richtext;
    case PreviewFileKind.json:
      return CupertinoIcons.chevron_left_slash_chevron_right;
    case PreviewFileKind.csv:
      return CupertinoIcons.table;
    case PreviewFileKind.html:
      return CupertinoIcons.globe;
    case PreviewFileKind.code:
      final lang = languageFromFilename(nameOrPath, mimeType: mimeType);
      if (lang == 'bash' || lang == 'dockerfile' || lang == 'makefile') {
        return CupertinoIcons.command;
      }
      if (lang == 'diff') return CupertinoIcons.arrow_left_right;
      if (lang == 'yaml' || lang == 'toml') return CupertinoIcons.slider_horizontal_3;
      return CupertinoIcons.chevron_left_slash_chevron_right;
    case PreviewFileKind.binary:
      final ext = _extractLowerExt(nameOrPath);
      if (ext == 'zip' || ext == 'tar' || ext == 'gz' || ext == 'tgz' || ext == '7z' || ext == 'rar') {
        return CupertinoIcons.archivebox;
      }
      if (ext == 'mp3' || ext == 'wav' || ext == 'flac' || ext == 'aac' || ext == 'ogg' || ext == 'm4a') {
        return CupertinoIcons.music_note_2;
      }
      if (ext == 'mp4' || ext == 'mov' || ext == 'mkv' || ext == 'avi' || ext == 'webm') {
        return CupertinoIcons.play_rectangle;
      }
      return CupertinoIcons.doc_fill;
    case PreviewFileKind.text:
      return CupertinoIcons.doc_text;
  }
}

/// Human-readable file size formatter (`0 B`, `1.4 KB`, `3.2 MB`, `1.1 GB`).
String formatPreviewBytes(num? rawBytes) {
  if (rawBytes == null || rawBytes < 0) return '';
  final b = rawBytes.toDouble();
  if (b < 1024) return '${b.round()} B';
  if (b < 1024 * 1024) {
    final kb = b / 1024;
    return kb >= 100 ? '${kb.round()} KB' : '${kb.toStringAsFixed(1)} KB';
  }
  if (b < 1024 * 1024 * 1024) {
    final mb = b / (1024 * 1024);
    return mb >= 100 ? '${mb.round()} MB' : '${mb.toStringAsFixed(1)} MB';
  }
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Expands `\t` characters to visual column tab stops (default 4 spaces)
/// so monospace horizontal widths and diff alignment are accurate.
String expandTabs(String line, {int tabSize = 4}) {
  if (!line.contains('\t')) return line;
  final out = StringBuffer();
  var col = 0;
  for (var i = 0; i < line.length; i++) {
    final cu = line.codeUnitAt(i);
    if (cu == 9) {
      final spaces = tabSize - (col % tabSize);
      out.write(' ' * spaces);
      col += spaces;
    } else {
      out.writeCharCode(cu);
      col++;
    }
  }
  return out.toString();
}

/// Estimates visual horizontal width in logical pixels of a monospace line,
/// accounting for CJK/wide glyphs (~1.85× ASCII advance).
double estimateMonospaceLinePx(String line, {required double fontSize}) {
  final expanded = expandTabs(line);
  final asciiAdvance = fontSize * 0.62;
  var units = 0.0;
  for (final rune in expanded.runes) {
    if (rune > 0x2E7F) {
      units += 1.82;
    } else {
      units += 1.0;
    }
  }
  return units * asciiAdvance;
}

// ═══════════════════════════════════════════════════════════════════════════
// Per-Line Incremental Syntax Highlighter (fast O(line) with block-comment state)
// ═══════════════════════════════════════════════════════════════════════════

class _SyntaxPalette {
  const _SyntaxPalette({
    required this.fg,
    required this.keyword,
    required this.type,
    required this.string,
    required this.number,
    required this.comment,
    required this.fn,
    required this.key,
    required this.annotation,
    required this.diffAdd,
    required this.diffDel,
    required this.diffHunk,
  });

  final Color fg;
  final Color keyword;
  final Color type;
  final Color string;
  final Color number;
  final Color comment;
  final Color fn;
  final Color key;
  final Color annotation;
  final Color diffAdd;
  final Color diffDel;
  final Color diffHunk;

  static const dark = _SyntaxPalette(
    fg: Color(0xFFE6EDF3),
    keyword: Color(0xFFFF7B72),
    type: Color(0xFFFFA657),
    string: Color(0xFFA5D6FF),
    number: Color(0xFF79C0FF),
    comment: Color(0xFF8B949E),
    fn: Color(0xFFD2A8FF),
    key: Color(0xFF7EE787),
    annotation: Color(0xFFE3B341),
    diffAdd: Color(0xFF6EE7B7),
    diffDel: Color(0xFFFCA5A5),
    diffHunk: Color(0xFF93C5FD),
  );

  static const light = _SyntaxPalette(
    fg: Color(0xFF1F2937),
    keyword: Color(0xFFCF222E),
    type: Color(0xFF953800),
    string: Color(0xFF0A3069),
    number: Color(0xFF0550AE),
    comment: Color(0xFF6E7781),
    fn: Color(0xFF8250DF),
    key: Color(0xFF116329),
    annotation: Color(0xFF9A6700),
    diffAdd: Color(0xFF0D7A4F),
    diffDel: Color(0xFFC42B2B),
    diffHunk: Color(0xFF2563EB),
  );
}

const Set<String> _commonKeywords = {
  'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'default', 'break',
  'continue', 'return', 'try', 'catch', 'finally', 'throw', 'throws', 'rethrow',
  'new', 'this', 'super', 'self', 'true', 'false', 'null', 'nil', 'none',
  'undefined', 'void', 'var', 'let', 'const', 'final', 'static', 'class',
  'struct', 'enum', 'interface', 'trait', 'impl', 'extends', 'implements',
  'mixin', 'with', 'abstract', 'sealed', 'open', 'override', 'virtual',
  'public', 'private', 'protected', 'internal', 'external', 'export', 'import',
  'from', 'as', 'is', 'in', 'of', 'not', 'and', 'or', 'async', 'await', 'yield',
  'sync', 'fn', 'func', 'function', 'def', 'lambda', 'pub', 'mod', 'use',
  'crate', 'mut', 'ref', 'match', 'where', 'type', 'typedef', 'package',
  'module', 'namespace', 'using', 'required', 'late', 'covariant', 'factory',
  'get', 'set', 'operator', 'part', 'library', 'show', 'hide', 'deferred',
  'assert', 'raise', 'pass', 'elif', 'except', 'global', 'nonlocal',
  'del', 'val', 'fun', 'when', 'object', 'companion', 'data', 'init',
  'suspend', 'inline', 'reified', 'guard', 'defer', 'go', 'chan', 'select',
  'range', 'fallthrough', 'sizeof', 'typeof', 'instanceof', 'delete', 'keyof',
  'readonly', 'declare', 'any', 'unknown', 'never', 'boolean', 'number',
  'string', 'int', 'double', 'float', 'bool', 'char', 'byte', 'short', 'long',
  'u8', 'u16', 'u32', 'u64', 'usize', 'i8', 'i16', 'i32', 'i64', 'isize',
  'f32', 'f64', 'str', 'auto', 'constexpr', 'nullptr', 'template', 'typename',
  'echo', 'fi', 'then', 'esac', 'done', 'local', 'exit', 'unset',
};

const Set<String> _sqlKeywords = {
  'select', 'from', 'where', 'insert', 'into', 'values', 'update', 'set',
  'delete', 'create', 'alter', 'drop', 'table', 'index', 'view', 'trigger',
  'join', 'inner', 'left', 'right', 'outer', 'full', 'cross', 'on', 'group',
  'by', 'order', 'asc', 'desc', 'having', 'limit', 'offset', 'union', 'all',
  'distinct', 'as', 'and', 'or', 'not', 'in', 'is', 'null', 'like', 'ilike',
  'between', 'exists', 'case', 'when', 'then', 'else', 'end', 'primary', 'key',
  'foreign', 'references', 'unique', 'default', 'constraint', 'begin', 'commit',
  'rollback', 'transaction', 'with', 'recursive', 'returning', 'count', 'sum',
  'avg', 'min', 'max', 'coalesce', 'cast', 'varchar', 'integer', 'bigint',
  'boolean', 'timestamp', 'text', 'jsonb',
};

String _normalizeLang(String raw) {
  final l = raw.trim().toLowerCase();
  if (l.isEmpty) return 'plaintext';
  if (_extToLang.containsKey(l)) return _extToLang[l]!;
  switch (l) {
    case 'js':
    case 'javascript':
    case 'jsx':
      return 'javascript';
    case 'ts':
    case 'typescript':
    case 'tsx':
      return 'typescript';
    case 'py':
    case 'python':
      return 'python';
    case 'sh':
    case 'shell':
    case 'bash':
    case 'zsh':
      return 'bash';
    case 'yml':
    case 'yaml':
      return 'yaml';
    case 'c++':
    case 'cpp':
    case 'c':
    case 'objc':
      return 'cpp';
    case 'kt':
    case 'kotlin':
      return 'kotlin';
    case 'rs':
    case 'rust':
      return 'rust';
    case 'md':
    case 'markdown':
      return 'markdown';
    default:
      return l;
  }
}

/// Highlights a single line of code with optional multi-line block comment state
/// and optional case-insensitive search match highlight overlay.
({TextSpan span, bool inBlockComment}) highlightCodeLineIncremental(
  String rawLine,
  String rawLang, {
  required bool isDark,
  required double fontSize,
  double height = 1.48,
  bool inBlockComment = false,
  String? searchQuery,
  Color? matchBg,
  Color? matchFg,
}) {
  final line = expandTabs(rawLine);
  final p = isDark ? _SyntaxPalette.dark : _SyntaxPalette.light;
  final lang = _normalizeLang(rawLang);
  final baseStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: fontSize,
    height: height,
    color: p.fg,
  );

  if (line.isEmpty) {
    return (span: TextSpan(text: '', style: baseStyle), inBlockComment: inBlockComment);
  }

  // Diff lines: fast semantic coloring.
  if (lang == 'diff') {
    Color c = p.fg;
    FontWeight? fw;
    if (line.startsWith('+++') || line.startsWith('---') || line.startsWith('diff ') || line.startsWith('index ')) {
      c = p.comment;
      fw = FontWeight.w600;
    } else if (line.startsWith('@@')) {
      c = p.diffHunk;
      fw = FontWeight.w600;
    } else if (line.startsWith('+')) {
      c = p.diffAdd;
    } else if (line.startsWith('-')) {
      c = p.diffDel;
    }
    final s = TextSpan(
      text: line,
      style: baseStyle.copyWith(color: c, fontWeight: fw),
    );
    return (
      span: _applySearchHighlightToSpan(s, searchQuery, matchBg, matchFg),
      inBlockComment: false,
    );
  }

  // Markdown source lines.
  if (lang == 'markdown') {
    final trimmed = line.trimLeft();
    Color? lineColor;
    FontWeight? fw;
    if (trimmed.startsWith('#')) {
      lineColor = p.keyword;
      fw = FontWeight.w700;
    } else if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      lineColor = p.annotation;
      fw = FontWeight.w600;
    } else if (trimmed.startsWith('>')) {
      lineColor = p.comment;
    } else if (trimmed.startsWith('- ') || trimmed.startsWith('* ') || RegExp(r'^\d+\.\s').hasMatch(trimmed)) {
      lineColor = p.fg;
    }
    if (lineColor != null && lineColor != p.fg) {
      final s = TextSpan(
        text: line,
        style: baseStyle.copyWith(color: lineColor, fontWeight: fw),
      );
      return (
        span: _applySearchHighlightToSpan(s, searchQuery, matchBg, matchFg),
        inBlockComment: false,
      );
    }
  }

  // Guard pathological single-line minified blobs (> 2400 chars) so frame time stays < 2ms.
  if (line.length > 2400) {
    final s = TextSpan(text: line, style: baseStyle);
    return (
      span: _applySearchHighlightToSpan(s, searchQuery, matchBg, matchFg),
      inBlockComment: inBlockComment,
    );
  }

  final supportsSlashComments = lang != 'python' &&
      lang != 'yaml' &&
      lang != 'toml' &&
      lang != 'bash' &&
      lang != 'dockerfile' &&
      lang != 'makefile' &&
      lang != 'sql' &&
      lang != 'html' &&
      lang != 'xml' &&
      lang != 'lua';
  final supportsHashComments = lang == 'python' ||
      lang == 'yaml' ||
      lang == 'toml' ||
      lang == 'bash' ||
      lang == 'ruby' ||
      lang == 'dockerfile' ||
      lang == 'makefile' ||
      lang == 'cmake' ||
      lang == 'graphql';
  final supportsDashComments = lang == 'sql' || lang == 'lua';
  final isMarkup = lang == 'html' || lang == 'xml';
  final isSql = lang == 'sql';
  final isJson = lang == 'json';
  final isYamlOrToml = lang == 'yaml' || lang == 'toml';

  final spans = <TextSpan>[];
  var i = 0;
  final n = line.length;
  var blockComment = inBlockComment;

  void addPlain(int start, int end, {Color? color, FontWeight? weight, FontStyle? fontStyle}) {
    if (end <= start) return;
    spans.add(
      TextSpan(
        text: line.substring(start, end),
        style: color == null && weight == null && fontStyle == null
            ? null
            : TextStyle(color: color, fontWeight: weight, fontStyle: fontStyle),
      ),
    );
  }

  // Continue open multi-line block comment from prior line.
  if (blockComment) {
    final endToken = isMarkup ? '-->' : '*/';
    final endIdx = line.indexOf(endToken);
    if (endIdx < 0) {
      final s = TextSpan(
        text: line,
        style: baseStyle.copyWith(color: p.comment, fontStyle: FontStyle.italic),
      );
      return (
        span: _applySearchHighlightToSpan(s, searchQuery, matchBg, matchFg),
        inBlockComment: true,
      );
    }
    final after = endIdx + endToken.length;
    addPlain(0, after, color: p.comment, fontStyle: FontStyle.italic);
    i = after;
    blockComment = false;
  }

  // YAML/TOML leading key highlight: `  my_key: value` or `[section]`
  if (isYamlOrToml && i == 0) {
    final trimmedStart = line.length - line.trimLeft().length;
    if (trimmedStart < n && line[trimmedStart] == '[' && lang == 'toml') {
      final close = line.indexOf(']', trimmedStart);
      if (close > trimmedStart) {
        addPlain(0, trimmedStart);
        addPlain(trimmedStart, close + 1, color: p.type, weight: FontWeight.w600);
        i = close + 1;
      }
    } else {
      final kvMatch = RegExp(r'^(\s*(?:-\s+)?)([A-Za-z0-9_.\-/"]+)(\s*[:=])').firstMatch(line);
      if (kvMatch != null) {
        addPlain(0, kvMatch.group(1)!.length);
        final keyStart = kvMatch.group(1)!.length;
        final keyEnd = keyStart + kvMatch.group(2)!.length;
        addPlain(keyStart, keyEnd, color: p.key);
        addPlain(keyEnd, kvMatch.end);
        i = kvMatch.end;
      }
    }
  }

  var plainStart = i;
  void flushPlain(int end) {
    if (end > plainStart) {
      spans.add(TextSpan(text: line.substring(plainStart, end)));
    }
  }

  while (i < n) {
    final ch = line.codeUnitAt(i);

    // HTML/XML comment <!-- ... -->
    if (isMarkup && i + 3 < n && line.startsWith('<!--', i)) {
      flushPlain(i);
      final endIdx = line.indexOf('-->', i + 4);
      if (endIdx < 0) {
        addPlain(i, n, color: p.comment, fontStyle: FontStyle.italic);
        blockComment = true;
        i = n;
        plainStart = n;
        break;
      }
      addPlain(i, endIdx + 3, color: p.comment, fontStyle: FontStyle.italic);
      i = endIdx + 3;
      plainStart = i;
      continue;
    }

    // HTML/XML tag name `<div`, `</div`
    if (isMarkup && ch == 60 /* < */) {
      final tagMatch = RegExp(r'^</?[A-Za-z][A-Za-z0-9:._-]*').firstMatch(line.substring(i));
      if (tagMatch != null) {
        flushPlain(i);
        addPlain(i, i + tagMatch.end, color: p.keyword);
        i += tagMatch.end;
        plainStart = i;
        continue;
      }
    }

    // Line comment `//`
    if (supportsSlashComments && ch == 47 /* / */ && i + 1 < n && line.codeUnitAt(i + 1) == 47) {
      flushPlain(i);
      addPlain(i, n, color: p.comment, fontStyle: FontStyle.italic);
      i = n;
      plainStart = n;
      break;
    }

    // Block comment `/* ... */`
    if (supportsSlashComments && ch == 47 /* / */ && i + 1 < n && line.codeUnitAt(i + 1) == 42) {
      flushPlain(i);
      final endIdx = line.indexOf('*/', i + 2);
      if (endIdx < 0) {
        addPlain(i, n, color: p.comment, fontStyle: FontStyle.italic);
        blockComment = true;
        i = n;
        plainStart = n;
        break;
      }
      addPlain(i, endIdx + 2, color: p.comment, fontStyle: FontStyle.italic);
      i = endIdx + 2;
      plainStart = i;
      continue;
    }

    // Hash comment `#` (skip `#include` in cpp or `#hex` colors in css)
    if (supportsHashComments && ch == 35 /* # */) {
      flushPlain(i);
      addPlain(i, n, color: p.comment, fontStyle: FontStyle.italic);
      i = n;
      plainStart = n;
      break;
    }

    // SQL / Lua `--` comment
    if (supportsDashComments && ch == 45 /* - */ && i + 1 < n && line.codeUnitAt(i + 1) == 45) {
      flushPlain(i);
      addPlain(i, n, color: p.comment, fontStyle: FontStyle.italic);
      i = n;
      plainStart = n;
      break;
    }

    // Quoted strings ("...", '...', `...`)
    if (ch == 34 || ch == 39 || (ch == 96 && lang != 'markdown')) {
      final quote = ch;
      var j = i + 1;
      while (j < n) {
        final cj = line.codeUnitAt(j);
        if (cj == 92 /* \ */ && j + 1 < n) {
          j += 2;
          continue;
        }
        if (cj == quote) {
          j++;
          break;
        }
        j++;
      }
      flushPlain(i);
      // In JSON, double-quoted string followed by `:` is an object key!
      var isJsonKey = false;
      if (isJson && quote == 34) {
        var k = j;
        while (k < n && (line.codeUnitAt(k) == 32 || line.codeUnitAt(k) == 9)) {
          k++;
        }
        if (k < n && line.codeUnitAt(k) == 58 /* : */) {
          isJsonKey = true;
        }
      }
      addPlain(i, j, color: isJsonKey ? p.key : p.string);
      i = j;
      plainStart = i;
      continue;
    }

    // Annotations / decorators / preprocessor (`@override`, `#include`)
    if ((ch == 64 /* @ */ || (ch == 35 /* # */ && (lang == 'cpp' || lang == 'glsl'))) &&
        i + 1 < n &&
        _isIdentStart(line.codeUnitAt(i + 1))) {
      var j = i + 2;
      while (j < n && _isIdentPart(line.codeUnitAt(j))) {
        j++;
      }
      flushPlain(i);
      addPlain(i, j, color: p.annotation);
      i = j;
      plainStart = i;
      continue;
    }

    // Shell / template variable `$VAR` or `${VAR}`
    if ((lang == 'bash' || lang == 'dockerfile' || lang == 'makefile' || lang == 'php') &&
        ch == 36 /* $ */ &&
        i + 1 < n) {
      final next = line.codeUnitAt(i + 1);
      if (next == 123 /* { */) {
        final close = line.indexOf('}', i + 2);
        if (close > i) {
          flushPlain(i);
          addPlain(i, close + 1, color: p.type);
          i = close + 1;
          plainStart = i;
          continue;
        }
      } else if (_isIdentStart(next)) {
        var j = i + 2;
        while (j < n && _isIdentPart(line.codeUnitAt(j))) {
          j++;
        }
        flushPlain(i);
        addPlain(i, j, color: p.type);
        i = j;
        plainStart = i;
        continue;
      }
    }

    // Numbers (int, float, hex)
    if (_isDigit(ch) && (i == 0 || !_isIdentPart(line.codeUnitAt(i - 1)))) {
      var j = i + 1;
      if (ch == 48 /* 0 */ &&
          j < n &&
          (line.codeUnitAt(j) == 120 || line.codeUnitAt(j) == 88)) {
        j++;
        while (j < n && _isHexDigit(line.codeUnitAt(j))) {
          j++;
        }
      } else {
        while (j < n && (_isDigit(line.codeUnitAt(j)) || line.codeUnitAt(j) == 95)) {
          j++;
        }
        if (j < n && line.codeUnitAt(j) == 46 /* . */ && j + 1 < n && _isDigit(line.codeUnitAt(j + 1))) {
          j++;
          while (j < n && (_isDigit(line.codeUnitAt(j)) || line.codeUnitAt(j) == 95)) {
            j++;
          }
        }
      }
      flushPlain(i);
      addPlain(i, j, color: p.number);
      i = j;
      plainStart = i;
      continue;
    }

    // Identifiers / keywords / types / function calls / HTML attributes
    if (_isIdentStart(ch)) {
      var j = i + 1;
      while (j < n && _isIdentPart(line.codeUnitAt(j))) {
        j++;
      }
      final word = line.substring(i, j);
      Color? color;
      FontWeight? weight;
      if (isSql && _sqlKeywords.contains(word.toLowerCase())) {
        color = p.keyword;
        weight = FontWeight.w600;
      } else if (lang == 'dockerfile' &&
          const {
            'FROM', 'RUN', 'CMD', 'LABEL', 'EXPOSE', 'ENV', 'ADD', 'COPY',
            'ENTRYPOINT', 'VOLUME', 'USER', 'WORKDIR', 'ARG', 'HEALTHCHECK',
            'SHELL', 'AS',
          }.contains(word.toUpperCase())) {
        color = p.keyword;
        weight = FontWeight.w600;
      } else if (!isMarkup && _commonKeywords.contains(word)) {
        color = p.keyword;
      } else if (isMarkup && j < n && line.codeUnitAt(j) == 61 /* = */) {
        color = p.key;
      } else if (!isJson && !isMarkup && j < n && line.codeUnitAt(j) == 40 /* ( */) {
        color = p.fn;
      } else if (!isJson &&
          !isMarkup &&
          word.length >= 2 &&
          ch >= 65 &&
          ch <= 90 &&
          word.codeUnits.any((c) => c >= 97 && c <= 122)) {
        color = p.type;
      }
      if (color != null) {
        flushPlain(i);
        addPlain(i, j, color: color, weight: weight);
        plainStart = j;
      }
      i = j;
      continue;
    }

    i++;
  }

  flushPlain(n);
  final root = TextSpan(style: baseStyle, children: spans);
  return (
    span: _applySearchHighlightToSpan(root, searchQuery, matchBg, matchFg),
    inBlockComment: blockComment,
  );
}

/// Computes block-comment entry state for each line so virtualized `ListView.builder`
/// can jump to any line index and still render accurate `/* ... */` multi-line comments.
List<bool> computeBlockCommentStates(List<String> lines, String rawLang) {
  final n = lines.length;
  final states = List<bool>.filled(n, false);
  final lang = _normalizeLang(rawLang);
  final isMarkup = lang == 'html' || lang == 'xml';
  final supportsBlock = isMarkup ||
      (lang != 'python' &&
          lang != 'yaml' &&
          lang != 'toml' &&
          lang != 'bash' &&
          lang != 'dockerfile' &&
          lang != 'makefile' &&
          lang != 'sql' &&
          lang != 'markdown' &&
          lang != 'diff' &&
          lang != 'csv' &&
          lang != 'plaintext');
  if (!supportsBlock || n == 0) return states;

  final openTok = isMarkup ? '<!--' : '/*';
  final closeTok = isMarkup ? '-->' : '*/';
  var inBlock = false;
  for (var idx = 0; idx < n; idx++) {
    states[idx] = inBlock;
    final line = lines[idx];
    if (line.length > 2400) continue;
    var pos = 0;
    while (pos < line.length) {
      if (inBlock) {
        final c = line.indexOf(closeTok, pos);
        if (c < 0) break;
        inBlock = false;
        pos = c + closeTok.length;
      } else {
        final o = line.indexOf(openTok, pos);
        if (o < 0) break;
        // Ignore `/*` after a `//` line comment on the same line.
        if (!isMarkup) {
          final sl = line.indexOf('//', pos);
          if (sl >= 0 && sl < o) break;
        }
        inBlock = true;
        pos = o + openTok.length;
      }
    }
  }
  return states;
}

bool _isDigit(int cu) => cu >= 48 && cu <= 57;
bool _isHexDigit(int cu) =>
    (cu >= 48 && cu <= 57) || (cu >= 65 && cu <= 70) || (cu >= 97 && cu <= 102);
bool _isIdentStart(int cu) =>
    (cu >= 65 && cu <= 90) || (cu >= 97 && cu <= 122) || cu == 95;
bool _isIdentPart(int cu) => _isIdentStart(cu) || _isDigit(cu);

TextSpan _applySearchHighlightToSpan(
  TextSpan root,
  String? query,
  Color? matchBg,
  Color? matchFg,
) {
  final q = (query ?? '').trim().toLowerCase();
  if (q.isEmpty || matchBg == null) return root;

  TextSpan walk(TextSpan node) {
    if (node.children != null && node.children!.isNotEmpty) {
      return TextSpan(
        style: node.style,
        children: [
          for (final child in node.children!)
            if (child is TextSpan) walk(child) else child,
        ],
      );
    }
    final text = node.text ?? '';
    if (text.isEmpty) return node;
    final lower = text.toLowerCase();
    var idx = lower.indexOf(q);
    if (idx < 0) return node;
    final parts = <InlineSpan>[];
    var cursor = 0;
    while (idx >= 0) {
      if (idx > cursor) {
        parts.add(TextSpan(text: text.substring(cursor, idx)));
      }
      parts.add(
        TextSpan(
          text: text.substring(idx, idx + q.length),
          style: TextStyle(
            backgroundColor: matchBg,
            color: matchFg,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      cursor = idx + q.length;
      idx = lower.indexOf(q, cursor);
    }
    if (cursor < text.length) {
      parts.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: node.style, children: parts);
  }

  return walk(root);
}

// ═══════════════════════════════════════════════════════════════════════════
// ANSI SGR Parser + Control Stripper + Semantic Terminal Log Coloring
// ═══════════════════════════════════════════════════════════════════════════

final RegExp _oscEscapeRe = RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)');
final RegExp _csiEscapeRe = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
final RegExp _sgrTokenRe = RegExp(r'\x1B\[([0-9;]*)m');
final RegExp _otherEscRe = RegExp(r'\x1B[@-Z\\-_]|\x1B');

/// Strips ANSI CSI/OSC escape codes and resolves `\r` progress overwrites cleanly
/// so Copy, Search, and log classification always operate on clean text.
String stripAnsiAndControl(String raw) {
  if (raw.isEmpty) return '';
  var out = raw.replaceAll('\r\n', '\n');
  if (out.contains('\r')) {
    final lines = out.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.contains('\r')) {
        final parts = line.split('\r');
        // Keep the last non-empty overwrite segment (or empty if all empty).
        var chosen = '';
        for (var j = parts.length - 1; j >= 0; j--) {
          if (parts[j].isNotEmpty) {
            chosen = parts[j];
            break;
          }
        }
        lines[i] = chosen;
      }
    }
    out = lines.join('\n');
  }
  out = out.replaceAll(_oscEscapeRe, '');
  out = out.replaceAll(_csiEscapeRe, '');
  out = out.replaceAll(_otherEscRe, '');
  return out;
}

final RegExp _errLineRe = RegExp(
  r'\b(error|err!|fatal|panic|exception|failed|failure|traceback|syntaxerror|typeerror|referenceerror|assertionerror|enoent|eacces|segfault|unhandled)\b|✗|×|\bexit\s+code\s+[1-9]',
  caseSensitive: false,
);
final RegExp _warnLineRe = RegExp(
  r'\b(warn|warning|deprecated|caution|retry|timeout)\b|⚠',
  caseSensitive: false,
);
final RegExp _okLineRe = RegExp(
  r'\b(passed|success|succeeded|done|ready|ok|built|compiled)\b|✓|✔',
  caseSensitive: false,
);
final RegExp _stackFrameRe = RegExp(
  r'(^\s*at\s+\S+|^\s*#\d+\s+\S+|\b[\w./\\-]+\.(?:dart|ts|tsx|js|jsx|py|go|rs|kt|java|swift|cpp|c):\d+)',
);

/// Returns true when a plain terminal output line indicates an error or stack frame.
bool isErrorLogLine(String plainLine) =>
    _errLineRe.hasMatch(plainLine) || _stackFrameRe.hasMatch(plainLine);

/// Returns true when a plain terminal output line indicates a warning.
bool isWarningLogLine(String plainLine) => _warnLineRe.hasMatch(plainLine);

Color _ansiBasicColor(int code, {required bool isDark, required bool bright}) {
  if (isDark) {
    switch (code) {
      case 0:
        return bright ? const Color(0xFF7D8590) : const Color(0xFF484F58);
      case 1:
        return bright ? const Color(0xFFFF7B72) : const Color(0xFFF85149);
      case 2:
        return bright ? const Color(0xFF56D364) : const Color(0xFF3FB950);
      case 3:
        return bright ? const Color(0xFFE3B341) : const Color(0xFFD29922);
      case 4:
        return bright ? const Color(0xFF79C0FF) : const Color(0xFF58A6FF);
      case 5:
        return bright ? const Color(0xFFD2A8FF) : const Color(0xFFBC8CFF);
      case 6:
        return bright ? const Color(0xFF56D4DD) : const Color(0xFF39C5CF);
      case 7:
        return bright ? const Color(0xFFFFFFFF) : const Color(0xFFE6EDF3);
    }
  } else {
    switch (code) {
      case 0:
        return bright ? const Color(0xFF57606A) : const Color(0xFF24292F);
      case 1:
        return bright ? const Color(0xFFCF222E) : const Color(0xFFA40E26);
      case 2:
        return bright ? const Color(0xFF1A7F37) : const Color(0xFF116329);
      case 3:
        return bright ? const Color(0xFF9A6700) : const Color(0xFF7D4E00);
      case 4:
        return bright ? const Color(0xFF0969DA) : const Color(0xFF0550AE);
      case 5:
        return bright ? const Color(0xFF8250DF) : const Color(0xFF6639BA);
      case 6:
        return bright ? const Color(0xFF0B7285) : const Color(0xFF1B7C83);
      case 7:
        return bright ? const Color(0xFF4B5563) : const Color(0xFF1F2937);
    }
  }
  return isDark ? const Color(0xFFE6EDF3) : const Color(0xFF1F2937);
}

Color _ansi256Color(int n, {required bool isDark}) {
  if (n < 8) return _ansiBasicColor(n, isDark: isDark, bright: false);
  if (n < 16) return _ansiBasicColor(n - 8, isDark: isDark, bright: true);
  if (n < 232) {
    final idx = n - 16;
    final r = (idx ~/ 36) * 51;
    final g = ((idx ~/ 6) % 6) * 51;
    final b = (idx % 6) * 51;
    return Color.fromARGB(255, r, g, b);
  }
  final gray = (8 + (n - 232) * 10).clamp(0, 255);
  return Color.fromARGB(255, gray, gray, gray);
}

/// Renders a single terminal output line with full ANSI SGR color support,
/// or semantic log coloring (errors, warnings, successes, stack frames) when
/// no ANSI sequences are present.
TextSpan buildAnsiOrLogLineSpan(
  String rawLine, {
  required bool isDark,
  required double fontSize,
  double height = 1.48,
  required Color defaultColor,
  required Color errColor,
  required Color warnColor,
  required Color okColor,
  required Color accentColor,
  String? searchQuery,
  Color? matchBg,
  Color? matchFg,
}) {
  final baseStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: fontSize,
    height: height,
    color: defaultColor,
  );
  // Strip non-SGR escapes (OSC, cursor moves) while keeping `\x1B[...m` for SGR parsing.
  var line = rawLine.replaceAll(_oscEscapeRe, '');
  if (line.contains('\r')) {
    final parts = line.split('\r');
    var chosen = '';
    for (var j = parts.length - 1; j >= 0; j--) {
      if (parts[j].isNotEmpty) {
        chosen = parts[j];
        break;
      }
    }
    line = chosen;
  }
  line = expandTabs(line);

  if (line.contains('\x1B[')) {
    final children = <TextSpan>[];
    Color? fg;
    bool bold = false;
    bool dim = false;
    bool italic = false;
    bool underline = false;
    var lastEnd = 0;

    for (final m in _sgrTokenRe.allMatches(line)) {
      if (m.start > lastEnd) {
        final seg = line.substring(lastEnd, m.start).replaceAll(_csiEscapeRe, '').replaceAll(_otherEscRe, '');
        if (seg.isNotEmpty) {
          final c = (fg ?? defaultColor).withValues(alpha: dim ? 0.62 : 1.0);
          children.add(
            TextSpan(
              text: seg,
              style: TextStyle(
                color: c,
                fontWeight: bold ? FontWeight.w700 : null,
                fontStyle: italic ? FontStyle.italic : null,
                decoration: underline ? TextDecoration.underline : null,
              ),
            ),
          );
        }
      }
      final rawCodes = (m.group(1) ?? '').trim();
      final codes = rawCodes.isEmpty
          ? <int>[0]
          : rawCodes.split(';').map((s) => int.tryParse(s) ?? 0).toList();
      for (var k = 0; k < codes.length; k++) {
        final code = codes[k];
        if (code == 0) {
          fg = null;
          bold = false;
          dim = false;
          italic = false;
          underline = false;
        } else if (code == 1) {
          bold = true;
        } else if (code == 2) {
          dim = true;
        } else if (code == 3) {
          italic = true;
        } else if (code == 4) {
          underline = true;
        } else if (code == 22) {
          bold = false;
          dim = false;
        } else if (code == 23) {
          italic = false;
        } else if (code == 24) {
          underline = false;
        } else if (code == 39) {
          fg = null;
        } else if (code >= 30 && code <= 37) {
          fg = _ansiBasicColor(code - 30, isDark: isDark, bright: bold);
        } else if (code >= 90 && code <= 97) {
          fg = _ansiBasicColor(code - 90, isDark: isDark, bright: true);
        } else if (code == 38 && k + 2 < codes.length && codes[k + 1] == 5) {
          fg = _ansi256Color(codes[k + 2], isDark: isDark);
          k += 2;
        } else if (code == 38 && k + 4 < codes.length && codes[k + 1] == 2) {
          fg = Color.fromARGB(
            255,
            codes[k + 2].clamp(0, 255),
            codes[k + 3].clamp(0, 255),
            codes[k + 4].clamp(0, 255),
          );
          k += 4;
        }
      }
      lastEnd = m.end;
    }
    if (lastEnd < line.length) {
      final tail = line.substring(lastEnd).replaceAll(_csiEscapeRe, '').replaceAll(_otherEscRe, '');
      if (tail.isNotEmpty) {
        final c = (fg ?? defaultColor).withValues(alpha: dim ? 0.62 : 1.0);
        children.add(
          TextSpan(
            text: tail,
            style: TextStyle(
              color: c,
              fontWeight: bold ? FontWeight.w700 : null,
              fontStyle: italic ? FontStyle.italic : null,
              decoration: underline ? TextDecoration.underline : null,
            ),
          ),
        );
      }
    }
    final root = TextSpan(style: baseStyle, children: children);
    return _applySearchHighlightToSpan(root, searchQuery, matchBg, matchFg);
  }

  // Plain (non-ANSI) line: semantic tinting without painting every line solid red.
  final clean = line.replaceAll(_csiEscapeRe, '').replaceAll(_otherEscRe, '');
  Color lineColor = defaultColor;
  FontWeight? weight;
  if (_errLineRe.hasMatch(clean)) {
    lineColor = errColor;
    weight = FontWeight.w600;
  } else if (_warnLineRe.hasMatch(clean)) {
    lineColor = warnColor;
  } else if (_stackFrameRe.hasMatch(clean)) {
    lineColor = accentColor;
  } else if (_okLineRe.hasMatch(clean)) {
    lineColor = okColor;
  }
  final root = TextSpan(
    text: clean,
    style: baseStyle.copyWith(color: lineColor, fontWeight: weight),
  );
  return _applySearchHighlightToSpan(root, searchQuery, matchBg, matchFg);
}

// ═══════════════════════════════════════════════════════════════════════════
// Intra-Line Word-Level Diff Engine
// ═══════════════════════════════════════════════════════════════════════════

/// Computes intra-line change emphasis spans between a paired removed line and
/// added line (excluding their leading `-`/`+` prefix).
({TextSpan oldSpan, TextSpan newSpan}) computeIntraLineDiffSpans({
  required String oldText,
  required String newText,
  required TextStyle oldBaseStyle,
  required TextStyle newBaseStyle,
  required Color oldEmphBg,
  required Color newEmphBg,
}) {
  final oldExp = expandTabs(oldText);
  final newExp = expandTabs(newText);
  if (oldExp.isEmpty || newExp.isEmpty || oldExp == newExp) {
    return (
      oldSpan: TextSpan(text: oldExp, style: oldBaseStyle),
      newSpan: TextSpan(text: newExp, style: newBaseStyle),
    );
  }

  final minLen = math.min(oldExp.length, newExp.length);
  var prefix = 0;
  while (prefix < minLen && oldExp.codeUnitAt(prefix) == newExp.codeUnitAt(prefix)) {
    prefix++;
  }

  var suffix = 0;
  final maxSuffix = minLen - prefix;
  while (suffix < maxSuffix &&
      oldExp.codeUnitAt(oldExp.length - 1 - suffix) ==
          newExp.codeUnitAt(newExp.length - 1 - suffix)) {
    suffix++;
  }

  // If the entire line changed (> 88% diff), skip noisy full-line inner pill tint.
  final oldMidLen = oldExp.length - prefix - suffix;
  final newMidLen = newExp.length - prefix - suffix;
  final sameChars = prefix + suffix;
  final maxLen = math.max(oldExp.length, newExp.length);
  if (maxLen > 0 && sameChars / maxLen < 0.14) {
    return (
      oldSpan: TextSpan(text: oldExp, style: oldBaseStyle),
      newSpan: TextSpan(text: newExp, style: newBaseStyle),
    );
  }

  TextSpan buildSide(String text, int midLen, TextStyle base, Color emphBg) {
    final children = <TextSpan>[];
    if (prefix > 0) {
      children.add(TextSpan(text: text.substring(0, prefix)));
    }
    if (midLen > 0) {
      children.add(
        TextSpan(
          text: text.substring(prefix, prefix + midLen),
          style: TextStyle(
            backgroundColor: emphBg,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    if (suffix > 0) {
      children.add(TextSpan(text: text.substring(text.length - suffix)));
    }
    return TextSpan(style: base, children: children);
  }

  return (
    oldSpan: buildSide(oldExp, oldMidLen, oldBaseStyle, oldEmphBg),
    newSpan: buildSide(newExp, newMidLen, newBaseStyle, newEmphBg),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// RFC-4180 CSV / TSV Table Parser
// ═══════════════════════════════════════════════════════════════════════════

/// Parses CSV or TSV text into rows of cells safely (handling quoted fields
/// and escaped `""` quotes), capped at [maxRows] × [maxCols] for smooth rendering.
List<List<String>> parseDelimitedTable(
  String content, {
  required String delimiter,
  int maxRows = 250,
  int maxCols = 32,
}) {
  if (content.isEmpty) return const [];
  final sep = delimiter.codeUnitAt(0);
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var inQuotes = false;
  var i = 0;
  final n = content.length;

  void finishCell() {
    if (row.length < maxCols) {
      row.add(cell.toString());
    }
    cell.clear();
  }

  void finishRow() {
    finishCell();
    if (row.length > 1 || (row.length == 1 && row[0].isNotEmpty)) {
      rows.add(row);
    }
    row = <String>[];
  }

  while (i < n && rows.length < maxRows) {
    final cu = content.codeUnitAt(i);
    if (inQuotes) {
      if (cu == 34 /* " */) {
        if (i + 1 < n && content.codeUnitAt(i + 1) == 34) {
          cell.write('"');
          i += 2;
        } else {
          inQuotes = false;
          i++;
        }
      } else {
        cell.writeCharCode(cu);
        i++;
      }
      continue;
    }

    if (cu == 34 /* " */ && cell.isEmpty) {
      inQuotes = true;
      i++;
    } else if (cu == sep) {
      finishCell();
      i++;
    } else if (cu == 13 /* \r */) {
      finishRow();
      i++;
      if (i < n && content.codeUnitAt(i) == 10) i++;
    } else if (cu == 10 /* \n */) {
      finishRow();
      i++;
    } else {
      cell.writeCharCode(cu);
      i++;
    }
  }
  if (rows.length < maxRows && (cell.isNotEmpty || row.isNotEmpty)) {
    finishRow();
  }
  return rows;
}
