#!/usr/bin/env python3
import unittest
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from event_receiver import (
    EventStreamParser,
    PACKET_SIZE,
    SAMPLES_PER_EVT,
    STATUS_LEN,
    decode_status_packet,
)


def make_packet(event_id, samples):
    packet = bytearray([0xA5, 0x5A, (event_id >> 8) & 0xFF, event_id & 0xFF])
    for sample in samples:
        packet.extend([(int(sample) >> 8) & 0xFF, int(sample) & 0xFF])
    return bytes(packet)


def make_status_packet():
    packet = bytearray(STATUS_LEN)
    packet[0:4] = bytes([0xD1, 0x6D, 0x01, STATUS_LEN])
    packet[4:6] = bytes([0xF0, 0xC3])
    packet[6] = 0x16
    packet[7] = 3
    fields = {
        8: 0x1234,
        10: 0x0005,
        12: 0x20AA,
        14: 0x0033,
        16: 0x0456,
        18: 0x0789,
        20: 0x0010,
        22: 0x0002,
        24: 0x1111,
        26: 0x0004,
    }
    for idx, value in fields.items():
        packet[idx] = (value >> 8) & 0xFF
        packet[idx + 1] = value & 0xFF
    packet[28] = 0b1100_0011
    packet[29] = 44
    packet[30] = 7
    checksum = 0
    for b in packet[:31]:
        checksum ^= b
    packet[31] = checksum
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

    def test_decode_status_packet(self):
        status = decode_status_packet(make_status_packet())

        self.assertEqual(status["version"], 1)
        self.assertEqual(status["trigger_state"], 1)
        self.assertEqual(status["drain_state"], 6)
        self.assertEqual(status["desc_count"], 3)
        self.assertEqual(status["sample_count_low"], 0x1234)
        self.assertEqual(status["event_counter"], 5)
        self.assertEqual(status["baseline"], 0x20AA)
        self.assertEqual(status["sigma"], 0x0033)
        self.assertEqual(status["cbuf_wr_ptr"], 0x0456)
        self.assertEqual(status["tx_fifo_wr_count"], 0x0789)
        self.assertEqual(status["reader_remaining"], 0x0010)
        self.assertEqual(status["lost_event_counter"], 2)
        self.assertEqual(status["crossing_count"], 0x1111)
        self.assertEqual(status["trigger_count"], 4)
        self.assertEqual(status["dr_sample_cnt"], 44)
        self.assertEqual(status["status_seq"], 7)
        self.assertTrue(status["flags"]["rst_n"])
        self.assertTrue(status["flags"]["adc_init_done"])
        self.assertTrue(status["live_flags"]["dpti_rx_vld"])
        self.assertTrue(status["live_flags"]["new_event_pending"])


if __name__ == "__main__":
    unittest.main()
