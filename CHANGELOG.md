## 1.0.1
- feat: introduce `HiveCache` for type-safe caching with expiration handling
  
  ```dart
  // Create a cache for a specific type
  class UserCache extends HiveCache<User> {
    UserCache([User? initialValue]) : super(initialValue ?? User.empty());
    
    @override
    String get id => 'current_user'; // Optional unique ID
    
    @override
    Duration get cacheValidityDuration => const Duration(days: 7); // Custom expiration
  }
  
  // Initialize the cache
  await HiveCache.initialize<User>(
    storageDirectory: HydratedStorageDirectory((await getTemporaryDirectory()).path),
    name: 'users', // Optional name
    encryptionCipher: HydratedAesCipher(encryptionKey), // Optional encryption
  );
  
  // Use the cache
  final userCache = UserCache();
  final user = userCache.cachedData; // Get current data
  await userCache.write(newUser); // Update cached data
  userCache.cachedDataStream.listen((user) => print('User updated: $user')); // Listen for changes
  ```

## 1.0.0

- Initial version.
