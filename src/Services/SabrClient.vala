/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Streams a video with the protocol the service's own player uses.
 *
 * There is no single file to download. The client asks the media server for a
 * slice of one video stream and one audio stream at a time, saying how much of
 * each it already holds; the server answers with the next slice as a run of
 * length-delimited parts. The client keeps asking, each time reporting a longer
 * buffer, until it has the whole video.
 */

private class SabrHeader : GLib.Object {
    public int itag { get; set; }
    public bool is_init { get; set; }
    public int sequence { get; set; }
    public int64 start_ms { get; set; }
    public int64 duration_ms { get; set; }
}

public class ByteTube.SabrClient : GLib.Object {
    public signal void video_data (GLib.Bytes data);
    public signal void audio_data (GLib.Bytes data);
    public signal void failed (string message);

    private const string PLAYER_URI = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false";
    private const string API_KEY = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";
    /**
     * The phone and television clients are handed plain media URLs; the web
     * client is only given a stream that has to be negotiated and, as of now,
     * carries a token requirement this app cannot satisfy. So the app asks as a
     * device would, and falls back to negotiating only if it has to.
     *
     * The phone client hands out URLs that may only be read near the beginning
     * of the file, which makes long videos unplayable. The headset client does
     * not have that limit, so it is asked first.
     */
    private const string CLIENT_NAME = "VISIONOS";
    private const string CLIENT_VERSION = "1.02";
    private const int CLIENT_NAME_ID = 101;
    private const string CLIENT_USER_AGENT =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/26.0 Safari/605.1.15";
    private const string DEVICE_MAKE = "Apple";
    private const string DEVICE_MODEL = "RealityDevice17,1";
    private const string OS_NAME = "visionOS";
    private const string OS_VERSION = "26.5.23O471";
    private const string USER_AGENT =
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/128.0.0.0 Safari/537.36";
    private const string ORIGIN = "https://www.youtube.com";

    private const uint READ_SIZE = 65536;

    /**
     * Asked before each request. Returning false holds the download back so
     * that a fast connection cannot fill memory with data the player has not
     * reached yet.
     */
    public delegate bool ReadyCheck ();

    /** A field, not a property: GObject properties cannot hold delegates. */
    public ReadyCheck? can_request_more = null;
    private const uint MAX_BACKOFF_MS = 5000;

    private Soup.Session session;
    private GLib.Cancellable? cancellable = null;
    private UmpReader reader;

    private Gee.HashMap<int, SabrHeader> headers = new Gee.HashMap<int, SabrHeader> ();

    private string video_id = "";
    private string stream_url = "";
    private uint8[] ustreamer_config = new uint8[0];

    private int video_itag = 0;
    private int audio_itag = 0;
    private int64 video_lmt = 0;
    private int64 audio_lmt = 0;
    private int64 video_end_ms = 0;
    private int64 audio_end_ms = 0;
    private int video_max_segment = -1;
    private int audio_max_segment = -1;
    private int64 duration_ms = 0;
    private int64 start_ms = 0;

    private bool running = false;
    private int failures = 0;

    public SabrClient () {
        session = HttpSession.get_shared ();

        reader = new UmpReader ();
        reader.part.connect (on_part);
    }

    // ------------------------------------------------------------------
    // Asking what is on offer
    // ------------------------------------------------------------------

    public async PlaybackInfo load (string video_id) throws InnertubeError {
        this.video_id = video_id;

        yield SiteConfig.ensure (session);

        Debug.log ("requesting playback info (site config %s)".printf (
            SiteConfig.cached ? "cached" : "fresh"));

        var info = PlaybackInfo.parse (yield post_player (video_id));

        if (!info.is_playable && SiteConfig.cached) {
            // The cached values may have expired: read the site and try once
            // more before giving up.
            Debug.log ("not playable (%s), refreshing site config and retrying".printf (
                info.playability_status));
            yield SiteConfig.refresh (session);
            info = PlaybackInfo.parse (yield post_player (video_id));
        }

        Debug.log ("playback info: status=%s formats=%d abr=%s".printf (
            info.playability_status, info.formats.size,
            info.stream_url != "" ? "yes" : "no"));

        return info;
    }

    private async string post_player (string video_id) throws InnertubeError {
        var version = CLIENT_NAME == "WEB" ? SiteConfig.client_version : CLIENT_VERSION;
        if (version == "") {
            version = CLIENT_VERSION;
        }

        var client = new Json.Object ();
        client.set_string_member ("clientName", CLIENT_NAME);
        client.set_string_member ("clientVersion", version);
        client.set_string_member ("deviceMake", DEVICE_MAKE);
        client.set_string_member ("deviceModel", DEVICE_MODEL);
        client.set_string_member ("osName", OS_NAME);
        client.set_string_member ("osVersion", OS_VERSION);
        client.set_string_member ("hl", "en");
        client.set_string_member ("gl", "US");
        client.set_string_member ("userAgent", CLIENT_USER_AGENT);
        client.set_string_member ("originalUrl", ORIGIN + "/watch?v=" + video_id);

        if (SiteConfig.visitor != "") {
            client.set_string_member ("visitorData", SiteConfig.visitor);
        }

        var user = new Json.Object ();
        user.set_boolean_member ("lockedSafetyMode", false);

        var request = new Json.Object ();
        request.set_boolean_member ("useSsl", true);

        var context = new Json.Object ();
        context.set_object_member ("client", client);
        context.set_object_member ("user", user);
        context.set_object_member ("request", request);

        var payload = new Json.Object ();
        payload.set_string_member ("videoId", video_id);
        payload.set_object_member ("context", context);
        payload.set_boolean_member ("contentCheckOk", true);
        payload.set_boolean_member ("racyCheckOk", true);

        // Without this the service answers "Video unavailable", because the
        // request does not prove it came from a current player.
        if (SiteConfig.signature != "") {
            var content = new Json.Object ();
            content.set_int_member ("signatureTimestamp", int.parse (SiteConfig.signature));

            var playback = new Json.Object ();
            playback.set_object_member ("contentPlaybackContext", content);
            payload.set_object_member ("playbackContext", playback);
        }

        var uri = "%s&key=%s".printf (PLAYER_URI, API_KEY);
        return yield post_json (uri, payload);
    }

    private async string post_json (string uri, Json.Object payload) throws InnertubeError {
        var generator = new Json.Generator ();
        generator.root = new Json.Node.alloc ().init_object (payload);

        var stream = new GLib.MemoryOutputStream.resizable ();
        try {
            generator.to_stream (stream);
            stream.close (null);
        } catch (Error e) {
            throw new InnertubeError.PARSE (e.message);
        }

        var message = new Soup.Message ("POST", uri);
        message.request_headers.append ("Content-Type", "application/json");
        message.request_headers.append ("User-Agent", USER_AGENT);
        message.request_headers.append ("Origin", ORIGIN);
        message.request_headers.append ("Accept-Encoding", "identity");
        message.request_headers.append ("X-Youtube-Client-Name", CLIENT_NAME_ID.to_string ());
        message.request_headers.append ("X-Youtube-Client-Version", CLIENT_VERSION);

        message.set_request_body_from_bytes ("application/json", stream.steal_as_bytes ());

        GLib.Bytes response;
        try {
            response = yield session.send_and_read_async (message, GLib.Priority.DEFAULT, null);
        } catch (Error e) {
            throw new InnertubeError.NETWORK (e.message);
        }

        if (message.status_code != Soup.Status.OK) {
            throw new InnertubeError.NETWORK (
                _("The video service replied with an error (%u).").printf (message.status_code)
            );
        }

        return ProtoReader.bytes_to_string (response.get_data ());
    }

    // ------------------------------------------------------------------
    // Streaming
    // ------------------------------------------------------------------

    public void start (PlaybackInfo info, MediaFormat video, MediaFormat audio) {
        stop ();

        stream_url = info.stream_url;
        ustreamer_config = info.ustreamer_config;
        duration_ms = (int64) info.duration_seconds * 1000;

        video_itag = video.itag;
        video_lmt = video.last_modified;
        audio_itag = audio.itag;
        audio_lmt = audio.last_modified;

        video_end_ms = 0;
        audio_end_ms = 0;
        video_max_segment = -1;
        audio_max_segment = -1;
        headers.clear ();
        start_ms = 0;
        failures = 0;

        running = true;
        cancellable = new GLib.Cancellable ();
        reader.reset ();

        run.begin ();
    }

    public void stop () {
        running = false;

        if (cancellable != null) {
            cancellable.cancel ();
            cancellable = null;
        }
    }

    private bool finished () {
        if (duration_ms <= 0) {
            return false;
        }

        var margin = 1000;
        return audio_end_ms + margin >= duration_ms
            && video_end_ms + margin >= duration_ms
            && audio_max_segment >= 0
            && video_max_segment >= 0;
    }

    private async void run () {
        while (running) {
            if (can_request_more != null && !can_request_more ()) {
                schedule (400);
                return;
            }

            try {
                yield fetch_once ();
            } catch (Error e) {
                failures++;
                if (failures > 4) {
                    failed (e.message);
                    running = false;
                    return;
                }

                schedule (1000);
                return;
            }

            if (!running) {
                return;
            }

            if (finished ()) {
                running = false;
                return;
            }

            failures = 0;
            schedule (backoff_ms);
            return;
        }
    }

    private uint backoff_ms = 120;

    private void schedule (uint delay) {
        if (!running) {
            return;
        }

        Timeout.add (uint.max (delay, 50), () => {
            if (running) {
                run.begin ();
            }

            return false;
        });
    }

    private async void fetch_once () throws Error {
        var request = new SabrRequest ();

        request.audio_itag = audio_itag;
        request.audio_lmt = audio_lmt;
        request.video_itag = video_itag;
        request.video_lmt = video_lmt;
        request.ustreamer_config = ustreamer_config;
        request.audio_max_segment = audio_max_segment;
        request.audio_downloaded_ms = start_ms + audio_end_ms;
        request.video_max_segment = video_max_segment;
        request.video_downloaded_ms = start_ms + video_end_ms;
        request.player_time_ms = start_ms + audio_end_ms;
        request.client_name = CLIENT_NAME;
        request.client_version = CLIENT_NAME == "WEB"
            ? SiteConfig.client_version
            : CLIENT_VERSION;
        request.os_name = "X11";
        request.client_name_id = CLIENT_NAME_ID;

        var body = request.to_bytes ();

        var message = new Soup.Message ("POST", stream_url);
        message.request_headers.append ("Content-Type", "application/x-protobuf");
        message.request_headers.append ("User-Agent", USER_AGENT);
        message.request_headers.append ("Origin", ORIGIN);
        message.request_headers.append ("Accept-Encoding", "identity");

        message.set_request_body_from_bytes ("application/x-protobuf", new GLib.Bytes (body));

        var stream = yield session.send_async (message, GLib.Priority.DEFAULT, cancellable);

        if (message.status_code != Soup.Status.OK) {
            throw new InnertubeError.NETWORK (
                _("The media server replied with an error (%u).").printf (message.status_code)
            );
        }

        while (running) {
            var chunk = yield stream.read_bytes_async (READ_SIZE, GLib.Priority.DEFAULT, cancellable);
            if (chunk.get_size () == 0) {
                break;
            }

            reader.feed (chunk.get_data ());
        }
    }

    // ------------------------------------------------------------------
    // Parts
    // ------------------------------------------------------------------

    private void on_part (int part_type, GLib.Bytes payload) {
        var data = payload.get_data ();

        switch (part_type) {
            case UmpReader.MEDIA_HEADER:
                read_media_header (data);
                break;
            case UmpReader.MEDIA:
                read_media (data);
                break;
            case UmpReader.MEDIA_END:
                read_media_end (data);
                break;
            case UmpReader.NEXT_REQUEST_POLICY:
                read_next_request_policy (data);
                break;
            case UmpReader.STREAM_PROTECTION_STATUS:
                read_protection_status (data);
                break;
            case UmpReader.SABR_ERROR:
                read_error (data);
                break;
            case UmpReader.SABR_REDIRECT:
                read_redirect (data);
                break;
            default:
                break;
        }
    }

    private void read_media_header (uint8[] data) {
        var parser = new ProtoReader (data);
        var header = new SabrHeader ();
        int header_id = 0;

        int field;
        int wire;
        while (parser.next (out field, out wire)) {
            switch (field) {
                case 1:
                    header_id = (int) parser.read_varint ();
                    break;
                case 3:
                    header.itag = (int) parser.read_varint ();
                    break;
                case 8:
                    header.is_init = parser.read_bool ();
                    break;
                case 9:
                    header.sequence = (int) parser.read_varint ();
                    break;
                case 11:
                    header.start_ms = parser.read_int ();
                    break;
                case 12:
                    header.duration_ms = parser.read_int ();
                    break;
                default:
                    parser.skip (wire);
                    break;
            }
        }

        headers.set (header_id, header);
    }

    private void read_media (uint8[] data) {
        if (data.length < 2) {
            return;
        }

        var header_id = (int) data[0];
        var header = headers.get (header_id);
        if (header == null) {
            return;
        }

        var payload = new uint8[data.length - 1];
        Memory.copy (payload, data[1:data.length], data.length - 1);
        var bytes = new GLib.Bytes (payload);

        if (header.itag == video_itag) {
            video_data (bytes);
        } else if (header.itag == audio_itag) {
            audio_data (bytes);
        }
    }

    private void read_media_end (uint8[] data) {
        if (data.length < 1) {
            return;
        }

        var header = headers.get ((int) data[0]);
        if (header == null || header.is_init) {
            return;
        }

        if (header.itag == video_itag) {
            if (header.sequence > video_max_segment) {
                video_max_segment = header.sequence;
            }

            video_end_ms = int64.max (video_end_ms, header.start_ms + header.duration_ms);
        } else if (header.itag == audio_itag) {
            if (header.sequence > audio_max_segment) {
                audio_max_segment = header.sequence;
            }

            audio_end_ms = int64.max (audio_end_ms, header.start_ms + header.duration_ms);
        }
    }

    private void read_next_request_policy (uint8[] data) {
        var parser = new ProtoReader (data);
        int field;
        int wire;

        while (parser.next (out field, out wire)) {
            if (field == 4) {
                var requested = (uint) parser.read_varint ();
                // The server's own pacing, within reason.
                if (requested > 0 && requested <= MAX_BACKOFF_MS) {
                    backoff_ms = requested;
                    return;
                }

                parser.skip (wire);
            } else {
                parser.skip (wire);
            }
        }
    }

    private void read_protection_status (uint8[] data) {
        var parser = new ProtoReader (data);
        int field;
        int wire;

        while (parser.next (out field, out wire)) {
            if (field == 1) {
                var status = (int) parser.read_varint ();
                if (status >= 2) {
                    failed (_("The video service refused to send this video to this client."));
                    running = false;
                    return;
                }
            } else {
                parser.skip (wire);
            }
        }
    }

    private void read_error (uint8[] data) {
        var parser = new ProtoReader (data);
        int field;
        int wire;
        var message = "";

        while (parser.next (out field, out wire)) {
            if (field == 1) {
                message = parser.read_string ();
            } else if (field == 2) {
                var code = parser.read_varint ();
                if (message == "") {
                    message = _("The media server refused the request (%lu).").printf ((ulong) code);
                }
            } else {
                parser.skip (wire);
            }
        }

        failed (message == "" ? _("The media server refused the request.") : message);
        running = false;
    }

    private void read_redirect (uint8[] data) {
        var parser = new ProtoReader (data);
        int field;
        int wire;

        while (parser.next (out field, out wire)) {
            if (field == 1) {
                var url = parser.read_string ();
                if (url != "") {
                    stream_url = url;
                    debug ("The media server moved the stream to another host");
                }
            } else {
                parser.skip (wire);
            }
        }
    }
}
