import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../sources/source_config.dart';

/// Persists provider configurations (credentials included) in the OS keychain
/// via flutter_secure_storage, plus which one is active.
class SourceStore {
  final FlutterSecureStorage _storage;

  static const _kSources = 'sources';
  static const _kActive = 'active_source';

  SourceStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  Future<List<SourceConfig>> list() async {
    final raw = await _storage.read(key: _kSources);
    if (raw == null || raw.isEmpty) return const [];
    final arr = jsonDecode(raw) as List;
    return arr
        .map((e) => SourceConfig.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> save(SourceConfig config) async {
    final all = List<SourceConfig>.of(await list());
    final i = all.indexWhere((c) => c.id == config.id);
    if (i >= 0) {
      all[i] = config;
    } else {
      all.add(config);
    }
    await _writeAll(all);
    // First source added becomes the active one automatically.
    if (await activeId() == null) await setActive(config.id);
  }

  Future<void> delete(String id) async {
    final all = List<SourceConfig>.of(await list());
    all.removeWhere((c) => c.id == id);
    await _writeAll(all);
    if (await activeId() == id) {
      await setActive(all.isEmpty ? null : all.first.id);
    }
  }

  Future<String?> activeId() => _storage.read(key: _kActive);

  Future<void> setActive(String? id) async {
    if (id == null) {
      await _storage.delete(key: _kActive);
    } else {
      await _storage.write(key: _kActive, value: id);
    }
  }

  Future<SourceConfig?> activeConfig() async {
    final id = await activeId();
    final all = await list();
    if (all.isEmpty) return null;
    return all.firstWhere(
      (c) => c.id == id,
      orElse: () => all.first,
    );
  }

  Future<void> _writeAll(List<SourceConfig> all) => _storage.write(
        key: _kSources,
        value: jsonEncode(all.map((e) => e.toJson()).toList()),
      );
}