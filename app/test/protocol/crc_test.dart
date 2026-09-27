/// CRC-16/CCITT-FALSE conformance (§3).
///
/// The vectors are the reference implementation's own (`golden.json` →
/// `crc16.vectors`), plus the structural property that actually protects the
/// scanner: a corrupted byte must change the CRC. A CRC that ignores half its
/// input still passes a table of four fixed strings.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_accident_alert/data/protocol/ble_frame.dart';

void main() {
  group('Crc16.compute', () {
    // golden.json -> crc16.vectors
    final Map<String, int> reference = <String, int>{
      '': 0xFFFF,
      'A': 0xB915,
      '123456789': 0x29B1,
      'The quick brown fox jumps over the lazy dog': 0x8FDD,
    };

    reference.forEach((String input, int expected) {
      test('reference vector ${input.isEmpty ? '<empty>' : input}', () {
        final Uint8List bytes = Uint8List.fromList(input.codeUnits);
        expect(Crc16.compute(bytes), expected, reason: 'crc("$input")');
      });
    });

    test('the classic CRC-16/CCITT-FALSE check value is 0x29B1', () {
      // Guards against accidentally swapping in CRC-16/XMODEM (0x31C3) or
      // CRC-16/IBM (0xBB3D), which differ only in the initial value and are the
      // three implementations people confuse.
      expect(Crc16.compute(Uint8List.fromList('123456789'.codeUnits)), 0x29B1);
      expect(
        Crc16.compute(Uint8List.fromList('123456789'.codeUnits)),
        isNot(0x31C3),
      );
      expect(
        Crc16.compute(Uint8List.fromList('123456789'.codeUnits)),
        isNot(0xBB3D),
      );
    });

    test('honours start and end so the SOF bytes can be excluded', () {
      final Uint8List frame = Uint8List.fromList(<int>[
        0xA5, 0x5A, // SOF
        0x01, 0x02, 0x00, 0x00, // VER TYPE LEN
        0x14, 0x9C, // CRC
      ]);
      // Over the whole frame, including the SOF, the value is different — this
      // is the assertion that §3's "CRC over VER … last PAYLOAD byte" is
      // implemented, rather than a CRC over the entire frame.
      expect(Crc16.compute(frame, 2, 6), 0x9C14);
      expect(Crc16.compute(frame), isNot(0x9C14));
    });

    test('an empty range yields the init value', () {
      expect(Crc16.compute(Uint8List(4), 2, 2), 0xFFFF);
    });

    test('every single-bit flip changes the CRC', () {
      // A 24-byte record is what telemetry actually checksums, so test that
      // size. 24 x 8 = 192 mutations.
      final Uint8List original = Uint8List.fromList(
        List<int>.generate(kProbeBytes, (int i) => (i * 37) & 0xFF),
      );
      final int base = Crc16.compute(original);
      for (int byte = 0; byte < original.length; byte++) {
        for (int bit = 0; bit < 8; bit++) {
          final Uint8List mutated = Uint8List.fromList(original);
          mutated[byte] ^= 1 << bit;
          expect(
            Crc16.compute(mutated),
            isNot(base),
            reason: 'flipping bit $bit of byte $byte did not change the CRC',
          );
        }
      }
    });
  });
}

/// Payload size used by the bit-flip test: the size of a telemetry record (§5).
///
/// Duplicated here rather than imported from the domain layer so this file stays
/// a pure protocol test with no dependency beyond the protocol itself.
const int kProbeBytes = 24;
