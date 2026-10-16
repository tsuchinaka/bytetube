/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Splits the playback stream into its parts.
 *
 * The service sends a chunked stream where each part is a type, a length and a
 * payload. Both numbers use the service's own variable-length integer encoding,
 * which is not the one protobuf uses: the leading bits of the first byte decide
 * how many bytes follow and how they are packed.
 */

public class ByteTube.UmpReader : GLib.Object {
    public const int MEDIA_HEADER = 20;
    public const int MEDIA = 21;
    public const int MEDIA_END = 22;
    public const int NEXT_REQUEST_POLICY = 35;
    public const int SABR_REDIRECT = 43;
    public const int SABR_ERROR = 44;
    public const int STREAM_PROTECTION_STATUS = 58;

    /** Emitted once per complete part in the stream. */
    public signal void part (int part_type, GLib.Bytes payload);

    private ByteArray buffer = new ByteArray ();

    public void feed (uint8[] chunk) {
        buffer.append (chunk);
        drain ();
    }

    public void reset () {
        buffer.set_size (0);
    }

    private void drain () {
        while (true) {
            int pos = 0;
            uint64 part_type;
            uint64 size;

            if (!read_varint (pos, out part_type, out pos)) {
                return;
            }

            if (!read_varint (pos, out size, out pos)) {
                return;
            }

            var end = pos + (int) size;
            if (end > buffer.len) {
                return;
            }

            var payload = new uint8[(int) size];
            if (size > 0) {
                Memory.copy (payload, buffer.data[pos:end], (size_t) size);
            }

            part ((int) part_type, new GLib.Bytes (payload));

            buffer.remove_range (0, (uint) end);
        }
    }

    private bool read_varint (int start, out uint64 value, out int end) {
        value = 0;
        end = start;

        if (start >= buffer.len) {
            return false;
        }

        var bytes = buffer.data;
        uint8 first = bytes[start];

        if (first < 128) {
            value = first;
            end = start + 1;
            return true;
        }

        if (first < 192) {
            if (start + 2 > buffer.len) {
                return false;
            }

            value = (first & 0x3f) + 64 * bytes[start + 1];
            end = start + 2;
            return true;
        }

        if (first < 224) {
            if (start + 3 > buffer.len) {
                return false;
            }

            value = (first & 0x1f) + 32 * (bytes[start + 1] + 256 * bytes[start + 2]);
            end = start + 3;
            return true;
        }

        if (first < 240) {
            if (start + 4 > buffer.len) {
                return false;
            }

            value = (first & 0x0f)
                + 16 * (bytes[start + 1] + 256 * (bytes[start + 2] + 256 * bytes[start + 3]));
            end = start + 4;
            return true;
        }

        if (start + 5 > buffer.len) {
            return false;
        }

        value = (uint64) bytes[start + 1]
            | ((uint64) bytes[start + 2] << 8)
            | ((uint64) bytes[start + 3] << 16)
            | ((uint64) bytes[start + 4] << 24);
        end = start + 5;
        return true;
    }
}
