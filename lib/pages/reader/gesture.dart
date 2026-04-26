part of 'reader.dart';

class _ReaderGestureDetector extends StatefulWidget {
  const _ReaderGestureDetector({required this.child});

  final Widget child;

  @override
  State<_ReaderGestureDetector> createState() => _ReaderGestureDetectorState();
}

class _ReaderGestureDetectorState extends AutomaticGlobalState<_ReaderGestureDetector> {
  static const _kLongPressMinTime = Duration(milliseconds: 250);

  static const _kDoubleTapMaxDistanceSquared = 20.0 * 20.0;

  static const _kTapToTurnPagePercent = 0.3;

  final _dragListeners = <_DragListener>[];

  late _ReaderState reader;

  bool _ignoreNextTap = false;

  Timer? _longPressTimer;

  bool _longPressInProgress = false;

  bool _dragInProgress = false;

  bool _preventNextTap = false;

  Offset? _initialPosition;

  Offset? _lastTapLocation;

  void ignoreNextTap() {
    _ignoreNextTap = true;
  }

  void clearIgnoreNextTap() {
    _ignoreNextTap = false;
  }

  @override
  void initState() {
    super.initState();
    context.readerScaffold._gestureDetectorState = this;
    reader = context.reader;
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.position == Offset.zero) {
          return;
        }
        if (_ignoreNextTap) {
          // 不要在这里清除标志，让 onTap 来处理
          return;
        }
        _initialPosition = event.position;
        _preventNextTap = false;
        if (_dragInProgress) {
          // 结束当前拖拽
          for (var dragListener in List<_DragListener>.from(_dragListeners)) {
            dragListener.onEnd?.call();
          }
          _dragInProgress = false;
        }
        // 用 Timer 替代 Future.delayed，便于取消
        _longPressTimer?.cancel();
        _longPressTimer = Timer(_kLongPressMinTime, () {
          if (!mounted) return;
          if (_dragInProgress) return;
          _longPressInProgress = true;
          if (_initialPosition != null) {
            onLongPressedDown(_initialPosition!);
          }
        });
      },
      onPointerMove: (event) {
        if (_longPressTimer?.isActive ?? false) {
          if (_initialPosition != null) {
            final distance = (event.position - _initialPosition!).distanceSquared;
            if (distance > _kDoubleTapMaxDistanceSquared) {
              // 移动超过阈值，取消长按，转为拖拽
              _longPressTimer?.cancel();
              _dragInProgress = true;
              for (var dragListener in List<_DragListener>.from(_dragListeners)) {
                dragListener.onStart?.call(event.position);
              }
            }
          }
        }
        if (_dragInProgress) {
          for (var dragListener in List<_DragListener>.from(_dragListeners)) {
            dragListener.onMove?.call(event.delta);
          }
        }
      },
      onPointerUp: (event) {
        if (_longPressInProgress) {
          _preventNextTap = true;
          onLongPressedUp(event.position);
          _longPressInProgress = false;
        }
        if (_dragInProgress) {
          for (var dragListener in List<_DragListener>.from(_dragListeners)) {
            dragListener.onEnd?.call();
          }
          _dragInProgress = false;
        }
        _longPressTimer?.cancel();
        _initialPosition = null;
      },
      onPointerCancel: (event) {
        _longPressTimer?.cancel();
        if (_longPressInProgress) {
          onLongPressedUp(event.position);
          _longPressInProgress = false;
        }
        if (_dragInProgress) {
          for (var dragListener in List<_DragListener>.from(_dragListeners)) {
            dragListener.onEnd?.call();
          }
          _dragInProgress = false;
        }
        _initialPosition = null;
      },
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          onMouseWheel(event.scrollDelta.dy > 0);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (details) {
          _lastTapLocation = details.globalPosition;
        },
        onSecondaryTapDown: (details) {
          onSecondaryTapUp(details.globalPosition);
        },
        onTap: () {
          if (_ignoreNextTap) {
            _ignoreNextTap = false;
            return;
          }
          if (_preventNextTap) {
            _preventNextTap = false;
            return;
          }
          if (_longPressInProgress) {
            _longPressInProgress = false;
            return;
          }
          if (!_dragInProgress && _lastTapLocation != null) {
            onTap(_lastTapLocation!);
          }
        },
        onDoubleTap: _enableDoubleTapToZoom ? () {
          if (_ignoreNextTap) {
            _ignoreNextTap = false;
            return;
          }
          if (_lastTapLocation != null) {
            onDoubleTap(_lastTapLocation!);
          }
        } : null,
        child: widget.child,
      ),
    );
  }

  void onMouseWheel(bool forward) {
    if (HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    if (context.reader.mode.key.startsWith('gallery')) {
      if (forward) {
        if (!context.reader.toNextPage() && !context.reader.isLastChapterOfGroup) {
          context.reader.toNextChapter();
        }
      } else {
        if (!context.reader.toPrevPage() && !context.reader.isFirstChapterOfGroup) {
          context.reader.toPrevChapter(toLastPage: true);
        }
      }
    }
  }

  bool get _enableDoubleTapToZoom =>
      appdata.settings.getReaderSetting(reader.cid, reader.type.sourceKey, 'enableDoubleTapToZoom');

  void onTap(Offset location) {
    if (reader._imageViewController!.handleOnTap(location)) {
      return;
    } else if (context.readerScaffold.isOpen) {
      context.readerScaffold.openOrClose();
    } else {
      // Don't open toolbar on chapter comments page
      if (reader.isOnChapterCommentsPage) {
        return;
      }
      if (appdata.settings.getReaderSetting(
          reader.cid, reader.type.sourceKey, 'enableTapToTurnPages')) {
        bool isLeft = false, isRight = false, isTop = false, isBottom = false;
        final width = context.width;
        final height = context.height;
        final x = location.dx;
        final y = location.dy;
        if (x < width * _kTapToTurnPagePercent) {
          isLeft = true;
        } else if (x > width * (1 - _kTapToTurnPagePercent)) {
          isRight = true;
        }
        if (y < height * _kTapToTurnPagePercent) {
          isTop = true;
        } else if (y > height * (1 - _kTapToTurnPagePercent)) {
          isBottom = true;
        }
        bool isCenter = false;
        var prev = () => context.reader.toPrevPage();
        var next = () => context.reader.toNextPage();
        if (appdata.settings.getReaderSetting(
            reader.cid, reader.type.sourceKey, 'reverseTapToTurnPages')) {
          prev = () => context.reader.toNextPage();
          next = () => context.reader.toPrevPage();
        }
        switch (context.reader.mode) {
          case ReaderMode.galleryLeftToRight:
          case ReaderMode.continuousLeftToRight:
            if (isLeft) {
              prev();
            } else if (isRight) {
              next();
            } else {
              isCenter = true;
            }
            break;
          case ReaderMode.galleryRightToLeft:
          case ReaderMode.continuousRightToLeft:
            if (isLeft) {
              next();
            } else if (isRight) {
              prev();
            } else {
              isCenter = true;
            }
            break;
          case ReaderMode.galleryTopToBottom:
          case ReaderMode.continuousTopToBottom:
            if (isTop) {
              prev();
            } else if (isBottom) {
              next();
            } else {
              isCenter = true;
            }
            break;
        }
        if (!isCenter) {
          return;
        }
      }
      context.readerScaffold.openOrClose();
    }
  }

  void onDoubleTap(Offset location) {
    context.reader._imageViewController?.handleDoubleTap(location);
  }

  void onSecondaryTapUp(Offset location) {
    showMenuX(
      context,
      location,
      [
        MenuEntry(
          icon: Icons.settings,
          text: "Settings".tl,
          onClick: () {
            context.readerScaffold.openSetting();
          },
        ),
        MenuEntry(
          icon: Icons.menu,
          text: "Chapters".tl,
          onClick: () {
            context.readerScaffold.openChapterDrawer();
          },
        ),
        MenuEntry(
          icon: Icons.fullscreen,
          text: "Fullscreen".tl,
          onClick: () {
            context.reader.fullscreen();
          },
        ),
        MenuEntry(
          icon: Icons.exit_to_app,
          text: "Exit".tl,
          onClick: () {
            context.pop();
          },
        ),
        if (App.isDesktop && !reader.isLoading)
          MenuEntry(
            icon: Icons.copy,
            text: "Copy Image".tl,
            onClick: () => copyImage(location),
          ),
        if (!reader.isLoading)
          MenuEntry(
            icon: Icons.download_outlined,
            text: "Save Image".tl,
            onClick: () => saveImage(location),
          ),
      ],
    );
  }

  void onLongPressedUp(Offset location) {
    context.reader._imageViewController?.handleLongPressUp(location);
  }

  void onLongPressedDown(Offset location) {
    context.reader._imageViewController?.handleLongPressDown(location);
  }

  void addDragListener(_DragListener listener) {
    _dragListeners.add(listener);
  }

  void removeDragListener(_DragListener listener) {
    _dragListeners.remove(listener);
  }

  @override
  Object? get key => "reader_gesture";

  void copyImage(Offset location) async {
    var controller = reader._imageViewController;
    var image = await controller!.getImageByOffset(location);
    if (image != null) {
      writeImageToClipboard(image);
    } else {
      context.showMessage(message: "No Image");
    }
  }

  void saveImage(Offset location) async {
    var controller = reader._imageViewController;
    var image = await controller!.getImageByOffset(location);
    if (image != null) {
      var filetype = detectFileType(image);
      saveFile(filename: "image${filetype.ext}", data: image);
    } else {
      context.showMessage(message: "No Image");
    }
  }
}

class _DragListener {
  void Function(Offset point)? onStart;
  void Function(Offset offset)? onMove;
  void Function()? onEnd;

  _DragListener({this.onMove, this.onEnd});
}
