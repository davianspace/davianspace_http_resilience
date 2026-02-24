/// Strongly-typed HTTP method constants.
///
/// Using a value-class instead of raw strings prevents typos and enables
/// exhaustive switch expressions in Dart 3.
final class HttpMethod {
  const HttpMethod._(this.value);

  /// The raw HTTP verb string (e.g. `'GET'`).
  final String value;

  static const HttpMethod get = HttpMethod._('GET');
  static const HttpMethod post = HttpMethod._('POST');
  static const HttpMethod put = HttpMethod._('PUT');
  static const HttpMethod patch = HttpMethod._('PATCH');
  static const HttpMethod delete = HttpMethod._('DELETE');
  static const HttpMethod head = HttpMethod._('HEAD');
  static const HttpMethod options = HttpMethod._('OPTIONS');

  /// Creates a custom [HttpMethod] for non-standard verbs.
  factory HttpMethod.custom(String verb) =>
      HttpMethod._(verb.toUpperCase().trim());

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is HttpMethod && other.value == value);

  @override
  int get hashCode => value.hashCode;
}
