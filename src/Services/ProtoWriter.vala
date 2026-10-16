/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Just enough protocol buffer encoding for the playback requests.
 *
 * The service describes its requests and responses in .proto files, but there
 * is no protobuf runtime among the dependencies, so the handful of messages the
 * player needs are written out by hand. Only proto2 wire types 0, 2 and 5
 * appear in those messages.
 */

namespace ByteTube.Proto {
    public const int WIRE_VARINT = 0;
    public const int WIRE_FIXED64 = 1;
    public const int WIRE_BYTES = 2;
    public const int WIRE_FIXED32 = 5;

    /** ByteArray only appends arrays, so single bytes go through here. */
    public void append_byte (ByteArray target, uint8 value) {
        uint8[] single = { value };
        target.append (single);
    }

    public void write_raw_varint (ByteArray target, uint64 value) {
        while (value > 0x7f) {
            append_byte (target, (uint8) ((value & 0x7f) | 0x80));
            value >>= 7;
        }

        append_byte (target, (uint8) value);
    }

    public void write_tag (ByteArray target, int field, int wire) {
        write_raw_varint (target, ((uint64) field << 3) | (uint64) wire);
    }

    public void write_uint (ByteArray target, int field, int64 value) {
        write_tag (target, field, WIRE_VARINT);
        write_raw_varint (target, (uint64) value);
    }

    public void write_float (ByteArray target, int field, float value) {
        uint32 bits = 0;
        Memory.copy (&bits, &value, sizeof (float));

        write_tag (target, field, WIRE_FIXED32);
        append_byte (target, (uint8) (bits & 0xff));
        append_byte (target, (uint8) ((bits >> 8) & 0xff));
        append_byte (target, (uint8) ((bits >> 16) & 0xff));
        append_byte (target, (uint8) ((bits >> 24) & 0xff));
    }

    public void write_bytes (ByteArray target, int field, uint8[] data) {
        write_tag (target, field, WIRE_BYTES);
        write_raw_varint (target, data.length);
        target.append (data);
    }

    public void write_string (ByteArray target, int field, string value) {
        write_tag (target, field, WIRE_BYTES);
        write_raw_varint (target, value.length);

        for (int i = 0; i < value.length; i++) {
            append_byte (target, (uint8) value[i]);
        }
    }

    /** Nested messages are length-delimited fields, exactly like bytes. */
    public void write_message (ByteArray target, int field, ByteArray body) {
        write_bytes (target, field, body.data);
    }
}
