# Contributing to davianspace_http_resilience

Thank you for your interest in contributing! This document provides guidelines
and instructions for contributing to this project.

---

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Coding Standards](#coding-standards)
- [Testing Requirements](#testing-requirements)
- [Pull Request Process](#pull-request-process)
- [Commit Convention](#commit-convention)
- [Architecture Guidelines](#architecture-guidelines)
- [Documentation](#documentation)
- [Reporting Issues](#reporting-issues)

---

## Code of Conduct

This project follows the [Contributor Covenant](https://www.contributor-covenant.org/)
code of conduct. By participating, you are expected to uphold this code.
Please report unacceptable behaviour to the maintainers.

---

## Getting Started

1. Fork the repository on GitHub.
2. Clone your fork locally.
3. Create a feature branch from `main`.
4. Make your changes.
5. Run the full quality gate before pushing.
6. Open a pull request against `main`.

---

## Development Setup

### Prerequisites

- **Dart SDK** `>=3.0.0 <4.0.0`
- Git

### Setup

```bash
git clone https://github.com/<your-fork>/davianspace_http_resilience.git
cd davianspace_http_resilience
dart pub get
```

### Quality Gate

Run all checks before every commit:

```bash
# Static analysis (zero issues required)
dart analyze --fatal-infos

# Full test suite (926+ tests must pass)
dart test

# Format check
dart format --set-exit-if-changed .
```

All three commands must pass with zero errors before a PR will be reviewed.

---

## Coding Standards

### Language & Analysis

- **Strict mode enabled**: `strict-casts`, `strict-inference`, `strict-raw-types`
  are all `true` in `analysis_options.yaml`.
- **Zero tolerance**: `dart analyze --fatal-infos` must produce zero issues.
- **Formatting**: `dart format` with default settings.

### Style Rules

| Rule | Guideline |
|------|-----------|
| **Classes** | Use `final class` for all concrete types. Use `sealed class` for closed hierarchies. |
| **Immutability** | Prefer `final` fields. Use `@immutable` annotation on value types. |
| **Const constructors** | Always provide `const` constructors where possible. |
| **Named parameters** | Required named parameters first. Use `@required` via `meta` package. |
| **Trailing commas** | Required on all multi-line argument lists. |
| **Single quotes** | Use single quotes for strings. |
| **Relative imports** | Use relative imports within `lib/src/`. |
| **Documentation** | All public APIs must have DartDoc comments with `///`. |
| **Assertions** | Use `assert()` in constructors for parameter validation. |

### Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| Classes | PascalCase | `RetryResiliencePolicy` |
| Methods / functions | camelCase | `buildPipeline()` |
| Constants | camelCase | `maxBodyBytes` |
| Private members | `_` prefix | `_defaultRandom` |
| Type parameters | Single uppercase | `T`, `R` |
| File names | snake_case | `retry_resilience_policy.dart` |
| Test files | `*_test.dart` suffix | `retry_resilience_policy_test.dart` |

---

## Testing Requirements

### Coverage

- Every new public API must have corresponding unit tests.
- Bug fixes must include a regression test.
- Target: all existing tests must continue to pass (926+).

### Test Organisation

Mirror the `lib/src/` directory structure under `test/`:

```
lib/src/resilience/retry_resilience_policy.dart
  →  test/resilience/retry_resilience_policy_test.dart
```

### Test Style

```dart
import 'package:test/test.dart';

void main() {
  group('RetryResiliencePolicy', () {
    group('execute', () {
      test('retries up to maxRetries on transient failure', () async {
        // Arrange
        final policy = RetryResiliencePolicy(maxRetries: 3);
        var attempts = 0;

        // Act
        final result = await policy.execute(() async {
          attempts++;
          if (attempts < 3) throw Exception('transient');
          return 'ok';
        });

        // Assert
        expect(result, equals('ok'));
        expect(attempts, equals(3));
      });
    });
  });
}
```

### What to Test

| Category | What to Verify |
|----------|---------------|
| **Happy path** | Normal operation with valid inputs |
| **Error paths** | Exceptions, invalid arguments, edge cases |
| **Boundary conditions** | Zero, one, max values |
| **Concurrency** | Under parallel execution (use `concurrency_stress_test.dart` as reference) |
| **Disposal** | Resources are released after `dispose()` |
| **Configuration** | JSON parsing, default values, type validation |

---

## Pull Request Process

### Before Opening a PR

1. **Run the full quality gate** (see above).
2. **Update documentation** — README, CHANGELOG, API docs as needed.
3. **Add tests** for new functionality or bug fixes.
4. **Keep commits focused** — one logical change per commit.

### PR Template

```markdown
## Description
Brief description of the change.

## Type
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update
- [ ] Refactoring (no functional change)

## Checklist
- [ ] `dart analyze --fatal-infos` passes (0 issues)
- [ ] `dart test` passes (all tests green)
- [ ] `dart format --set-exit-if-changed .` passes
- [ ] New tests added for new functionality
- [ ] CHANGELOG.md updated
- [ ] Documentation updated (if applicable)
```

### Review Criteria

- Follows coding standards (above).
- All CI checks pass.
- Tests are meaningful, not just coverage padding.
- No unnecessary dependencies added.
- Public API additions include DartDoc comments.
- Breaking changes are documented and justified.

---

## Commit Convention

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

### Types

| Type | Purpose |
|------|---------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code restructuring (no behaviour change) |
| `test` | Adding or updating tests |
| `perf` | Performance improvement |
| `chore` | Build, CI, tooling changes |

### Examples

```
feat(config): add hedging and fallback JSON configuration sections
fix(bulkhead): prevent semaphore slot leak on cancellation
docs(readme): add migration guide for 1.0.0 → 1.0.1
test(retry): add onRetry callback integration tests
refactor(backoff): share single Random instance across strategies
```

---

## Architecture Guidelines

### Layer Rules

1. **Core** (`src/core/`) — Value types only. No dependencies on other layers.
2. **Pipeline** (`src/pipeline/`) — Handler abstractions. Depends only on Core.
3. **Policies** (`src/policies/`) — Immutable config objects. Depends on Pipeline + Core.
4. **Handlers** (`src/handlers/`) — Concrete middleware. Depends on Policies + Pipeline + Core.
5. **Factory** (`src/factory/`) — Client construction. Depends on Handlers + Pipeline + Core.
6. **Resilience** (`src/resilience/`) — Transport-agnostic engine. Depends on Core only.
7. **Config** (`src/config/`) — JSON config layer. Depends on Policies + Resilience.

**Never add upward dependencies** (e.g., Core must never depend on Factory).

### Adding a New Policy

1. Create the policy config in `src/policies/new_policy.dart`.
2. Create the handler in `src/handlers/new_handler.dart`.
3. Add the transport-agnostic version in `src/resilience/new_resilience_policy.dart`.
4. Add the config section in `src/config/resilience_config.dart`.
5. Add the parser in `src/config/resilience_config_loader.dart`.
6. Add the binder method in `src/config/resilience_config_binder.dart`.
7. Export from the appropriate barrel files.
8. Add tests for all new code.
9. Update README, CHANGELOG, and architecture docs.

---

## Documentation

### DartDoc Standards

- Every public class, method, field, and constructor must have `///` docs.
- Include code examples for key APIs (fenced in ` ```dart ` blocks).
- Cross-reference related types with `[TypeName]` bracket notation.
- Document parameter constraints in `assert()` statements and comments.

### Files to Update

| Change Type | Files to Update |
|-------------|-----------------|
| New feature | README.md, CHANGELOG.md, library doc comment |
| Bug fix | CHANGELOG.md |
| New policy | README.md, CHANGELOG.md, doc/architecture.md, library doc |
| Breaking change | README.md (Migration Guide), CHANGELOG.md |

---

## Reporting Issues

### Bug Reports

Include:
1. Dart SDK version (`dart --version`).
2. Package version.
3. Minimal reproduction code.
4. Expected vs actual behaviour.
5. Stack trace (if applicable).

### Feature Requests

Include:
1. Use case description.
2. Proposed API surface (if any).
3. Alternatives considered.

---

Thank you for contributing!
