/// Frame scanner behaviour (§3).
///
/// These are the cases the reference `tools/protocol/codec.js` scanner *fails*,
/// plus the invariants that keep it from allocating its way into an OOM on a
/// corrupt `LEN`. Every test here is a real failure mode observed in a moving
/// vehicle: a congested link that splits a frame across two notifications, a
/// neighbouring peripheral's advertisement interleaving with ours, a bootloader
/// emitting garbage while the radio settles.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_accident_alert/data/protocol/ble_frame.dart';

Uint8List _hex(String s) {
  final String clean = s.replaceAll(' ', '');
  final Uint8List out = Uint8List(clean.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  // A5 5A 01 02 0000 149C — TYPE 0x02 (PING), LEN 0, from golden.json "empty".
  const String pingFrameHex = 'A55A01020000149C';
  // A5 5A 01 10 18 00 <24 B payload> 85BD — TYPE 0x10 (TELEMETRY).
  const String telemetryFrameHex =
      'A55A01101800000000000100020003000000FFFFFEFF000000000000000085BD';

  group('single frame', () {
    test('delivers a complete frame and its exact payload', () {
      final FrameScanner scanner = FrameScanner();
      final List<BleFrame> frames = scanner.scanToList(_hex(pingFrameHex));

      expect(frames, hasLength(1));
      expect(frames.single.type, MessageType.ping);
      expect(frames.single.typeCode, 0x02);
      expect(frames.single.version, kProtocolVersion);
      expect(frames.single.payload, isEmpty);
      expect(frames.single.crc, 0x9C14);
      expect(frames.single.frameLength, 8);
      expect(scanner.stats.frames, 1);
      expect(scanner.stats.discardedBytes, 0);
      expect(scanner.stats.integrityRatio, 1.0);
    });

    test(
        'decodes a 24-byte binary payload without copying it out of the '
        'buffer', () {
      final FrameScanner scanner = FrameScanner();
      final List<int> seen = <int>[];
      scanner.scan(_hex(telemetryFrameHex), (BleFrameView view) {
        expect(view.type, MessageType.telemetry);
        expect(view.payloadLength, 24);
        // The view is a window into the scanner's own buffer: identical storage
        // would be an implementation detail, but `payloadStart == kHeaderBytes`
        // is the contract that makes the offset arithmetic auditable.
        expect(view.payloadStart, kHeaderBytes);
        expect(
          view.payload,
          _hex('000000000100020003000000FFFFFEFF0000000000000000'),
        );
        seen.add(view.payloadLength);
        return true;
      });
      expect(seen, <int>[24]);
    });

    test('the payload offset is the payload, not the CRC', () {
      // The reference implementation reports `payload` as
      // `[i - payloadLen - 2, i)`, which is the two CRC bytes *before* the end
      // of the payload — so its JSON payloads never parse and its binary
      // payloads decode shifted by two. This asserts the first payload byte.
      final FrameScanner scanner = FrameScanner();
      scanner.scan(_hex(telemetryFrameHex), (BleFrameView view) {
        expect(view.payload[0], 0x00, reason: 't_ms low byte');
        expect(view.payload[3], 0x00, reason: 't_ms high byte');
        return true;
      });
    });
  });

  group('frame split across chunks', () {
    test('survives every possible split point', () {
      final Uint8List whole = _hex(telemetryFrameHex);
      for (int cut = 1; cut < whole.length; cut++) {
        final FrameScanner scanner = FrameScanner();
        final List<BleFrame> frames = <BleFrame>[];
        scanner.scan(Uint8List.sublistView(whole, 0, cut), (BleFrameView v) {
          frames.add(v.copy());
          return true;
        });
        scanner.scan(Uint8List.sublistView(whole, cut), (BleFrameView v) {
          frames.add(v.copy());
          return true;
        });
        expect(
          frames,
          hasLength(1),
          reason: 'split at $cut produced ${frames.length} frames',
        );
        expect(frames.single.payload, hasLength(24), reason: 'split at $cut');
      }
    });

    test('survives byte-at-a-time delivery', () {
      final Uint8List whole = _hex(telemetryFrameHex);
      final FrameScanner scanner = FrameScanner();
      int delivered = 0;
      for (final int byte in whole) {
        delivered += scanner.scan(
          Uint8List.fromList(<int>[byte]),
          (BleFrameView _) => true,
        );
      }
      expect(delivered, 1);
      expect(scanner.bufferedBytes, 0);
      expect(scanner.hasPartialFrame, isFalse);
    });

    test('retains a partial frame between chunks instead of flushing it', () {
      final FrameScanner scanner = FrameScanner();
      // A5 5A 01 10 18 00 — the whole header and nothing else.
      final int delivered =
          scanner.scan(_hex('A55A01101800'), (BleFrameView _) => true);
      expect(delivered, 0);
      expect(scanner.hasPartialFrame, isTrue);
      expect(scanner.bufferedBytes, 6);
      expect(scanner.stats.frames, 0);
      expect(
        scanner.stats.crcErrors,
        0,
        reason: 'a half-frame is not a CRC error',
      );
    });

    test('reports a cut frame as truncatedTail', () {
      final FrameScanner scanner = FrameScanner();
      scanner.scan(_hex('A55A0110180000'), (BleFrameView _) => true);
      expect(scanner.stats.truncatedTail, 7);
    });
  });

  group('resynchronisation', () {
    test('A5 A5 does not hang and the following frame is still found', () {
      final FrameScanner scanner = FrameScanner();
      final List<BleFrame> frames = <BleFrame>[];
      scanner.scan(_hex('A5A5A5'), (BleFrameView v) {
        frames.add(v.copy());
        return true;
      });
      expect(frames, isEmpty, reason: 'three SOF0 bytes are not a frame');
      expect(scanner.hasPartialFrame, isTrue, reason: 'latched on the last A5');
      scanner.scan(_hex(pingFrameHex), (BleFrameView v) {
        frames.add(v.copy());
        return true;
      });
      expect(frames, hasLength(1));
    });

    test('A5 13 A5 5A … resyncs on the second SOF pair', () {
      final FrameScanner scanner = FrameScanner();
      final List<BleFrame> frames = <BleFrame>[];
      // A5, then junk 13 (so the first A5 is not a start), then a real frame.
      scanner.scan(_hex('A513'), (BleFrameView v) {
        frames.add(v.copy());
        return true;
      });
      expect(frames, isEmpty);
      scanner.scan(_hex(pingFrameHex), (BleFrameView v) {
        frames.add(v.copy());
        return true;
      });
      expect(frames, hasLength(1));
    });

    test('leading noise is counted once and then ignored', () {
      final FrameScanner scanner = FrameScanner();
      scanner.scan(_hex('00FF1337'), (BleFrameView _) => true);
      expect(scanner.stats.discardedBytes, 4);
      expect(scanner.stats.bytesConsumed, 4);
      expect(scanner.hasPartialFrame, isFalse);
    });

    test('two frames in one notification', () {
      final FrameScanner scanner = FrameScanner();
      final List<BleFrame> frames =
          scanner.scanToList(_hex('$pingFrameHex$pingFrameHex'));
      expect(frames, hasLength(2));
      expect(frames.every((BleFrame f) => f.type == MessageType.ping), isTrue);
    });

    test('a frame is found after a rejected one in the same chunk', () {
      final FrameScanner scanner = FrameScanner();
      const String corrupt = 'A55A01020000149D'; // last byte flipped
      final List<BleFrame> frames =
          scanner.scanToList(_hex('$corrupt$pingFrameHex'));
      expect(frames, hasLength(1), reason: 'only the good frame is delivered');
      expect(scanner.stats.crcErrors, 1);
      expect(scanner.stats.frames, 1);
    });
  });

  group('rejection', () {
    test('a bad CRC is counted, not delivered', () {
      final FrameScanner scanner = FrameScanner();
      final List<BleFrame> frames =
          scanner.scanToList(_hex('A55A01020000149D'));
      expect(frames, isEmpty);
      expect(scanner.stats.crcErrors, 1);
      expect(scanner.stats.integrityRatio, 0.0);
    });

    test('a wrong VER is rejected and counted separately', () {
      final FrameScanner scanner = FrameScanner();
      // A5 5A 02 02 0000 <crc over 02 02 00 00>
      final Uint8List frame = _hex('A55A02020000C807');
      final List<BleFrame> frames = scanner.scanToList(frame);
      expect(frames, isEmpty);
      expect(scanner.stats.versionRejects, 1);
      expect(
        scanner.stats.crcErrors,
        0,
        reason: 'version is checked before CRC',
      );
    });

    test('LEN above 512 is rejected without reserving anything', () {
      final FrameScanner scanner = FrameScanner();
      // LEN = 0xFFFF. The spec calls this out explicitly: a corrupt length must
      // never cause a large allocation. We assert both the rejection and that
      // the scanner did not sit waiting for 65535 bytes.
      final List<BleFrame> frames =
          scanner.scanToList(_hex('A55A0102FFFF0000'));
      expect(frames, isEmpty);
      expect(scanner.stats.lengthRejects, 1);
      expect(scanner.hasPartialFrame, isFalse);
      expect(scanner.bufferedBytes, 0);
    });

    test('LEN of exactly 512 is accepted', () {
      final Uint8List payload = Uint8List(kMaxPayloadBytes);
      final Uint8List frame = encodeFrame(typeCode: 0x13, payload: payload);
      expect(frame.length, kMaxFrameBytes);
      final FrameScanner scanner = FrameScanner();
      final List<BleFrame> frames = scanner.scanToList(frame);
      expect(frames, hasLength(1));
      expect(frames.single.payload, hasLength(512));
      expect(scanner.stats.lengthRejects, 0);
    });

    test('an unknown TYPE is delivered as unknown and counted', () {
      // TYPE 0x03 is not in §4 (deliberately skipped). The scanner must not
      // drop it — a firmware that adds a type should cost one ignored message,
      // not a dead link.
      final Uint8List frame = encodeFrame(
        typeCode: 0x03,
        payload: Uint8List.fromList(<int>[1, 2, 3]),
      );
      final FrameScanner scanner = FrameScanner();
      final List<BleFrame> frames = scanner.scanToList(frame);
      expect(frames, hasLength(1));
      expect(frames.single.type, MessageType.unknown);
      expect(frames.single.typeCode, 0x03);
      expect(scanner.stats.unknownType, 1);
    });
  });

  group('padding', () {
    test('trailing 0x00 bytes are ignored, not treated as data', () {
      // §3: "Readers MUST ignore trailing bytes after LEN." The 8-byte PING
      // frame is already 4-byte aligned, so a padding writer would emit 0…3
      // bytes; 0x00 can never be part of an SOF, so the scanner drops it.
      final FrameScanner scanner = FrameScanner();
      final List<BleFrame> frames =
          scanner.scanToList(_hex('${pingFrameHex}000000'));
      expect(frames, hasLength(1));
      expect(frames.single.payload, isEmpty);
    });

    test('a 4-byte-aligned writer round-trips', () {
      final Uint8List frame = encodeFrame(
        typeCode: 0x13,
        payload: Uint8List.fromList(<int>[7]),
        pad: true,
      );
      expect(frame.length % 4, 0);
      final FrameScanner scanner = FrameScanner();
      final List<BleFrame> frames = scanner.scanToList(frame);
      expect(frames.single.payload, <int>[7]);
    });
  });

  group('bounded memory', () {
    test(
        'a 24 kB stream of pure noise allocates nothing beyond one frame '
        'buffer', () {
      final FrameScanner scanner = FrameScanner();
      final Uint8List noise = Uint8List(24 * 1024);
      for (int i = 0; i < noise.length; i++) {
        // Never 0xA5, so nothing is ever latched.
        noise[i] = i & 0xFE;
      }
      int delivered = 0;
      for (int offset = 0; offset < noise.length; offset += 512) {
        final int end =
            (offset + 512) < noise.length ? offset + 512 : noise.length;
        delivered += scanner.scan(
          Uint8List.sublistView(noise, offset, end),
          (BleFrameView _) => true,
        );
      }
      expect(delivered, 0);
      expect(scanner.stats.discardedBytes, 24 * 1024);
      expect(scanner.bufferedBytes, 0);
    });

    test('reset drops a partial frame so a reconnect does not look corrupt',
        () {
      final FrameScanner scanner = FrameScanner();
      scanner.scan(_hex('A55A01101800'), (BleFrameView _) => true);
      expect(scanner.hasPartialFrame, isTrue);
      scanner.reset();
      expect(scanner.hasPartialFrame, isFalse);
      expect(scanner.bufferedBytes, 0);
      expect(scanner.stats, FrameScanStats.zero);
    });
  });

  group('encodeFrame', () {
    test('produces bytes the scanner accepts', () {
      final Uint8List frame = encodeFrame(
        typeCode: MessageType.hello.code,
        payload: Uint8List.fromList(<int>[0x7B, 0x7D]),
      );
      expect(frame.sublist(0, 6), <int>[0xA5, 0x5A, 0x01, 0x01, 0x02, 0x00]);
      final FrameScanner scanner = FrameScanner();
      expect(scanner.scanToList(frame).single.payload, <int>[0x7B, 0x7D]);
    });

    test('refuses a payload larger than 512', () {
      expect(
        () => encodeFrame(
          typeCode: 0x13,
          payload: Uint8List(kMaxPayloadBytes + 1),
        ),
        throwsArgumentError,
      );
    });
  });
}
