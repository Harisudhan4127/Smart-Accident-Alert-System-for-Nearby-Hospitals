/// The wire frame: constants, CRC, and the streaming scanner (§3, §4).
///
/// **This is the only file in the app that knows the frame layout exists.**
/// Everything above it works in terms of [MessageType] and typed payloads, and
/// everything below it produces bytes. That boundary is what makes the protocol
/// testable at all: the conformance tests in `test/protocol/` never touch BLE,
/// `flutter_blue_plus`, or a real clock.
///
/// ## Deviations from `tools/protocol/codec.js` (the reference implementation)
///
/// The reference scanner has three defects that this implementation does not
/// inherit. Each was reproduced against `tools/protocol/golden.json` before
/// fixing; see `docs/02-ble-protocol.md` §3 for the frozen spec.
///
/// 1. **`A5 A5` livelock.** In `sof1` the reference re-latches on the *same*
///    byte it is inspecting, so a second `0xA5` advances nothing and the
///    `for` loop never terminates. Here, a repeated `SOF0` simply re-latches,
///    which is also the correct behaviour per §3 ("on `0xA5` the parser
///    latches").
/// 2. **Frames split across notifications fail CRC.** The reference flushes
///    its accumulated buffer on `chunk_end` and then validates a CRC over
///    whatever survived — a header-only or body-only remainder can never match.
///    Here the frame buffer is retained across chunks until the declared length
///    plus CRC has actually arrived.
/// 3. **The decoded `payload` is 2 bytes early.** The reference computes
///    `start = i - payloadLen - 2`, which is the offset of the CRC field rather
///    than of the first payload byte, so JSON payloads fail to parse and binary
///    payloads decode shifted by two. Here the payload is exactly
///    `[i - payloadLen, i)` and the raw frame is `[frameStart, i + 2)`.
///
/// The reference also reports `telemetryImpact.telemetry.flags = 255` and
/// `telemetrySaturated.telemetry.ay = -32767` in `golden.json`; the frame bytes
/// in the same file encode `0xF7` and `-32768` respectively. The bytes are
/// authoritative and the metadata is stale — the conformance test asserts
/// against the bytes, and `docs/02-ble-protocol.md` is wrong on two details
/// (`CALIB_LOG` is `{"samples": [...]}`, not a bare array; `maxPayload` is 403
/// bytes, not 512).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../core/constants.dart';

/// `SOF0` (§3).
const int kSof0 = 0xA5;

/// `SOF1` (§3).
const int kSof1 = 0x5A;

/// Protocol version this app speaks (§3 `VER = 0x01`).
const int kProtocolVersion = 0x01;

/// `SOF0 SOF1 VER TYPE LEN_LO LEN_HI` (§3).
const int kHeaderBytes = 6;

/// `CRC_LO CRC_HI` (§3).
const int kCrcBytes = 2;

/// Largest payload `LEN` this app will accept (§3: `0 … 512`).
const int kMaxPayloadBytes = 512;

/// Total size of the largest legal frame: header + payload + CRC.
const int kMaxFrameBytes = kHeaderBytes + kMaxPayloadBytes + kCrcBytes;

/// CRC-16/CCITT-FALSE, the reference checksum in §3.
///
/// Parameters: polynomial `0x1021`, initial value `0xFFFF`, no input or output
/// reflection, final XOR `0x0000`. Computed over `VER … last PAYLOAD byte` —
/// that is, the SOF bytes are *excluded* (§3).
abstract final class Crc16 {
  /// Table of remainders for `0x00…0xFF`, built once on first use.
  static final Uint16List _table = _buildTable();

  /// CRC of [bytes] from [start] (inclusive) to [end] (exclusive).
  ///
  /// Table-driven because this runs on every received frame: a bitwise
  /// implementation is 8× slower and, at 50 Hz on a phone, irrelevant either
  /// way — but the table makes the intent ("this is CRC-16/CCITT-FALSE, not
  /// CRC-16/IBM") checkable by eye.
  static int compute(Uint8List bytes, [int start = 0, int? end]) {
    final int limit = end ?? bytes.length;
    int crc = 0xFFFF;
    for (int i = start; i < limit; i++) {
      final int index = (crc >> 8) ^ bytes[i];
      crc = ((crc << 8) & 0xFFFF) ^ _table[index & 0xFF];
    }
    return crc & 0xFFFF;
  }

  static Uint16List _buildTable() {
    final Uint16List table = Uint16List(256);
    for (int i = 0; i < 256; i++) {
      int value = i << 8;
      for (int bit = 0; bit < 8; bit++) {
        value = (value & 0x8000) != 0
            ? ((value << 1) ^ 0x1021) & 0xFFFF
            : (value << 1) & 0xFFFF;
      }
      table[i] = value;
    }
    return table;
  }
}

/// The GATT characteristic a message travels on (§2.2, §4).
enum BleChannel {
  /// `RX` — phone → device.
  rx('rx', kRxUuid),

  /// `TX` — device → phone, best-effort telemetry, 50 Hz.
  tx('tx', kTxUuid),

  /// `CTRL` — device → phone, highest priority: events, ACK, ERROR, STATUS.
  ctrl('ctrl', kCtrlUuid),

  /// `INFO` — device → phone, static identity.
  info('info', kInfoUuid);

  const BleChannel(this.wireName, this.uuid);

  /// Name used in `HELLO` and log tags.
  final String wireName;

  /// Full 128-bit characteristic UUID.
  final String uuid;

  /// Whether the device sends on this channel (device → phone).
  bool get isInbound => this != BleChannel.rx;

  /// Look up by wire name, or `null` if unknown.
  static BleChannel? fromWireName(String name) {
    for (final BleChannel channel in BleChannel.values) {
      if (channel.wireName == name) {
        return channel;
      }
    }
    return null;
  }
}

/// §4 message types.
enum MessageType {
  /// `0x01` phone → device.
  hello(0x01, BleChannel.rx),

  /// `0x02` phone → device.
  ping(0x02, BleChannel.rx),

  /// `0x04` phone → device. Partial update; absent keys keep their value.
  config(0x04, BleChannel.rx),

  /// `0x05` phone → device.
  calibrate(0x05, BleChannel.rx),

  /// `0x06` phone → device.
  command(0x06, BleChannel.rx),

  /// `0x07` device → phone.
  ack(0x07, BleChannel.ctrl),

  /// `0x08` device → phone.
  error(0x08, BleChannel.ctrl),

  /// `0x09` device → phone. The one event envelope (§4, §6.6).
  event(0x09, BleChannel.ctrl),

  /// `0x10` device → phone. 24-byte binary record on `TX` (§5).
  telemetry(0x10, BleChannel.tx),

  /// `0x11` device → phone.
  status(0x11, BleChannel.ctrl),

  /// `0x12` device → phone. Device identity + capability negotiation (§6.2).
  helloAck(0x12, BleChannel.ctrl),

  /// `0x13` device → phone. `{"samples": [...]}`, downsampled calibration.
  calibLog(0x13, BleChannel.ctrl),

  /// `0x14` device → phone.
  diag(0x14, BleChannel.ctrl),

  /// `0x20` device → phone, on `INFO` (§6.3).
  deviceInfo(0x20, BleChannel.info),

  /// A `TYPE` byte this app version does not know.
  ///
  /// Modelled rather than dropped: the scanner still rejects the frame if the
  /// *version* is wrong (spec-mandated), but an unknown type is handed to the
  /// service so it can be counted and logged. A firmware that adds a type
  /// therefore degrades to "one ignored message" instead of "no telemetry at
  /// all", which is the difference between a log line and a failed demo.
  unknown(0xFF, BleChannel.ctrl);

  const MessageType(this.code, this.channel);

  /// The byte on the wire.
  final int code;

  /// The characteristic this type is expected on (§4 `Chars`).
  final BleChannel channel;

  /// Look up a `TYPE` byte; `null` when it is not in §4.
  static MessageType? fromCode(int code) {
    for (final MessageType type in MessageType.values) {
      if (type != MessageType.unknown && type.code == code) {
        return type;
      }
    }
    return null;
  }

  /// Whether the phone sends this type.
  bool get isOutbound => channel == BleChannel.rx;
}

/// A complete, valid frame (§3).
///
/// Immutable and owning: [payload] is a private copy, so a frame may outlive the
/// scanner's internal buffer. Use [BleFrameView] on the hot path to avoid that
/// copy entirely.
@immutable
class BleFrame {
  /// An owned, immutable frame: header fields plus a private copy of the
  /// payload. This is what a [FrameVisitor] receives.
  const BleFrame({
    required this.version,
    required this.type,
    required this.typeCode,
    required this.payload,
    required this.crc,
  });

  /// `VER` (§3).
  final int version;

  /// Decoded [type]. [MessageType.unknown] when `TYPE` was not in §4.
  final MessageType type;

  /// The raw `TYPE` byte, kept even when [type] is [MessageType.unknown].
  final int typeCode;

  /// The `LEN` payload bytes, a private copy.
  final Uint8List payload;

  /// The CRC-16 that was verified over `VER … last PAYLOAD byte` (§3).
  final int crc;

  /// `LEN` (§3).
  int get length => payload.length;

  /// Total frame size on the wire: header + payload + CRC.
  int get frameLength => kHeaderBytes + payload.length + kCrcBytes;

  /// The payload decoded as UTF-8 JSON, or `null` if it is not valid JSON.
  ///
  /// A `null` return (rather than a throw) is deliberate: a malformed JSON
  /// payload is a device bug that must not take down the notification handler.
  Map<String, Object?>? get jsonPayload => decodeJsonObject(payload);

  @override
  String toString() =>
      'BleFrame(${type.name} type=0x${typeCode.toRadixString(16)} '
      'len=${payload.length} crc=0x${crc.toRadixString(16).padLeft(4, '0')})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BleFrame &&
          other.version == version &&
          other.typeCode == typeCode &&
          other.crc == crc &&
          _bytesEqual(other.payload, payload);

  @override
  int get hashCode => Object.hash(version, typeCode, crc, payload.length);
}

/// A borrowed view of a frame inside the scanner's internal buffer.
///
/// **Lifetime: valid only inside the visitor callback.** The scanner reuses its
/// buffer for the next frame, so a retained view will change underneath you. This
/// is the whole point — decoding a 50 Hz telemetry frame through [BleFrame] would
/// allocate a 24-byte copy 50 times a second for nothing, so the hot path takes
/// this instead and parses straight out of the notification.
@immutable
class BleFrameView {
  /// A *borrowed* view over a scanner's buffer.
  ///
  /// Zero-copy, so it is only valid for the duration of the visitor
  /// callback. Call [copy] to keep it.
  const BleFrameView({
    required this.buffer,
    required this.frameStart,
    required this.version,
    required this.type,
    required this.typeCode,
    required this.payloadStart,
    required this.payloadLength,
    required this.crc,
  });

  /// The scanner's reusable buffer. Do not retain.
  final Uint8List buffer;

  /// Index of `SOF0` within [buffer].
  final int frameStart;

  /// `VER` (§3).
  final int version;

  /// Decoded [type]; [MessageType.unknown] when the `TYPE` byte was not in §4.
  final MessageType type;

  /// The raw `TYPE` byte.
  final int typeCode;

  /// Index of the first payload byte within [buffer].
  final int payloadStart;

  /// `LEN` (§3).
  final int payloadLength;

  /// Verified CRC-16.
  final int crc;

  /// Zero-copy view of the payload, valid only during the visitor callback.
  Uint8List get payload =>
      Uint8List.sublistView(buffer, payloadStart, payloadStart + payloadLength);

  /// Total frame size on the wire.
  int get frameLength => kHeaderBytes + payloadLength + kCrcBytes;

  /// Copy this view into an owning [BleFrame], for callers that need to keep it.
  BleFrame copy() => BleFrame(
        version: version,
        type: type,
        typeCode: typeCode,
        payload: Uint8List.fromList(payload),
        crc: crc,
      );
}

/// Called by [FrameScanner.scan] for each complete, CRC-verified frame.
///
/// Return `true` to keep scanning, `false` to stop early. The view is only valid
/// for the duration of the call.
typedef FrameVisitor = bool Function(BleFrameView frame);

/// Counters describing what the scanner has seen.
///
/// Exposed as a value object (not a mutable counter bag) so it can be logged as
/// one immutable line and compared in tests. §25's "Bluetooth disconnected"
/// diagnostics screen reads these; a scanner that silently drops 40 % of frames
/// is indistinguishable from a device that is not sending any.
@immutable
class FrameScanStats {
  /// Cumulative counters across a whole session, for the diagnostics screen.
  const FrameScanStats({
    required this.frames,
    required this.crcErrors,
    required this.versionRejects,
    required this.lengthRejects,
    required this.unknownType,
    required this.discardedBytes,
    required this.bytesConsumed,
    required this.truncatedTail,
  });

  /// No bytes seen yet.
  static const FrameScanStats zero = FrameScanStats(
    frames: 0,
    crcErrors: 0,
    versionRejects: 0,
    lengthRejects: 0,
    unknownType: 0,
    discardedBytes: 0,
    bytesConsumed: 0,
    truncatedTail: 0,
  );

  /// Complete, CRC-verified frames delivered to the visitor.
  /// Frames handed to the visitor.
  final int frames;

  /// Frames whose CRC did not match (§3).
  /// Frames rejected by CRC (noise, or a corrupted link).
  final int crcErrors;

  /// Frames rejected because `VER != 0x01` (§3: "Receiver drops frames with an
  /// unknown version").
  /// Frames with an unknown protocol version.
  final int versionRejects;

  /// Frames rejected because `LEN > 512` (§3).
  /// Frames whose LEN is out of range.
  final int lengthRejects;

  /// Frames whose `TYPE` byte was not in §4. Still delivered to the visitor as
  /// [MessageType.unknown]; counted so the diagnostics screen can show it.
  /// Well-formed frames whose TYPE is not in [MessageType].
  final int unknownType;

  /// Bytes dropped as noise or as part of a rejected frame.
  ///
  /// "Dropped" means *not attributable to a valid frame*: leading garbage,
  /// resync bytes, and every byte of a frame that failed its CRC check. Bytes
  /// skipped while hunting for `SOF0` after a completed frame are **not**
  /// counted — they are the writer's 4-byte padding (§3), which the reader is
  /// required to ignore.
  /// Bytes thrown away while hunting for a frame start.
  final int discardedBytes;

  /// Total bytes fed to the scanner.
  /// Bytes taken from the chunk, including discarded ones.
  final int bytesConsumed;

  /// Bytes of a partial frame still buffered when [FrameScanStats.snapshot] was
  /// taken — i.e. the tail of a frame split across notifications.
  ///
  /// Non-zero between notifications is normal; non-zero when the link is idle is
  /// the signal that a frame was cut in half.
  /// Bytes of a partial frame still buffered when the visitor stopped.
  final int truncatedTail;

  /// Fraction of delivered frames whose bytes were not corrupt, 0.0…1.0.
  ///
  /// `1.0` when nothing has been seen. Expressed as a ratio rather than a
  /// percentage so it can be used directly as a `LinearProgressIndicator`
  /// value.
  double get integrityRatio {
    final int attempts = frames + crcErrors + versionRejects + lengthRejects;
    return attempts == 0 ? 1.0 : frames / attempts;
  }

  /// A copy with the deltas from [deltas] applied.
  FrameScanStats operator +(FrameScanDeltas deltas) => FrameScanStats(
        frames: frames + deltas.frames,
        crcErrors: crcErrors + deltas.crcErrors,
        versionRejects: versionRejects + deltas.versionRejects,
        lengthRejects: lengthRejects + deltas.lengthRejects,
        unknownType: unknownType + deltas.unknownType,
        discardedBytes: discardedBytes + deltas.discardedBytes,
        bytesConsumed: bytesConsumed + deltas.bytesConsumed,
        truncatedTail: deltas.truncatedTail,
      );

  @override
  String toString() => 'FrameScanStats(frames: $frames, crc: $crcErrors, '
      'ver: $versionRejects, len: $lengthRejects, unknownType: $unknownType, '
      'discarded: $discardedBytes/$bytesConsumed, tail: $truncatedTail)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FrameScanStats &&
          other.frames == frames &&
          other.crcErrors == crcErrors &&
          other.versionRejects == versionRejects &&
          other.lengthRejects == lengthRejects &&
          other.unknownType == unknownType &&
          other.discardedBytes == discardedBytes &&
          other.bytesConsumed == bytesConsumed &&
          other.truncatedTail == truncatedTail;

  @override
  int get hashCode => Object.hash(
        frames,
        crcErrors,
        versionRejects,
        lengthRejects,
        unknownType,
        discardedBytes,
        bytesConsumed,
        truncatedTail,
      );
}

/// The per-chunk counter the scanner accumulates, folded into [FrameScanStats].
@immutable
class FrameScanDeltas {
  /// Counters for a single `scan` call.
  const FrameScanDeltas({
    required this.frames,
    required this.crcErrors,
    required this.versionRejects,
    required this.lengthRejects,
    required this.unknownType,
    required this.discardedBytes,
    required this.bytesConsumed,
    required this.truncatedTail,
  });

  /// Nothing happened.
  static const FrameScanDeltas zero = FrameScanDeltas(
    frames: 0,
    crcErrors: 0,
    versionRejects: 0,
    lengthRejects: 0,
    unknownType: 0,
    discardedBytes: 0,
    bytesConsumed: 0,
    truncatedTail: 0,
  );

  /// Frames handed to the visitor.
  final int frames;

  /// Frames rejected by CRC (noise, or a corrupted link).
  final int crcErrors;

  /// Frames with an unknown protocol version.
  final int versionRejects;

  /// Frames whose LEN is out of range.
  final int lengthRejects;

  /// Well-formed frames whose TYPE is not in `MessageType`.
  final int unknownType;

  /// Bytes thrown away while hunting for a frame start.
  final int discardedBytes;

  /// Bytes taken from the chunk, including discarded ones.
  final int bytesConsumed;

  /// Bytes of a partial frame still buffered when the visitor stopped.
  final int truncatedTail;

  /// Whether anything at all happened in this chunk.
  bool get isEmpty =>
      frames == 0 &&
      crcErrors == 0 &&
      versionRejects == 0 &&
      lengthRejects == 0 &&
      unknownType == 0 &&
      discardedBytes == 0 &&
      bytesConsumed == 0;
}

/// The streaming frame scanner (§3).
///
/// **Design constraints, in priority order:**
///
/// 1. **Bounded memory.** One fixed [kMaxFrameBytes] buffer, allocated lazily.
///    The buffer never grows to a *declared* length — that is the ESP32
///    `malloc(65535)`-on-a-corrupt-length bug §3 warns about, and the reason
///    `TYPE`/`LEN` are validated before anything is reserved.
/// 2. **Resynchronise on garbage.** A dropped byte must cost at most the frame
///    it damaged, not the rest of the session. Hunting for `A5 5A` again after
///    any rejection does this.
/// 3. **Survive chunk boundaries.** A frame split across two notifications is
///    normal, not exceptional: Android delivers a 247-byte MTU notification as
///    one `List<int>`, but a 512-byte payload or a congested link will not, and
///    the reference implementation's CRC check fails in exactly that case.
/// 4. **Allocate nothing per frame.** [scan] hands out a [BleFrameView] over an
///    internal buffer, so the 50 Hz telemetry path is allocation-free.
///
/// Not thread-safe by design: a scanner belongs to one subscription. Sharing one
/// across the `ctrl` and `tx` characteristic callbacks would be a bug even though
/// both run on the platform thread, because a single `A5 5A` could be split
/// across the two and there would be no way to know which buffer it belongs to.
class FrameScanner {
  /// Create a scanner. [initialStats] lets a reconnect continue the same
  /// counters, which is what the diagnostics screen wants: "37 CRC errors since
  /// this car was paired", not "13 since the last reconnect".
  FrameScanner({FrameScanStats initialStats = FrameScanStats.zero})
      : _stats = initialStats;

  /// Reusable frame buffer, [kMaxFrameBytes] long. `null` until the first
  /// `SOF0` so an idle connection costs nothing.
  Uint8List? _buffer;

  /// Number of valid bytes currently in [_buffer].
  int _length = 0;

  /// Index within [_buffer] of the `SOF0` of the frame being assembled, or -1.
  int _frameStart = -1;

  /// How many bytes of the SOF we have matched: 0 = hunting, 1 = saw `SOF0`,
  /// 2 = saw `SOF0 SOF1` and the rest of the header follows.
  int _sofMatched = 0;

  FrameScanStats _stats;

  /// Cumulative counters (§25 diagnostics, and the golden conformance report).
  FrameScanStats get stats => _stats;

  /// Bytes of a partial frame currently buffered.
  int get bufferedBytes => _length;

  /// Whether a frame is partially assembled, i.e. the link was cut mid-frame.
  bool get hasPartialFrame => _frameStart >= 0;

  /// Feed [chunk] and invoke [visit] for every complete, CRC-verified frame.
  ///
  /// Returns the number of frames delivered. [visit] returning `false` stops the
  /// scan; bytes already consumed are still counted, and the partial frame
  /// remains buffered for the next chunk.
  int scan(Uint8List chunk, FrameVisitor visit) {
    final FrameScanDeltas deltas = _scan(chunk, visit);
    _stats = _stats + deltas;
    return deltas.frames;
  }

  /// Convenience for tests and cold paths: scan and collect owned [BleFrame]s.
  ///
  /// Allocates one [BleFrame] and one payload copy per frame — correct, but not
  /// what the 50 Hz path should use.
  List<BleFrame> scanToList(Uint8List chunk) {
    final List<BleFrame> frames = <BleFrame>[];
    scan(chunk, (BleFrameView view) {
      frames.add(view.copy());
      return true;
    });
    return frames;
  }

  /// Forget any partial frame and zero the counters.
  ///
  /// Called on disconnect. A half-assembled frame from the previous connection is
  /// not part of the next one, and a stale `SOF0` in the buffer would otherwise
  /// make the first frame of the new connection look like a CRC error.
  void reset() {
    _buffer = null;
    _length = 0;
    _frameStart = -1;
    _sofMatched = 0;
    _stats = FrameScanStats.zero;
  }

  /// Zero the counters but keep any partial frame.
  ///
  /// Not used by the app today; it exists so a test can assert that the scanner
  /// is genuinely stateless with respect to its counters, rather than relying on
  /// [reset] being called exactly once somewhere.
  void resetCounters() => _stats = FrameScanStats.zero;

  FrameScanDeltas _scan(Uint8List chunk, FrameVisitor visit) {
    int frames = 0;
    int crcErrors = 0;
    int versionRejects = 0;
    int lengthRejects = 0;
    int unknownType = 0;
    int discarded = 0;

    final int end = chunk.length;
    int i = 0;
    while (i < end) {
      if (_frameStart < 0) {
        // Hunting for SOF0. Everything before it is link noise (or a previous
        // frame's 4-byte padding, which is 0x00 and therefore free to skip).
        if (chunk[i] == kSof0) {
          _beginFrame();
        } else {
          discarded++;
        }
        i++;
        continue;
      }

      // A frame is being assembled. `_length` is how many bytes we hold.
      if (_sofMatched < 2) {
        // We are inside the two SOF bytes.
        if (_sofMatched == 1) {
          if (chunk[i] == kSof1) {
            _sofMatched = 2;
            _append(chunk[i]);
            i++;
            continue;
          }
          if (chunk[i] == kSof0) {
            // A5 A5: the second A5 is the start of the next candidate frame.
            // Re-latch on it. The reference implementation loops forever here.
            _sofMatched = 1;
            _length = 1;
            _buffer![0] = kSof0;
            i++;
            continue;
          }
          // Not a start-of-frame after all: this byte is noise, and the
          // candidate A5 was noise too.
          discarded += _length + 1;
          _resetFrame();
          i++;
          continue;
        }
        _sofMatched = 0;
      }

      _append(chunk[i]);
      i++;

      if (_length == kHeaderBytes) {
        final int reject = _validateHeader();
        if (reject != _accept) {
          if (reject == _rejectVersion) {
            versionRejects++;
          } else {
            lengthRejects++;
          }
          // The rejected header's bytes are noise. `_resetFrame` returns us to
          // hunting; note that we do *not* rescan the header bytes, because
          // rescan could match an A5 that is part of a corrupt length field and
          // fabricate a frame out of it.
          discarded += _length;
          _resetFrame();
          continue;
        }
      }

      if (_length < kHeaderBytes) {
        continue;
      }

      final int total = kHeaderBytes + _declaredLength + kCrcBytes;
      if (_length < total) {
        // Frame still incomplete; more bytes will arrive with the next chunk.
        continue;
      }

      // Complete. CRC covers VER .. last payload byte, i.e. skips the two SOF
      // bytes (§3).
      final Uint8List buf = _buffer!;
      final int computed =
          Crc16.compute(buf, 2, kHeaderBytes + _declaredLength);
      final int declared = buf[kHeaderBytes + _declaredLength] |
          (buf[kHeaderBytes + _declaredLength + 1] << 8);

      if (computed != declared) {
        crcErrors++;
        discarded += total;
        _resetFrame();
        continue;
      }

      final int typeCode = buf[3];
      final MessageType type =
          MessageType.fromCode(typeCode) ?? MessageType.unknown;
      if (type == MessageType.unknown) {
        unknownType++;
      }

      // Snapshot into the view *before* handing it out, and reset first, so a
      // visitor that throws cannot leave the scanner mid-frame.
      final BleFrameView view = BleFrameView(
        buffer: buf,
        frameStart: _frameStart,
        version: buf[2],
        type: type,
        typeCode: typeCode,
        payloadStart: kHeaderBytes,
        payloadLength: _declaredLength,
        crc: declared,
      );
      _resetFrame();

      frames++;
      if (!visit(view)) {
        return FrameScanDeltas(
          frames: frames,
          crcErrors: crcErrors,
          versionRejects: versionRejects,
          lengthRejects: lengthRejects,
          unknownType: unknownType,
          discardedBytes: discarded,
          bytesConsumed: i,
          truncatedTail: _length,
        );
      }
    }

    return FrameScanDeltas(
      frames: frames,
      crcErrors: crcErrors,
      versionRejects: versionRejects,
      lengthRejects: lengthRejects,
      unknownType: unknownType,
      discardedBytes: discarded,
      bytesConsumed: end,
      truncatedTail: _length,
    );
  }

  /// Header validation result codes. Named so the `switch` in `_scan` cannot
  /// silently accept a new rejection reason.
  static const int _accept = 0;
  static const int _rejectVersion = 1;
  static const int _rejectLength = 2;

  /// `LEN` of the frame being assembled, valid once the header is complete.
  int _declaredLength = 0;

  /// Returns [_accept], [_rejectVersion] or [_rejectLength].
  int _validateHeader() {
    final Uint8List buf = _buffer!;
    if (buf[2] != kProtocolVersion) {
      return _rejectVersion;
    }
    final int declared = buf[4] | (buf[5] << 8);
    if (declared > kMaxPayloadBytes) {
      // Do not reserve anything for a length we are refusing (§3). The buffer is
      // already a fixed 520 bytes, so this bounds nothing by itself — it is the
      // `> 512` *semantics* that matter: a corrupt length must not make us wait
      // forever for bytes that will never arrive.
      return _rejectLength;
    }
    _declaredLength = declared;
    return _accept;
  }

  void _beginFrame() {
    // The buffer is a fixed 520 B and is only ever indexed buffer-relative: a
    // new candidate frame overwrites from index 0, so there is no compaction
    // and no way for a stale byte to survive into the next frame.
    _buffer ??= Uint8List(kMaxFrameBytes);
    _frameStart = 0;
    _sofMatched = 1;
    _length = 1;
    _buffer![0] = kSof0;
  }

  void _append(int byte) {
    if (_length >= kMaxFrameBytes) {
      // Unreachable: the header is validated before more than
      // kHeaderBytes + kMaxPayloadBytes + kCrcBytes bytes can be appended. Kept
      // as a hard bound rather than an assertion so a future change to the
      // frame layout cannot turn into a buffer overflow.
      return;
    }
    _buffer![_length] = byte;
    _length++;
  }

  void _resetFrame() {
    _length = 0;
    _frameStart = -1;
    _sofMatched = 0;
    _declaredLength = 0;
  }
}

/// Build a frame (§3). Used by the app for phone → device messages, by the
/// simulator, and by the conformance tests.
///
/// [pad] controls the §3 optional 4-byte padding for 23-byte-MTU devices. The app
/// does not pad: the phone is never the MTU-constrained side, and trailing bytes
/// are ignored by the reader anyway. Tests use [pad] to prove the reader ignores
/// them.
Uint8List encodeFrame({
  required int typeCode,
  required Uint8List payload,
  int version = kProtocolVersion,
  bool pad = false,
}) {
  final int len = payload.length;
  if (len > kMaxPayloadBytes) {
    throw ArgumentError.value(
      len,
      'payload',
      'exceeds kMaxPayloadBytes ($kMaxPayloadBytes)',
    );
  }
  final int unpadded = kHeaderBytes + len + kCrcBytes;
  final int total =
      pad && unpadded % 4 != 0 ? unpadded + (4 - unpadded % 4) : unpadded;

  final Uint8List out = Uint8List(total);
  final ByteData view = ByteData.sublistView(out);
  out[0] = kSof0;
  out[1] = kSof1;
  out[2] = version;
  out[3] = typeCode;
  view.setUint16(4, len, Endian.little);
  out.setRange(kHeaderBytes, kHeaderBytes + len, payload);

  // CRC over VER .. last payload byte, i.e. bytes 2 .. kHeaderBytes+len-1.
  final int crc = Crc16.compute(out, 2, kHeaderBytes + len);
  view.setUint16(kHeaderBytes + len, crc, Endian.little);
  // Padding stays 0x00, which the reader can never mistake for SOF0.
  return out;
}

/// Encode a JSON payload into a frame with UTF-8 (§3, §6).
Uint8List encodeJsonFrame({
  required int typeCode,
  required Map<String, Object?> json,
  int version = kProtocolVersion,
  bool sortKeys = false,
  bool pad = false,
}) =>
    encodeFrame(
      typeCode: typeCode,
      payload:
          Uint8List.fromList(utf8.encode(encodeJson(json, sortKeys: sortKeys))),
      pad: pad,
    );

/// Serialise [json] to a compact string: no whitespace, one key per step.
///
/// ## Key order: the spec and the reference disagree
///
/// §6 says "keys sorted for stable diffing". The reference encoder
/// (`tools/protocol/codec.js`) and the generator that produced
/// `golden.json` do **not** sort — they emit insertion order, which is
/// byte-for-byte what `golden.json` contains. Sorting is therefore opt-in here
/// too, and the conformance test asserts the *unsorted* default against the
/// golden bytes.
///
/// Nothing on the wire depends on this: JSON object member order is
/// insignificant, and the firmware's parser does not care. It only matters for
/// byte-exact comparison with the golden vectors, which is the only reason to
/// care at all.
String encodeJson(Map<String, Object?> json, {bool sortKeys = false}) {
  if (sortKeys) {
    final List<String> keys = json.keys.toList()..sort();
    final StringBuffer buffer = StringBuffer('{');
    for (int i = 0; i < keys.length; i++) {
      if (i > 0) {
        buffer.write(',');
      }
      buffer
        ..write(jsonEncode(keys[i]))
        ..write(':')
        ..write(jsonEncode(json[keys[i]]));
    }
    return (buffer..write('}')).toString();
  }
  return jsonEncode(json);
}

/// Decode [bytes] as a JSON object with fully typed values, or `null` if it is
/// not a valid JSON object.
///
/// **The `dynamic` barrier.** `jsonDecode` returns `dynamic`, and letting that
/// reach the domain is how a `String` field ends up holding an `int` and the
/// app crashes on the one frame that matters. So this function rebuilds the
/// decoded tree as `Object?` — maps become `Map<String, Object?>`, lists become
/// `List<Object?>`, and the four scalars keep their types — and every protocol
/// message above it works with that instead. `jsonDecode` cannot produce a map
/// with non-`String` keys or a non-JSON value, so the recursion is total; the
/// `else` arm exists only to satisfy the type system and returns `null` for a
/// value the decoder invented.
///
/// §6 payloads are all objects, so a non-object (a bare number, an array) is a
/// protocol violation, not something to accommodate: `null`.
Map<String, Object?>? decodeJsonObject(Uint8List bytes) {
  try {
    final Object? decoded = decodeJsonValue(bytes);
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    return decoded;
  } on FormatException {
    return null;
  }
}

/// Decodes [bytes] as *any* JSON value with fully typed contents.
///
/// The same `dynamic` barrier as [decodeJsonObject] — the returned tree is
/// `Object?` all the way down — but without the object-only restriction, because
/// one §6 payload genuinely is not an object. `CALIB_LOG` (§6.8) is documented
/// both as `{"samples":[...]}` and as a bare array of samples, and a decoder
/// that collapses arrays to `null` cannot tell "the device sent an array" from
/// "the device sent nothing", so the permissive branch is unreachable and the
/// firmware's other documented shape fails.
///
/// Throws [FormatException] on invalid UTF-8 or invalid JSON, so the caller can
/// report *why* the payload was rejected instead of a bare `null`. This is
/// deliberate: it is the frame codec's job to be total, and every protocol
/// caller runs inside a `guard`/`guardSync` that converts it to a
/// [FailureKind.protocol] failure.
Object? decodeJsonValue(Uint8List bytes) {
  final Object? decoded = jsonDecode(utf8.decode(bytes));
  final Object? frozen = _freezeJson(decoded);
  if (frozen == _impossible) {
    throw FormatException('not a JSON value', utf8.decode(bytes));
  }
  return frozen;
}

/// Sentinel returned by [_freezeJson] for a value that cannot exist in JSON.
const Object _impossible = Object();

/// Recursively rebuild a `jsonDecode` result as `Object?`.
Object? _freezeJson(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Map<String, Object?>) {
    final Map<String, Object?> out = <String, Object?>{};
    for (final MapEntry<String, Object?> entry in value.entries) {
      final Object? frozen = _freezeJson(entry.value);
      if (frozen == _impossible) {
        return _impossible;
      }
      out[entry.key] = frozen;
    }
    return out;
  }
  if (value is List<Object?>) {
    final List<Object?> out = <Object?>[];
    for (final Object? element in value) {
      final Object? frozen = _freezeJson(element);
      if (frozen == _impossible) {
        return _impossible;
      }
      out.add(frozen);
    }
    return out;
  }
  return _impossible;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
