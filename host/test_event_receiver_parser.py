#!/usr/bin/env python3
import unittest
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from event_receiver import EventStreamParser, PACKET_SIZE, SAMPLES_PER_EVT


def make_packet(event_id, samples):
    packet = bytearray([0xA5, 0x5A, (event_id >> 8) & 0xFF, event_id & 0xFF])
    for sample in samples:
        packet.extend([(int(sample) >> 8) & 0xFF, int(sample) & 0xFF])
    return bytes(packet)


class EventReceiverParserTest(unittest.TestCase):
    def test_packet_size_matches_1800_sample_hw_frame(self):
        self.assertEqual(SAMPLES_PER_EVT, 1800)
        self.assertEqual(PACKET_SIZE, 3604)

    def test_parse_two_back_to_back_full_packets(self):
        samples0 = np.arange(SAMPLES_PER_EVT, dtype=np.uint16)
        samples1 = (np.arange(SAMPLES_PER_EVT, dtype=np.uint16) + 1000) & 0x3FFF
        raw = make_packet(0, samples0) + make_packet(1, samples1)

        events = EventStreamParser().parse_buffer(np.frombuffer(raw, dtype=np.uint8))

        self.assertEqual(len(events), 2)
        self.assertEqual(events[0][0], 0)
        self.assertEqual(events[1][0], 1)
        np.testing.assert_array_equal(events[0][1], samples0)
        np.testing.assert_array_equal(events[1][1], samples1)

    def test_preserves_partial_tail_after_offset_sync(self):
        samples0 = np.arange(SAMPLES_PER_EVT, dtype=np.uint16)
        samples1 = (np.arange(SAMPLES_PER_EVT, dtype=np.uint16) + 2000) & 0x3FFF
        raw = b"\x00\xff" + make_packet(0, samples0) + make_packet(1, samples1)
        split = 2 + PACKET_SIZE + 17
        parser = EventStreamParser()

        first = parser.parse_buffer(np.frombuffer(raw[:split], dtype=np.uint8))
        tail = bytearray(raw[parser.last_consumed:split])
        tail.extend(raw[split:])
        second = parser.parse_buffer(np.frombuffer(tail, dtype=np.uint8))

        self.assertEqual(len(first), 1)
        self.assertEqual(len(second), 1)
        self.assertEqual(second[0][0], 1)
        np.testing.assert_array_equal(second[0][1], samples1)


if __name__ == "__main__":
    unittest.main()
