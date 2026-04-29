/// Decoded response of the remote launch gateway. Accepts a few alternative
/// field names so the same client can talk to slightly different backends
/// without code changes.
class GateResponse {
  final bool granted;
  final String? destination;
  final String? note;
  final int? expiresAtEpoch;

  const GateResponse._({
    required this.granted,
    this.destination,
    this.note,
    this.expiresAtEpoch,
  });

  factory GateResponse.fromMap(Map<String, dynamic> raw) {
    final granted = (raw['ok'] as bool?) ??
        (raw['granted'] as bool?) ??
        (raw['accepted'] as bool?) ??
        false;

    final destination = raw['url'] as String? ??
        raw['link'] as String? ??
        raw['target'] as String? ??
        raw['destination'] as String?;

    final note = raw['message'] as String? ??
        raw['note'] as String? ??
        raw['reason'] as String?;

    final dynamic ttl = raw['expires'] ?? raw['expires_at'] ?? raw['valid_until'];
    int? expires;
    if (ttl is int) {
      expires = ttl;
    } else if (ttl is num) {
      expires = ttl.toInt();
    } else if (ttl is String) {
      expires = int.tryParse(ttl);
    }

    return GateResponse._(
      granted: granted,
      destination: destination,
      note: note,
      expiresAtEpoch: expires,
    );
  }

  factory GateResponse.declined(String reason) {
    return GateResponse._(granted: false, note: reason);
  }
}
