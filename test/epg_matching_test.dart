import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/epg_matching.dart';
import 'package:iptvs/sources/source.dart';

Channel _ch(String id, String name, {String? tvgId}) => Channel(
  id: id,
  name: name,
  extra: tvgId == null ? const {} : {'tvgId': tvgId},
);

void main() {
  group('normalizeChannelName', () {
    test('folds case, punctuation and spacing', () {
      expect(normalizeChannelName('Digi Sport 1'), 'digisport1');
      expect(normalizeChannelName('digi-sport_1'), 'digisport1');
      expect(normalizeChannelName('  DIGI   SPORT 1  '), 'digisport1');
    });

    test('folds diacritics, including the Romanian comma-below forms', () {
      expect(normalizeChannelName('Știri'), normalizeChannelName('Stiri'));
      // U+0219 (comma below) vs U+015F (cedilla) are distinct code points that
      // a playlist and a guide routinely disagree on.
      expect(normalizeChannelName('Şansa'), normalizeChannelName('Șansa'));
      expect(normalizeChannelName('Télé'), 'tele');
    });

    test('drops quality markers as whole words only', () {
      expect(
        normalizeChannelName('Eurosport 1 HD'),
        normalizeChannelName('Eurosport 1'),
      );
      expect(
        normalizeChannelName('Film Now FHD'),
        normalizeChannelName('Film Now SD'),
      );
      // "hd" inside a name is part of the name.
      expect(normalizeChannelName('HDNet'), 'hdnet');
      expect(normalizeChannelName('Sharjah'), 'sharjah');
    });

    test('strips a leading country tag only with an explicit separator', () {
      expect(normalizeChannelName('RO: Digi Sport 1'), 'digisport1');
      expect(normalizeChannelName('UK | Sky Sports'), 'skysports');
      expect(normalizeChannelName('|FR| TF1'), 'tf1');
      // No separator: the first word is part of the name.
      expect(normalizeChannelName('Film Now'), 'filmnow');
      expect(normalizeChannelName('BBC One'), 'bbcone');
    });

    test('keeps parenthesised disambiguators', () {
      expect(
        normalizeChannelName('HBO (RO)'),
        isNot(normalizeChannelName('HBO (HU)')),
      );
    });

    test('returns empty when nothing identifying survives', () {
      expect(normalizeChannelName('---'), '');
      expect(normalizeChannelName('HD'), '');
      expect(normalizeChannelName(''), '');
    });
  });

  group('buildChannelNameIndex', () {
    test('groups HD/SD variants of one channel under one key', () {
      final index = buildChannelNameIndex([
        _ch('a', 'Digi Sport 1 HD'),
        _ch('b', 'Digi Sport 1 SD'),
        _ch('c', 'Pro TV'),
      ]);
      expect(index['digisport1'], ['a', 'b']);
      expect(index['protv'], ['c']);
    });

    test('skips channels whose name normalises to nothing', () {
      expect(buildChannelNameIndex([_ch('a', '***')]), isEmpty);
    });
  });

  group('XmltvChannelResolver', () {
    test('a guide that declares nothing is pure tvg-id matching', () {
      final channels = [_ch('a', 'Pro TV', tvgId: 'protv.ro')];
      final r = XmltvChannelResolver(
        tvgIdToChannelId: buildTvgIdIndex(channels),
        nameToChannelIds: buildChannelNameIndex(channels),
      );
      expect(r.resolve('protv.ro'), ['a']);
      expect(r.resolve('unknown.id'), isEmpty);
    });

    test('an exact id claims its channel', () {
      final channels = [_ch('a', 'Pro TV', tvgId: 'protv.ro')];
      final r = XmltvChannelResolver(
        tvgIdToChannelId: buildTvgIdIndex(channels),
        nameToChannelIds: buildChannelNameIndex(channels),
      );
      r.declareChannel('protv.ro', const ['Pro TV']);
      expect(r.resolve('protv.ro'), ['a']);
    });

    test('a name claims a channel whose tvg-id the guide does not carry', () {
      // The case the whole feature exists for: the playlist's tvg-ids are
      // provider-specific junk, the third-party guide numbers channels its own
      // way, and only the names line up.
      final channels = [_ch('a', 'RO: Pro TV HD', tvgId: 'provider-8821')];
      final r = XmltvChannelResolver(
        tvgIdToChannelId: buildTvgIdIndex(channels),
        nameToChannelIds: buildChannelNameIndex(channels),
      );
      r.declareChannel('ProTV.ro', const ['Pro TV']);
      expect(r.resolve('ProTV.ro'), ['a']);
    });

    test('one guide channel feeds every HD/SD variant of our channel', () {
      final channels = [
        _ch('a', 'Digi Sport 1 HD'),
        _ch('b', 'Digi Sport 1 SD'),
      ];
      final r = XmltvChannelResolver(
        tvgIdToChannelId: buildTvgIdIndex(channels),
        nameToChannelIds: buildChannelNameIndex(channels),
      );
      r.declareChannel('digisport1', const ['Digi Sport 1']);
      expect(r.resolve('digisport1'), ['a', 'b']);
    });

    test('an exact id beats a name match declared earlier in the document', () {
      final channels = [_ch('a', 'Pro TV', tvgId: 'protv.ro')];
      final r = XmltvChannelResolver(
        tvgIdToChannelId: buildTvgIdIndex(channels),
        nameToChannelIds: buildChannelNameIndex(channels),
      );
      // The name-matching candidate is declared FIRST; the exact one second.
      // Document order must not decide this.
      r.declareChannel('some-other-id', const ['Pro TV']);
      r.declareChannel('protv.ro', const ['Pro TV Romania']);
      expect(r.resolve('protv.ro'), ['a']);
      expect(r.resolve('some-other-id'), isEmpty);
    });

    test('two guide channels contesting one name give it to neither', () {
      final channels = [_ch('a', 'Sport 1')];
      final r = XmltvChannelResolver(
        tvgIdToChannelId: buildTvgIdIndex(channels),
        nameToChannelIds: buildChannelNameIndex(channels),
      );
      r.declareChannel('sport1.de', const ['Sport 1']);
      r.declareChannel('sport1.pl', const ['Sport 1']);
      expect(r.resolve('sport1.de'), isEmpty);
      expect(r.resolve('sport1.pl'), isEmpty);
    });

    test('a third claimant cannot pick up a contested channel', () {
      final channels = [_ch('a', 'Sport 1')];
      final r = XmltvChannelResolver(
        tvgIdToChannelId: buildTvgIdIndex(channels),
        nameToChannelIds: buildChannelNameIndex(channels),
      );
      r.declareChannel('sport1.de', const ['Sport 1']);
      r.declareChannel('sport1.pl', const ['Sport 1']);
      r.declareChannel('sport1.at', const ['Sport 1']);
      expect(r.resolve('sport1.de'), isEmpty);
      expect(r.resolve('sport1.pl'), isEmpty);
      expect(r.resolve('sport1.at'), isEmpty);
    });

    test('an undeclared exact id cannot take a name-claimed channel', () {
      // Our channel carries tvg-id "x". The guide declares "y" by name (which
      // claims it) and never declares "x", but emits a programme on "x".
      // Honouring that would put two overlapping schedules on one channel.
      final channels = [_ch('a', 'Pro TV', tvgId: 'x')];
      final r = XmltvChannelResolver(
        tvgIdToChannelId: buildTvgIdIndex(channels),
        nameToChannelIds: buildChannelNameIndex(channels),
      );
      r.declareChannel('y', const ['Pro TV']);
      expect(r.resolve('y'), ['a']);
      expect(r.resolve('x'), isEmpty);
    });

    test('multiple display names all count', () {
      final channels = [_ch('a', 'TVR 1')];
      final r = XmltvChannelResolver(
        tvgIdToChannelId: buildTvgIdIndex(channels),
        nameToChannelIds: buildChannelNameIndex(channels),
      );
      r.declareChannel('tvr.one', const ['Televiziunea Romana 1', 'TVR1']);
      expect(r.resolve('tvr.one'), ['a']);
    });

    test('name matching is off when no name index is supplied', () {
      final channels = [_ch('a', 'Pro TV', tvgId: 'x')];
      final r = XmltvChannelResolver(
        tvgIdToChannelId: buildTvgIdIndex(channels),
      );
      r.declareChannel('y', const ['Pro TV']);
      expect(r.resolve('y'), isEmpty);
      expect(r.resolve('x'), ['a']);
    });

    test('declarations after the freeze are ignored', () {
      final channels = [_ch('a', 'Pro TV')];
      final r = XmltvChannelResolver(
        tvgIdToChannelId: buildTvgIdIndex(channels),
        nameToChannelIds: buildChannelNameIndex(channels),
      );
      expect(r.isFrozen, isFalse);
      expect(r.resolve('anything'), isEmpty);
      expect(r.isFrozen, isTrue);
      r.declareChannel('protv', const ['Pro TV']);
      expect(r.resolve('protv'), isEmpty);
    });

    test('resolve memoises the undeclared-id answer', () {
      final channels = [_ch('a', 'Pro TV', tvgId: 'x')];
      final r = XmltvChannelResolver(
        tvgIdToChannelId: buildTvgIdIndex(channels),
      );
      expect(identical(r.resolve('x'), r.resolve('x')), isTrue);
    });
  });

  group('quality tokens do not eat channel identities', () {
    test('"WWE Raw" stays distinct from "WWE"', () {
      // 'raw' is a real part of a channel name, unlike hd/fhd/backup. Stripping
      // it collapsed the two, so one guide entry would paint WWE's schedule
      // onto WWE Raw.
      expect(
        normalizeChannelName('WWE Raw'),
        isNot(normalizeChannelName('WWE')),
      );
      expect(normalizeChannelName('WWE Raw HD'), normalizeChannelName('WWE Raw'));
    });

    test('a backup feed still folds onto its channel', () {
      expect(
        normalizeChannelName('Sky Sports Backup'),
        normalizeChannelName('Sky Sports'),
      );
    });
  });

  group('epgNameIndexFor', () {
    final channels = [_ch('a', 'Pro TV'), _ch('b', 'Digi Sport 1')];

    test('is empty with no user-added guides', () {
      // Name matching is for user-added guides only: a provider's own guide
      // stays on exact tvg-id matching, so an install that adds no guide sees
      // no behaviour change and pays no index-building cost.
      expect(epgNameIndexFor(channels, extraCount: 0), isEmpty);
      expect(epgNameIndexFor(channels, extraCount: -1), isEmpty);
    });

    test('builds the index once there is a user-added guide', () {
      final index = epgNameIndexFor(channels, extraCount: 1);
      expect(index['protv'], ['a']);
      expect(index['digisport1'], ['b']);
    });
  });
}
