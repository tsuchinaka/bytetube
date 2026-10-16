/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Talks to the video service's internal web API.
 *
 * The service has no public, documented API for anonymous clients, so this
 * speaks the same protocol the web player itself uses. Responses are handed to
 * ResponseParser, which is deliberately tolerant of the service changing its
 * response objects.
 */

public errordomain ByteTube.InnertubeError {
    NETWORK,
    PARSE
}

public class ByteTube.InnertubeClient : GLib.Object {
    private const string BASE_URI = "https://www.youtube.com/youtubei/v1/";
    private const string API_KEY = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";
    private const string CLIENT_NAME = "WEB";
    private const string CLIENT_VERSION = "2.20240916.01.00";
    private const string USER_AGENT =
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/128.0.0.0 Safari/537.36";

    /** Identifies a channel's uploads, and its other tabs. */
    /**
     * Shared by anything that talks to the service: it already carries the
     * user agent and the timeouts.
     */
    public Soup.Session session;
    private string language = "en";
    private string region = "US";

    public InnertubeClient () {
        session = HttpSession.get_shared ();
        guess_locale ();
    }

    public GLib.Cancellable cancellable { get; set; }

    /**
     * Looks up a plain search term.
     */
    public async BrowseResult search (string query, string? continuation = null) throws InnertubeError {
        var payload = new Json.Object ();
        payload.set_string_member ("query", query);

        add_continuation (payload, continuation);

        return ResponseParser.parse (yield post ("search", payload));
    }

    /**
     * Looks up anything the service addresses by a browse identifier: the
     * uploads of a channel, a playlist, or one of the service's own feeds.
     */
    public async BrowseResult browse (string browse_id, string? continuation = null) throws InnertubeError {
        var payload = new Json.Object ();
        payload.set_string_member ("browseId", browse_id);

        add_continuation (payload, continuation);

        return ResponseParser.parse (yield post ("browse", payload));
    }

    /**
     * Loads the comments on a video.
     *
     * They are not part of the video's own response: the service only sends
     * them when asked, with a token. Which of the tokens in that response leads
     * to the comments is not stated, so they are tried in turn.
     */
    public async Gee.ArrayList<Comment> comments (string video_id) throws InnertubeError {
        var first = yield post ("next", video_payload (video_id));
        var comments = ResponseParser.parse_comments (first);
        if (comments.size > 0) {
            return comments;
        }

        foreach (var token in ResponseParser.parse_continuation_tokens (first)) {
            var payload = video_payload (video_id);
            payload.set_string_member ("continuation", token);

            comments = ResponseParser.parse_comments (yield post ("next", payload));
            if (comments.size > 0) {
                return comments;
            }
        }

        return new Gee.ArrayList<Comment> ();
    }

    private static Json.Object video_payload (string video_id) {
        var payload = new Json.Object ();
        payload.set_string_member ("videoId", video_id);
        return payload;
    }

    /**
     * Looks up everything shown around a single video: its own details and the
     * videos the service suggests watching next.
     */
    public async BrowseResult watch (string video_id) throws InnertubeError {
        var payload = new Json.Object ();
        payload.set_string_member ("videoId", video_id);

        return ResponseParser.parse (yield post ("next", payload), video_id);
    }

    // ------------------------------------------------------------------
    // Transport
    // ------------------------------------------------------------------

    private async string post (string endpoint, Json.Object payload) throws InnertubeError {
        yield SiteConfig.ensure (session);

        // A code sign-in speaks for the account: the bearer token travels
        // with the request, and without one the service answers as a stranger.
        // The token names the account, so the anonymous visitor tag stays out
        // of its way: mixing the two fails the signed-in pages.
        var bearer = yield TokenStore.get_default ().valid_token ();
        payload.set_object_member ("context", build_context (bearer == null));

        var generator = new Json.Generator ();
        generator.root = new Json.Node.alloc ().init_object (payload);

        var stream = new GLib.MemoryOutputStream.resizable ();
        try {
            generator.to_stream (stream);
            stream.close (null);
        } catch (Error e) {
            throw new InnertubeError.PARSE (e.message);
        }

        var uri = "%s%s?key=%s&prettyPrint=false".printf (BASE_URI, endpoint, API_KEY);
        var message = new Soup.Message ("POST", uri);
        message.request_headers.append ("Content-Type", "application/json");
        message.request_headers.append ("User-Agent", USER_AGENT);
        message.request_headers.append ("X-Youtube-Client-Name", "1");
        var reported = SiteConfig.client_version != ""
            ? SiteConfig.client_version
            : CLIENT_VERSION;
        message.request_headers.append ("X-Youtube-Client-Version", reported);

        if (bearer != null) {
            message.request_headers.append ("Authorization", "Bearer " + bearer);
        }

        message.set_request_body_from_bytes ("application/json", stream.steal_as_bytes ());

        GLib.Bytes response;
        try {
            response = yield session.send_and_read_async (
                message,
                GLib.Priority.DEFAULT,
                cancellable
            );
        } catch (Error e) {
            throw new InnertubeError.NETWORK (e.message);
        }

        if (message.status_code != Soup.Status.OK) {
            throw new InnertubeError.NETWORK (
                _("The video service replied with an error (%u).").printf (message.status_code)
            );
        }

        return bytes_to_string (response);
    }

    /** The client identity and locale every request has to repeat. */


    public Json.Object build_context (bool include_visitor = true) {
        var client = new Json.Object ();
        client.set_string_member ("clientName", CLIENT_NAME);
        var version = SiteConfig.client_version != ""
            ? SiteConfig.client_version
            : CLIENT_VERSION;
        client.set_string_member ("clientVersion", version);
        client.set_string_member ("hl", language);
        client.set_string_member ("gl", region);
        client.set_string_member ("userAgent", USER_AGENT);
        client.set_string_member ("originalUrl", "https://www.youtube.com/");

        if (include_visitor && SiteConfig.visitor != "") {
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
        return context;
    }

    private static void add_continuation (Json.Object payload, string? continuation) {
        if (continuation != null && continuation != "") {
            payload.set_string_member ("continuation", continuation);
        }
    }

    /**
     * Copies the response out of the read buffer so that it can be handed to
     * the JSON parser as a regular, null-terminated string.
     */
    private static string bytes_to_string (GLib.Bytes bytes) {
        unowned uint8[] data = bytes.get_data ();
        var buffer = new uint8[data.length + 1];
        GLib.Memory.copy (buffer, data, data.length);
        buffer[data.length] = 0;

        return (string) buffer;
    }

    /**
     * Asks the service for results in the user's own language where possible.
     */
    private void guess_locale () {
        var locale = GLib.Environment.get_variable ("LC_ALL");
        if (locale == null || locale == "") {
            locale = GLib.Environment.get_variable ("LANG");
        }

        if (locale == null || locale == "") {
            return;
        }

        var name = locale.split (".")[0];
        if (name == "" || name == "C" || name == "POSIX") {
            return;
        }

        var parts = name.split ("_");
        if (parts.length > 0 && parts[0] != "") {
            language = parts[0];
        }

        if (parts.length > 1 && parts[1] != "") {
            region = parts[1];
        }
    }
}
