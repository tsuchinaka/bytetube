/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * An image fetched from the network, with an optional badge in the corner.
 *
 * Thumbnails are the bulk of what the app draws, so the widget keeps the layout
 * stable while the image is on its way: it always occupies exactly the space it
 * was given and simply stays empty until the image arrives.
 *
 * The picture and the badge are composed inside a box rather than by deriving
 * from a container, because GTK 4.22 no longer exposes the instance structures
 * of the widgets that would be needed to derive from them.
 */

public class ByteTube.Thumbnail : Gtk.Box {
    public int thumb_width { get; construct; default = Config.CARD_WIDTH; }
    public int thumb_height { get; construct; default = Config.CARD_HEIGHT; }
    public bool circular { get; construct; default = false; }
    public string badge { get; construct; default = ""; }

    /** A live badge is red; every other badge is a neutral dark chip. */
    public bool live_badge { get; construct; default = false; }

    private string _uri = "";
    private Gtk.Picture picture;

    public string uri {
        get {
            return _uri;
        }
    }

    public Thumbnail (string uri, int width, int height) {
        Object (
            thumb_width: width,
            thumb_height: height,
            badge: ""
        );

        load_uri (uri);
    }

    public Thumbnail.with_badge (string uri, int width, int height, string badge) {
        Object (
            thumb_width: width,
            thumb_height: height,
            badge: badge,
            live_badge: false
        );

        load_uri (uri);
    }

    public Thumbnail.with_live_badge (string uri, int width, int height, string badge) {
        Object (
            thumb_width: width,
            thumb_height: height,
            badge: badge,
            live_badge: true
        );

        load_uri (uri);
    }

    public Thumbnail.avatar (string uri, int size) {
        Object (
            thumb_width: size,
            thumb_height: size,
            circular: true,
            badge: ""
        );

        load_uri (uri);
    }

    construct {
        orientation = Gtk.Orientation.VERTICAL;
        width_request = thumb_width;
        height_request = thumb_height;

        // The picture inside always expands, and GTK lets a container inherit
        // that from its children. Saying so explicitly here keeps a thumbnail
        // from stretching the card — or the avatar from stretching the channel
        // header — that it sits in.
        hexpand = false;
        vexpand = false;

        picture = new Gtk.Picture () {
            content_fit = Gtk.ContentFit.CONTAIN,
            can_shrink = true,
            overflow = Gtk.Overflow.HIDDEN,
            hexpand = true,
            vexpand = true
        };

        if (circular) {
            picture.add_css_class ("bytetube-avatar");
        } else {
            picture.add_css_class ("bytetube-thumbnail");
        }

        if (badge == "") {
            append (picture);
        } else {
            var overlay = new Gtk.Overlay () { child = picture };

            var label = new Gtk.Label (badge) {
                halign = Gtk.Align.END,
                valign = Gtk.Align.END,
                margin_end = 6,
                margin_bottom = 6
            };
            label.add_css_class ("bytetube-badge");

            if (live_badge) {
                label.add_css_class ("bytetube-badge-live");
            }

            overlay.add_overlay (label);

            append (overlay);
        }

        if (_uri != "") {
            fetch ();
        }
    }

    /** Points the widget at a different image. */
    public void load_uri (string new_uri) {
        if (new_uri == "" || new_uri == _uri) {
            return;
        }

        _uri = new_uri;
        fetch ();
    }

    private GLib.Cancellable? fetch_cancel = null;

    private void fetch () {
        // Rows are recycled while scrolling, so a previous fetch for another
        // image may still be running: it is cancelled, and whatever slips
        // through is ignored once this widget has moved on.
        if (fetch_cancel != null) {
            fetch_cancel.cancel ();
        }

        fetch_cancel = new GLib.Cancellable ();

        var wanted = _uri;
        ThumbnailCache.get_default ().load.begin (_uri, fetch_cancel, (source, result) => {
            if (wanted != _uri) {
                return;
            }

            on_loaded (source, result);
        });
    }

    private void on_loaded (GLib.Object? source, GLib.AsyncResult result) {
        var texture = ThumbnailCache.get_default ().load.end (result);
        if (texture == null) {
            return;
        }

        // The picture is told to report the size the thumbnail is drawn at,
        // rather than the size the file happens to be.
        picture.paintable = new SizedPaintable (texture, thumb_width, thumb_height);
    }
}
