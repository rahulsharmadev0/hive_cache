// ignore_for_file: public_member_api_docs, sdk_version_since, lines_longer_than_80_chars, do_not_use_environment

import 'dart:async';

import 'package:hive_ce/hive.dart';
import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';
import 'package:synchronized/synchronized.dart';

/// Generates a box name with type-specific prefix to prevent box name collisions
@internal
String boxNameGen<T>(String name) => 'hive_cache-$T-$name';

@internal
void debugPrint(dynamic message) {
  if (!const bool.fromEnvironment('dart.vm.product')) {}
}

/// A base class for caching data using Hive.
///
/// This abstract class provides the foundation for type-safe caching with Hive,
/// including expiration handling and error recovery.
abstract class HiveCacheBase<T extends Object?> {
  /// Creates a new [HiveCacheBase] with the given initial value and name
  ///
  /// The [initialValue] will be used when no cached value exists.
  /// The [name] will be used to identify the cache in cached.
  HiveCacheBase(this.initialValue, this.name)
      : _lock = Lock(),
        _box = Hive.box<T>(boxNameGen<T>(name)),
        assert(T != Object, 'HiveCache<T> must be initialized with a specific type.');

  /// The default value to use when no cached value exists
  final T initialValue;

  /// The name of this cache instance
  final String name;

  /// Lock for thread-safe operations
  final Lock _lock;

  /// The underlying Hive box
  final Box<T> _box;

  //--------------------------------------------------------------------------

  /// Duration for which cached data is considered valid
  ///
  /// Set to [Duration.zero] to disable expiration (cache never expires).
  /// Defaults to 30 days.
  /// After this duration, Cache will be reset to [initialValue].
  Duration get cacheValidityDuration => const Duration(days: 30);

  /// Maximum number of items to keep in cache
  ///
  /// When exceeded, oldest items will be removed.
  /// Set to 0 to disable this limit.
  /// Defaults to 100.
  @Deprecated('Currently not implemented, will be in future releases.')
  int get maxCacheItems => 100;

  /// The ID of this cache instance
  ///
  /// Override this to provide a unique identifier for different instances
  /// of the same cache type.
  String get id => '';

  /// The prefix to use for cached keys
  ///
  /// Override this to provide a custom cached prefix.
  /// Defaults to the runtime type of the cache.
  @protected
  String get storagePrefix => runtimeType.toString();

  /// The full cached key used for this cache instance
  @nonVirtual
  String get storageToken => '$storagePrefix$id';

  /// Logger for cache operations
  ///
  /// Override to provide custom logging behavior.
  @protected
  void log(String message, {Object? error, StackTrace? stackTrace}) {
    if (error != null) {
      debugPrint('$message: $error\n$stackTrace');
    } else {
      debugPrint(message);
    }
  }
}

/// Manages cached data with Hive cached, including type-safety,
/// expiration handling, and error recovery.
///
/// ```dart
/// final userCache = UserCache(); // extends HiveCache<User>
///
/// // Read from cache
/// final user = userCache.storageData;
///
/// // Write to cache
/// await userCache.write(newUser);
///
/// // Listen for changes
/// userCache.storageDataStream.listen((user) {
///   // Handle updated user data
/// });
/// ```
abstract class HiveCache<T extends Object?> extends HiveCacheBase<T> {
  /// Creates a new [HiveCache] with the given initial value and name
  ///
  /// If no cached data exists, the [initialValue] will be written to cached.
  HiveCache(T initialValue, [String name = '']) : super(initialValue, name);

  /// Initializes the Hive box for the given type and name
  ///
  /// This must be called before creating any instances of the cache.
  /// If [encryptionCipher] is provided, the box will be encrypted.
  static Future<void> initialize<T extends Object?>({
    required String storageDirectory,
    String name = '',
    HiveAesCipher? encryptionCipher,
  }) async {
    late final Box<T> box;
    final boxName = boxNameGen<T>(name);

    try {
      // Ensure timestamp box is open for expiration tracking
      try {
        await Hive.openBox<int>('hive_cache_timestamp_box');
      } catch (e) {
        // If the box is corrupted, delete and recreate
        await Hive.deleteBoxFromDisk('hive_cache_timestamp_box');
        await Hive.openBox<int>('hive_cache_timestamp_box');
      }

      // Open or initialize the main box
      if (storageDirectory.isEmpty) {
        box = await Hive.openBox<T>(
          boxName,
          encryptionCipher: encryptionCipher,
        );
      } else {
        Hive.init(storageDirectory);
        box = await Hive.openBox<T>(
          boxName,
          encryptionCipher: encryptionCipher,
        );
      }

      if (!box.isOpen) {
        throw Exception('Failed to open Hive box: $boxName');
      }
    } catch (error, stackTrace) {
      debugPrint('Error initializing Hive box error: $error, stackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Box for storing timestamps of when each cache entry was last updated
  static final Box<int> _timestampBox = Hive.box<int>('hive_cache_timestamp_box');

  /// Stream of cached data changes
  ///
  /// This stream emits the current value immediately and then
  /// emits whenever the data changes in the box.
  Stream<T> get cachedDataStream => _box
      .watch(key: storageToken)
      .map((event) => _processData(event.value as T?))
      .cast<T>()
      .startWith(cachedData);

  /// Gets the current cached data
  ///
  /// If the data doesn't exist or has expired, it returns [initialValue].
  /// Can return null if T is nullable and a null value was explicitly cached.
  T get cachedData {
    try {
      final data = _box.get(storageToken, defaultValue: initialValue);
      return _processData(data);
    } catch (error, stackTrace) {
      onError(error, stackTrace);
      if (error is StorageNotFound) rethrow;
      return initialValue;
    }
  }

  /// Writes a value to cached
  ///
  /// This also updates the timestamp for expiration tracking.
  Future<void> write(T value) async => _sync(
        () async => [
          _box.put(storageToken, value),
          _timestampBox.put(storageToken, DateTime.now().millisecondsSinceEpoch),
        ].wait,
      );

  /// Deletes the cached value
  Future<void> delete() async => _sync(() => _box.delete(storageToken));

  /// Clears all cached values for this type
  Future<void> clearAll() async => _sync(_box.clear);

  /// Compacts the database to reclaim cached space
  Future<void> compact() async => _sync(_box.compact);

  /// Called when an error occurs during a cached operation
  ///
  /// Override this to provide custom error handling.
  @protected
  void onError(Object error, [StackTrace? stackTrace]) {
    log('Error reading from cached', error: error, stackTrace: stackTrace);
  }

  /// Process data to handle expiration
  T _processData(T? data) {
    if (_isExpired(data)) return initialValue;
    return data as T;
  }

  /// Synchronizes access to the cached
  ///
  /// This ensures that concurrent operations don't interfere with each other.
  Future<T?> _sync<T>(FutureOr<T> Function() computation, {Duration? timeout}) async {
    if (!_box.isOpen) throw Exception('Box is not open');

    return _lock.synchronized(
      () async {
        try {
          return await computation();
        } catch (error, stackTrace) {
          onError(error, stackTrace);
          if (error is StorageNotFound) rethrow;
          return null;
        }
      },
      timeout: timeout,
    );
  }

  /// Checks if the cached data has expired
  bool _isExpired(T? data) {
    // Do not consider null as expired - it might be an intentionally cached null value
    if (data == null && initialValue != null) return false;

    // If no validity duration set, cache never expires
    if (cacheValidityDuration == Duration.zero) return false;

    final timestamp = HiveCache._timestampBox.get(storageToken);
    if (timestamp == null) return false;

    final now = DateTime.now();
    final expired =
        now.millisecondsSinceEpoch - timestamp > cacheValidityDuration.inMilliseconds;

    // Trigger Data Reset with initaldata if expired
    if (expired) {
      _box.put(storageToken, initialValue);
      _timestampBox.put(storageToken, now.millisecondsSinceEpoch);
      log('Cache expired for $storageToken. Resetting to initial value.');
    }

    return expired;
  }
}

/// Exception thrown when cached is accessed before it is initialized.
class StorageNotFound implements Exception {
  /// Creates a new [StorageNotFound] exception.
  const StorageNotFound();

  @override
  String toString() {
    return 'Storage was accessed before it was initialized.\n'
        'Please ensure that cached has been initialized.\n\n'
        'For example:\n\n'
        'HydratedBloc.cached = await HydratedStorage.build();';
  }
}
