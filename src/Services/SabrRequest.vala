/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * The request the player posts to the media server.
 *
 * The server is told which formats are wanted and, just as importantly, how
 * much of each one the client already holds. That is what makes the stream
 * adaptive: the reply contains the next slice of each requested format, and the
 * client asks again with a longer buffer until it has the whole video.
 */

public class ByteTube.SabrRequest : GLib.Object {
    private const int64 MAX_INT32 = 0x7fffffff;

    public int audio_itag { get; set; }
    public int64 audio_lmt { get; set; }
    public int video_itag { get; set; }
    public int64 video_lmt { get; set; }

    public uint8[] ustreamer_config = new uint8[0];

    /** Milliseconds of audio received so far. */
    public int64 audio_downloaded_ms { get; set; default = 0; }

    /** Highest audio segment index received, or -1 before the first one. */
    public int audio_max_segment { get; set; default = -1; }

    /** Milliseconds of video received so far. */
    public int64 video_downloaded_ms { get; set; default = 0; }

    /** Highest video segment index received, or -1 before the first one. */
    public int video_max_segment { get; set; default = -1; }

    public int64 player_time_ms { get; set; default = 0; }
    public int64 bandwidth_estimate { get; set; default = 8000000; }

    /** Bit 0 selects audio, bit 1 selects video. */
    public int enabled_tracks { get; set; default = 3; }

    public string client_name { get; set; default = "WEB"; }
    public string client_version { get; set; default = "2.20240916.01.00"; }
    public string device_make { get; set; default = ""; }
    public string device_model { get; set; default = ""; }
    public string os_name { get; set; default = "X11"; }
    public string os_version { get; set; default = ""; }
    public int client_name_id { get; set; default = 1; }

    public uint8[] to_bytes () {
        var request = new ByteArray ();

        Proto.write_message (request, 1, client_abr_state ());
        Proto.write_message (request, 2, format_id (video_itag, video_lmt));

        if (audio_max_segment >= 0) {
            Proto.write_message (request, 2, format_id (audio_itag, audio_lmt));
        }

       Proto.write_message (request, 3, audio_buffered_range ());
        Proto.write_message (request, 3, video_buffered_range ());

        if (ustreamer_config.length > 0) {
            Proto.write_bytes (request, 5, ustreamer_config);
        }

        Proto.write_message (request, 16, format_id (audio_itag, audio_lmt));
        Proto.write_message (request, 17, format_id (video_itag, video_lmt));
        Proto.write_message (request, 19, streamer_context ());

        return request.data;
    }

    private ByteArray client_abr_state () {
        var state = new ByteArray ();

        Proto.write_uint (state, 23, bandwidth_estimate);   // bandwidth estimate
        Proto.write_uint (state, 28, player_time_ms);       // playback position
        Proto.write_uint (state, 34, 1);                    // visible
        Proto.write_float (state, 35, 1.0f);                // normal speed
        Proto.write_uint (state, 40, enabled_tracks);
        Proto.write_uint (state, 44, 1);                    // playing

        return state;
    }

    private static ByteArray format_id (int itag, int64 last_modified) {
        var id = new ByteArray ();

        Proto.write_uint (id, 1, itag);
        Proto.write_uint (id, 2, last_modified);

        return id;
    }

    private ByteArray audio_buffered_range () {
        var range = new ByteArray ();

        Proto.write_message (range, 1, format_id (audio_itag, audio_lmt));
        Proto.write_uint (range, 2, 0);
        Proto.write_uint (range, 3, audio_downloaded_ms);

        if (audio_max_segment < 0) {
            Proto.write_uint (range, 4, 0);
            Proto.write_uint (range, 5, MAX_INT32);
        } else {
            Proto.write_uint (range, 4, 0);
            Proto.write_uint (range, 5, audio_max_segment);
        }

        Proto.write_message (range, 6, time_range (0, audio_downloaded_ms));

        return range;
    }

    private ByteArray video_buffered_range () {
        var range = new ByteArray ();

        Proto.write_message (range, 1, format_id (video_itag, video_lmt));
        Proto.write_uint (range, 2, 0);
        Proto.write_uint (range, 3, video_downloaded_ms);

        if (video_max_segment < 0) {
            Proto.write_uint (range, 4, 0);
            Proto.write_uint (range, 5, MAX_INT32);
        } else {
            Proto.write_uint (range, 4, 0);
            Proto.write_uint (range, 5, video_max_segment);
        }

        Proto.write_message (range, 6, time_range (0, video_downloaded_ms));

        return range;
    }

    private static ByteArray time_range (int64 start_ms, int64 duration_ms) {
        var range = new ByteArray ();

        Proto.write_uint (range, 1, start_ms);
        Proto.write_uint (range, 2, duration_ms);
        Proto.write_uint (range, 3, 1000);

        return range;
    }

    private ByteArray streamer_context () {
        var context = new ByteArray ();

        Proto.write_message (context, 1, client_info ());

        return context;
    }

    private ByteArray client_info () {
        var info = new ByteArray ();

        Proto.write_string (info, 12, device_make);
        Proto.write_string (info, 13, device_model);
        Proto.write_uint (info, 16, client_name_id);
        Proto.write_string (info, 17, client_version);
        Proto.write_string (info, 18, os_name);
        Proto.write_string (info, 19, os_version);

        return info;
    }
}
