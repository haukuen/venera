part of 'package:venera/pages/home_page.dart';

class _ComicArchiveWidget extends StatefulWidget {
  const _ComicArchiveWidget();

  @override
  State<_ComicArchiveWidget> createState() => _ComicArchiveWidgetState();
}

class _ComicArchiveWidgetState extends State<_ComicArchiveWidget> {
  List<BackupFile>? files;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (!BackupConfig.fromSettings().isValid) return;
    final result = await ComicBackupManager.listBackups();
    if (!mounted) return;
    setState(() {
      if (result.success) {
        files = result.data;
        error = null;
      } else {
        files = null;
        error = result.errorMessage;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!BackupConfig.fromSettings().isValid) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    final currentFiles = files ?? const <BackupFile>[];
    final totalSize = currentFiles.fold<int>(0, (sum, file) => sum + file.size);
    final newest = currentFiles.isEmpty ? null : currentFiles.first.modified;
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: ListTile(
          leading: const Icon(Icons.archive_outlined),
          title: Text("Comic Archive".tl),
          subtitle: Text(
            error != null
                ? error!
                : currentFiles.isEmpty
                ? "No archive files".tl
                : "@a archives · @b".tlParams({
                        'a': currentFiles.length,
                        'b': bytesToReadableString(totalSize),
                      }) +
                      (newest == null
                          ? ''
                          : '\n${"Latest".tl}: ${_formatTime(newest)}'),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            context.to(() => const ComicArchivePage()).then((_) => load());
          },
        ),
      ),
    );
  }

  static String _formatTime(DateTime time) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)}';
  }
}
