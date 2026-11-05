import 'dart:typed_data';

import 'print_doc.dart';

// ---------------------------------------------------------------------------
// ESC/POS bytes, for a raw TCP connection (port 9100) or USB/Bluetooth.
// Every Epson TM receipt printer understands these commands.
// ---------------------------------------------------------------------------

const _esc = 0x1b;
const _gs = 0x1d;
const _lf = 0x0a;

/// Code page 858 (Latin-1 for DOS, with the euro sign): covers English and
/// French. Selected with ESC t 19.
const _cp858 = 19;

/// Latin-1 characters French uses, to their code page 858 bytes. Anything
/// else that isn't plain ASCII prints as `?`.
const Map<String, int> _cp858Bytes = {
  'Ç': 0x80, 'ü': 0x81, 'é': 0x82, 'â': 0x83, 'ä': 0x84, 'à': 0x85, //
  'ç': 0x87, 'ê': 0x88, 'ë': 0x89, 'è': 0x8a, 'ï': 0x8b, 'î': 0x8c,
  'Ä': 0x8e, 'É': 0x90, 'ô': 0x93, 'ö': 0x94, 'û': 0x96, 'ù': 0x97,
  'ÿ': 0x98, 'Ö': 0x99, 'Ü': 0x9a, '£': 0x9c, '«': 0xae, '»': 0xaf,
  'Â': 0xb6, 'À': 0xb7, '©': 0xb8, 'Ê': 0xd2, 'Ë': 0xd3, 'È': 0xd4,
  '€': 0xd5, 'Î': 0xd7, 'Ï': 0xd8, 'Ô': 0xe2, 'Û': 0xea, 'Ù': 0xeb,
  '°': 0xf8,
};

/// Typographic punctuation people paste into menus, to plain ASCII.
const Map<String, String> _asciiFor = {
  '\u2018': "'", '\u2019': "'", '\u201c': '"', '\u201d': '"', //
  '\u2013': '-', '\u2014': '-', '\u2022': '*', '\u2026': '...',
  '\u00a0': ' ', '\u0153': 'oe', '\u0152': 'OE',
};

List<int> _textBytes(String text) {
  final out = <int>[];
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    final ascii = _asciiFor[ch];
    if (ascii != null) {
      out.addAll(ascii.codeUnits);
    } else if (rune >= 0x20 && rune < 0x7f) {
      out.add(rune);
    } else {
      out.add(_cp858Bytes[ch] ?? 0x3f);
    }
  }
  return out;
}

/// Encodes [doc] as ESC/POS.
Uint8List encodeEscPos(PrintDoc doc) {
  final b = BytesBuilder(copy: false)
    ..add([_esc, 0x40]) // initialize
    ..add([_esc, 0x74, _cp858]);
  for (final op in doc.ops) {
    switch (op) {
      case PrintLine(:final text, :final align, :final bold, :final big):
        b
          ..add([_esc, 0x61, align.index])
          ..add([_esc, 0x45, bold ? 1 : 0])
          ..add([_gs, 0x21, big ? 0x11 : 0x00])
          ..add(_textBytes(text))
          ..addByte(_lf);
      case PrintFeed(:final lines):
        b.add([_esc, 0x64, lines.clamp(0, 255)]);
      case PrintCut():
        // Feed to the cutter, then a partial cut.
        b.add([_gs, 0x56, 0x42, 0x00]);
      case PrintDrawerKick():
        // Pulse drawer pin 2 for 50 ms, then wait 500 ms.
        b.add([_esc, 0x70, 0x00, 0x19, 0xfa]);
    }
  }
  return b.toBytes();
}

// ---------------------------------------------------------------------------
// Epson ePOS-Print XML, POSTed over HTTP(S) to the printer itself. Works
// from a browser and from Android without drivers, on any TM printer with a
// network port and ePOS-Print turned on (TM-m30 series, TM-T88VI/VII,
// TM-T20III/IV, TM-m50 and others).
// ---------------------------------------------------------------------------

const eposNamespace = 'http://www.epson-pos.com/schemas/2011/03/epos-print';

String _xml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// The `<epos-print>` element for [doc].
String encodeEposPrint(PrintDoc doc) {
  final out = StringBuffer('<epos-print xmlns="$eposNamespace">')
    ..write('<text lang="en" smooth="true"/>');
  for (final op in doc.ops) {
    switch (op) {
      case PrintLine(:final text, :final align, :final bold, :final big):
        final size = big ? '2' : '1';
        out
          ..write('<text align="${align.name}"/>')
          ..write(
            '<text em="$bold" width="$size" height="$size">'
            '${_xml(text)}&#10;</text>',
          );
      case PrintFeed(:final lines):
        out.write('<feed line="${lines.clamp(0, 255)}"/>');
      case PrintCut():
        out.write('<cut type="feed"/>');
      case PrintDrawerKick():
        out.write('<pulse drawer="drawer_1" time="pulse_100"/>');
    }
  }
  out.write('</epos-print>');
  return out.toString();
}

/// The SOAP envelope the printer's ePOS-Print service expects.
String encodeEposXml(PrintDoc doc) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
    '<s:Body>${encodeEposPrint(doc)}</s:Body></s:Envelope>';

/// Where to POST [encodeEposXml]. `local_printer` is the printer's own
/// device ID; the printer gives up after [timeoutMs].
Uri eposUri(
  String host, {
  bool https = false,
  int? port,
  int timeoutMs = 10000,
}) => Uri(
  scheme: https ? 'https' : 'http',
  host: host,
  port: port,
  path: '/cgi-bin/epos/service.cgi',
  queryParameters: {'devid': 'local_printer', 'timeout': '$timeoutMs'},
);

/// What the printer answered. [code] explains a failure, for example
/// `EPTR_COVER_OPEN`, `EPTR_REC_EMPTY` (out of paper) or `EX_TIMEOUT`.
class EposResponse {
  const EposResponse({required this.success, this.code = ''});
  final bool success;
  final String code;

  static EposResponse parse(String body) {
    final tag = RegExp(r'<response\b[^>]*>').firstMatch(body)?.group(0);
    if (tag == null) {
      return const EposResponse(success: false, code: 'NO_RESPONSE');
    }
    String? attr(String name) =>
        RegExp('$name="([^"]*)"').firstMatch(tag)?.group(1);
    return EposResponse(
      success: attr('success') == 'true',
      code: attr('code') ?? '',
    );
  }

  /// For staff: what to check at the printer.
  String get message => switch (code) {
    'EPTR_COVER_OPEN' => 'The printer cover is open.',
    'EPTR_REC_EMPTY' => 'The printer is out of paper.',
    'EPTR_AUTOMATICAL' || 'EPTR_UNRECOVERABLE' || 'EPTR_MECHANICAL' =>
      'The printer has a paper jam or fault. Check it and turn it off and on.',
    'EX_TIMEOUT' => 'The printer took too long to answer.',
    'DeviceNotFound' => 'The printer isn\'t set up for ePOS-Print.',
    _ => success ? 'Printed.' : 'The printer refused the job ($code).',
  };
}
