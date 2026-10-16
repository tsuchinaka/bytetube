/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * A reader for the protocol buffer responses the player receives.
 *
 * Unknown fields are skipped rather than rejected: the service adds fields to
 * these messages as it evolves, and none of them should stop playback.
 */

public class ByteTube.ProtoReader : GLib.Object {
    private uint8[] data;
    private int pos = 0;

    public ProtoReader (uint8[] data) {
        this.data = data;
    }

    public bool at_end {
        get {
            return pos >= data.length;
        }
    }

    /** Reads the next tag. Returns false once the message is exhausted. */
    public bool next (out int field, out int wire) {
        field = 0;
        wire = 0;

        if (at_end) {
            return false;
        }

        var key = read_varint ();
        field = (int) (key >> 3);
        wire = (int) (key & 0x07);
        return true;
    }

    public uint64 read_varint () {
        uint64 result = 0;
        int shift = 0;

        while (pos < data.length) {
            uint8 byte = data[pos++];
            result |= ((uint64) (byte & 0x7f)) << shift;

            if ((byte & 0x80) == 0) {
                break;
            }

            shift += 7;
        }

        return result;
    }

    public int64 read_int () {
        return (int64) read_varint ();
    }

    public bool read_bool () {
        return read_varint () != 0;
    }

    public uint8[] read_bytes () {
        var length = (int) read_varint ();
        if (length <= 0 || pos + length > data.length) {
            pos = data.length;
            return new uint8[0];
        }

        var slice = new uint8[length];
        Memory.copy (slice, data[pos:pos + length], length);
        pos += length;
        return slice;
    }

    public string read_string () {
        return bytes_to_string (read_bytes ());
    }

    /** Consumes the value of a field the caller is not interested in. */
    public void skip (int wire) {
        switch (wire) {
            case Proto.WIRE_VARINT:
                read_varint ();
                break;
            case Proto.WIRE_FIXED64:
                pos += 8;
                break;
            case Proto.WIRE_BYTES:
                read_bytes ();
                break;
            case Proto.WIRE_FIXED32:
                pos += 4;
                break;
            default:
                pos = data.length;
                break;
        }

        if (pos > data.length) {
            pos = data.length;
        }
    }

    /** Copies a byte array into a regular null-terminated string. */
    public static string bytes_to_string (uint8[] bytes) {
        var buffer = new uint8[bytes.length + 1];
        Memory.copy (buffer, bytes, bytes.length);
        buffer[bytes.length] = 0;

        return (string) buffer;
    }
}
