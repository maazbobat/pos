/// A printout as a list of simple steps (lines of text, feeds, a cut, a
/// drawer kick), laid out for a fixed number of characters per line.
///
/// Layouts ([receiptDoc], [kitchenTicketDoc]) build one of these, and an
/// encoder turns it into what the printer speaks: ESC/POS bytes
/// ([encodeEscPos]) or Epson ePOS-Print XML ([encodeEposXml]). Keeping the
/// layout separate means both connections print the same thing and tests
/// can read a receipt as plain text ([PrintDoc.preview]).
library;

enum PrintAlign { left, center, right }

sealed class PrintOp {
  const PrintOp();
}

/// One line of text. [big] is double width and height, so half as many
/// characters fit.
class PrintLine extends PrintOp {
  const PrintLine(
    this.text, {
    this.align = PrintAlign.left,
    this.bold = false,
    this.big = false,
  });
  final String text;
  final PrintAlign align;
  final bool bold;
  final bool big;
}

class PrintFeed extends PrintOp {
  const PrintFeed(this.lines);
  final int lines;
}

/// Feeds past the tear bar and cuts the paper.
class PrintCut extends PrintOp {
  const PrintCut();
}

/// Opens the cash drawer plugged into the printer's drawer port.
class PrintDrawerKick extends PrintOp {
  const PrintDrawerKick();
}

class PrintDoc {
  const PrintDoc({required this.width, required this.ops});

  /// Characters per line at normal size: 48 on 80 mm paper, 32 on 58 mm.
  final int width;
  final List<PrintOp> ops;

  bool get opensDrawer => ops.any((o) => o is PrintDrawerKick);

  /// The text as it would come out, for tests and on-screen previews.
  /// Big lines are shown in capitals at their real width.
  String preview() {
    final out = StringBuffer();
    for (final op in ops) {
      switch (op) {
        case PrintLine(:final text, :final align, :final big):
          final w = big ? width ~/ 2 : width;
          out.writeln(_aligned(big ? text.toUpperCase() : text, w, align));
        case PrintFeed(:final lines):
          for (var i = 0; i < lines; i++) {
            out.writeln();
          }
        case PrintCut():
          out.writeln('~' * width);
        case PrintDrawerKick():
          out.writeln('[drawer]');
      }
    }
    return out.toString();
  }
}

String _aligned(String text, int width, PrintAlign align) {
  if (text.length >= width) return text;
  final pad = width - text.length;
  return switch (align) {
    PrintAlign.left => text,
    PrintAlign.right => ' ' * pad + text,
    PrintAlign.center => ' ' * (pad ~/ 2) + text,
  };
}

/// Builds a [PrintDoc], wrapping long text so nothing runs off the paper.
class PrintDocBuilder {
  PrintDocBuilder(this.width);
  final int width;
  final List<PrintOp> _ops = [];

  int _cols(bool big) => big ? width ~/ 2 : width;

  /// Text, wrapped at word boundaries. [indent] spaces start every line.
  void text(
    String text, {
    PrintAlign align = PrintAlign.left,
    bool bold = false,
    bool big = false,
    int indent = 0,
  }) {
    final cols = _cols(big);
    for (final line in wrap(text, cols - indent)) {
      _ops.add(
        PrintLine(' ' * indent + line, align: align, bold: bold, big: big),
      );
    }
  }

  /// [left] and [right] on one line, for example an item and its price. A
  /// long [left] wraps above, with [right] on its last line.
  void row(String left, String right, {bool bold = false, bool big = false}) {
    final cols = _cols(big);
    final room = cols - right.length - 1;
    final lines = room > 4 ? wrap(left, room) : [left];
    for (var i = 0; i < lines.length - 1; i++) {
      _ops.add(PrintLine(lines[i], bold: bold, big: big));
    }
    final last = lines.last;
    final gap = cols - last.length - right.length;
    _ops.add(
      PrintLine(
        gap >= 1 ? '$last${' ' * gap}$right' : '$last $right',
        bold: bold,
        big: big,
      ),
    );
  }

  void rule([String char = '-']) => _ops.add(PrintLine(char * width));
  void feed([int lines = 1]) => _ops.add(PrintFeed(lines));
  void cut() => _ops.add(const PrintCut());
  void openDrawer() => _ops.add(const PrintDrawerKick());

  PrintDoc build() => PrintDoc(width: width, ops: List.unmodifiable(_ops));
}

/// Splits [text] into lines of at most [width] characters, at spaces where
/// it can and mid-word where a word is longer than a line.
List<String> wrap(String text, int width) {
  if (width < 1) return [text];
  final lines = <String>[];
  for (final para in text.split('\n')) {
    var line = '';
    for (var word in para.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      while (word.length > width) {
        if (line.isNotEmpty) {
          lines.add(line);
          line = '';
        }
        lines.add(word.substring(0, width));
        word = word.substring(width);
      }
      if (line.isEmpty) {
        line = word;
      } else if (line.length + 1 + word.length <= width) {
        line = '$line $word';
      } else {
        lines.add(line);
        line = word;
      }
    }
    lines.add(line);
  }
  return lines;
}
