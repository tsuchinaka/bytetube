/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * One of the streams a video is offered in.
 *
 * A video is never sent as a single file: video and audio arrive as separate
 * streams, each identified by an "itag", and the player picks one of each and
 * plays them together.
 */

public class ByteTube.MediaFormat : GLib.Object {
    public int itag { get; set; }
    public int64 last_modified { get; set; }
    public string mime_type { get; set; default = ""; }
    public int64 bitrate { get; set; }
    public int width { get; set; }
    public int height { get; set; }
    public bool is_audio { get; set; }
    public bool is_video { get; set; }

    /**
     * Some clients are handed a plain URL that GStreamer can fetch directly,
     * with no negotiation of its own. When there is one, it is by far the
     * simplest way to play the stream.
     */
    public string url { get; set; default = ""; }

    public bool has_url {
        get {
            return url != "";
        }
    }

    /**
     * How large the file is, from the size the service states in the url.
     * Some very large files are served with a url that only allows reads near
     * the beginning, which a player cannot stream — so size matters when
     * choosing between formats, not just picture quality.
     */
    private int64? size_cache = null;

    public int64 size_bytes {
        get {
            if (size_cache != null) {
                return size_cache;
            }

            size_cache = parse_size (url);
            return size_cache;
        }
    }

    private static int64 parse_size (string url) {
        var marker = url.index_of ("clen=");
        if (marker < 0) {
            return 0;
        }

        var start = marker + 5;
        var end = start;
        while (end < url.length && url[end] >= '0' && url[end] <= '9') {
            end++;
        }

        if (end == start) {
            return 0;
        }

        return int64.parse (url.substring (start, end - start));
    }

    /** The codec named inside the mime type, e.g. "avc1.640028". */
    public string codecs {
        owned get {
            var marker = mime_type.index_of ("codecs=");
            if (marker < 0) {
                return "";
            }

            var value = mime_type.substring (marker + 7);
            return value.replace ("\"", "").strip ();
        }
    }

    public int pixels {
        get {
            return width * height;
        }
    }
}
