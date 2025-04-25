
## Getting started
```
dependencies:
  meta: ^1.16.0
  hive_ce: ^2.10.1
  hive_cache:
    git:
      url: https://github.com/rahulsharmadev0/hive_cache.git
      ref: main

dev_dependencies:
  hive_ce_generator: ^1.8.2

```

## Usage

```dart

// ----Repositories----
class PersonRepository extends HiveCache<Person?> {
  PersonRepository() : super(null);

  Future<void> edit(Person person) => write(person);

  @override
  Duration get cacheValidityDuration => const Duration(seconds: 10);
}

class FreezedPersonRepository extends HiveCache<FreezedPerson> {
  FreezedPersonRepository() : super(FreezedPerson.sample);

  Future<void> edit(FreezedPerson person) => write(person);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Register Hive adapters
  HiveRegistrar.registerAdapters();

  await HiveCache.initialize<Person?>(storageDirectory: '');
  await HiveCache.initialize<FreezedPerson>(storageDirectory: '');

}
```

