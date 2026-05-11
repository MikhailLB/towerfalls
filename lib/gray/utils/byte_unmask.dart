import 'dart:typed_data';

/// XOR-based unmasking utility for storing AppsFlyer / Firebase / endpoint
/// strings as obfuscated byte arrays in source. Until real keys arrive the
/// arrays are empty, so [unmask] returns an empty string and gray services
/// short-circuit to the host's fallback home.
///
/// The salt is hardcoded — both `tool/encode_keys.dart` and this file MUST
/// use the same byte sequence, otherwise the round-trip fails. Treat the
/// value below as opaque; do not change it unless you also re-mask all
/// existing constants in `runtime_brand.dart` / `gateway_endpoints.dart`.
const _saltBytes = <int>[
  0x74, 0x66, 0x2E, 0x67, 0x61, 0x74, 0x65, 0x2E, 0x73, 0x61, 0x6C, 0x74,
  0x2E, 0x76, 0x31, 0x2E, 0x74, 0x6F, 0x77, 0x65, 0x72, 0x66, 0x61, 0x6C,
  0x6C, 0x73,
];

Uint8List _streamFor(int size) {
  var hash = 0x811C9DC5;
  for (final b in _saltBytes) {
    hash = ((hash ^ b) * 0x01000193) & 0xFFFFFFFF;
  }

  final out = Uint8List(size);
  var state = hash == 0 ? 0xC0FFEE : hash;
  for (var i = 0; i < size; i++) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    out[i] = (state >> 9) & 0xFF;
  }
  return out;
}

final Uint8List _stream = _streamFor(48);

String unmask(List<int> raw) {
  if (raw.isEmpty) return '';
  final n = raw.length;
  final stream = _stream;
  final sn = stream.length;
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = raw[i] ^ stream[i % sn];
  }
  return String.fromCharCodes(out);
}
