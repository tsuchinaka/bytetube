/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * The three things the service expects a current client to repeat back.
 *
 * The client version, the visitor identifier and the player script's signature
 * timestamp all change as the service updates, so they are read from the site
 * rather than written down. Reading them costs two downloads of about a
 * megabyte each, which is most of the wait before a video starts — so they are
 * kept in memory for the session and on disk for half a day. A cached set that
 * the service no longer accepts is thrown away and read again.
 */

public class ByteTube.SiteConfig : GLib.Object {
    private const int64 FRESH_USEC = 12 * 60 * 60 * 1000000;

    private static string version = "";
    private static string visitor_data = "";
    private static string signature_timestamp = "";
    private static bool loaded = false;

    public static string client_version { get { return version; } }
    public static string visitor { get { return visitor_data; } }
    public static string signature { get { return signature_timestamp; } }

    /** True when the values came from the cache rather than the site. */
    public static bool cached { get; private set; default = false; }

    private static string cache_path () {
        return GLib.Path.build_filename (
            GLib.Environment.get_user_cache_dir (),
            "bytetube",
            "site-config.json"
        );
    }

    /**
     * Makes sure the values are known. Uses the cache when it is fresh;
     * otherwise reads the site.
     */
    public static async void ensure (Soup.Session session) {
        if (loaded) {
            return;
        }

        if (load_cache ()) {
            loaded = true;
            cached = true;
            return;
        }

        yield refresh (session);
    }

    /** Reads the site even when the cache looks fresh. */
    public static async void refresh (Soup.Session session) {
        loaded = true;
        cached = false;

        var html = yield get_text (session, "https://www.youtube.com/");
        if (html == "") {
            return;
        }

        var found_version = extract (html, "INNERTUBE_CLIENT_VERSION");
        if (found_version == "") {
            found_version = extract (html, "INNERTUBE_CONTEXT_CLIENT_VERSION");
        }

        if (found_version != "") {
            version = found_version;
        }

        var found_visitor = extract (html, "VISITOR_DATA");
        if (found_visitor == "") {
            found_visitor = extract (html, "visitorData");
        }

        if (found_visitor != "") {
            visitor_data = found_visitor;
        }

        var script = extract (html, "PLAYER_JS_URL");
        if (script == "") {
            script = extract (html, "jsUrl");
        }

        if (script != "") {
            signature_timestamp = extract_signature (yield get_text (session, join (script)));
        }

        debug ("Site config: version=%s visitor=%s sts=%s (cached=%s)",
            version, visitor_data != "" ? "yes" : "no",
            signature_timestamp, cached.to_string ());

        save_cache ();
    }

    private static string join (string script) {
        if (script.has_prefix ("/")) {
            return "https://www.youtube.com" + script;
        }

        if (!script.has_prefix ("http")) {
            return "https://www.youtube.com/" + script;
        }

        return script;
    }

    private static async string get_text (Soup.Session session, string uri) {
        var message = new Soup.Message ("GET", uri);
        message.request_headers.append ("Accept-Encoding", "identity");

        try {
            var response = yield session.send_and_read_async (
                message, GLib.Priority.LOW, null);

            if (message.status_code != Soup.Status.OK) {
                return "";
            }

            return ProtoReader.bytes_to_string (response.get_data ());
        } catch (Error e) {
            debug ("Could not read %s: %s", uri, e.message);
            return "";
        }
    }

    private static string extract (string haystack, string key) {
        var marker = "\"%s\":\"".printf (key);
        var start = haystack.index_of (marker);
        if (start < 0) {
            return "";
        }

        start += marker.length;
        var end = haystack.index_of ("\"", start);
        if (end < 0) {
            return "";
        }

        return haystack.substring (start, end - start).replace ("\\/", "/");
    }

    /**
     * The player script carries its own timestamp as a plain assignment; the
     * digits after the name are what is wanted.
     */
    private static string extract_signature (string script) {
        var marker = "signatureTimestamp";
        var from = 0;

        while (true) {
            var at = script.index_of (marker, from);
            if (at < 0) {
                return "";
            }

            from = at + marker.length;
            var i = from;

            while (i < script.length && (script[i] < '0' || script[i] > '9')) {
                var c = script[i];
                if (c != '"' && c != ':' && c != '=' && c != ' ' && c != ',') {
                    break;
                }

                i++;
            }

            var start = i;
            while (i < script.length && script[i] >= '0' && script[i] <= '9') {
                i++;
            }

            var digits = script.substring (start, i - start);
            if (digits.length >= 4) {
                return digits;
            }
        }
    }

    private static bool load_cache () {
        var path = cache_path ();
        if (!GLib.FileUtils.test (path, GLib.FileTest.EXISTS)) {
            return false;
        }

        try {
            string contents;
            GLib.FileUtils.get_contents (path, out contents);

            var parser = new Json.Parser ();
            parser.load_from_data (contents);

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                return false;
            }

            var object = root.get_object ();
            var age = GLib.get_real_time () - object.get_int_member_with_default ("fetched", 0);
            if (age < 0 || age > FRESH_USEC) {
                return false;
            }

            version = object.get_string_member_with_default ("version", "");
            visitor_data = object.get_string_member_with_default ("visitor", "");
            signature_timestamp = object.get_string_member_with_default ("sts", "");

            return version != "" && signature_timestamp != "";
        } catch (Error e) {
            return false;
        }
    }

    private static void save_cache () {
        if (version == "" || signature_timestamp == "") {
            return;
        }

        var object = new Json.Object ();
        object.set_string_member ("version", version);
        object.set_string_member ("visitor", visitor_data);
        object.set_string_member ("sts", signature_timestamp);
        object.set_int_member ("fetched", GLib.get_real_time ());

        var generator = new Json.Generator ();
        generator.root = new Json.Node.alloc ().init_object (object);

        try {
            var path = cache_path ();
            GLib.DirUtils.create_with_parents (GLib.Path.get_dirname (path), 0755);
            GLib.FileUtils.set_contents (path, generator.to_data (null));
        } catch (Error e) {
            debug ("Could not save the site config: %s", e.message);
        }
    }
}
