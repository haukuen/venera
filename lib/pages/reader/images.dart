part of 'reader.dart';

class _ReaderImages extends StatefulWidget {
  const _ReaderImages({super.key});

  @override
  State<_ReaderImages> createState() => _ReaderImagesState();
}

class _ReaderImagesState extends State<_ReaderImages> {
  String? error;

  bool inProgress = false;

  late _ReaderState reader;

  void _savePagesCache(String key, List<String> images) async {
    try {
      var data = utf8.encode(jsonEncode(images));
      await CacheManager().writeCache(key, data);
    } catch (e) {
      Log.warning("Reader", "Failed to save pages cache: $e");
    }
  }

  @override
  void initState() {
    reader = context.reader;
    reader.isLoading = true;
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    ImageDownloader.cancelAllLoadingImages();
  }

  void _onPagesCacheInvalid() {
    if (!mounted || inProgress) return;
    setState(() {
      error = null;
      reader.isLoading = true;
    });
    context.readerScaffold.update();
  }

  /// Handle jumping to last page when _jumpToLastPageOnLoad is true
  void _handleJumpToLastPage() {
    if (reader._jumpToLastPageOnLoad) {
      reader._page = reader.maxPage;
      reader._jumpToLastPageOnLoad = false;
    }
  }

  void load() async {
    if (inProgress) return;
    inProgress = true;
    if (reader.type == ComicType.local ||
        (LocalManager().isDownloaded(
          reader.cid,
          reader.type,
          reader.chapter,
          reader.widget.chapters,
        ))) {
      try {
        var images = await LocalManager().getImages(
          reader.cid,
          reader.type,
          reader.chapter,
        );
        if (!mounted) return;
        setState(() {
          reader.images = images;
          reader.isLoading = false;
          inProgress = false;
          _handleJumpToLastPage();
          Future.microtask(() {
            reader.updateHistory();
          });
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          error = e.toString();
          reader.isLoading = false;
          inProgress = false;
        });
      }
    } else {
      var cp = reader.widget.chapters?.ids.elementAtOrNull(reader.chapter - 1);
      var cacheKey =
          "loadComicPages@${reader.type.sourceKey}@${reader.cid}@${reader.eid}";

      // Try cache first
      var cacheFile = await CacheManager().findCache(cacheKey);
      if (cacheFile != null) {
        try {
          var cacheData = await cacheFile.readAsBytes();
          var cacheList = (jsonDecode(utf8.decode(cacheData)) as List)
              .cast<String>();
          if (!mounted) return;
          setState(() {
            reader.images = cacheList;
            reader.isLoading = false;
            inProgress = false;
            _handleJumpToLastPage();
            Future.microtask(() {
              reader.updateHistory();
            });
          });
          context.readerScaffold.update();
          return;
        } catch (_) {
          // Cache corrupted, fall through to network request
        }
      }

      var res = await reader.type.comicSource!.loadComicPages!(
        reader.widget.cid,
        cp,
      );
      if (!mounted) return;
      if (res.error) {
        setState(() {
          error = res.errorMessage;
          reader.isLoading = false;
          inProgress = false;
        });
      } else {
        // Save to cache in background
        _savePagesCache(cacheKey, res.data);
        setState(() {
          reader.images = res.data;
          reader.isLoading = false;
          inProgress = false;
          _handleJumpToLastPage();
          Future.microtask(() {
            reader.updateHistory();
          });
        });
      }
    }
    if (!mounted) return;
    context.readerScaffold.update();
  }

  @override
  Widget build(BuildContext context) {
    if (reader.isLoading) {
      load();
      return const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      return GestureDetector(
        onTap: () {
          context.readerScaffold.openOrClose();
        },
        child: SizedBox.expand(
          child: NetworkError(
            message: error!,
            retry: () {
              setState(() {
                reader.isLoading = true;
                error = null;
              });
            },
          ),
        ),
      );
    } else {
      if (reader.mode.isGallery) {
        var showComments =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true;
        var showCommentsAtEnd =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
        return _GalleryMode(
          key: Key(
            '${reader.mode.key}_${reader.imagesPerPage}_${showComments}_$showCommentsAtEnd',
          ),
        );
      } else {
        return _ContinuousMode(key: Key(reader.mode.key));
      }
    }
  }
}

class _SwipeChangeChapterProgress extends StatefulWidget {
  const _SwipeChangeChapterProgress({this.controller, required this.isPrev});

  final ScrollController? controller;

  final bool isPrev;

  @override
  State<_SwipeChangeChapterProgress> createState() =>
      _SwipeChangeChapterProgressState();
}

class _SwipeChangeChapterProgressState
    extends State<_SwipeChangeChapterProgress> {
  double value = 0;

  late final isPrev = widget.isPrev;

  ScrollController? controller;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      controller = widget.controller;
      controller!.addListener(onScroll);
    }
  }

  @override
  void didUpdateWidget(covariant _SwipeChangeChapterProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      controller?.removeListener(onScroll);
      controller = widget.controller;
      controller?.addListener(onScroll);
      if (value != 0) {
        setState(() {
          value = 0;
        });
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
    controller?.removeListener(onScroll);
  }

  void onScroll() {
    var position = controller!.position.pixels;
    var offset = isPrev
        ? controller!.position.minScrollExtent - position
        : position - controller!.position.maxScrollExtent;
    var newValue = offset / _kChangeChapterOffset;
    newValue = newValue.clamp(0.0, 1.0);
    if (newValue != value) {
      setState(() {
        value = newValue;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.isPrev
        ? "Swipe down for previous chapter".tl
        : "Swipe up for next chapter".tl;

    return CustomPaint(
      painter: _ProgressPainter(
        value: value,
        backgroundColor: context.colorScheme.surfaceContainerLow,
        color: context.colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            widget.isPrev ? Icons.arrow_downward : Icons.arrow_upward,
            color: context.colorScheme.onSurface,
            size: 16,
          ),
          const SizedBox(width: 4),
          Text(msg),
        ],
      ).paddingVertical(6).paddingHorizontal(16),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  final double value;

  final Color backgroundColor;

  final Color color;

  const _ProgressPainter({
    required this.value,
    required this.backgroundColor,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromLTRBR(
        0,
        0,
        size.width,
        size.height,
        Radius.circular(AppRadius.xl),
      ),
      paint,
    );

    paint.color = color;
    canvas.drawRRect(
      RRect.fromLTRBR(
        0,
        0,
        size.width * value,
        size.height,
        Radius.circular(AppRadius.xl),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _ProgressPainter ||
        oldDelegate.value != value ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.color != color;
  }
}
