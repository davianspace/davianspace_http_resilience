import 'package:davianspace_dependencyinjection/davianspace_dependencyinjection.dart';

import '../factory/http_client_factory.dart';
import '../factory/resilient_http_client.dart';

// =============================================================================
// HttpResilienceServiceCollectionExtensions
// =============================================================================

/// Extension methods that register `davianspace_http_resilience` types into
/// `ServiceCollection`.
///
/// ## Quick start
///
/// ```dart
/// final provider = ServiceCollection()
///   ..addHttpClientFactory((factory) {
///     factory
///       ..configureDefaults((b) => b
///           .withDefaultHeader('Accept', 'application/json')
///           .withLogging())
///       ..addTypedClient<CatalogService>(
///           (client) => CatalogService(client),
///           clientName: 'catalog',
///           configure: (b) => b
///               .withBaseUri(Uri.parse('https://catalog.svc/v2'))
///               .withRetry(RetryPolicy.exponential(maxRetries: 3))
///               .withCircuitBreaker(CircuitBreakerPolicy(circuitName: 'catalog'))
///               .withTimeout(TimeoutPolicy(timeout: Duration(seconds: 10))),
///         );
///   })
///   ..addTypedHttpClient<PaymentsService>(
///     (client) => PaymentsService(client),
///     clientName: 'payments',
///     configure: (b) => b
///         .withBaseUri(Uri.parse('https://payments.internal/v1'))
///         .withRetry(RetryPolicy.exponential(maxRetries: 2)),
///   )
///   .buildServiceProvider();
///
/// // Inject:
/// final catalog = provider.getRequired<CatalogService>();
/// ```
extension HttpResilienceServiceCollectionExtensions on ServiceCollection {
  // -------------------------------------------------------------------------
  // addHttpClientFactory
  // -------------------------------------------------------------------------

  /// Registers a singleton [HttpClientFactory], optionally applying
  /// [configure] to set up defaults and named clients.
  ///
  /// Uses try-add semantics: if [HttpClientFactory] is already registered
  /// this method is a no-op (the existing registration is kept).
  ///
  /// ```dart
  /// services.addHttpClientFactory((factory) {
  ///   factory.configureDefaults((b) => b
  ///       .withDefaultHeader('Accept', 'application/json')
  ///       .withLogging());
  /// });
  /// ```
  ServiceCollection addHttpClientFactory([
    void Function(HttpClientFactory factory)? configure,
  ]) {
    if (!isRegistered<HttpClientFactory>()) {
      addSingletonFactory<HttpClientFactory>((_) {
        final f = HttpClientFactory();
        configure?.call(f);
        return f;
      });
    }
    return this;
  }

  // -------------------------------------------------------------------------
  // addTypedHttpClient
  // -------------------------------------------------------------------------

  /// Registers [TClient] as a **transient** service backed by a named HTTP
  /// client managed by [HttpClientFactory].
  ///
  /// [create]       – wraps a [ResilientHttpClient] into your service type.
  /// [clientName]   – optional name for the underlying named client;
  ///                  defaults to the empty-string default client.
  /// [configure]    – optional pipeline builder callback applied to the
  ///                  underlying named client.
  ///
  /// [HttpClientFactory] is automatically registered as a singleton if it has
  /// not been explicitly registered via [addHttpClientFactory].
  ///
  /// ```dart
  /// services.addTypedHttpClient<CatalogService>(
  ///   (client) => CatalogService(client),
  ///   clientName: 'catalog',
  ///   configure: (b) => b
  ///       .withBaseUri(Uri.parse('https://catalog.svc/v2'))
  ///       .withRetry(RetryPolicy.exponential(maxRetries: 3)),
  /// );
  ///
  /// // Inject:
  /// final catalog = provider.getRequired<CatalogService>();
  /// ```
  ServiceCollection addTypedHttpClient<TClient extends Object>(
    TClient Function(ResilientHttpClient client) create, {
    String clientName = '',
    void Function(HttpClientBuilder builder)? configure,
  }) {
    // Ensure a factory singleton is present.
    addHttpClientFactory();

    // Configure the typed client on the factory once the container is fully
    // assembled (onContainerBuilt runs before any service is resolved).
    onContainerBuilt((provider) {
      final factory = provider.getRequired<HttpClientFactory>();
      factory.addTypedClient<TClient>(
        create,
        clientName: clientName,
        configure: configure,
      );
    });

    // The typed client is transient: each resolution calls createTypedClient
    // on the shared factory, which caches internally per type.
    addTransientFactory<TClient>(
      (p) => p.getRequired<HttpClientFactory>().createTypedClient<TClient>(),
    );

    return this;
  }
}
