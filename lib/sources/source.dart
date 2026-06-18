import 'package:flutter/foundation.dart';

/// Provider-agnostic domain model + interface for an IPTV source.
///
/// Stalker, Xtream Codes, and M3U each implement [Source], so the rest of the
/// app never needs to know which kind of provider it's talking to. To add a
/// new provider you implement this one interface and change nothing else.

@immutable
class Category {
  final String id;
  final String title;
  const Category({required this.id, required this.title});
}

@immutable
class Channel {
  final String id;
  final String name;
  final String? logo;
  final String? categoryId;
  final int? number;

  /// Provider-specific payload the owning [Source] knows how to interpret in
  /// [Source.resolve] — e.g. Stalker's `cmd`, Xtream's stream id. Keeps
  /// provider details out of the shared model.
  final Map<String, dynamic> extra;

  const Channel({
    required this.id,
    required this.name,
    this.logo,
    this.categoryId,
    this.number,
    this.extra = const {},
  });
}

/// A resolved, playable stream: the URL plus any HTTP headers the player must
/// send (User-Agent, Referer, etc.). Stalker and Xtream often need a MAG
/// User-Agent here; M3U usually needs nothing.
///
/// [isLive] is set by the owning [Source] — liveness is provider metadata, not
/// something to infer from the stream (an HLS live window reports a finite
/// duration, which looks just like VOD). Live streams get no seek bar; VOD does.
@immutable
class StreamInfo {
  final String url;
  final Map<String, String> headers;
  final bool isLive;
  const StreamInfo({
    required this.url,
    this.headers = const {},
    this.isLive = true,
  });
}

@immutable
class Programme {
  final String channelId;
  final DateTime start;
  final DateTime stop;
  final String title;
  final String? description;

  const Programme({
    required this.channelId,
    required this.start,
    required this.stop,
    required this.title,
    this.description,
  });
}

abstract class Source {
  /// Stable identifier, used as the cache key for this source's data.
  String get id;

  /// Display name for the UI.
  String get name;

  /// Authenticate / prepare the source. For M3U this may be a no-op.
  Future<void> connect();

  /// Live TV categories.
  Future<List<Category>> categories();

  /// Channels, optionally filtered to a single category.
  Future<List<Channel>> channels({String? categoryId});

  /// Turn a channel into a playable stream. For Stalker this is where
  /// create_link is called — the URL is short-lived, so resolve at play time,
  /// never ahead of it.
  Future<StreamInfo> resolve(Channel channel);

  /// Electronic program guide for roughly the next few hours, given the
  /// source's [channels] (XMLTV sources need them to map tvg-id → channel id;
  /// Stalker ignores them and keys by channel id directly). Programmes are
  /// keyed via [Programme.channelId]. Sources without EPG return an empty list.
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  /// Release any held resources.
  Future<void> dispose() async {}
}