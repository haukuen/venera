import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/comic_export.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// The scope of comics to export.
enum ExportScope {
  /// Export all local comics.
  all,

  /// Export only the selected comics.
  selected,
}

/// A dialog that allows the user to export local comics.
///
/// Shows scope selection (all vs selected), handles the export process,
/// and displays progress or error messages.
class ExportComicsDialog extends StatefulWidget {
  /// The comics that are currently selected for export.
  /// If null or empty, the "selected" option will be disabled.
  final List<LocalComic>? selectedComics;

  const ExportComicsDialog({
    super.key,
    this.selectedComics,
  });

  @override
  State<ExportComicsDialog> createState() => _ExportComicsDialogState();
}

class _ExportComicsDialogState extends State<ExportComicsDialog> {
  ExportScope _scope = ExportScope.all;
  bool _isExporting = false;
  int _current = 0;
  int _total = 0;
  String? _error;

  bool get _hasSelectedComics =>
      widget.selectedComics != null && widget.selectedComics!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "Export Comics".tl,
      content: _isExporting ? _buildProgress() : _buildSelection(),
      actions: _isExporting ? [] : _buildActions(),
    );
  }

  Widget _buildSelection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RadioGroup<ExportScope>(
          groupValue: _scope,
          onChanged: (value) {
            if (value == null) return;
            // Disable "selected" if no comics are selected
            if (value == ExportScope.selected && !_hasSelectedComics) return;
            setState(() {
              _scope = value;
            });
          },
          child: Column(
            children: [
              RadioListTile<ExportScope>(
                title: Text("Export All".tl),
                value: ExportScope.all,
              ),
              RadioListTile<ExportScope>(
                title: Text("Export Selected".tl),
                value: ExportScope.selected,
                enabled: _hasSelectedComics,
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 16, right: 16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget _buildProgress() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LinearProgressIndicator(
          value: _total > 0 ? _current / _total : null,
        ),
        const SizedBox(height: 16),
        Text("$_current / $_total"),
      ],
    ).paddingHorizontal(16);
  }

  List<Widget> _buildActions() {
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text("Cancel".tl),
      ),
      FilledButton(
        onPressed: _startExport,
        child: Text("Export".tl),
      ),
    ];
  }

  Future<void> _startExport() async {
    // 1. Get the list of comics to export
    List<LocalComic> comics;
    if (_scope == ExportScope.all) {
      comics = LocalManager().getComics(LocalSortType.timeDesc);
    } else {
      comics = widget.selectedComics ?? [];
    }

    if (comics.isEmpty) {
      setState(() {
        _error = "No comics to export".tl;
      });
      return;
    }

    // 2. Export to a temporary file first
    final tempFile = File(
      FilePath.join(App.cachePath, 'comics_export.venera-comics'),
    );

    setState(() {
      _isExporting = true;
      _total = comics.length;
      _current = 0;
      _error = null;
    });

    try {
      await ComicExporter.exportComics(
        comics: comics,
        outputPath: tempFile.path,
        onProgress: (progress, total) {
          if (!mounted) return;
          setState(() {
            _current = progress;
          });
        },
      );

      if (!mounted) return;

      // 3. Save to user-selected location
      final saved = await saveFile(
        file: tempFile,
        filename: "comics.venera-comics",
      );

      if (!saved) {
        // User cancelled the save dialog — stay on the current state
        setState(() {
          _isExporting = false;
        });
        return;
      }

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Export completed".tl)),
        );
      }
    } catch (e, s) {
      Log.error("Export Comics", e, s);
      setState(() {
        _isExporting = false;
        _error = "${"Export failed".tl}: $e";
      });
    } finally {
      tempFile.deleteIgnoreError();
    }
  }
}
