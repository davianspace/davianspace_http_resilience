import '../core/http_context.dart';
import '../core/http_response.dart';
import '../pipeline/delegating_handler.dart';
import '../resilience/resilience_policy.dart';

/// A [DelegatingHandler] that wraps the remainder of the HTTP pipeline in a
/// [ResiliencePolicy]'s execution context.
///
/// [PolicyHandler] bridges the two layers of the library:
///
/// * The **middleware pipeline** layer ([DelegatingHandler] chain).
/// * The **free-standing policy engine** layer ([ResiliencePolicy]).
///
/// When a request reaches this handler, [`policy.execute`] is invoked with a
/// closure that calls [`innerHandler.send`]. The policy then controls whether
/// (and how many times) the inner pipeline is invoked, subject to its own
/// rules (retries, timeouts, circuit-breaking, etc.).
///
/// ## Recommended placement
///
/// Attach a [PolicyHandler] near the **outermost** position in the pipeline so
/// that the policy governs the entire downstream chain including circuit
/// breakers and timeouts:
///
/// ```
/// LoggingHandler                    ← 1. full round-trip logging
///   PolicyHandler(retryPolicy)      ← 2. retry wraps everything below
///     PolicyHandler(circuitBreaker) ← 3. circuit guard per-attempt
///       PolicyHandler(timeout)      ← 4. deadline per attempt
///         BulkheadHandler           ← 5. concurrency cap
///           TerminalHandler         ← 6. real I/O
/// ```
///
/// ## Usage via [`HttpClientBuilder`]
///
/// The preferred way to add a [PolicyHandler] is through the fluent builder:
///
/// ```dart
/// final client = HttpClientFactory()
///     .addClient('payments', (b) => b
///         .withBaseUri(Uri.parse('https://payments.internal/v1'))
///         .withPolicy(Policy.wrap([
///           Policy.timeout(const Duration(seconds: 10)),
///           Policy.circuitBreaker(circuitName: 'payments', failureThreshold: 5),
///           Policy.retry(maxRetries: 3),
///         ])))
///     .createClient('payments');
/// ```
///
/// ## Direct construction
///
/// ```dart
/// final handler = PolicyHandler(
///   Policy.retry(maxRetries: 3, backoff: const ExponentialBackoff(Duration(milliseconds: 200))),
/// );
/// ```
final class PolicyHandler extends DelegatingHandler {
  /// Creates a [PolicyHandler] that applies [policy] to every request.
  PolicyHandler(this.policy);

  /// The [ResiliencePolicy] applied to every inbound request.
  final ResiliencePolicy policy;

  @override
  Future<HttpResponse> send(HttpContext context) =>
      policy.execute(() => innerHandler.send(context));

  @override
  String toString() => 'PolicyHandler($policy)';
}
