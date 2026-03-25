import 'package:qr/qr.dart';

/// Renders [data] as an inline SVG QR code.
String generateQrSvg(String data, {int moduleSize = 6}) {
  final qr = QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M);
  final image = QrImage(qr);
  final count = image.moduleCount;
  const quietZone = 4;
  final total = count + quietZone * 2;
  final size = total * moduleSize;

  final buffer = StringBuffer()
    ..write(
      '<svg xmlns="http://www.w3.org/2000/svg" '
      'viewBox="0 0 $total $total" width="$size" height="$size" '
      'shape-rendering="crispEdges" aria-hidden="true">',
    )
    ..write('<rect width="$total" height="$total" fill="white"/>')
    ..write('<g fill="black">');

  for (var y = 0; y < count; y++) {
    for (var x = 0; x < count; x++) {
      if (image.isDark(y, x)) {
        buffer.write('<rect x="${x + quietZone}" y="${y + quietZone}" width="1" height="1"/>');
      }
    }
  }

  buffer.write('</g></svg>');
  return buffer.toString();
}
