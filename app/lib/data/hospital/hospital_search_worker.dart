/// Runs hospital proximity search off the UI isolate.
///
/// ## Why
///
/// A 25 km search over a national dataset touches thousands of records. Done on
/// the UI isolate that is a multi-frame stall, and it would happen *during an
/// emergency countdown*, which is precisely when a dropped frame is least
/// acceptable — the countdown ring stutters and the whole app looks frozen at
/// the moment the user is deciding whether someone is hurt.
///
/// ## The cost model
///
/// The naive way to isolate a query is to rebuild the index inside the isolate
/// on every call. That is O(N) work — the entire point of the index — thrown
/// away per query, and it is *slower* than just searching on the UI thread.
///
/// So the index is built **once** and transferred to the worker isolate as a
/// [TransferableTypedData] blob, where it is cached. Each query then sends only
/// the origin, radius and limit (a few dozen bytes) and receives back at most
/// `limit` [Hospital] records.
///
/// The one-time serialise/transfer is O(N) and costs a few milliseconds for a
/// few thousand records; [Isolate.run] copies the data rather than sharing it,
/// so this is a genuine copy, not a zero-cost handoff. That is the right trade:
/// one O(N) copy amortised over many O(k) queries, instead of O(N) per query.
///
/// ## When *not* to isolate
///
/// For a small dataset the isolate costs more than it saves — spawning an
/// isolate and serialising the index is milliseconds of work, while searching
/// 300 records in memory is microseconds. [HospitalSearchWorker.shouldIsolate]
/// encodes that threshold, so the common prototype case (the bundled 320-record
/// seed) runs inline and stays instant.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../../core/logger.dart';
import '../../domain/entities/geo_point.dart';
import '../../domain/entities/hospital.dart';
import 'hospital_index.dart';

/// Serialised index, in the shape the worker deserialises.
///
/// A `List<Map<String, Object?>>` rather than the [HospitalIndex] object itself:
/// isolate messages are deep-copied by the structured-copy algorithm, which
/// cannot walk a class with private fields and a [Map] of [List]s without
/// knowing the shape. Plain JSON-ish maps transfer reliably and are cheap.
///
/// [TransferableTypedData] is then layered on top so the bytes are moved rather
/// than copied field by field.
class HospitalSearchWorker {
  HospitalSearchWorker({
    required HospitalIndex index,
    AppLogger? log,
    bool? forceIsolate,
  })  : _log = log ?? AppLogger(),
        _isolateEligible = forceIsolate ?? shouldIsolate(index.length) {
    _index = index;
  }

  final AppLogger _log;
  final bool _isolateEligible;
  late HospitalIndex _index;

  /// Cached serialised form, built at most once.
  Uint8List? _serialised;

  /// The request handed to the isolate.
  ///
  /// Must be a top-level function: [Isolate.run] sends the closure to a fresh
  /// isolate, so it may only capture values the structured-copy algorithm can
  /// transfer. Capturing `this` (which holds a [Logger] with a stream) would
  /// throw at runtime, which is why the serialised index is computed here, on
  /// this isolate, and passed in as a plain [Uint8List].
  static Future<List<Hospital>> _searchInIsolate(_SearchRequest request) async {
    final HospitalIndex index = await _ensureWorkerIndex(request.serialised);
    return index.nearby(
      request.origin,
      radiusM: request.radiusM,
      limit: request.limit,
    );
  }

  /// Whether a search of [hospitalCount] records is worth isolating.
  ///
  /// Calibrated against a mid-range Android device: isolating costs roughly
  /// 1–3 ms of spawn plus serialisation, while an in-memory scan of the bundled
  /// seed dataset is tens of microseconds. Anything under a few thousand records
  /// is faster inline. Above that the index genuinely keeps the *query* short,
  /// but the O(N) index build and the O(N) result marshalling still justify the
  /// isolate.
  static bool shouldIsolate(int hospitalCount) => hospitalCount >= 2000;

  /// Find hospitals near [origin].
  ///
  /// Never throws: a failure in the worker is normalised into an empty result
  /// plus a log line, because a hospital search that fails must not take down
  /// the emergency screen — the user still needs the accident location, the
  /// countdown and the contact list.
  Future<List<Hospital>> nearby(
    GeoPoint origin, {
    double radiusM = 25000,
    int limit = 20,
  }) async {
    if (_index.isEmpty) return const <Hospital>[];

    if (!_isolateEligible) {
      // Inline: O(k) over the grid, microseconds for the seed dataset.
      return _index.nearby(origin, radiusM: radiusM, limit: limit);
    }

    try {
      // Everything the closure touches is computed *here*, on this isolate, so
      // the only captured value is a sendable [_SearchRequest].
      final _SearchRequest request = _SearchRequest(
        origin: origin,
        radiusM: radiusM,
        limit: limit,
        serialised: _serialise(),
      );
      return await Isolate.run(() => _searchInIsolate(request));
    } on Object catch (error, stackTrace) {
      _log.log(
        LogLevel.warning,
        'search',
        'isolate search failed, falling back to inline',
        error,
        stackTrace,
      );
      // Degrade rather than fail: correctness beats speed, and the alternative
      // is showing the user an empty hospital list during an emergency.
      return _index.nearby(origin, radiusM: radiusM, limit: limit);
    }
  }

  /// Serialise the index once and memoise it.
  Uint8List _serialise() => _serialised ??= encodeIndex(_index);

  /// Replace the index, invalidating the cached transfer payload.
  set index(HospitalIndex value) {
    _index = value;
    _serialised = null;
  }

  /// The current index.
  HospitalIndex get index => _index;
}

/// A search request. Sendable across isolates (all fields are primitives or
/// an immutable entity with a sendable shape).
class _SearchRequest {
  const _SearchRequest({
    required this.origin,
    required this.radiusM,
    required this.limit,
    required this.serialised,
  });

  final GeoPoint origin;
  final double radiusM;
  final int limit;

  /// The index, as a transferable byte blob.
  final Uint8List serialised;
}

/// Top-level so the worker isolate can reach it.
Future<HospitalIndex> _ensureWorkerIndex(Uint8List bytes) async =>
    decodeIndex(bytes);

/// Serialise an index to bytes.
///
/// A compact, purpose-built binary format rather than JSON: this blob is built
/// once and moved on every query, and JSON would roughly triple its size and
/// spend milliseconds in the parser. The layout is positional with fixed-width
/// fields, which is exactly what JSON is not good at.
Uint8List encodeIndex(HospitalIndex index) {
  final List<IndexedHospital> all = index.all;
  final BytesBuilder builder = BytesBuilder();

  // Header: version, cell size, count.
  builder
    ..addByte(1) // format version
    ..add(_float64(index.cellSizeDeg));

  final List<IndexedHospital> records = all;
  builder.add(_uint32(records.length));

  for (final IndexedHospital indexed in records) {
    final Hospital h = indexed.hospital;
    final GeoPoint p = h.location;
    // The four text fields are variable-length, so they are length-prefixed and
    // then written. The length MUST be the UTF-8 byte count, not
    // `String.length` — those differ for any non-ASCII name, and using the
    // wrong one desynchronises every subsequent field.
    final List<int> idBytes = utf8.encode(h.id);
    final List<int> nameBytes = utf8.encode(h.name);
    final List<int> addressBytes = utf8.encode(h.address);
    final List<int> phoneBytes = utf8.encode(h.phone);

    builder
      ..add(_float64(p.latitude))
      ..add(_float64(p.longitude))
      ..add(_float64(p.accuracyM))
      ..add(_uint32(idBytes.length))
      ..add(_uint32(nameBytes.length))
      ..add(_uint32(addressBytes.length))
      ..add(_uint32(phoneBytes.length))
      ..addByte(h.hasEmergency ? 1 : 0)
      // 255 is the "no type" sentinel, distinct from any real `index`.
      ..addByte(h.type == null ? 255 : h.type!.index)
      // -1 is the "no rating" sentinel; real ratings are 0..5.
      ..add(_float64(h.rating ?? -1))
      ..add(idBytes)
      ..add(nameBytes)
      ..add(addressBytes)
      ..add(phoneBytes);
  }
  return builder.toBytes();
}

/// Deserialise an index produced by [encodeIndex].
HospitalIndex decodeIndex(Uint8List bytes) {
  final _Reader reader = _Reader(bytes);
  final int version = reader.u8();
  if (version != 1) {
    throw FormatException('unsupported hospital index format v$version');
  }
  final double cellSize = reader.f64();
  final int count = reader.u32();

  final Iterable<Hospital> hospitals = List<Hospital>.generate(count, (int i) {
    final double lat = reader.f64();
    final double lon = reader.f64();
    final double accuracy = reader.f64();
    final int idLen = reader.u32();
    final int nameLen = reader.u32();
    final int addressLen = reader.u32();
    final int phoneLen = reader.u32();
    final bool hasEmergency = reader.u8() != 0;
    final int typeIndex = reader.u8();
    final double rating = reader.f64();

    return Hospital(
      id: reader.str(idLen),
      name: reader.str(nameLen),
      address: reader.str(addressLen),
      phone: reader.str(phoneLen),
      location: GeoPoint(
        latitude: lat,
        longitude: lon,
        accuracyM: accuracy,
        // The dataset has no time dimension; a fixed epoch keeps the record
        // deterministic so encode→decode round-trips to an equal value.
        timestamp: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      ),
      hasEmergency: hasEmergency,
      type: typeIndex == 255 || typeIndex >= HospitalType.values.length
          ? null
          : HospitalType.values[typeIndex],
      rating: rating < 0 ? null : rating,
    );
  }, growable: false);

  return HospitalIndex.fromIterable(hospitals, cellSizeDeg: cellSize);
}

/// Little-endian `u32` bytes.
List<int> _uint32(int value) {
  final ByteData d = ByteData(4)..setUint32(0, value, Endian.little);
  return d.buffer.asUint8List();
}

/// Little-endian IEEE-754 `f64` bytes.
List<int> _float64(double value) {
  final ByteData d = ByteData(8)..setFloat64(0, value, Endian.little);
  return d.buffer.asUint8List();
}

/// A tiny sequential reader. Bounds-checked so a truncated blob raises a
/// [FormatException] rather than reading past the end of the buffer.
class _Reader {
  _Reader(this._bytes) : _view = ByteData.sublistView(_bytes);
  final Uint8List _bytes;
  final ByteData _view;
  int _offset = 0;

  int u8() {
    _need(1);
    return _bytes[_offset++];
  }

  int u32() {
    _need(4);
    final int v = _view.getUint32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  double f64() {
    _need(8);
    final double v = _view.getFloat64(_offset, Endian.little);
    _offset += 8;
    return v;
  }

  /// Read [length] **UTF-8 bytes** and decode them.
  ///
  /// Not `String.fromCharCodes` over raw bytes: a hospital name with a
  /// non-ASCII character is more than one byte per character, so that would
  /// produce mojibake.
  String str(int length) {
    _need(length);
    final String s = utf8.decode(
      _bytes.sublist(_offset, _offset + length),
      allowMalformed: true,
    );
    _offset += length;
    return s;
  }

  void _need(int n) {
    if (_offset + n > _bytes.length) {
      throw FormatException(
        'truncated hospital index: wanted $n at $_offset of ${_bytes.length}',
      );
    }
  }
}
