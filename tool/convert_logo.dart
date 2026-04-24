import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  final webp = File('assets/logo/logo.webp').readAsBytesSync();
  final decoded = img.decodeWebP(webp);
  if (decoded == null) {
    stderr.writeln('Failed to decode logo.webp');
    exit(1);
  }
  final png = img.encodePng(decoded);
  File('assets/logo/logo.png').writeAsBytesSync(png);
  stdout.writeln('Wrote assets/logo/logo.png (${decoded.width}x${decoded.height})');
}
