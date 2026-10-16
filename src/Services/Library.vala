/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * The parts of the app the user builds up themselves: what they watched, what
 * they put aside for later, and which channels they follow.
 *
 * None of this needs an account. It lives in a single JSON file in the user's
 * data directory, next to the GSettings that describe the window.
 */

public class ByteTube.Library : GLib.Object {
    private const string FILE_NAME = "library.json";

    private static Library? instance = null;

    private Gee.ArrayList<Video> _history = new Gee.ArrayList<Video> ();
    private Gee.ArrayList<Video> _watch_later = new Gee.ArrayList<Video> ();
    private Gee.ArrayList<Channel> _channels = new Gee.ArrayList<Channel> ();
    private GLib.Settings settings;

    public signal void history_changed ();
    public signal void watch_later_changed ();
    public signal void channels_changed ();

    /** Newest first. */
    public Gee.ArrayList<Video> history { get { return _history; } }

    /** Newest first. */
    public Gee.ArrayList<Video> watch_later { get { return _watch_later; } }

    /** In the order the user followed them. */
    public Gee.ArrayList<Channel> channels { get { return _channels; } }

    public bool records_history {
        get {
            return settings.get_boolean ("save-watch-history");
        }
    }

    public static unowned Library get_default () {
        if (instance == null) {
            instance = new Library ();
        }

        return instance;
    }

    private Library () {
        settings = new GLib.Settings (Config.APP_ID);
        load ();
    }

    // ------------------------------------------------------------------
    // Watch history
    // ------------------------------------------------------------------

    public void record_watch (Video video) {
        if (video.id == "" || !records_history) {
            return;
        }

        remove_by_id (_history, video.id);
        _history.insert (0, video);

        while (_history.size > Config.MAX_HISTORY) {
            _history.remove_at (_history.size - 1);
        }

        history_changed ();
        save ();
    }

    public void clear_history () {
        if (_history.size == 0) {
            return;
        }

        _history.clear ();
        history_changed ();
        save ();
    }

    // ------------------------------------------------------------------
    // Watch Later
    // ------------------------------------------------------------------

    public bool is_saved (string video_id) {
        return index_of (_watch_later, video_id) >= 0;
    }

    public void save_for_later (Video video) {
        if (video.id == "" || is_saved (video.id)) {
            return;
        }

        _watch_later.insert (0, video);
        watch_later_changed ();
        save ();
    }

    public void remove_saved (string video_id) {
        var index = index_of (_watch_later, video_id);
        if (index < 0) {
            return;
        }

        _watch_later.remove_at (index);
        watch_later_changed ();
        save ();
    }

    // ------------------------------------------------------------------
    // Followed channels
    // ------------------------------------------------------------------

    public bool is_following (string channel_id) {
        foreach (var channel in _channels) {
            if (channel.id == channel_id) {
                return true;
            }
        }

        return false;
    }

    public void follow (Channel channel) {
        if (channel.id == "" || is_following (channel.id)) {
            return;
        }

        _channels.add (channel);
        channels_changed ();
        save ();
    }

    public void unfollow (string channel_id) {
        for (int i = 0; i < _channels.size; i++) {
            if (_channels[i].id == channel_id) {
                _channels.remove_at (i);
                channels_changed ();
                save ();
                return;
            }
        }
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    private static string store_path () {
        return GLib.Path.build_filename (
            GLib.Environment.get_user_data_dir (),
            "bytetube",
            FILE_NAME
        );
    }

    private void load () {
        var file = GLib.File.new_for_path (store_path ());
        if (!file.query_exists ()) {
            return;
        }

        try {
            uint8[] contents;
            string? etag;
            file.load_contents (null, out contents, out etag);

            var parser = new Json.Parser ();
            parser.load_from_data ((string) contents);

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                return;
            }

            var object = root.get_object ();
            read_videos (object, "history", _history);
            read_videos (object, "watch_later", _watch_later);
            read_channels (object, "channels", _channels);
        } catch (Error e) {
            warning ("Could not read the library: %s", e.message);
        }
    }

    private void save () {
        var root = new Json.Object ();
        root.set_array_member ("history", videos_to_array (_history));
        root.set_array_member ("watch_later", videos_to_array (_watch_later));
        root.set_array_member ("channels", channels_to_array (_channels));

        var generator = new Json.Generator ();
        generator.root = new Json.Node.alloc ().init_object (root);
        generator.pretty = true;

        var path = store_path ();

        try {
            GLib.DirUtils.create_with_parents (GLib.Path.get_dirname (path), 0755);
            GLib.FileUtils.set_contents (path, generator.to_data (null));
        } catch (Error e) {
            warning ("Could not save the library: %s", e.message);
        }
    }

    private static Json.Array videos_to_array (Gee.ArrayList<Video> videos) {
        var array = new Json.Array ();
        foreach (var video in videos) {
            var node = new Json.Node.alloc ();
            node.init_object (video.to_json_object ());
            array.add_element (node);
        }

        return array;
    }

    private static Json.Array channels_to_array (Gee.ArrayList<Channel> channels) {
        var array = new Json.Array ();
        foreach (var channel in channels) {
            var node = new Json.Node.alloc ();
            node.init_object (channel.to_json_object ());
            array.add_element (node);
        }

        return array;
    }

    private static void read_videos (
        Json.Object object,
        string member,
        Gee.ArrayList<Video> target
    ) {
        var node = object.get_member (member);
        if (node == null || node.get_node_type () != Json.NodeType.ARRAY) {
            return;
        }

        var array = node.get_array ();
        for (uint i = 0; i < array.get_length (); i++) {
            var element = array.get_element (i);
            if (element == null || element.get_node_type () != Json.NodeType.OBJECT) {
                continue;
            }

            var video = Video.from_json_object (element.get_object ());
            if (video != null) {
                target.add (video);
            }
        }
    }

    private static void read_channels (
        Json.Object object,
        string member,
        Gee.ArrayList<Channel> target
    ) {
        var node = object.get_member (member);
        if (node == null || node.get_node_type () != Json.NodeType.ARRAY) {
            return;
        }

        var array = node.get_array ();
        for (uint i = 0; i < array.get_length (); i++) {
            var element = array.get_element (i);
            if (element == null || element.get_node_type () != Json.NodeType.OBJECT) {
                continue;
            }

            var channel = Channel.from_json_object (element.get_object ());
            if (channel != null) {
                target.add (channel);
            }
        }
    }

    private static int index_of (Gee.ArrayList<Video> videos, string video_id) {
        for (int i = 0; i < videos.size; i++) {
            if (videos[i].id == video_id) {
                return i;
            }
        }

        return -1;
    }

    private static void remove_by_id (Gee.ArrayList<Video> videos, string video_id) {
        var index = index_of (videos, video_id);
        if (index >= 0) {
            videos.remove_at (index);
        }
    }
}
