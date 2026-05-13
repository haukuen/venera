import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/comic_import.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// A dialog that allows the user to import comics from a .venera-comics file.
///
/// Handles file selection, displays import progress, and shows the final result
/// including counts of imported, skipped comics and any errors.
class ImportComicsDialog extends StatefulWidget {
  const ImportComicsDialog({super.key});

  @override
  State<ImportComicsDialog> createState() => _ImportComicsDialogState();
}

class _ImportComicsDialogState extends State<ImportComicsDialog> {
  bool _isImporting = false;
  bool _cancelled = false;
  int _current = 0;
  int _total = 0;
  String? _error;
  ImportResult? _result;

  @override
  Widget build(BuildContext context) {
    if (_result != null) {
      return _buildResult();
    }
    return ContentDialog(
      title: "Import Migrated Comics".tl,
      content: _isImporting ? _buildProgress() : _buildInitial(),
      actions: _isImporting ? _buildProgressActions() : _buildActions(),
    );
  }

  Widget _buildInitial() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          "Select a .venera-comics file to import.".tl,
        ).paddingHorizontal(16),
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
        LinearProgressIndicator(value: _total > 0 ? _current / _total : null),
        const SizedBox(height: 16),
        Text("$_current / $_total"),
      ],
    ).paddingHorizontal(16);
  }

  Widget _buildResult() {
    return ContentDialog(
      title: "Import Result".tl,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("${"Imported".tl}: ${_result!.imported}").paddingHorizontal(16),
          Text("${"Skipped".tl}: ${_result!.skipped}").paddingHorizontal(16),
          if (_result!.errors.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              "Errors:".tl,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ).paddingHorizontal(16),
            ..._result!.errors.map((e) => Text("• $e").paddingHorizontal(16)),
          ],
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text("OK".tl),
        ),
      ],
    );
  }

  List<Widget> _buildActions() {
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text("Cancel".tl),
      ),
      FilledButton(onPressed: _startImport, child: Text("Select File".tl)),
    ];
  }

  List<Widget> _buildProgressActions() {
    return [
      TextButton(
        onPressed: () {
          setState(() {
            _cancelled = true;
          });
        },
        child: Text("Cancel".tl),
      ),
    ];
  }

  Future<void> _startImport() async {
    final file = await selectFile(ext: ['venera-comics']);
    if (file == null) return;

    setState(() {
      _isImporting = true;
      _cancelled = false;
      _error = null;
    });

    try {
      final result = await ComicImporter.importComics(
        filePath: file.path,
        onProgress: (current, total) {
          if (!mounted) return;
          setState(() {
            _current = current;
            _total = total;
          });
        },
        isCancelled: () => _cancelled,
      );

      if (!mounted) return;

      if (_cancelled) {
        setState(() {
          _isImporting = false;
          _cancelled = false;
          _result = result;
        });
        return;
      }

      setState(() {
        _isImporting = false;
        _result = result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isImporting = false;
        _error = "${"Import failed".tl}: $e";
      });
    }
  }
}
