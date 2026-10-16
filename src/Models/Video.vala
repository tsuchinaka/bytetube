/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * A single video, as returned by a search, a channel, or a playlist.
 */

public class ByteTube.Video : GLib.Object {
    public string id { get; set; default = ""; }
    public string title { get; set; default = ""; }
    public string channel_id { get; set; default = ""; }
    public string channel_name { get; set; default = ""; }
    public string channel_avatar { get; set; default = ""; }
    public string thumbnail_uri { get; set; default = ""; }
    public string duration { get; set; default = ""; }
    public string view_count { get; set; default = ""; }
    public string published { get; set; default = ""; }
    public string summary { get; set; default = ""; }
    public bool is_live { get; set; default = false; }

    /// TRANSLATORS: Shown in place of a duration for a running live stream
    public string duration_label {
        get {
            if (is_live) {
                return _("Live");
            }

            return duration;
        }
    }

    public string watch_uri {
        owned get {
            return "https://www.youtube.com/watch?v=%s".printf (id);
        }
    }

    /**
     * Pulls a video identifier out of anything a user might hand the app:
     * a link from a browser, or the identifier on its own.
     */
    public static string? id_from_uri (string uri) {
        var text = uri.strip ();
        if (text == "") {
            return null;
        }

        var id = id_after (text, "watch?v=");
        if (id == null) {
            id = id_after (text, "youtu.be/");
        }

        if (id == null) {
            id = id_after (text, "/embed/");
        }

        if (id == null) {
            id = id_after (text, "/shorts/");
        }

        if (id == null) {
            id = id_after (text, "/live/");
        }

        if (id == null && !text.contains ("/") && !text.contains (" ") && text.length == 11) {
            id = text;
        }

        return id;
    }

    private static string? id_after (string text, string marker) {
        var start = text.index_of (marker);
        if (start < 0) {
            return null;
        }

        start += marker.length;

        var end = start;
        while (end < text.length) {
            var c = text[end];
            var allowed = (c >= 'a' && c <= 'z')
                || (c >= 'A' && c <= 'Z')
                || (c >= '0' && c <= '9')
                || c == '-'
                || c == '_';

            if (!allowed) {
                break;
            }

            end++;
        }

        if (end == start) {
            return null;
        }

        return text.substring (start, end - start);
    }

    /**
     * The image to show for this video. Videos opened from a link have no
     * thumbnail of their own yet, but the service serves one for every
     * identifier, so there is always something to show.
     */
    public string display_thumbnail {
        owned get {
            if (thumbnail_uri != "") {
                return thumbnail_uri;
            }

            if (id == "") {
                return "";
            }

            return "https://i.ytimg.com/vi/%s/mqdefault.jpg".printf (id);
        }
    }

    /** Channel, view count, and age, joined the way lists show them. */
    public string byline {
        owned get {
            var parts = new Gee.ArrayList<string> ();

            if (channel_name != "") {
                parts.add (channel_name);
            }

            if (view_count != "") {
                parts.add (view_count);
            }

            if (published != "") {
                parts.add (published);
            }

            return string.joinv (" • ", parts.to_array ());
        }
    }

    public Json.Object to_json_object () {
        var object = new Json.Object ();
        object.set_string_member ("id", id);
        object.set_string_member ("title", title);
        object.set_string_member ("channel_id", channel_id);
        object.set_string_member ("channel_name", channel_name);
        object.set_string_member ("channel_avatar", channel_avatar);
        object.set_string_member ("thumbnail_uri", thumbnail_uri);
        object.set_string_member ("duration", duration);
        object.set_string_member ("view_count", view_count);
        object.set_string_member ("published", published);
        object.set_string_member ("summary", summary);
        object.set_boolean_member ("is_live", is_live);
        return object;
    }

    public static Video? from_json_object (Json.Object object) {
        var id = object.get_string_member_with_default ("id", "");
        if (id == "") {
            return null;
        }

        var video = new Video () { id = id };
        video.title = object.get_string_member_with_default ("title", "");
        video.channel_id = object.get_string_member_with_default ("channel_id", "");
        video.channel_name = object.get_string_member_with_default ("channel_name", "");
        video.channel_avatar = object.get_string_member_with_default ("channel_avatar", "");
        video.thumbnail_uri = object.get_string_member_with_default ("thumbnail_uri", "");
        video.duration = object.get_string_member_with_default ("duration", "");
        video.view_count = object.get_string_member_with_default ("view_count", "");
        video.published = object.get_string_member_with_default ("published", "");
        video.summary = object.get_string_member_with_default ("summary", "");
        video.is_live = object.get_boolean_member_with_default ("is_live", false);
        return video;
    }
}
