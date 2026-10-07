part of 'package:venera/pages/comic_source_page.dart';

class ComicSourceEditFilePage extends StatefulWidget {
  const ComicSourceEditFilePage(this.path, this.onExit, {super.key});

  final String path;

  final void Function() onExit;

  @override
  State<ComicSourceEditFilePage> createState() =>
      _ComicSourceEditFilePageState();
}

class _ComicSourceEditFilePageState extends State<ComicSourceEditFilePage> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = File(widget.path).readAsStringSync();
  }

  @override
  void dispose() {
    File(widget.path).writeAsStringSync(current);
    widget.onExit();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Edit".tl)),
      body: Column(
        children: [
          Container(height: 0.6, color: context.colorScheme.outlineVariant),
          Expanded(
            child: CodeEditor(
              initialValue: current,
              onChanged: (value) => current = value,
            ),
          ),
        ],
      ),
    );
  }
}
