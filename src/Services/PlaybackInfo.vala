/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * What the service says about a video before anything is played.
 *
 * This is the answer to the player request: whether the video can be played at
 * all, where to ask for its stream, the settings the client is expected to echo
 * back, and the list of formats on offer.
 */

public class ByteTube.PlaybackInfo : GLib.Object {
    public string playability_status { get; set; default = ""; }
    public string playability_reason { get; set; default = ""; }

    public string stream_url { get; set; default = ""; }
    /** Sent back with every stream request. A field, not a property: GObject
     *  properties cannot hold arrays. */
    public uint8[] ustreamer_config = new uint8[0];

    public Gee.ArrayList<MediaFormat> formats { get; default = new Gee.ArrayList<MediaFormat> (); }

    public string title { get; set; default = ""; }
    public string author { get; set; default = ""; }
    public string channel_id { get; set; default = ""; }
    public int duration_seconds { get; set; default = 0; }

    /** Length in milliseconds, however it had to be worked out. */
    public int64 duration_ms { get; set; default = 0; }
    public string view_count { get; set; default = ""; }
    public string description { get; set; default = ""; }
    public string thumbnail_uri { get; set; default = ""; }

    public bool is_playable {
        get {
            return playability_status == "OK" && stream_url != "";
        }
    }

    public bool needs_sign_in {
        get {
            return playability_status == "LOGIN_REQUIRED"
                || playability_reason.down ().contains ("sign in");
        }
    }

    /**
     * Files larger than this tend to be served with a url that refuses reads
     * past the beginning, which no player can stream in one piece. The literal
     * is written out because the arithmetic form overflows 32 bits.
     */
    private const int64 STREAMABLE_LIMIT = 4294967296;

    public static PlaybackInfo parse (string json) throws InnertubeError {
        var parser = new Json.Parser ();
        try {
            parser.load_from_data (json);
        } catch (Error e) {
            throw new InnertubeError.PARSE (
                _("The video service sent a response that could not be read.")
            );
        }

        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new InnertubeError.PARSE (
                _("The video service sent a response that could not be read.")
            );
        }

        var info = new PlaybackInfo ();
        var object = root.get_object ();

        if (object.has_member ("playabilityStatus")) {
            var status = object.get_member ("playabilityStatus");
            if (status != null && status.get_node_type () == Json.NodeType.OBJECT) {
                var status_object = status.get_object ();
                info.playability_status =
                    status_object.get_string_member_with_default ("status", "");
                info.playability_reason =
                    status_object.get_string_member_with_default ("reason", "");
            }
        }

        if (object.has_member ("videoDetails")) {
            var details = object.get_member ("videoDetails");
            if (details != null && details.get_node_type () == Json.NodeType.OBJECT) {
                read_details (info, details.get_object ());
            }
        }

        if (object.has_member ("streamingData")) {
            var streaming = object.get_member ("streamingData");
            if (streaming != null && streaming.get_node_type () == Json.NodeType.OBJECT) {
                read_streaming (info, streaming.get_object ());
            }
        }

        read_ustreamer_config (info, object);

        return info;
    }

    private static void read_details (PlaybackInfo info, Json.Object details) {
        info.title = details.get_string_member_with_default ("title", "");
        info.author = details.get_string_member_with_default ("author", "");
        info.channel_id = details.get_string_member_with_default ("channelId", "");
        info.view_count = details.get_string_member_with_default ("viewCount", "");
        info.description = details.get_string_member_with_default ("shortDescription", "");

        if (details.has_member ("lengthSeconds")) {
            info.duration_seconds =
                (int) details.get_int_member_with_default ("lengthSeconds", 0);

            if (info.duration_seconds > 0) {
                info.duration_ms = (int64) info.duration_seconds * 1000;
            }
        }

        var thumbs = details.get_member ("thumbnail");
        if (thumbs != null && thumbs.get_node_type () == Json.NodeType.OBJECT) {
            var array = thumbs.get_object ().get_member ("thumbnails");
            if (array != null && array.get_node_type () == Json.NodeType.ARRAY) {
                var list = array.get_array ();
                if (list.get_length () > 0) {
                    var last = list.get_element (list.get_length () - 1);
                    if (last != null && last.get_node_type () == Json.NodeType.OBJECT) {
                        info.thumbnail_uri =
                            last.get_object ().get_string_member_with_default ("url", "");
                    }
                }
            }
        }
    }

    private static void read_streaming (PlaybackInfo info, Json.Object streaming) {
        info.stream_url = streaming.get_string_member_with_default (
            "serverAbrStreamingUrl", "");

        var node = streaming.get_member ("adaptiveFormats");
        if (node == null || node.get_node_type () != Json.NodeType.ARRAY) {
            return;
        }

        var array = node.get_array ();
        for (uint i = 0; i < array.get_length (); i++) {
            var element = array.get_element (i);
            if (element == null || element.get_node_type () != Json.NodeType.OBJECT) {
                continue;
            }

            var object = element.get_object ();
            var format = read_format (object);
            if (format != null) {
                info.formats.add (format);

                // The service writes this one as a string.
                var approx = object.get_string_member_with_default ("approxDurationMs", "");
                if (approx != "") {
                    var ms = int64.parse (approx);
                    if (ms > info.duration_ms) {
                        info.duration_ms = ms;
                    }
                }
            }
        }
    }

    private static MediaFormat? read_format (Json.Object object) {
        var itag = (int) object.get_int_member_with_default ("itag", 0);
        if (itag == 0) {
            return null;
        }

        var format = new MediaFormat () { itag = itag };
        format.mime_type = object.get_string_member_with_default ("mimeType", "");
        format.bitrate = object.get_int_member_with_default ("bitrate", 0);
        format.width = (int) object.get_int_member_with_default ("width", 0);
        format.height = (int) object.get_int_member_with_default ("height", 0);
        format.last_modified = object.get_int_member_with_default ("lastModified", 0);

        if (object.has_member ("lastModified")) {
            format.last_modified = object.get_int_member_with_default ("lastModified", 0);
        }

        format.url = object.get_string_member_with_default ("url", "");
        format.is_audio = format.mime_type.has_prefix ("audio/");
        format.is_video = format.mime_type.has_prefix ("video/");

        return format;
    }

    private static void read_ustreamer_config (PlaybackInfo info, Json.Object object) {
        if (!object.has_member ("playerConfig")) {
            return;
        }

        var config = object.get_member ("playerConfig");
        if (config == null || config.get_node_type () != Json.NodeType.OBJECT) {
            return;
        }

        var common = config.get_object ().get_member ("mediaCommonConfig");
        if (common == null || common.get_node_type () != Json.NodeType.OBJECT) {
            return;
        }

        var request = common.get_object ().get_member ("mediaUstreamerRequestConfig");
        if (request == null || request.get_node_type () != Json.NodeType.OBJECT) {
            return;
        }

        var encoded = request.get_object ().get_string_member_with_default (
            "videoPlaybackUstreamerConfig", "");
        if (encoded == "") {
            return;
        }

        var decoded = GLib.Base64.decode (encoded);
        if (decoded != null && decoded.length > 0) {
            info.ustreamer_config = decoded;
        }
    }

    /**
     * The best video the player can stream, limited to 1080p: anything larger
     * costs a lot of bandwidth for very little gain on a desktop screen, and
     * the very largest files cannot be streamed from a single url at all.
     */
    public MediaFormat? choose_video () {
        var candidates = video_candidates ();

        if (candidates.size == 0) {
            return null;
        }

        return candidates[0];
    }

    /** All playable video formats, best first. */
    public Gee.ArrayList<MediaFormat> video_candidates () {
        var usable = new Gee.ArrayList<MediaFormat> ();
        var small_enough = new Gee.ArrayList<MediaFormat> ();
        var seen = new Gee.HashSet<int> ();

        foreach (var format in formats) {
            if (!format.is_video || format.height <= 0 || !format.has_url || format.height > 1080) {
                continue;
            }

            if (!seen.add (format.itag)) {
                continue;
            }

            usable.add (format);

            if (format.size_bytes == 0 || format.size_bytes < STREAMABLE_LIMIT) {
                small_enough.add (format);
            }
        }

        // A file beyond the limit cannot be streamed through a single url, so
        // smaller formats are offered first when there are any.
        var ordered = small_enough.size > 0 ? small_enough : usable;
        ordered.sort ((a, b) => score_video (b) - score_video (a));
        return ordered;
    }

    /** All playable audio formats, best first. */
    public Gee.ArrayList<MediaFormat> audio_candidates () {
        var usable = new Gee.ArrayList<MediaFormat> ();
        var seen = new Gee.HashSet<int> ();

        foreach (var format in formats) {
            if (!format.is_audio || !format.has_url || !seen.add (format.itag)) {
                continue;
            }

            usable.add (format);
        }

        usable.sort ((a, b) => (int) (b.bitrate - a.bitrate));
        return usable;
    }

    public MediaFormat? choose_audio () {
        var candidates = audio_candidates ();

        if (candidates.size == 0) {
            return null;
        }

        return candidates[0];
    }

    /**
     * Formats are ranked so that the one that can be seeked comes first.
     *
     * A seek has to be carried out by the file's own demuxer, and only the
     * Matroska demuxer manages it from a stream that is still arriving: every
     * Matroska stream tested seeks in about a second, even hours into a file
     * of several gigabytes. The mp4 demuxer refuses the same seek outright,
     * leaving the sound at the new position and the picture behind for good,
     * so its formats are only chosen when there is nothing else.
     *
     * Within a container the codecs are ranked by picture for the bandwidth,
     * since all of them are decoded here.
     */
    private static int score_video (MediaFormat format) {
        var score = 0;

        if (format.mime_type.has_prefix ("video/webm")) {
            score += 4000000;
        }

        if (format.codecs.has_prefix ("av01")) {
            score += 2000000;
        } else if (format.codecs.has_prefix ("vp9") || format.codecs.has_prefix ("vp09")) {
            score += 1000000;
        } else if (format.codecs.has_prefix ("avc1")) {
            score += 500000;
        }

        return score + format.pixels;
    }
}
