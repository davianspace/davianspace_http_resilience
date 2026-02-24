# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.0.x   | Yes       |
| < 1.0   | No        |

Only the latest patch release of each supported minor version receives
security updates.

---

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, please report security concerns privately:

1. **Email**: Send a detailed report to the maintainers via the contact
   information in the repository.
2. **GitHub Private Reporting**: Use GitHub's
   [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
   feature on this repository (if enabled).

### What to Include

- Description of the vulnerability.
- Steps to reproduce.
- Potential impact assessment.
- Suggested fix (if any).
- Your contact information for follow-up.

### Response Timeline

| Action | Timeline |
|--------|----------|
| Acknowledgement | Within 48 hours |
| Initial assessment | Within 5 business days |
| Fix development | Depends on severity |
| Patch release | As soon as fix is verified |
| Public disclosure | After patch is released |

---

## Security Measures in This Package

### Header Redaction

`LoggingHandler` automatically redacts sensitive headers before logging:

| Header | Redacted by Default |
|--------|-------------------|
| `authorization` | Yes |
| `proxy-authorization` | Yes |
| `cookie` | Yes |
| `set-cookie` | Yes |
| `x-api-key` | Yes |

You can customise the redaction set:

```dart
LoggingHandler(
  logHeaders: true,
  redactedHeaders: {'authorization', 'x-api-key', 'x-custom-secret'},
)
```

### Response Body Truncation

`HttpStatusException.body` is capped at 64 KB to prevent unbounded memory
consumption when error responses contain large payloads. Bodies exceeding
the limit are truncated with a `… [truncated N bytes]` suffix.

### No Reflection

This package uses zero `dart:mirrors` — no runtime introspection, no
dynamic code generation. This eliminates an entire class of injection and
information-disclosure vulnerabilities.

### Immutable Request/Response Models

`HttpRequest` and `HttpResponse` are `@immutable final class` types.
Once constructed, they cannot be mutated by middleware or user code,
preventing TOCTOU (time-of-check/time-of-use) vulnerabilities in the
pipeline.

### No Credential Storage

This package never stores, caches, or persists credentials, tokens, or
secrets. Authentication headers must be injected per-request by the caller
(e.g., via a custom `DelegatingHandler`).

---

## Dependencies

This package depends only on well-maintained pub.dev packages:

| Package | Purpose | Security Posture |
|---------|---------|-----------------|
| `http` | HTTP client | Dart team maintained |
| `logging` | Structured logging | Dart team maintained |
| `meta` | Annotations | Dart team maintained |

No transitive dependencies beyond the Dart SDK and these three packages.

---

## Best Practices for Users

1. **Always dispose clients** — Call `client.dispose()` to release resources
   and close HTTP connections.
2. **Use header redaction** — Enable `logHeaders: true` only with
   `redactedHeaders` configured for your sensitive headers.
3. **Set timeouts** — Always configure `TimeoutPolicy` to prevent requests
   from hanging indefinitely.
4. **Limit concurrency** — Use `BulkheadPolicy` or `BulkheadIsolationPolicy`
   to prevent resource exhaustion under load.
5. **Pin dependencies** — Use exact version constraints in production to
   prevent supply-chain attacks via transitive dependency updates.
