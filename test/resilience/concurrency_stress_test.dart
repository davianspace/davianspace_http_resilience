// ignore_for_file: lines_longer_than_80_chars

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:test/test.dart';

//
//  Concurrency stress tests
//
//  These tests launch many concurrent futures and verify that semaphore-based
//  policies (Bulkhead, BulkheadIsolation) never violate their invariants even
//  when dozens of coroutines interact simultaneously.
//

void main() {
  group('BulkheadResiliencePolicy  concurrency invariants', () {
    test('activeCount never exceeds maxConcurrency under concurrent load',
        () async {
      const maxConcurrent = 5;
      // BulkheadResiliencePolicy uses `maxConcurrency` (not maxConcurrentRequests)
      final policy = BulkheadResiliencePolicy(
        maxConcurrency: maxConcurrent,
        maxQueueDepth: 50,
        queueTimeout: const Duration(seconds: 5),
      );

      int peakActive = 0;

      Future<void> runOne() async {
        try {
          await policy.execute(() async {
            // Sample inside the callback — this is where concurrency is live.
            if (policy.activeCount > peakActive) {
              peakActive = policy.activeCount;
            }
            await Future<void>.delayed(Duration.zero);
            return 'ok';
          });
        } on BulkheadRejectedException {
          // Some may be rejected — expected and valid.
        }
      }

      await Future.wait([for (var i = 0; i < 30; i++) runOne()]);

      expect(
        peakActive,
        lessThanOrEqualTo(maxConcurrent),
        reason:
            'activeCount must never exceed maxConcurrency ($maxConcurrent), '
            'but peaked at $peakActive',
      );
    });

    test('queuedCount never exceeds maxQueueDepth', () async {
      const maxQueue = 5;
      final policy = BulkheadResiliencePolicy(
        maxConcurrency: 1,
        maxQueueDepth: maxQueue,
        queueTimeout: const Duration(seconds: 5),
      );

      int peakQueued = 0;

      Future<void> runOne(int index) async {
        try {
          await policy.execute(() async {
            await Future<void>.delayed(Duration.zero);
            return 'ok';
          });
        } on BulkheadRejectedException {
          // expected for overflow requests
        }
        if (policy.queuedCount > peakQueued) peakQueued = policy.queuedCount;
      }

      await Future.wait([for (var i = 0; i < 20; i++) runOne(i)]);

      expect(
        peakQueued,
        lessThanOrEqualTo(maxQueue),
        reason: 'queuedCount must not exceed maxQueueDepth ($maxQueue), '
            'but peaked at $peakQueued',
      );
    });

    test('all requests either succeed or get a BulkheadRejectedException',
        () async {
      final policy = BulkheadResiliencePolicy(
        maxConcurrency: 3,
        maxQueueDepth: 5,
        queueTimeout: const Duration(seconds: 5),
      );

      int successes = 0;
      int rejections = 0;

      Future<void> runOne() async {
        try {
          await policy.execute(() async {
            await Future<void>.delayed(Duration.zero);
            return 'done';
          });
          successes++;
        } on BulkheadRejectedException {
          rejections++;
        }
      }

      await Future.wait([for (var i = 0; i < 25; i++) runOne()]);

      expect(
        successes + rejections,
        25,
        reason: 'all 25 requests should have succeeded or been rejected',
      );
    });

    test('after all concurrent calls finish, activeCount and queuedCount are 0',
        () async {
      final policy = BulkheadResiliencePolicy(
        maxConcurrency: 4,
        maxQueueDepth: 20,
        queueTimeout: const Duration(seconds: 5),
      );

      await Future.wait([
        for (var i = 0; i < 15; i++)
          policy.execute(() async {
            await Future<void>.delayed(Duration.zero);
            return 'ok';
          }).catchError((_) => 'rejected'),
      ]);

      expect(
        policy.activeCount,
        0,
        reason: 'activeCount must be 0 after all calls complete',
      );
      expect(
        policy.queuedCount,
        0,
        reason: 'queuedCount must be 0 after all calls complete',
      );
    });
  });

  //
  //  BulkheadIsolationResiliencePolicy
  //

  group('BulkheadIsolationResiliencePolicy  concurrency invariants', () {
    test(
        'activeCount never exceeds maxConcurrentRequests under concurrent load',
        () async {
      const maxConcurrent = 4;
      // BulkheadIsolationResiliencePolicy uses `maxConcurrentRequests`
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: maxConcurrent,
        maxQueueSize: 50,
        queueTimeout: const Duration(seconds: 5),
      );

      int peakActive = 0;

      Future<void> runOne() async {
        try {
          await policy.execute(() async {
            await Future<void>.delayed(Duration.zero);
            return 'ok';
          });
        } on BulkheadRejectedException {
          // expected for overflow
        }
        if (policy.activeCount > peakActive) peakActive = policy.activeCount;
      }

      await Future.wait([for (var i = 0; i < 30; i++) runOne()]);

      expect(
        peakActive,
        lessThanOrEqualTo(maxConcurrent),
        reason:
            'BulkheadIsolationResiliencePolicy activeCount peaked at $peakActive '
            '(limit: $maxConcurrent)',
      );
    });

    test('counters return to zero after all calls settle', () async {
      final policy = BulkheadIsolationResiliencePolicy(
        maxConcurrentRequests: 5,
        maxQueueSize: 20,
      );

      await Future.wait([
        for (var i = 0; i < 12; i++)
          policy.execute(() async {
            await Future<void>.delayed(Duration.zero);
            return 'done';
          }).catchError((_) => 'err'),
      ]);

      expect(policy.activeCount, 0);
      expect(policy.queuedCount, 0);
    });
  });

  //
  //  PolicyWrap concurrency
  //

  group('PolicyWrap  concurrent executions are isolated', () {
    test('10 concurrent PolicyWrap executions each get independent results',
        () async {
      final policy = Policy.wrap([
        Policy.retry(maxRetries: 1),
        Policy.bulkheadIsolation(
          maxConcurrentRequests: 15,
          maxQueueSize: 5,
        ),
      ]);

      final results = <int>[];
      await Future.wait([
        for (var i = 0; i < 10; i++)
          policy.execute(() async {
            await Future<void>.delayed(Duration.zero);
            return i;
          }).then(results.add),
      ]);

      expect(results.length, 10, reason: 'all 10 executions should complete');
      expect(results.toSet().length, 10, reason: 'each result must be unique');
    });
  });
}
