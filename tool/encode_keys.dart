// Utility: prints obfuscated byte arrays for the gray flow constants.
//
// Run: `dart run tool/encode_keys.dart`
//
// Edit the `secrets` map below with the real values from the brand owner
// (Firebase project number, AppsFlyer dev key, gateway URL, GCD URL) and
// paste the output back into the matching constants in
// lib/gray/config/runtime_brand.dart and lib/gray/config/gateway_endpoints.dart.

import 'dart:typed_data';

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

List<int> mask(String plain) {
  final stream = _streamFor(plain.length.clamp(1, 256));
  final out = <int>[];
  for (var i = 0; i < plain.length; i++) {
    out.add(plain.codeUnitAt(i) ^ stream[i % stream.length]);
  }
  return out;
}

String unmask(List<int> raw) {
  if (raw.isEmpty) return '';
  final stream = _streamFor(raw.length.clamp(1, 256));
  final out = <int>[];
  for (var i = 0; i < raw.length; i++) {
    out.add(raw[i] ^ stream[i % stream.length]);
  }
  return String.fromCharCodes(out);
}

void main() {
  // Fill in real values temporarily, run `dart run tool/encode_keys.dart`,
  // copy the printed byte arrays into runtime_brand.dart / gateway_endpoints
  // and then revert this map back to empty strings before committing.
  final secrets = <String, String>{
    'firebase_project_number_android': '',
    'firebase_project_number_ios': '',
    'appsflyer_dev_key_android': '',
    'appsflyer_dev_key_ios': '',
    'gateway_url': '',
    'gcd_host': '',
  };

  for (final entry in secrets.entries) {
    final value = entry.value;
    if (value.isEmpty) {
      print('// ${entry.key}: <not provided>');
      print('const ${entry.key} = <int>[];\n');
      continue;
    }
    final masked = mask(value);
    print('// ${entry.key}: ${value.length} chars');
    print('const ${entry.key} = ${masked};');
    final back = unmask(masked);
    print('// roundtrip: $back\n');
  }
}
