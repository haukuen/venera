import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/local_comics/export_dialog.dart';
import 'package:venera/pages/local_comics/chapter_export.dart';
import 'package:venera/pages/local_comics/import_dialog.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/comic_backup.dart';
import 'package:venera/utils/epub.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf.dart';
import 'package:venera/utils/translations.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';

class LocalComicsPage extends StatefulWidget {
  const LocalComicsPage({super.key});

  @override
  State<LocalComicsPage> createState() => _LocalComicsPageState();
}

enum _LocalComicExportScope { entireComic, selectedChapters }

class _LocalComicsPageState extends State<LocalComicsPage> {
  late List<LocalComic> comics;

  late LocalSortType sortType;

  String keyword = "";

  bool searchMode = false;

  bool multiSelectMode = false;

  Map<LocalComic, bool> selectedComics = {};

  void update() {
    if (keyword.isEmpty) {
      setState(() {
        comics = LocalManager().getComics(sortType);
      });
    } else {
      setState(() {
        comics = LocalManager().search(keyword);
      });
    }
  }

  @override
  void initState() {
    var sort = appdata.implicitData["local_sort"] ?? "name";
    sortType = LocalSortType.fromString(sort);
    comics = LocalManager().getComics(sortType);
    LocalManager().addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(update);
    super.dispose();
  }

  void sort() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Sort".tl,
              content: RadioGroup<LocalSortType>(
                groupValue: sortType,
                onChanged: (v) {
                  setState(() {
                    sortType = v ?? sortType;
                  });
                },
                child: Column(
                  children: [
                    RadioListTile<LocalSortType>(
                      title: Text("Name".tl),
                      value: LocalSortType.name,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date".tl),
                      value: LocalSortType.timeAsc,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date Desc".tl),
                      value: LocalSortType.timeDesc,
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () {
                    appdata.implicitData["local_sort"] = sortType.value;
                    appdata.writeImplicitData();
                    Navigator.pop(context);
                    update();
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget buildMultiSelectMenu() {
    return MenuButton(
      entries: [
        MenuEntry(
          icon: Icons.delete_outline,
          text: "Delete".tl,
          onClick: () {
            deleteComics(selectedComics.keys.toList()).then((value) {
              if (value) {
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });
              }
            });
          },
        ),
        MenuEntry(
          icon: Icons.favorite_border,
          text: "Add to favorites".tl,
          onClick: () {
            addFavorite(selectedComics.keys.toList());
          },
        ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.folder_open,
            text: "Open Folder".tl,
            onClick: () {
              openComicFolder(selectedComics.keys.first);
            },
          ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.chrome_reader_mode_outlined,
            text: "View Detail".tl,
            onClick: () {
              context.to(
                () => ComicPage(
                  id: selectedComics.keys.first.id,
                  sourceKey: selectedComics.keys.first.sourceKey,
                ),
              );
            },
          ),
        if (selectedComics.isNotEmpty)
          ...exportActions(selectedComics.keys.toList()),
        if (selectedComics.isNotEmpty && BackupConfig.fromSettings().isValid)
          MenuEntry(
            icon: Icons.cloud_upload_outlined,
            text: "Archive to WebDAV".tl,
            onClick: () {
              backupComics(selectedComics.keys.toList());
            },
          ),
        if (selectedComics.isNotEmpty)
          MenuEntry(
            icon: Icons.upload,
            text: "Migrate Comics".tl,
            onClick: () {
              showDialog(
                context: context,
                builder: (context) => ExportComicsDialog(
                  selectedComics: selectedComics.keys.toList(),
                ),
              );
            },
          ),
      ],
    );
  }

  void selectAll() {
    setState(() {
      selectedComics = comics.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      comics.asMap().forEach((k, v) {
        selectedComics[v] = !selectedComics.putIfAbsent(v, () => false);
      });
      selectedComics.removeWhere((k, v) => !v);
    });
  }

  @override
  Widget build(BuildContext context) {
    void showExportImportMenu() {
      showDialog(
        context: context,
        builder: (context) => ExportComicsDialog(
          selectedComics: selectedComics.isNotEmpty
              ? selectedComics.keys.toList()
              : null,
        ),
      );
    }

    void showImportDialog() {
      showDialog(
        context: context,
        builder: (context) => const ImportComicsDialog(),
      );
    }

    final exportImportMenu = MenuButton(
      entries: [
        MenuEntry(
          icon: Icons.upload,
          text: "Migrate Comics".tl,
          onClick: showExportImportMenu,
        ),
        MenuEntry(
          icon: Icons.file_download,
          text: "Import Migrated Comics".tl,
          onClick: showImportDialog,
        ),
      ],
    );

    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      buildMultiSelectMenu(),
    ];

    List<Widget> normalActions = [
      Tooltip(
        message: "Search".tl,
        child: IconButton(
          icon: const Icon(Icons.search),
          onPressed: () {
            setState(() {
              searchMode = true;
            });
          },
        ),
      ),
      Tooltip(
        message: "Sort".tl,
        child: IconButton(icon: const Icon(Icons.sort), onPressed: sort),
      ),
      Tooltip(
        message: "Downloading".tl,
        child: IconButton(
          icon: const Icon(Icons.download),
          onPressed: () {
            showPopUpWidget(context, const DownloadingPage());
          },
        ),
      ),
      exportImportMenu,
    ];

    var body = Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          if (!searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : Text("Local".tl),
              actions: multiSelectMode ? selectActions : normalActions,
            )
          else if (searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Cancel".tl,
                child: IconButton(
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.close),
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      setState(() {
                        searchMode = false;
                        keyword = "";
                        update();
                      });
                    }
                  },
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: "Search".tl,
                        border: InputBorder.none,
                      ),
                      onChanged: (v) {
                        keyword = v;
                        update();
                      },
                    ),
              actions: multiSelectMode ? selectActions : null,
            ),
          SliverGridComics(
            comics: comics,
            selections: selectedComics,
            onLongPressed: (c, heroID) {
              setState(() {
                multiSelectMode = true;
                selectedComics[c as LocalComic] = true;
              });
            },
            onTap: (c, heroID) {
              if (multiSelectMode) {
                setState(() {
                  if (selectedComics.containsKey(c as LocalComic)) {
                    selectedComics.remove(c);
                  } else {
                    selectedComics[c] = true;
                  }
                  if (selectedComics.isEmpty) {
                    multiSelectMode = false;
                  }
                });
              } else {
                // prevent dirty data
                var comic = LocalManager().find(
                  c.id,
                  ComicType.fromKey(c.sourceKey),
                )!;
                comic.read();
              }
            },
            menuBuilder: (c) {
              return [
                MenuEntry(
                  icon: Icons.folder_open,
                  text: "Open Folder".tl,
                  onClick: () {
                    openComicFolder(c as LocalComic);
                  },
                ),
                MenuEntry(
                  icon: Icons.delete,
                  text: "Delete".tl,
                  onClick: () {
                    deleteComics([c as LocalComic]).then((value) {
                      if (value && multiSelectMode) {
                        setState(() {
                          multiSelectMode = false;
                          selectedComics.clear();
                        });
                      }
                    });
                  },
                ),
                ...exportActions([c as LocalComic]),
              ];
            },
          ),
        ],
      ),
    );

    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            update();
          });
        }
      },
      child: body,
    );
  }

  Future<bool> deleteComics(List<LocalComic> comics) async {
    bool isDeleted = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        bool removeComicFile = true;
        bool removeFavoriteAndHistory = true;
        return StatefulBuilder(
          builder: (context, state) {
            return ContentDialog(
              title: "Delete".tl,
              content: Column(
                children: [
                  CheckboxListTile(
                    title: Text("Remove local favorite and history".tl),
                    value: removeFavoriteAndHistory,
                    onChanged: (v) {
                      state(() {
                        removeFavoriteAndHistory = !removeFavoriteAndHistory;
                      });
                    },
                  ),
                  CheckboxListTile(
                    title: Text("Also remove files on disk".tl),
                    value: removeComicFile,
                    onChanged: (v) {
                      state(() {
                        removeComicFile = !removeComicFile;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                if (comics.length == 1 && comics.first.hasChapters)
                  TextButton(
                    child: Text("Delete Chapters".tl),
                    onPressed: () {
                      context.pop();
                      showDeleteChaptersPopWindow(context, comics.first);
                    },
                  ),
                FilledButton(
                  onPressed: () {
                    context.pop();
                    LocalManager().batchDeleteComics(
                      comics,
                      removeComicFile,
                      removeFavoriteAndHistory,
                    );
                    isDeleted = true;
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
    return isDeleted;
  }

  Future<void> backupComics(List<LocalComic> comics) async {
    if (comics.isEmpty) return;
    var current = 0;
    var total = comics.length;
    var currentTitle = "";
    var cancelled = false;
    var started = false;
    BackupResult? result;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            if (result == null && !started) {
              started = true;
              Future.microtask(() async {
                final backupResult = await ComicBackupManager.backup(
                  comics,
                  isCancelled: () => cancelled,
                  onProgress: (progress, totalCount, title) {
                    if (!context.mounted) return;
                    setState(() {
                      current = progress;
                      total = totalCount;
                      currentTitle = title;
                    });
                  },
                );
                if (!context.mounted) return;
                setState(() {
                  result = backupResult;
                });
              });
            }
            return ContentDialog(
              title: result == null
                  ? "Archive to WebDAV".tl
                  : "Backup Complete".tl,
              content: result == null
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LinearProgressIndicator(
                          value: total > 0 ? current / total : null,
                        ),
                        const SizedBox(height: 16),
                        Text("$current / $total"),
                        if (currentTitle.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(currentTitle, overflow: TextOverflow.ellipsis),
                        ],
                      ],
                    ).paddingHorizontal(16)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Success: @a".tlParams({'a': result!.success})),
                        Text("Skipped: @a".tlParams({'a': result!.skipped})),
                        Text("Failed: @a".tlParams({'a': result!.failed})),
                        if (result!.errors.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          for (final error in result!.errors.take(3))
                            Text(error),
                        ],
                      ],
                    ).paddingHorizontal(16),
              actions: result == null
                  ? [
                      TextButton(
                        onPressed: () {
                          setState(() {
                            cancelled = true;
                          });
                        },
                        child: Text("Cancel".tl),
                      ),
                    ]
                  : [
                      FilledButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: Text("OK".tl),
                      ),
                    ],
            );
          },
        );
      },
    );
  }

  List<MenuEntry> exportActions(List<LocalComic> comics) {
    return [
      MenuEntry(
        icon: Icons.outbox_outlined,
        text: "Export as cbz".tl,
        onClick: () {
          chooseExportScopeAndExport(comics, CBZ.export, ".cbz");
        },
      ),
      MenuEntry(
        icon: Icons.picture_as_pdf_outlined,
        text: "Export as pdf".tl,
        onClick: () async {
          chooseExportScopeAndExport(comics, createPdfFromComicIsolate, ".pdf");
        },
      ),
      MenuEntry(
        icon: Icons.import_contacts_outlined,
        text: "Export as epub".tl,
        onClick: () async {
          chooseExportScopeAndExport(comics, createEpubWithLocalComic, ".epub");
        },
      ),
    ];
  }

  Future<void> chooseExportScopeAndExport(
    List<LocalComic> comics,
    ExportComicFunc export,
    String ext,
  ) async {
    final canSelectChapters =
        comics.length == 1 &&
        comics.first.chapters != null &&
        orderedDownloadedChapters(comics.first).isNotEmpty;
    var scope = _LocalComicExportScope.entireComic;

    final selectedScope = await showDialog<_LocalComicExportScope>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Export".tl,
              content: RadioGroup<_LocalComicExportScope>(
                groupValue: scope,
                onChanged: (value) {
                  if (value == null) return;
                  if (value == _LocalComicExportScope.selectedChapters &&
                      !canSelectChapters) {
                    return;
                  }
                  setState(() {
                    scope = value;
                  });
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<_LocalComicExportScope>(
                      title: Text("Entire comic".tl),
                      value: _LocalComicExportScope.entireComic,
                    ),
                    RadioListTile<_LocalComicExportScope>(
                      title: Text("Select chapters".tl),
                      value: _LocalComicExportScope.selectedChapters,
                      enabled: canSelectChapters,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text("Cancel".tl),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(scope),
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );

    if (selectedScope == null) return;
    if (!mounted) return;
    switch (selectedScope) {
      case _LocalComicExportScope.entireComic:
        exportComics(comics, export, ext);
      case _LocalComicExportScope.selectedChapters:
        showExportChaptersPopWindow(comics.first, export, ext);
    }
  }

  void showExportChaptersPopWindow(
    LocalComic comic,
    ExportComicFunc export,
    String ext,
  ) {
    final chapters = orderedDownloadedChapters(comic);
    final selectedChapterIds = <String>{};

    showPopUpWidget(
      context,
      PopUpWidgetScaffold(
        title: "Select chapters".tl,
        body: StatefulBuilder(
          builder: (context, setState) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() {
                            if (selectedChapterIds.length == chapters.length) {
                              selectedChapterIds.clear();
                            } else {
                              selectedChapterIds.addAll(
                                chapters.map((chapter) => chapter.id),
                              );
                            }
                          });
                        },
                        child: Text(
                          selectedChapterIds.length == chapters.length
                              ? "Deselect All".tl
                              : "Select All".tl,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: chapters.length,
                    itemBuilder: (context, index) {
                      final chapter = chapters[index];
                      return CheckboxListTile(
                        title: Text(chapter.title),
                        subtitle: Text("#${chapter.position}"),
                        value: selectedChapterIds.contains(chapter.id),
                        onChanged: (value) {
                          setState(() {
                            if (value == true) {
                              selectedChapterIds.add(chapter.id);
                            } else {
                              selectedChapterIds.remove(chapter.id);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      FilledButton(
                        onPressed: selectedChapterIds.isEmpty
                            ? null
                            : () {
                                final selectedChapters = chapters
                                    .where(
                                      (chapter) => selectedChapterIds.contains(
                                        chapter.id,
                                      ),
                                    )
                                    .toList();
                                final filteredComic = copyWithSelectedChapters(
                                  comic,
                                  selectedChapters
                                      .map((chapter) => chapter.id)
                                      .toList(),
                                );
                                final filename = selectedChapterExportFilename(
                                  comic: comic,
                                  selectedChapters: selectedChapters,
                                  extension: ext,
                                );
                                App.rootContext.pop();
                                exportComics(
                                  [filteredComic],
                                  export,
                                  ext,
                                  filenameOverride: filename,
                                );
                              },
                        child: Text("Submit".tl),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Export given comics to a file
  void exportComics(
    List<LocalComic> comics,
    ExportComicFunc export,
    String ext, {
    String? filenameOverride,
  }) async {
    var current = 0;
    var cacheDir = FilePath.join(App.cachePath, 'comics_export');
    var outFile = FilePath.join(App.cachePath, 'comics_export.zip');
    bool canceled = false;
    if (filenameOverride != null && comics.length != 1) {
      throw ArgumentError.value(
        filenameOverride,
        'filenameOverride',
        'can only be used when exporting one comic',
      );
    }
    if (Directory(cacheDir).existsSync()) {
      Directory(cacheDir).deleteSync(recursive: true);
    }
    Directory(cacheDir).createSync();
    var loadingController = showLoadingDialog(
      context,
      allowCancel: true,
      message: "${"Exporting".tl} $current/${comics.length}",
      withProgress: comics.length > 1,
      onCancel: () {
        canceled = true;
      },
    );
    try {
      var fileName = "";
      // For each comic, export it to a file
      for (var comic in comics) {
        fileName = FilePath.join(
          cacheDir,
          filenameOverride ??
              sanitizeFileNameWithSuffix(
                comic.title,
                extension: ext,
                fallback: 'comic',
              ),
        );
        await export(comic, fileName);
        current++;
        if (comics.length > 1) {
          loadingController.setMessage(
            "${"Exporting".tl} $current/${comics.length}",
          );
          loadingController.setProgress(current / comics.length);
        }
        if (canceled) {
          return;
        }
      }
      // For single comic, just save the file
      if (comics.length == 1) {
        await saveFile(file: File(fileName), filename: File(fileName).name);
        Directory(cacheDir).deleteSync(recursive: true);
        loadingController.close();
        return;
      }
      // For multiple comics, compress the folder
      loadingController.setProgress(null);
      loadingController.setMessage("Compressing".tl);
      await ZipFile.compressFolderAsync(cacheDir, outFile);
      if (canceled) {
        File(outFile).deleteIgnoreError();
        return;
      }
    } catch (e, s) {
      Log.error("Export Comics", e, s);
      if (!mounted) {
        loadingController.close();
        return;
      }
      context.showMessage(message: e.toString());
      loadingController.close();
      return;
    } finally {
      Directory(cacheDir).deleteIgnoreError(recursive: true);
    }
    await saveFile(file: File(outFile), filename: "comics_export.zip");
    loadingController.close();
    File(outFile).deleteIgnoreError();
  }
}

typedef ExportComicFunc =
    Future<File> Function(LocalComic comic, String outFilePath);

/// Opens the folder containing the comic in the system file explorer
Future<void> openComicFolder(LocalComic comic) async {
  try {
    final folderPath = comic.baseDir;

    if (App.isWindows) {
      await Process.run('explorer', [folderPath]);
    } else if (App.isMacOS) {
      await Process.run('open', [folderPath]);
    } else if (App.isLinux) {
      // Try different file managers commonly found on Linux
      try {
        await Process.run('xdg-open', [folderPath]);
      } catch (e) {
        // Fallback to other common file managers
        try {
          await Process.run('nautilus', [folderPath]);
        } catch (e) {
          try {
            await Process.run('dolphin', [folderPath]);
          } catch (e) {
            try {
              await Process.run('thunar', [folderPath]);
            } catch (e) {
              // Last resort: use the URL launcher with file:// protocol
              await launchUrlString('file://$folderPath');
            }
          }
        }
      }
    } else {
      // For mobile platforms, use the URL launcher with file:// protocol
      await launchUrlString('file://$folderPath');
    }
  } catch (e, s) {
    Log.error("Open Folder", "Failed to open comic folder: $e", s);
    // Show error message to user
    if (App.rootContext.mounted) {
      App.rootContext.showMessage(message: "Failed to open folder: $e");
    }
  }
}

void showDeleteChaptersPopWindow(BuildContext context, LocalComic comic) {
  var chapters = <String>[];

  showPopUpWidget(
    context,
    PopUpWidgetScaffold(
      title: "Delete Chapters".tl,
      body: StatefulBuilder(
        builder: (context, setState) {
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  itemCount: comic.downloadedChapters.length,
                  itemBuilder: (context, index) {
                    var id = comic.downloadedChapters[index];
                    var chapter = comic.chapters![id] ?? "Unknown Chapter";
                    return CheckboxListTile(
                      title: Text(chapter),
                      value: chapters.contains(id),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            chapters.add(id);
                          } else {
                            chapters.remove(id);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton(
                      onPressed: () {
                        Future.delayed(const Duration(milliseconds: 200), () {
                          LocalManager().deleteComicChapters(comic, chapters);
                        });
                        App.rootContext.pop();
                      },
                      child: Text("Submit".tl),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
