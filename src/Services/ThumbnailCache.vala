/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Downloads thumbnails in the background and keeps them in memory and on disk.
 *
 * Thumbnails are the bulk of what the app draws, so they are cached twice: a
 * decoded texture is kept for as long as a view is on screen, and the encoded
 * image is written to the user's cache directory so that reopening a view does
 * not hit the network again.
 */

public class ByteTube.ThumbnailCache : GLib.Object {
    private const int MAX_MEMORY_ENTRIES = 320;

    private static ThumbnailCache? instance = null;

    private Gee.HashMap<string, Gdk.Texture> textures = new Gee.HashMap<string, Gdk.Texture> ();
    private Soup.Session session;

    public static unowned ThumbnailCache get_default () {
        if (instance == null) {
            instance = new ThumbnailCache ();
        }

        return instance;
    }

    private ThumbnailCache () {
        session = HttpSession.get_shared ();
    }

    private static string directory {
        owned get {
            return GLib.Path.build_filename (
                GLib.Environment.get_user_cache_dir (),
                "bytetube",
                "thumbnails"
            );
        }
    }

    /**
     * Returns the thumbnail for `uri`, fetching it if necessary. The returned
     * value is null when the image could not be retrieved, in which case the
     * caller should show its placeholder.
     */
    public async Gdk.Texture? load (string uri, GLib.Cancellable? cancellable = null) {
        if (uri == "") {
            return null;
        }

        var cached = textures.get (uri);
        if (cached != null) {
            return cached;
        }

        var path = disk_path (uri);

        GLib.Bytes? bytes = null;
        try {
            bytes = yield read_bytes (uri, path, cancellable);
        } catch (Error e) {
            debug ("Could not load thumbnail %s: %s", uri, e.message);
            return null;
        }

        if (bytes == null) {
            return null;
        }

        // Decoding is the one genuinely synchronous step here, so it is handed
        // to a worker and the coroutine resumes on the main loop. The hand-off
        // has to sit outside a try block: a coroutine cannot be suspended into
        // a catch handler.
        Gdk.Texture? decoded = null;
        Work.submit_with_resume (() => {
            try {
                decoded = Gdk.Texture.from_bytes (bytes);
            } catch (Error e) {
                debug ("Could not decode %s: %s", uri, e.message);
            }
        }, load.callback);

        yield;

        if (decoded == null) {
            return null;
        }

        remember (uri, decoded);
        return decoded;
    }

    private async GLib.Bytes? read_bytes (
        string uri,
        string path,
        GLib.Cancellable? cancellable
    ) throws Error {
        var file = GLib.File.new_for_path (path);
        if (file.query_exists ()) {
            try {
                uint8[] contents;
                file.load_contents (cancellable, out contents, null);
                return new GLib.Bytes (contents);
            } catch (Error e) {
                debug ("Cached thumbnail %s was unreadable: %s", path, e.message);
            }
        }

        var message = new Soup.Message ("GET", uri);
        message.request_headers.append ("User-Agent", "ByteTube");
        var response = yield session.send_and_read_async (
            message,
            GLib.Priority.LOW,
            cancellable
        );

        if (message.status_code != Soup.Status.OK) {
            return null;
        }

        try {
            GLib.DirUtils.create_with_parents (directory, 0755);
            var stream = file.replace (null, false, GLib.FileCreateFlags.NONE, cancellable);
            stream.write_bytes (response, cancellable);
            stream.close (cancellable);
        } catch (Error e) {
            debug ("Could not cache thumbnail %s: %s", path, e.message);
        }

        return response;
    }

    private static string disk_path (string uri) {
        var key = GLib.Checksum.compute_for_string (GLib.ChecksumType.SHA256, uri);
        return GLib.Path.build_filename (directory, key);
    }

    private void remember (string uri, Gdk.Texture texture) {
        if (textures.size >= MAX_MEMORY_ENTRIES) {
            var oldest = textures.keys.iterator ();
            if (oldest.next ()) {
                textures.unset (oldest.get ());
            }
        }

        textures.set (uri, texture);
    }
}
