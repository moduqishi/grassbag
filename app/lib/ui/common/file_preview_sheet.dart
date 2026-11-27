import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/native_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/grassbag_glass.dart';
import '../../theme/grassbag_theme.dart';
import '../web/web_embed.dart';
import 'grassbag_sheets.dart';
import 'preview_highlight_utils.dart';

enum FilePreviewSourceKind {
  workspace,
  deliverable,
  memoryBytes,
  sessionAttachment,
}

/// Source descriptor for the unified flagship file, deliverable & attachment previewer.
class FilePreviewSource {
  const FilePreviewSource._({
    required this.kind,
    required this.name,
    this.path,
    this.inlineContent,
    this.bytes,
    this.attachmentId,
    this.mimeType,
  });

  const FilePreviewSource.workspace({
    required String path,
    required String name,
    String? inlineContent,
  }) : this._(
          kind: FilePreviewSourceKind.workspace,
          name: name,
          path: path,
          inlineContent: inlineContent,
        );

  const FilePreviewSource.deliverable({
    required String name,
    String? path,
  }) : this._(
          kind: FilePreviewSourceKind.deliverable,
          name: name,
          path: path,
        );

  const FilePreviewSource.memoryBytes({
    required String name,
    required Uint8List bytes,
    String? mimeType,
  }) : this._(
          kind: FilePreviewSourceKind.memoryBytes,
          name: name,
          bytes: bytes,
          mimeType: mimeType,
        );

  const FilePreviewSource.sessionAttachment({
    required String name,
    required String attachmentId,
    Uint8List? localBytes,
    String? mimeType,
  }) : this._(
          kind: FilePreviewSourceKind.sessionAttachment,
          name: name,
          attachmentId: attachmentId,
          bytes: localBytes,
          mimeType: mimeType,
        );

  final FilePreviewSourceKind kind;
  final String name;
  final String? path;
  final String? inlineContent;
  final Uint8List? bytes;
  final String? attachmentId;
  final String? mimeType;
}

/// Opens the unified flagship workspace file preview sheet from any page.
/// Supports optional `#L123-L145` line anchor parsing directly inside [path] or via
/// explicit [initialLine] / [highlightEndLine].
void showWorkspaceFilePreviewSheet(
  BuildContext context, {
  required String path,
  String? title,
  int? initialLine,
  int? highlightEndLine,
  String? inlineContent,
}) {
  final parsed = parseFilePathAnchor(path);
  final clean = parsed.path.trim();
  if (clean.isEmpty) return;
  final parts = clean.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).toList(growable: false);
  final displayName = (title != null && title.trim().isNotEmpty)
      ? title.trim()
      : (parts.isNotEmpty ? parts.last : clean);
  final startLine = initialLine ?? parsed.startLine;
  final endLine = highlightEndLine ?? parsed.endLine ?? startLine;
  final lineSuffix = startLine != null
      ? (endLine != null && endLine > startLine ? ' · L$startLine-L$endLine' : ' · L$startLine')
      : '';
  showUnifiedFilePreviewSheet(
    context,
    source: FilePreviewSource.workspace(
      path: clean,
      name: displayName,
      inlineContent: inlineContent,
    ),
    title: displayName,
    subtitle: '$clean$lineSuffix',
    initialLine: startLine,
    highlightEndLine: endLine,
  );
}

/// Opens the unified previewer for an in-memory file (e.g. composer pending attachment).
void showMemoryFilePreviewSheet(
  BuildContext context, {
  required String name,
  required Uint8List bytes,
  String? mimeType,
  String? subtitle,
}) {
  final sizeLabel = formatPreviewBytes(bytes.length);
  final sub = subtitle ??
      [
        if (mimeType != null && mimeType.isNotEmpty) mimeType,
        if (sizeLabel.isNotEmpty) sizeLabel,
      ].join(' · ');
  showUnifiedFilePreviewSheet(
    context,
    source: FilePreviewSource.memoryBytes(
      name: name,
      bytes: bytes,
      mimeType: mimeType,
    ),
    title: name,
    subtitle: sub.isEmpty ? '本地附件预览' : sub,
  );
}

/// Opens the unified previewer for an uploaded session attachment (local bytes or remote download).
void showSessionAttachmentPreviewSheet(
  BuildContext context, {
  required String name,
  required String attachmentId,
  String? mimeType,
  String? sizeLabel,
  Uint8List? localBytes,
}) {
  final sub = [
    if (mimeType != null && mimeType.isNotEmpty) mimeType,
    if (sizeLabel != null && sizeLabel.isNotEmpty) sizeLabel,
  ].join(' · ');
  showUnifiedFilePreviewSheet(
    context,
    source: FilePreviewSource.sessionAttachment(
      name: name,
      attachmentId: attachmentId,
      localBytes: localBytes,
      mimeType: mimeType,
    ),
    title: name,
    subtitle: sub.isEmpty ? '对话附件' : sub,
  );
}

/// Opens the unified previewer for a generated deliverable file.
void showDeliverableFilePreviewSheet(
  BuildContext context, {
  required String name,
  String? path,
  String subtitle = '生成产物',
  String sizeLabel = '',
}) {
  final parsed = path != null && path.trim().isNotEmpty
      ? parseFilePathAnchor(path)
      : null;
  final cleanPath = parsed?.path.trim();
  final sub = [
    if (cleanPath != null && cleanPath.isNotEmpty) cleanPath else subtitle,
    if (sizeLabel.isNotEmpty) sizeLabel,
  ].join(' · ');
  showUnifiedFilePreviewSheet(
    context,
    source: FilePreviewSource.deliverable(
      name: name,
      path: cleanPath,
    ),
    title: name,
    subtitle: sub,
    initialLine: parsed?.startLine,
    highlightEndLine: parsed?.endLine,
  );
}

/// Core launcher for the unified flagship File / Deliverable / Attachment Previewer.
void showUnifiedFilePreviewSheet(
  BuildContext context, {
  required FilePreviewSource source,
  String? title,
  String? subtitle,
  int? initialLine,
  int? highlightEndLine,
}) {
  final displayTitle = (title != null && title.trim().isNotEmpty) ? title.trim() : source.name;
  final icon = previewFileIcon(
    source.path?.isNotEmpty == true ? source.path! : source.name,
    mimeType: source.mimeType,
  );
  showGrassBagSheet<void>(
    context,
    title: displayTitle,
    subtitle: subtitle,
    icon: icon,
    expandable: true,
    initialExpanded: true,
    wideLayout: true,
    scrollableBody: false,
    bodyBuilder: (_) => _UnifiedFilePreviewBody(
      source: source,
      initialLine: initialLine,
      highlightEndLine: highlightEndLine,
    ),
  );
}

enum _RichViewMode {
  rich,
  source,
  diff,
}

class _UnifiedFilePreviewBody extends ConsumerStatefulWidget {
  const _UnifiedFilePreviewBody({
    required this.source,
    this.initialLine,
    this.highlightEndLine,
  });

  final FilePreviewSource source;
  final int? initialLine;
  final int? highlightEndLine;

  @override
  ConsumerState<_UnifiedFilePreviewBody> createState() => _UnifiedFilePreviewBodyState();
}

class _UnifiedFilePreviewBodyState extends ConsumerState<_UnifiedFilePreviewBody> {
  final ScrollController _vScrollCtrl = ScrollController();
  final ScrollController _hScrollCtrl = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  bool _loading = true;
  bool _loadingMore = false;
  bool _eof = true;
  bool _binary = false;
  bool _softWrap = false;
  bool _showSearch = false;
  bool _copiedFlash = false;
  bool _savingImage = false;
  bool _savedImageFlash = false;
  Timer? _flashTimer;

  double _fontSize = 12.0;
  int _firstLineNumber = 1;
  int _nextOffset = 1;
  int? _totalLines;
  int? _byteSize;

  String _resolvedPath = '';
  String _rawText = '';
  List<String> _lines = const [];
  List<bool> _blockCommentStates = const [];
  double _maxLinePx = 280.0;
  Uint8List? _imageBytes;
  Uint8List? _binaryBytes;
  Size? _imageDims;
  String? _error;
  String? _loadMoreError;

  // Format-specific caches
  String? _prettyJsonText;
  List<String>? _prettyJsonLines;
  List<List<String>>? _csvRows;
  _RichViewMode _viewMode = _RichViewMode.source;

  // Search state
  String _searchQuery = '';
  List<int> _matchLineIndices = const [];
  int _activeMatchCursor = 0;

  ImageStream? _imgInfoStream;
  ImageStreamListener? _imgInfoListener;

  String get _effectiveName =>
      _resolvedPath.isNotEmpty ? _resolvedPath : widget.source.name;

  PreviewFileKind get _fileKind => classifyPreviewFile(
        _effectiveName,
        mimeType: widget.source.mimeType,
      );

  String get _lang => languageFromFilename(
        _effectiveName,
        mimeType: widget.source.mimeType,
      );

  bool get _supportsRichMode =>
      _fileKind == PreviewFileKind.markdown ||
      (_fileKind == PreviewFileKind.json && _prettyJsonText != null) ||
      (_fileKind == PreviewFileKind.csv && _csvRows != null && _csvRows!.isNotEmpty);

  @override
  void initState() {
    super.initState();
    unawaited(_loadInitial());
  }

  @override
  void dispose() {
    _disposeImageStream();
    _flashTimer?.cancel();
    _vScrollCtrl.dispose();
    _hScrollCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _disposeImageStream() {
    if (_imgInfoStream != null && _imgInfoListener != null) {
      _imgInfoStream!.removeListener(_imgInfoListener!);
    }
    _imgInfoStream = null;
    _imgInfoListener = null;
  }

  void _resolveImageDims(Uint8List bytes) {
    _disposeImageStream();
    final stream = MemoryImage(bytes).resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() {
          _imageDims = Size(info.image.width.toDouble(), info.image.height.toDouble());
        });
      },
      onError: (_, __) {},
    );
    _imgInfoStream = stream;
    _imgInfoListener = listener;
    stream.addListener(listener);
  }

  String _resolveDeliverablePath() {
    final rawPath = widget.source.path?.trim() ?? '';
    if (rawPath.isNotEmpty) return rawPath;
    final targetName = widget.source.name;
    final state = ref.read(appProvider);
    String found = targetName;
    bool hit = false;
    void walk(List<WorkspaceFileNode> nodes) {
      for (final n in nodes) {
        if (hit) return;
        if (!n.isDir &&
            (n.name == targetName ||
                n.path == targetName ||
                n.path.endsWith('/$targetName'))) {
          found = n.path;
          hit = true;
          return;
        }
        if (n.children.isNotEmpty) walk(n.children);
      }
    }

    walk(state.workspaceFiles);
    return found;
  }

  void _ingestTextContent(
    String txt, {
    bool append = false,
    bool setInitialRichMode = false,
  }) {
    final normalized = txt.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (append && _rawText.isNotEmpty) {
      final newLines = normalized.isEmpty ? <String>[] : normalized.split('\n');
      if (newLines.length > 1 && newLines.last.isEmpty) {
        newLines.removeLast();
      }
      final sep = _rawText.endsWith('\n') ? '' : '\n';
      _rawText = '$_rawText$sep$normalized';
      _lines = [..._lines, ...newLines];
      var maxPx = _maxLinePx;
      for (final line in newLines) {
        final px = estimateMonospaceLinePx(line, fontSize: 12.0);
        if (px > maxPx) maxPx = px;
      }
      _maxLinePx = maxPx.clamp(160.0, 9600.0);
    } else {
      _rawText = normalized;
      if (normalized.isEmpty) {
        _lines = const [];
        _maxLinePx = 160.0;
      } else {
        final split = normalized.split('\n');
        // Trim a single trailing empty element produced by a trailing newline on non-empty files.
        if (split.length > 1 && split.last.isEmpty) {
          split.removeLast();
        }
        _lines = split;
        var maxPx = 160.0;
        for (final line in split) {
          final px = estimateMonospaceLinePx(line, fontSize: 12.0);
          if (px > maxPx) maxPx = px;
        }
        _maxLinePx = maxPx.clamp(160.0, 9600.0);
      }
    }

    _blockCommentStates = computeBlockCommentStates(_lines, _lang);
    _prepareFormatViews(setInitialRichMode: setInitialRichMode);
    _recomputeSearchMatches();
  }

  void _prepareFormatViews({required bool setInitialRichMode}) {
    _prettyJsonText = null;
    _prettyJsonLines = null;
    _csvRows = null;

    if (_fileKind == PreviewFileKind.json && _rawText.trim().isNotEmpty && _rawText.length <= 400000) {
      try {
        final decoded = jsonDecode(_rawText);
        final formatted = const JsonEncoder.withIndent('  ').convert(decoded);
        _prettyJsonText = formatted;
        _prettyJsonLines = formatted.split('\n');
      } catch (_) {}
    } else if (_fileKind == PreviewFileKind.csv && _rawText.trim().isNotEmpty) {
      final isTsv = _effectiveName.toLowerCase().endsWith('.tsv') ||
          (widget.source.mimeType?.toLowerCase().contains('tab-separated') ?? false);
      final parsed = parseDelimitedTable(
        _rawText,
        delimiter: isTsv ? '\t' : ',',
        maxRows: 250,
        maxCols: 32,
      );
      if (parsed.isNotEmpty) {
        _csvRows = parsed;
      }
    }

    if (setInitialRichMode) {
      if (widget.initialLine != null) {
        // When jumping straight to `#L123`, always show line-numbered source code!
        _viewMode = _RichViewMode.source;
      } else if (_supportsRichMode) {
        _viewMode = _RichViewMode.rich;
      } else {
        _viewMode = _RichViewMode.source;
      }
    }
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
      _loadMoreError = null;
      _imageBytes = null;
      _binaryBytes = null;
      _imageDims = null;
      _binary = false;
      _lines = const [];
      _rawText = '';
    });

    try {
      final ctrl = ref.read(appProvider.notifier);
      final src = widget.source;

      if (src.kind == FilePreviewSourceKind.memoryBytes ||
          src.kind == FilePreviewSourceKind.sessionAttachment) {
        Uint8List? bytes = src.bytes;
        if ((bytes == null || bytes.isEmpty) &&
            src.attachmentId != null &&
            src.attachmentId!.isNotEmpty) {
          bytes = await ctrl.downloadSessionAttachment(src.attachmentId!);
        }
        if (!mounted) return;
        if (bytes == null) {
          setState(() {
            _loading = false;
            _error = '暂无法加载该附件内容（可能主机离线或附件已过期）。';
          });
          return;
        }
        _byteSize = bytes.length;
        if (_fileKind == PreviewFileKind.rasterImage) {
          if (bytes.isEmpty) {
            setState(() {
              _loading = false;
              _error = '图片字节为空。';
            });
            return;
          }
          _resolveImageDims(bytes);
          setState(() {
            _loading = false;
            _imageBytes = bytes;
          });
          return;
        }
        if (bytes.isEmpty) {
          setState(() {
            _loading = false;
            _eof = true;
            _totalLines = 0;
            _ingestTextContent('', setInitialRichMode: false);
          });
          return;
        }
        if (_fileKind == PreviewFileKind.binary || _looksBinaryBytes(bytes)) {
          setState(() {
            _loading = false;
            _binary = true;
            _binaryBytes = bytes;
            _eof = true;
          });
          return;
        }
        final decoded = utf8.decode(bytes, allowMalformed: true);
        setState(() {
          _loading = false;
          _eof = true;
          _ingestTextContent(decoded, setInitialRichMode: true);
          _totalLines = _lines.length;
        });
        _scheduleScrollToInitialLine();
        return;
      }

      // Workspace or deliverable source
      final targetPath = src.kind == FilePreviewSourceKind.deliverable
          ? _resolveDeliverablePath()
          : (src.path ?? src.name);
      _resolvedPath = targetPath;

      if (_fileKind == PreviewFileKind.rasterImage) {
        final bytes = await ctrl.readWorkspaceFileBytes(targetPath);
        if (!mounted) return;
        if (bytes == null || bytes.isEmpty) {
          setState(() {
            _loading = false;
            _error = '无法加载图片字节，可能不在当前会话工作区或文件过大。';
          });
          return;
        }
        _byteSize = bytes.length;
        _resolveImageDims(bytes);
        setState(() {
          _loading = false;
          _imageBytes = bytes;
        });
        return;
      }

      if (src.inlineContent != null) {
        _byteSize = utf8.encode(src.inlineContent!).length;
        if (!mounted) return;
        setState(() {
          _loading = false;
          _eof = true;
          _ingestTextContent(src.inlineContent!, setInitialRichMode: true);
          _totalLines = _lines.length;
        });
        _scheduleScrollToInitialLine();
        return;
      }

      final startLine = widget.initialLine;
      final fetchOffset = (startLine != null && startLine > 320) ? math.max(1, startLine - 40) : 1;
      const pageLimit = 400;
      final page = await ctrl.readWorkspaceFilePage(
        targetPath,
        offset: fetchOffset,
        limit: pageLimit,
      );
      if (!mounted) return;

      final txt = (page['text'] ?? '').toString();
      final isError = page['error'] == true;
      final isBin = page['binary'] == true;
      final pageLines = (page['lines'] as num?)?.toInt() ??
          (txt.isEmpty ? 0 : txt.split('\n').length);
      final totalLines = (page['totalLines'] as num?)?.toInt();

      setState(() {
        _loading = false;
        _firstLineNumber = fetchOffset;
        _binary = isBin;
        _totalLines = totalLines;
        if (isError) {
          _error = txt.isNotEmpty ? txt : '读取文件失败';
          _eof = true;
        } else if (isBin) {
          _eof = true;
        } else {
          _ingestTextContent(txt, setInitialRichMode: true);
          _eof = page['eof'] != false;
          _nextOffset = fetchOffset + (pageLines > 0 ? pageLines : _lines.length);
          if (_eof && _totalLines == null && fetchOffset == 1) {
            _totalLines = _lines.length;
          }
        }
      });
      _scheduleScrollToInitialLine();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = GrassBagController.formatReadableError(e);
      });
    }
  }

  bool _looksBinaryBytes(Uint8List bytes) {
    final sampleLen = math.min(bytes.length, 4096);
    var bad = 0;
    for (var i = 0; i < sampleLen; i++) {
      final b = bytes[i];
      if (b == 0) return true;
      if (b < 7 || (b > 14 && b < 32 && b != 27)) bad++;
    }
    return sampleLen > 0 && (bad / sampleLen) > 0.25;
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _eof || _resolvedPath.isEmpty) return;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final page = await ref.read(appProvider.notifier).readWorkspaceFilePage(
            _resolvedPath,
            offset: _nextOffset,
            limit: 400,
          );
      if (!mounted) return;
      final chunk = (page['text'] ?? '').toString();
      final pageLines = (page['lines'] as num?)?.toInt() ??
          (chunk.isEmpty ? 0 : chunk.split('\n').length);
      final totalLines = (page['totalLines'] as num?)?.toInt();
      setState(() {
        _loadingMore = false;
        if (page['error'] == true) {
          _loadMoreError = chunk.isNotEmpty ? chunk : '继续加载失败，请重试';
        } else {
          if (totalLines != null) _totalLines = totalLines;
          if (chunk.isNotEmpty) {
            _ingestTextContent(chunk, append: true);
          }
          _eof = page['eof'] != false || pageLines == 0;
          _nextOffset += pageLines > 0 ? pageLines : 400;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loadMoreError = GrassBagController.formatReadableError(e);
      });
    }
  }

  List<String> get _activeCodeLines =>
      (_fileKind == PreviewFileKind.json &&
              _viewMode == _RichViewMode.rich &&
              _prettyJsonLines != null)
          ? _prettyJsonLines!
          : _lines;

  String get _activeCopyText =>
      (_fileKind == PreviewFileKind.json &&
              _viewMode == _RichViewMode.rich &&
              _prettyJsonText != null)
          ? _prettyJsonText!
          : _rawText;

  double _lineExtentFor(BuildContext ctx) {
    final scaler = MediaQuery.textScalerOf(ctx);
    return math.max(18.0, scaler.scale(_fontSize) * 1.54).ceilToDouble();
  }

  void _scheduleScrollToInitialLine() {
    final target = widget.initialLine;
    if (target == null) return;
    final idx = target - _firstLineNumber;
    if (idx < 0 || idx >= _activeCodeLines.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vScrollCtrl.hasClients || _vScrollCtrl.positions.length != 1) return;
      final extent = _lineExtentFor(context);
      final offset = math.max(0.0, (idx - 3) * extent);
      _vScrollCtrl.animateTo(
        offset.clamp(0.0, _vScrollCtrl.position.maxScrollExtent),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _recomputeSearchMatches() {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) {
      _matchLineIndices = const [];
      _activeMatchCursor = 0;
      return;
    }
    final lines = _activeCodeLines;
    final matches = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].toLowerCase().contains(q)) {
        matches.add(i);
      }
    }
    _matchLineIndices = matches;
    if (matches.isEmpty) {
      _activeMatchCursor = 0;
    } else if (_activeMatchCursor >= matches.length) {
      _activeMatchCursor = 0;
    }
  }

  void _jumpToMatch(int cursorDelta) {
    if (_matchLineIndices.isEmpty) return;
    HapticFeedback.selectionClick();
    final next = (_activeMatchCursor + cursorDelta) % _matchLineIndices.length;
    setState(() {
      _activeMatchCursor = next < 0 ? next + _matchLineIndices.length : next;
    });
    final lineIdx = _matchLineIndices[_activeMatchCursor];
    if (_vScrollCtrl.hasClients && _vScrollCtrl.positions.length == 1) {
      final extent = _lineExtentFor(context);
      final offset = math.max(0.0, (lineIdx - 3) * extent);
      _vScrollCtrl.animateTo(
        offset.clamp(0.0, _vScrollCtrl.position.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _stepFontSize(double delta) {
    HapticFeedback.selectionClick();
    setState(() {
      _fontSize = (_fontSize + delta).clamp(10.0, 18.0);
    });
  }

  void _triggerCopiedFlash(String toastMsg) {
    _flashTimer?.cancel();
    setState(() => _copiedFlash = true);
    ref.read(appProvider.notifier).showToast(toastMsg);
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copiedFlash = false);
    });
  }

  void _insertPathReference() {
    final refPath = _resolvedPath.isNotEmpty ? _resolvedPath : widget.source.name;
    if (refPath.isEmpty) return;
    HapticFeedback.selectionClick();
    final ctrl = ref.read(appProvider.notifier);
    final existing = ctrl.getComposerDraftForActiveHost();
    final token = '@$refPath ';
    final next = existing.isEmpty
        ? token
        : (existing.endsWith(' ') || existing.endsWith('\n')
            ? '$existing$token'
            : '$existing $token');
    ctrl.setComposerDraftForActiveHost(next);
    ctrl.bumpDraftHydratedSignal();
    ctrl.showToast('已引用 @$refPath 到输入框', tone: ToastTone.info);
  }

  Future<void> _shareOrExport() async {
    HapticFeedback.selectionClick();
    final ctrl = ref.read(appProvider.notifier);
    final baseName = (_resolvedPath.isNotEmpty
            ? _resolvedPath.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull
            : null) ??
        widget.source.name;

    if (_imageBytes != null && _imageBytes!.isNotEmpty) {
      final mime = widget.source.mimeType ?? 'image/png';
      if (GrassBagNativeBridge.instance.isAndroidNative) {
        final ok = await GrassBagNativeBridge.instance.shareFileBytes(
          bytes: _imageBytes!,
          filename: baseName,
          mimeType: mime,
        );
        if (!ok) ctrl.showToast('调用系统分享失败');
      } else if (downloadWebBytes(baseName, _imageBytes!, mimeType: mime)) {
        ctrl.showToast(kIsWeb ? '已下载 $baseName' : '已保存至下载目录 · $baseName');
      } else {
        ctrl.showToast('当前环境暂不支持导出');
      }
      return;
    }

    if (_binary) {
      Uint8List? binBytes = _binaryBytes ?? widget.source.bytes;
      if ((binBytes == null || binBytes.isEmpty) && _resolvedPath.isNotEmpty) {
        binBytes = await ctrl.readWorkspaceFileBytes(_resolvedPath);
        if (!mounted) return;
        if (binBytes != null && binBytes.isNotEmpty) {
          _binaryBytes = binBytes;
        }
      }
      if (binBytes != null && binBytes.isNotEmpty) {
        final mime = widget.source.mimeType ?? 'application/octet-stream';
        if (GrassBagNativeBridge.instance.isAndroidNative) {
          final ok = await GrassBagNativeBridge.instance.shareFileBytes(
            bytes: binBytes,
            filename: baseName,
            mimeType: mime,
          );
          if (!ok) ctrl.showToast('调用系统分享失败');
        } else if (downloadWebBytes(baseName, binBytes, mimeType: mime)) {
          ctrl.showToast(kIsWeb ? '已下载 $baseName' : '已保存至下载目录 · $baseName');
        } else {
          ctrl.showToast('当前环境暂不支持导出');
        }
        return;
      }
      ctrl.showToast('暂无法导出该二进制文件');
      return;
    }

    final text = _activeCopyText;
    if (text.isEmpty) {
      ctrl.showToast('文件内容为空');
      return;
    }
    final mime = widget.source.mimeType ?? 'text/plain';
    if (GrassBagNativeBridge.instance.isAndroidNative) {
      final ok = await GrassBagNativeBridge.instance.shareTextFile(
        text: text,
        filename: baseName,
        mimeType: mime,
      );
      if (!ok) {
        await GrassBagNativeBridge.instance.shareText(text);
      }
    } else if (downloadWebBytes(
      baseName,
      Uint8List.fromList(utf8.encode(text)),
      mimeType: mime,
    )) {
      ctrl.showToast(kIsWeb ? '已下载 $baseName' : '已保存至下载目录 · $baseName');
    } else {
      await Clipboard.setData(ClipboardData(text: text));
      ctrl.showToast('已复制文件内容到剪贴板');
    }
  }

  Future<void> _saveImageToGallery() async {
    final bytes = _imageBytes;
    if (bytes == null || bytes.isEmpty || _savingImage) return;
    HapticFeedback.selectionClick();
    setState(() => _savingImage = true);
    try {
      final ctrl = ref.read(appProvider.notifier);
      final baseName = (_resolvedPath.isNotEmpty
              ? _resolvedPath.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull
              : null) ??
          widget.source.name;
      final mime = widget.source.mimeType ?? 'image/png';
      if (GrassBagNativeBridge.instance.isAndroidNative) {
        final res = await GrassBagNativeBridge.instance.saveImageBytes(
          bytes: bytes,
          filename: baseName,
          mimeType: mime,
        );
        if (!mounted) return;
        if (res.ok) {
          _flashTimer?.cancel();
          setState(() => _savedImageFlash = true);
          ctrl.showToast('已保存至相册 · ${res.location ?? baseName}');
          _flashTimer = Timer(const Duration(milliseconds: 1800), () {
            if (mounted) setState(() => _savedImageFlash = false);
          });
        } else {
          ctrl.showToast(res.error ?? '保存失败');
        }
      } else if (downloadWebBytes(baseName, bytes, mimeType: mime)) {
        ctrl.showToast(kIsWeb ? '已下载 $baseName' : '已保存至下载目录 · $baseName');
      }
    } finally {
      if (mounted) setState(() => _savingImage = false);
    }
  }

  WorkspaceDiffRecord? _findMatchingDiff(List<WorkspaceDiffRecord> diffs) {
    if (diffs.isEmpty || _resolvedPath.isEmpty) return null;
    final normTarget = _resolvedPath
        .trim()
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^\./+'), '')
        .replaceFirst(RegExp(r'^/+'), '');
    for (final d in diffs) {
      final dp = d.path
          .trim()
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'^\./+'), '')
          .replaceFirst(RegExp(r'^/+'), '');
      if (dp == normTarget || normTarget.endsWith('/$dp') || dp.endsWith('/$normTarget')) {
        return d;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final tier = ref.watch(appProvider.select((s) => s.glassTier));
    final matchingDiff = ref.watch(
      appProvider.select((s) => _findMatchingDiff(s.workspaceDiffs)),
    );
    final isImage = _fileKind == PreviewFileKind.rasterImage && _imageBytes != null;
    final isCodeLike = !isImage && !_binary && !_loading && _error == null;
    final showingDiff = _viewMode == _RichViewMode.diff && matchingDiff != null;
    final showingMarkdownRich =
        !showingDiff && _fileKind == PreviewFileKind.markdown && _viewMode == _RichViewMode.rich;
    final showingCsvRich = !showingDiff &&
        _fileKind == PreviewFileKind.csv &&
        _viewMode == _RichViewMode.rich &&
        _csvRows != null &&
        _csvRows!.isNotEmpty;
    final showingCodeLines = isCodeLike && !showingDiff && !showingMarkdownRich && !showingCsvRich;

    final langBadge = _fileKind == PreviewFileKind.svg
        ? 'SVG'
        : (_lang == 'plaintext' ? 'TEXT' : _lang.toUpperCase());
    final lineMeta = _totalLines != null && !_eof
        ? '${_lines.length} / $_totalLines 行'
        : '${_activeCodeLines.length} 行${_eof ? '' : '+'}';
    final sizeStr = formatPreviewBytes(_byteSize);
    final metaSummary = [
      langBadge,
      if (!isImage && !_binary && !_loading && _error == null) lineMeta,
      if (isImage && _imageDims != null)
        '${_imageDims!.width.round()} × ${_imageDims!.height.round()}',
      if (sizeStr.isNotEmpty) sizeStr,
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Top compact glass toolbar ─────────────────────────────────────────
        if (!_loading && _error == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(
                      color: t.fill1,
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(color: t.sep, width: 0.6),
                    ),
                    child: Text(
                      metaSummary,
                      style: TextStyle(
                        fontSize: 11.2,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: t.text2,
                      ),
                    ),
                  ),
                  if (isCodeLike && _supportsRichMode) ...[
                    const SizedBox(width: 6),
                    _PreviewToolbarPill(
                      icon: _viewMode == _RichViewMode.rich
                          ? CupertinoIcons.chevron_left_slash_chevron_right
                          : (_fileKind == PreviewFileKind.csv
                              ? CupertinoIcons.table
                              : CupertinoIcons.doc_richtext),
                      label: switch (_fileKind) {
                        PreviewFileKind.markdown =>
                          _viewMode == _RichViewMode.rich ? '源码' : '渲染预览',
                        PreviewFileKind.json =>
                          _viewMode == _RichViewMode.rich ? '原始' : '格式化',
                        PreviewFileKind.csv =>
                          _viewMode == _RichViewMode.rich ? '原始' : '表格视图',
                        _ => '切换视图',
                      },
                      active: _viewMode == _RichViewMode.rich,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          _viewMode = _viewMode == _RichViewMode.rich
                              ? _RichViewMode.source
                              : _RichViewMode.rich;
                          _recomputeSearchMatches();
                        });
                      },
                    ),
                  ],
                  if (matchingDiff != null) ...[
                    const SizedBox(width: 6),
                    _PreviewToolbarPill(
                      icon: CupertinoIcons.arrow_left_right,
                      label: showingDiff
                          ? '完整文件'
                          : 'Diff +${matchingDiff.added} -${matchingDiff.removed}',
                      active: showingDiff,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          _viewMode = showingDiff
                              ? (_supportsRichMode ? _RichViewMode.rich : _RichViewMode.source)
                              : _RichViewMode.diff;
                        });
                      },
                    ),
                  ],
                  if (showingCodeLines) ...[
                    const SizedBox(width: 6),
                    _PreviewToolbarPill(
                      icon: CupertinoIcons.search,
                      label: _showSearch && _matchLineIndices.isNotEmpty
                          ? '${_activeMatchCursor + 1}/${_matchLineIndices.length}'
                          : '查找',
                      active: _showSearch,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          _showSearch = !_showSearch;
                          if (!_showSearch) {
                            _searchQuery = '';
                            _searchCtrl.clear();
                            _recomputeSearchMatches();
                          }
                        });
                        if (_showSearch) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _searchFocus.requestFocus();
                          });
                        }
                      },
                    ),
                    const SizedBox(width: 6),
                    _PreviewToolbarPill(
                      icon: CupertinoIcons.text_alignleft,
                      label: _softWrap ? '自动换行' : '单行',
                      active: _softWrap,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _softWrap = !_softWrap);
                      },
                    ),
                    const SizedBox(width: 6),
                    _FontStepperPill(
                      fontSize: _fontSize,
                      onDecrease: () => _stepFontSize(-1.0),
                      onIncrease: () => _stepFontSize(1.0),
                    ),
                  ],
                ],
              ),
            ),
          ),

        // ── Collapsible in-file search bar ────────────────────────────────────
        GrassBagSmoothDisclosure(
          expanded: _showSearch && showingCodeLines,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: GrassBagTextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    placeholder: '在文件中查找关键词…',
                    insideGlass: true,
                    fontSize: 12.5,
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                    prefix: Padding(
                      padding: const EdgeInsets.only(left: 2, right: 6),
                      child: Icon(CupertinoIcons.search, size: 13.5, color: t.text3),
                    ),
                    suffix: _searchQuery.isEmpty
                        ? null
                        : GrassBagSpringTap(
                            pressedScale: 0.88,
                            enablePointerGlow: false,
                            onTap: () {
                              _searchCtrl.clear();
                              setState(() {
                                _searchQuery = '';
                                _recomputeSearchMatches();
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: Icon(CupertinoIcons.xmark_circle_fill, size: 14, color: t.text3),
                            ),
                          ),
                    onChanged: (v) {
                      setState(() {
                        _searchQuery = v;
                        _activeMatchCursor = 0;
                        _recomputeSearchMatches();
                      });
                      if (_matchLineIndices.isNotEmpty) {
                        _jumpToMatch(0);
                      }
                    },
                    onSubmitted: (_) => _jumpToMatch(1),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _searchQuery.trim().isEmpty
                      ? ''
                      : (_matchLineIndices.isEmpty
                          ? '0 匹配'
                          : '${_activeMatchCursor + 1}/${_matchLineIndices.length}'),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: _matchLineIndices.isEmpty && _searchQuery.trim().isNotEmpty
                        ? t.warn
                        : t.text3,
                  ),
                ),
                const SizedBox(width: 4),
                _MiniNavButton(
                  icon: CupertinoIcons.chevron_up,
                  enabled: _matchLineIndices.isNotEmpty,
                  tooltip: '上一个匹配',
                  onTap: () => _jumpToMatch(-1),
                ),
                const SizedBox(width: 4),
                _MiniNavButton(
                  icon: CupertinoIcons.chevron_down,
                  enabled: _matchLineIndices.isNotEmpty,
                  tooltip: '下一个匹配',
                  onTap: () => _jumpToMatch(1),
                ),
              ],
            ),
          ),
        ),

        // ── Main bounded viewport ─────────────────────────────────────────────
        Expanded(
          child: CustomPaint(
            foregroundPainter: tier == GrassBagGlassTier.solid
                ? null
                : GrassBagFresnelRimPainter(
                    isDark: t.isDark,
                    borderRadius: 16,
                    accent: (showingCodeLines && t.isDark) ? t.primaryHi : null,
                    innerWell: true,
                    frosted: tier == GrassBagGlassTier.frosted,
                    paintTopSheen: false,
                    strokeWidth: 0.8,
                  ),
            child: ClipRSuperellipse(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                decoration: ShapeDecoration(
                  color: (isImage || _binary || showingMarkdownRich)
                      ? t.fill1
                      : t.codeBg,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: tier == GrassBagGlassTier.solid
                        ? BorderSide(
                            color: (isImage || _binary || showingMarkdownRich)
                                ? t.sep
                                : (t.isDark
                                    ? Colors.white.withValues(alpha: 0.11)
                                    : t.sep),
                            width: 0.7,
                          )
                        : BorderSide.none,
                  ),
                ),
                child: AnimatedSwitcher(
                  duration: GrassBagMotion.duration(
                    context,
                    const Duration(milliseconds: 185),
                  ),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (currentChild, previousChildren) {
                    final curKey = currentChild?.key;
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        for (final prev in previousChildren)
                          if (prev.key != curKey) prev,
                        if (currentChild != null) currentChild,
                      ],
                    );
                  },
                  child: KeyedSubtree(
                    key: ValueKey(
                      _loading
                          ? 'fp-loading'
                          : (_error != null
                              ? 'fp-error'
                              : (isImage
                                  ? 'fp-img'
                                  : (_binary
                                      ? 'fp-bin'
                                      : (showingDiff
                                          ? 'fp-diff'
                                          : (showingMarkdownRich
                                              ? 'fp-md'
                                              : (showingCsvRich && _csvRows != null
                                                  ? 'fp-csv'
                                                  : 'fp-code')))))),
                    ),
                    child: _buildViewportContent(
                      context,
                      t: t,
                      tier: tier,
                      matchingDiff: matchingDiff,
                      isImage: isImage,
                      showingDiff: showingDiff,
                      showingMarkdownRich: showingMarkdownRich,
                      showingCsvRich: showingCsvRich,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),

        // ── Pagination & Load-more bar ────────────────────────────────────────
        GrassBagSmoothDisclosure(
          expanded: _loadMoreError != null,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: GrassBagStatusBanner(
              tone: GrassBagBannerTone.warn,
              message: '继续加载失败：${_loadMoreError ?? ''}',
              borderRadius: 12,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            ),
          ),
        ),
        GrassBagSmoothDisclosure(
          expanded: isCodeLike && !showingDiff && !_eof,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: GrassBagSecondaryGlassButton(
              label: _loadingMore
                  ? '正在加载更多行…'
                  : (_loadMoreError != null
                      ? '重试加载（第 $_nextOffset 行起）'
                      : (_totalLines != null
                          ? '加载下 400 行（已加载 ${_lines.length} / $_totalLines 行）'
                          : '加载下 400 行（从第 $_nextOffset 行起）')),
              icon: _loadMoreError != null ? CupertinoIcons.refresh : CupertinoIcons.chevron_down,
              height: 36,
              tier: tier,
              insideGlass: true,
              accentForeground: true,
              enabled: !_loadingMore,
              onTap: _loadingMore ? null : _loadMore,
            ),
          ),
        ),

        // ── Pinned Footer Actions (never auto-pops on copy!) ──────────────────
        const SizedBox(height: 10),
        Row(
          children: [
            if (_resolvedPath.isNotEmpty) ...[
              GrassBagSecondaryGlassButton(
                label: '引用',
                icon: CupertinoIcons.at,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                height: 38,
                tier: tier,
                insideGlass: true,
                accentForeground: true,
                onTap: _insertPathReference,
              ),
              const SizedBox(width: 8),
            ],
            if (isImage) ...[
              Expanded(
                child: GrassBagSecondaryGlassButton(
                  label: '分享',
                  icon: CupertinoIcons.share,
                  height: 38,
                  tier: tier,
                  insideGlass: true,
                  onTap: _shareOrExport,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GrassBagPrimaryGlassButton(
                  label: _savingImage
                      ? '保存中…'
                      : (_savedImageFlash ? '已保存' : '保存图片'),
                  icon: _savedImageFlash
                      ? CupertinoIcons.checkmark
                      : CupertinoIcons.arrow_down_to_line,
                  height: 38,
                  tier: tier,
                  insideGlass: true,
                  enabled: !_savingImage,
                  onTap: _savingImage ? null : _saveImageToGallery,
                ),
              ),
            ] else ...[
              Expanded(
                child: GrassBagSecondaryGlassButton(
                  label: '分享 / 导出',
                  icon: CupertinoIcons.share,
                  height: 38,
                  tier: tier,
                  insideGlass: true,
                  enabled: !_loading && _error == null,
                  onTap: (_loading || _error != null) ? null : _shareOrExport,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GrassBagPrimaryGlassButton(
                  label: _copiedFlash
                      ? '已复制'
                      : (_binary
                          ? '复制路径'
                          : (showingDiff
                              ? '复制 Diff'
                              : (_eof ? '复制全部' : '复制已加载'))),
                  icon: _copiedFlash ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
                  height: 38,
                  tier: tier,
                  insideGlass: true,
                  enabled: !_loading && _error == null,
                  onTap: (_loading || _error != null)
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          final copyText = _binary
                              ? (_resolvedPath.isNotEmpty ? _resolvedPath : widget.source.name)
                              : (showingDiff ? matchingDiff.unifiedDiff : _activeCopyText);
                          Clipboard.setData(ClipboardData(text: copyText));
                          _triggerCopiedFlash(
                            _binary
                                ? '已复制路径'
                                : (showingDiff
                                    ? '已复制 Diff'
                                    : (_eof ? '已复制文件内容' : '已复制已加载片段')),
                          );
                        },
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildViewportContent(
    BuildContext context, {
    required GrassBagTokens t,
    required GrassBagGlassTier tier,
    required WorkspaceDiffRecord? matchingDiff,
    required bool isImage,
    required bool showingDiff,
    required bool showingMarkdownRich,
    required bool showingCsvRich,
  }) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GrassBagActivityIndicator(
              radius: 11,
              color: t.isDark ? Colors.white70 : t.primary,
            ),
            const SizedBox(height: 10),
            Text(
              '正在读取 ${widget.source.name}…',
              style: TextStyle(fontSize: 12.5, color: t.text3),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.exclamationmark_triangle, size: 28, color: t.err),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: t.isDark ? const Color(0xFFFF8582) : t.err,
                ),
              ),
              const SizedBox(height: 12),
              GrassBagSecondaryGlassButton(
                label: '重新加载',
                icon: CupertinoIcons.refresh,
                height: 34,
                tier: tier,
                insideGlass: true,
                onTap: _loadInitial,
              ),
            ],
          ),
        ),
      );
    }

    if (isImage) {
      final bytes = _imageBytes!;
      return _PreviewInteractiveImageStage(
        bytes: bytes,
        name: widget.source.name,
        mimeType: widget.source.mimeType,
        heroTag: 'file-preview-img-${widget.source.path ?? widget.source.name}-${bytes.length}',
        isDark: t.isDark,
        errColor: t.err,
      );
    }

    if (_binary) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                previewFileIcon(_effectiveName, mimeType: widget.source.mimeType),
                size: 36,
                color: t.text3,
              ),
              const SizedBox(height: 10),
              Text(
                '二进制文件，不支持纯文本预览',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: t.text2),
              ),
              const SizedBox(height: 5),
              Text(
                _resolvedPath.isNotEmpty
                    ? '可点击下方「分享 / 导出」或引用路径到对话检查'
                    : '可点击下方「分享 / 导出」使用外部应用打开',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: t.text3),
              ),
            ],
          ),
        ),
      );
    }

    if (showingDiff && matchingDiff != null) {
      return _InlineDiffPreviewPane(record: matchingDiff, fontSize: _fontSize);
    }

    if (showingMarkdownRich) {
      return _RichMarkdownPreviewPane(markdown: _rawText);
    }

    if (showingCsvRich && _csvRows != null) {
      return _CsvTablePreviewPane(rows: _csvRows!);
    }

    final lines = _activeCodeLines;
    if (lines.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.doc, size: 28, color: t.text3),
            const SizedBox(height: 8),
            Text(
              '空文件（0 行）',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: t.text3),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (ctx, box) {
        final textScaler = MediaQuery.textScalerOf(ctx);
        final lineExtent = _lineExtentFor(ctx);
        final maxLineNum = _firstLineNumber + lines.length - 1;
        final digits = math.max(2, maxLineNum.toString().length);
        final gutterW = (digits * textScaler.scale(_fontSize * 0.62) + 16.0)
            .ceilToDouble()
            .clamp(32.0, 78.0);
        final availW = box.maxWidth.isFinite ? box.maxWidth : 320.0;
        final matchBg = t.isDark ? const Color(0xCC9A6700) : const Color(0xFFFFE58F);
        final matchFg = t.isDark ? Colors.white : const Color(0xFF1F2937);
        final activeMatchLine = _matchLineIndices.isNotEmpty
            ? _matchLineIndices[_activeMatchCursor.clamp(0, _matchLineIndices.length - 1)]
            : -1;
        final usePrettyJson =
            _fileKind == PreviewFileKind.json && _viewMode == _RichViewMode.rich;
        final effectiveBlockStates = usePrettyJson ? const <bool>[] : _blockCommentStates;
        final targetStart = widget.initialLine;
        final targetEnd = widget.highlightEndLine ?? targetStart;

        Widget buildLineRow(int idx, {required bool wrap}) {
          final realLineNum = _firstLineNumber + idx;
          final isAnchorHighlighted = targetStart != null &&
              targetEnd != null &&
              realLineNum >= targetStart &&
              realLineNum <= targetEnd;
          final isActiveSearchRow = idx == activeMatchLine;
          final rowBg = isActiveSearchRow
              ? t.warn.withValues(alpha: t.isDark ? 0.22 : 0.18)
              : (isAnchorHighlighted
                  ? t.primary.withValues(alpha: t.isDark ? 0.20 : 0.13)
                  : null);
          final inBlock = idx < effectiveBlockStates.length ? effectiveBlockStates[idx] : false;
          final highlighted = highlightCodeLineIncremental(
            lines[idx],
            _lang,
            isDark: t.isDark,
            fontSize: _fontSize,
            height: 1.52,
            inBlockComment: inBlock,
            searchQuery: _searchQuery,
            matchBg: matchBg,
            matchFg: matchFg,
          );

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0.5),
            decoration: BoxDecoration(
              color: rowBg,
              border: isAnchorHighlighted
                  ? Border(left: BorderSide(color: t.primary, width: 2.5))
                  : null,
            ),
            child: Row(
              crossAxisAlignment: wrap ? CrossAxisAlignment.start : CrossAxisAlignment.center,
              children: [
                SelectionContainer.disabled(
                  child: SizedBox(
                    width: gutterW,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Text(
                        '$realLineNum',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: math.max(9.5, _fontSize - 1.5),
                          height: 1.52,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: isAnchorHighlighted
                              ? (t.isDark ? t.primaryHi : t.primary)
                              : t.text3.withValues(alpha: 0.56),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Text.rich(
                    highlighted.span,
                    softWrap: wrap,
                    maxLines: wrap ? null : 1,
                    overflow: wrap ? TextOverflow.clip : TextOverflow.visible,
                  ),
                ),
              ],
            ),
          );
        }

        if (_softWrap) {
          return SelectionArea(
            contextMenuBuilder: buildGrassBagSelectableContextMenu,
            child: Scrollbar(
              controller: _vScrollCtrl,
              child: ListView.builder(
                controller: _vScrollCtrl,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: lines.length,
                physics: const BouncingScrollPhysics(),
                itemBuilder: (_, idx) => buildLineRow(idx, wrap: true),
              ),
            ),
          );
        }

        // CRITICAL: SelectionArea is placed OUTSIDE horizontal SingleChildScrollView
        // so Android horizontal swipe NEVER gets stolen by SelectableRegion!
        // Also compute exact width from longest line + gutter (zero phantom overflow on short files!).
        final fontScaleRatio = textScaler.scale(_fontSize) / 12.0;
        final scaledMaxCodePx = (_maxLinePx * fontScaleRatio).clamp(160.0, 12000.0);
        final contentW = math.max(availW, scaledMaxCodePx + gutterW + 36.0);

        return SelectionArea(
          contextMenuBuilder: buildGrassBagSelectableContextMenu,
          child: Scrollbar(
            controller: _hScrollCtrl,
            notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: _hScrollCtrl,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: SizedBox(
                width: contentW,
                height: box.maxHeight,
                child: Scrollbar(
                  controller: _vScrollCtrl,
                  child: ListView.builder(
                    controller: _vScrollCtrl,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: lines.length,
                    itemExtent: lineExtent,
                    physics: const BouncingScrollPhysics(),
                    itemBuilder: (_, idx) => buildLineRow(idx, wrap: false),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SubtleCheckerboardPainter extends CustomPainter {
  const _SubtleCheckerboardPainter({required this.isDark});
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    const sq = 14.0;
    final c1 = isDark ? const Color(0xFF1A1F29) : const Color(0xFFE7EBF2);
    final c2 = isDark ? const Color(0xFF232A37) : const Color(0xFFD5DCE7);
    final p1 = Paint()..color = c1;
    final p2 = Paint()..color = c2;
    canvas.drawRect(Offset.zero & size, p1);
    final cols = (size.width / sq).ceil();
    final rows = (size.height / sq).ceil();
    for (var r = 0; r < rows; r++) {
      for (var c = (r.isEven ? 0 : 1); c < cols; c += 2) {
        canvas.drawRect(Rect.fromLTWH(c * sq, r * sq, sq, sq), p2);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SubtleCheckerboardPainter old) => old.isDark != isDark;
}

class _PreviewToolbarPill extends StatelessWidget {
  const _PreviewToolbarPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final fg = active ? (t.isDark ? t.primaryHi : t.primary) : t.text2;
    return GrassBagSpringTap(
      onTap: onTap,
      pressedScale: 0.94,
      enablePointerGlow: false,
      haptic: true,
      child: GrassBagFresnelGlassSurface(
        isPill: true,
        innerWell: true,
        interactive: false,
        tintColor: active ? t.primarySoft : null,
        padding: const EdgeInsets.symmetric(horizontal: 9.5, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4.5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.4,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewInteractiveImageStage extends StatefulWidget {
  const _PreviewInteractiveImageStage({
    required this.bytes,
    required this.name,
    required this.mimeType,
    required this.heroTag,
    required this.isDark,
    required this.errColor,
  });

  final Uint8List bytes;
  final String name;
  final String? mimeType;
  final Object heroTag;
  final bool isDark;
  final Color errColor;

  @override
  State<_PreviewInteractiveImageStage> createState() =>
      _PreviewInteractiveImageStageState();
}

class _PreviewInteractiveImageStageState extends State<_PreviewInteractiveImageStage>
    with SingleTickerProviderStateMixin {
  final TransformationController _ctrl = TransformationController();
  late final AnimationController _zoomCtrl;
  late final CurvedAnimation _zoomCurve;
  Animation<Matrix4>? _zoomAnim;
  Offset _doubleTapPos = Offset.zero;
  Size _viewportSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _zoomCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(() {
        final anim = _zoomAnim;
        if (anim != null) _ctrl.value = anim.value;
      });
    _zoomCurve = CurvedAnimation(parent: _zoomCtrl, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _zoomCurve.dispose();
    _zoomCtrl.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _animateTo(Matrix4 end) {
    if (mounted && MediaQuery.disableAnimationsOf(context)) {
      _ctrl.value = end;
      return;
    }
    _zoomAnim = Matrix4Tween(begin: Matrix4.copy(_ctrl.value), end: end)
        .animate(_zoomCurve);
    _zoomCtrl.forward(from: 0.0);
  }

  void _handleDoubleTap() {
    if (_ctrl.value.getMaxScaleOnAxis() > 1.05) {
      _animateTo(Matrix4.identity());
      return;
    }
    const targetScale = 2.4;
    var tx = -_doubleTapPos.dx * (targetScale - 1.0);
    var ty = -_doubleTapPos.dy * (targetScale - 1.0);
    if (_viewportSize.width > 0 && _viewportSize.height > 0) {
      tx = tx.clamp(-_viewportSize.width * (targetScale - 1.0), 0.0);
      ty = ty.clamp(-_viewportSize.height * (targetScale - 1.0), 0.0);
    }
    _animateTo(
      Matrix4.identity()
        ..translateByDouble(tx, ty, 0.0, 1.0)
        ..scaleByDouble(targetScale, targetScale, 1.0, 1.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tier = resolveAmbientGlassTier(context);
    return LayoutBuilder(
      builder: (ctx, box) {
        _viewportSize = box.biggest;
        return Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                painter: _SubtleCheckerboardPainter(isDark: widget.isDark),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
              onDoubleTap: _handleDoubleTap,
              child: InteractiveViewer(
                transformationController: _ctrl,
                minScale: 0.75,
                maxScale: 4.5,
                onInteractionStart: (_) {
                  if (_zoomCtrl.isAnimating) _zoomCtrl.stop();
                },
                onInteractionEnd: (_) {
                  if (_ctrl.value.getMaxScaleOnAxis() < 0.99) {
                    _animateTo(Matrix4.identity());
                  }
                },
                child: Center(
                  child: Hero(
                    tag: widget.heroTag,
                    child: Image.memory(
                      widget.bytes,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => Text(
                        '图片解码失败',
                        style: TextStyle(fontSize: 13, color: widget.errColor),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 10,
              bottom: 10,
              child: GrassBagGlassPillButton(
                tier: tier,
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tintColor: Colors.black.withValues(alpha: 0.56),
                onTap: () => showImagePreviewDialog(
                  context,
                  bytes: widget.bytes,
                  title: widget.name,
                  mimeType: widget.mimeType,
                  heroTag: widget.heroTag,
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      CupertinoIcons.arrow_up_left_arrow_down_right,
                      size: 12,
                      color: Colors.white,
                    ),
                    SizedBox(width: 5),
                    Text(
                      '全屏灯箱',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FontStepperPill extends StatelessWidget {
  const _FontStepperPill({
    required this.fontSize,
    required this.onDecrease,
    required this.onIncrease,
  });

  final double fontSize;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return GrassBagFresnelGlassSurface(
      isPill: true,
      innerWell: true,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GrassBagSpringTap(
            enabled: fontSize > 10.0,
            pressedScale: 0.88,
            enablePointerGlow: false,
            haptic: true,
            onTap: onDecrease,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                'A-',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: fontSize > 10.0 ? t.text2 : t.text3.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
          Text(
            '${fontSize.round()}',
            style: TextStyle(
              fontSize: 10.8,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: t.text3,
            ),
          ),
          GrassBagSpringTap(
            enabled: fontSize < 18.0,
            pressedScale: 0.88,
            enablePointerGlow: false,
            haptic: true,
            onTap: onIncrease,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                'A+',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: fontSize < 18.0 ? t.text2 : t.text3.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniNavButton extends StatelessWidget {
  const _MiniNavButton({
    required this.icon,
    required this.enabled,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: GrassBagSpringTap(
        enabled: enabled,
        onTap: enabled ? onTap : () {},
        pressedScale: 0.9,
        enablePointerGlow: false,
        child: GrassBagFresnelGlassSurface(
          isCircle: true,
          innerWell: true,
          width: 30,
          height: 30,
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 13,
            color: enabled ? t.text2 : t.text3.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}

/// Self-contained rich Markdown renderer for `.md` files inside the unified previewer
/// (supports headings, paragraphs, bold/italic/code/links, syntax-highlighted code blocks,
/// blockquotes, lists, checklists, tables, horizontal rules, and clickable images).
class _RichMarkdownPreviewPane extends StatelessWidget {
  const _RichMarkdownPreviewPane({required this.markdown});
  final String markdown;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final lines = markdown.replaceAll('\r\n', '\n').split('\n');
    final widgets = <Widget>[];

    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        i++;
        continue;
      }

      // Fenced code block
      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        final fence = trimmed.substring(0, 3);
        final lang = trimmed.substring(3).trim();
        final codeLines = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith(fence)) {
          codeLines.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++;
        final blockStates = computeBlockCommentStates(codeLines, lang);
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Container(
              decoration: BoxDecoration(
                color: t.codeBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.sep, width: 0.6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (lang.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: t.codeBar,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                      ),
                      child: Text(
                        lang,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: t.text3,
                        ),
                      ),
                    ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var k = 0; k < codeLines.length; k++)
                          Text.rich(
                            highlightCodeLineIncremental(
                              codeLines[k],
                              lang,
                              isDark: t.isDark,
                              fontSize: 11.8,
                              height: 1.48,
                              inBlockComment: k < blockStates.length ? blockStates[k] : false,
                            ).span,
                            softWrap: false,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        continue;
      }

      // Horizontal rule
      if (RegExp(r'^(?:-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 0.8, thickness: 0.8, color: t.sepStrong),
          ),
        );
        i++;
        continue;
      }

      // Headings
      final hMatch = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
      if (hMatch != null) {
        final level = hMatch.group(1)!.length;
        final headingText = hMatch.group(2)!.trim();
        final fs = switch (level) {
          1 => 19.5,
          2 => 16.8,
          3 => 15.0,
          _ => 13.8,
        };
        widgets.add(
          Padding(
            padding: EdgeInsets.only(top: widgets.isEmpty ? 0 : 12, bottom: 5),
            child: Text.rich(
              _buildInlineMdSpan(headingText, t,
                  baseSize: fs, baseWeight: FontWeight.w700, baseColor: t.text),
            ),
          ),
        );
        i++;
        continue;
      }

      // Standalone image `![alt](https://...)`
      final imgMatch = RegExp(r'^!\[([^\]]*)\]\((https?://[^)\s]+)\)$').firstMatch(trimmed);
      if (imgMatch != null) {
        final alt = imgMatch.group(1)!.trim();
        final url = imgMatch.group(2)!.trim();
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: GestureDetector(
              onTap: () => showImagePreviewDialog(
                context,
                url: url,
                title: alt.isEmpty ? '图片预览' : alt,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Container(
                      padding: const EdgeInsets.all(10),
                      color: t.fill2,
                      child: Text(
                        alt.isEmpty ? url : alt,
                        style: TextStyle(fontSize: 12, color: t.text3),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        i++;
        continue;
      }

      // Pipe table
      if (trimmed.startsWith('|') &&
          i + 1 < lines.length &&
          RegExp(r'^\|?[\s:|-]+\|[\s:|-]*$').hasMatch(lines[i + 1].trim())) {
        final tableRows = <List<String>>[];
        List<String> splitPipe(String r) {
          var s = r.trim();
          if (s.startsWith('|')) s = s.substring(1);
          if (s.endsWith('|')) s = s.substring(0, s.length - 1);
          return s.split('|').map((c) => c.trim()).toList();
        }

        tableRows.add(splitPipe(lines[i]));
        i += 2; // skip separator
        while (i < lines.length && lines[i].trim().contains('|')) {
          tableRows.add(splitPipe(lines[i]));
          i++;
        }
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _CompactTableCard(rows: tableRows),
          ),
        );
        continue;
      }

      // Blockquote
      if (trimmed.startsWith('>')) {
        final quoteLines = <String>[];
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          quoteLines.add(lines[i].trim().replaceFirst(RegExp(r'^>\s?'), ''));
          i++;
        }
        widgets.add(
          Container(
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.fromLTRB(11, 6, 10, 6),
            decoration: BoxDecoration(
              color: t.primary.withValues(alpha: t.isDark ? 0.10 : 0.06),
              border: Border(left: BorderSide(color: t.primary, width: 3)),
              borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
            ),
            child: Text.rich(
              _buildInlineMdSpan(quoteLines.join('\n'), t,
                  baseSize: 13.0, baseColor: t.text2),
            ),
          ),
        );
        continue;
      }

      // Bullet / checklist / numbered list item
      final listMatch = RegExp(r'^(\s*)([-*+]|\d+\.)\s+(.*)$').firstMatch(line);
      if (listMatch != null) {
        final indent = (listMatch.group(1)!.length ~/ 2).clamp(0, 4) * 14.0;
        final marker = listMatch.group(2)!;
        var body = listMatch.group(3)!;
        bool? checked;
        if (body.startsWith('[ ] ')) {
          checked = false;
          body = body.substring(4);
        } else if (body.startsWith('[x] ') || body.startsWith('[X] ')) {
          checked = true;
          body = body.substring(4);
        }
        widgets.add(
          Padding(
            padding: EdgeInsets.fromLTRB(indent, 2.5, 0, 2.5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (checked != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3, right: 6),
                    child: Icon(
                      checked
                          ? CupertinoIcons.checkmark_square_fill
                          : CupertinoIcons.square,
                      size: 14,
                      color: checked ? t.ok : t.text3,
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 1, right: 7),
                    child: Text(
                      marker.endsWith('.') ? marker : '•',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: t.primary,
                      ),
                    ),
                  ),
                Expanded(
                  child: Text.rich(
                    _buildInlineMdSpan(body, t, baseSize: 13.4, baseColor: t.text),
                  ),
                ),
              ],
            ),
          ),
        );
        i++;
        continue;
      }

      // Paragraph
      final para = <String>[line];
      i++;
      while (i < lines.length) {
        final next = lines[i].trim();
        if (next.isEmpty ||
            next.startsWith('#') ||
            next.startsWith('```') ||
            next.startsWith('~~~') ||
            next.startsWith('>') ||
            next.startsWith('|') ||
            RegExp(r'^([-*+]|\d+\.)\s+').hasMatch(next)) {
          break;
        }
        para.add(lines[i]);
        i++;
      }
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text.rich(
            _buildInlineMdSpan(para.join('\n'), t, baseSize: 13.5, baseColor: t.text),
          ),
        ),
      );
    }

    return SelectionArea(
      contextMenuBuilder: buildGrassBagSelectableContextMenu,
      child: ListView(
        padding: const EdgeInsets.all(14),
        physics: const BouncingScrollPhysics(),
        children: widgets,
      ),
    );
  }

  TextSpan _buildInlineMdSpan(
    String text,
    GrassBagTokens t, {
    required double baseSize,
    required Color baseColor,
    FontWeight baseWeight = FontWeight.w400,
  }) {
    final baseStyle = TextStyle(
      fontSize: baseSize,
      height: 1.56,
      fontWeight: baseWeight,
      color: baseColor,
    );
    final spans = <InlineSpan>[];
    final tokenRe = RegExp(
      r'`([^`]+)`|\*\*([^*]+)\*\*|__([^_]+)__|~~([^~]+)~~|\*([^*]+)\*|\[([^\]]+)\]\(([^)]+)\)',
    );
    var cursor = 0;
    for (final m in tokenRe.allMatches(text)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, m.start)));
      }
      if (m.group(1) != null) {
        spans.add(
          TextSpan(
            text: m.group(1),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: baseSize - 0.8,
              backgroundColor: t.fill2,
              color: t.isDark ? t.primaryHi : t.primary,
            ),
          ),
        );
      } else if (m.group(2) != null || m.group(3) != null) {
        spans.add(
          TextSpan(
            text: m.group(2) ?? m.group(3),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      } else if (m.group(4) != null) {
        spans.add(
          TextSpan(
            text: m.group(4),
            style: TextStyle(
              decoration: TextDecoration.lineThrough,
              color: t.text3,
            ),
          ),
        );
      } else if (m.group(5) != null) {
        spans.add(
          TextSpan(
            text: m.group(5),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      } else if (m.group(6) != null && m.group(7) != null) {
        spans.add(
          TextSpan(
            text: m.group(6),
            style: TextStyle(
              color: t.isDark ? t.primaryHi : t.primary,
              decoration: TextDecoration.underline,
            ),
          ),
        );
      }
      cursor = m.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: baseStyle, children: spans);
  }
}

/// Interactive horizontal+vertical scrollable CSV/TSV table previewer.
class _CsvTablePreviewPane extends StatelessWidget {
  const _CsvTablePreviewPane({required this.rows});
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: SelectionArea(
        contextMenuBuilder: buildGrassBagSelectableContextMenu,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: _CompactTableCard(rows: rows),
        ),
      ),
    );
  }
}

class _CompactTableCard extends StatelessWidget {
  const _CompactTableCard({required this.rows});
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    if (rows.isEmpty) return const SizedBox.shrink();
    final colCount = rows.fold<int>(0, (m, r) => math.max(m, r.length));
    if (colCount == 0) return const SizedBox.shrink();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(color: t.sep, width: 0.6),
          children: [
            for (var r = 0; r < rows.length; r++)
              TableRow(
                decoration: BoxDecoration(
                  color: r == 0
                      ? (t.isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : t.primarySoft.withValues(alpha: 0.55))
                      : (r.isOdd
                          ? Colors.transparent
                          : (t.isDark
                              ? Colors.white.withValues(alpha: 0.045)
                              : Colors.black.withValues(alpha: 0.028))),
                ),
                children: [
                  for (var c = 0; c < colCount; c++)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6.5),
                        child: Text(
                          c < rows[r].length ? rows[r][c] : '',
                          style: TextStyle(
                            fontSize: 11.8,
                            fontWeight: r == 0 ? FontWeight.w700 : FontWeight.w400,
                            color: r == 0 ? t.text : t.text2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// In-place Diff view toggled inside the unified previewer (zero post-pop context bug!).
class _InlineDiffPreviewPane extends StatelessWidget {
  const _InlineDiffPreviewPane({
    required this.record,
    required this.fontSize,
  });

  final WorkspaceDiffRecord record;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    final raw = record.unifiedDiff.trim();
    if (raw.isEmpty) {
      return Center(
        child: Text(
          '暂无 Diff 补丁内容',
          style: TextStyle(fontSize: 12.5, color: t.text3),
        ),
      );
    }
    final lines = raw.split('\n');
    return LayoutBuilder(
      builder: (ctx, box) {
        var maxPx = box.maxWidth.isFinite ? box.maxWidth : 320.0;
        for (final l in lines) {
          final px = estimateMonospaceLinePx(l, fontSize: fontSize) + 40.0;
          if (px > maxPx) maxPx = px;
        }
        return SelectionArea(
          contextMenuBuilder: buildGrassBagSelectableContextMenu,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: SizedBox(
              width: maxPx.clamp(240.0, 9600.0),
              height: box.maxHeight,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: lines.length,
                physics: const BouncingScrollPhysics(),
                itemBuilder: (_, idx) {
                  final line = expandTabs(lines[idx]);
                  final isAdd = line.startsWith('+') && !line.startsWith('+++');
                  final isDel = line.startsWith('-') && !line.startsWith('---');
                  final isHunk = line.startsWith('@@');
                  final isMeta = line.startsWith('diff ') ||
                      line.startsWith('index ') ||
                      line.startsWith('---') ||
                      line.startsWith('+++');
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1.5),
                    color: isAdd
                        ? t.ok.withValues(alpha: t.isDark ? 0.16 : 0.12)
                        : (isDel
                            ? t.err.withValues(alpha: t.isDark ? 0.16 : 0.12)
                            : (isHunk
                                ? t.primary.withValues(alpha: t.isDark ? 0.14 : 0.09)
                                : null)),
                    child: Text(
                      line,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: fontSize,
                        height: 1.48,
                        fontWeight: isHunk ? FontWeight.w600 : FontWeight.w400,
                        color: isAdd
                            ? (t.isDark ? const Color(0xFF6EE7B7) : const Color(0xFF0D7A4F))
                            : (isDel
                                ? (t.isDark ? const Color(0xFFFCA5A5) : const Color(0xFFC42B2B))
                                : (isHunk
                                    ? (t.isDark ? const Color(0xFF93C5FD) : const Color(0xFF2563EB))
                                    : (isMeta ? t.text3 : t.codeFg))),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
