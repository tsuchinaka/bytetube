/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * One result in a grid: a video, a channel, or a playlist.
 *
 * Results of different kinds sit in the same grid so that a page keeps the
 * order the service returned them in, without the view having to know which
 * kind of result it is looking at.
 */

public class ByteTube.ResultCard : Gtk.FlowBoxChild {
    public GLib.Object item { get; construct; }

    public ResultCard (GLib.Object item) {
        Object (item: item);
    }

    construct {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            width_request = Config.CARD_WIDTH
        };

        if (item is Video) {
            build_video (box, (Video) item);
        } else if (item is Channel) {
            build_channel (box, (Channel) item);
        } else if (item is Playlist) {
            build_playlist (box, (Playlist) item);
        }

        child = box;
    }

    private void build_video (Gtk.Box box, Video video) {
        if (video.is_live) {
            box.append (new Thumbnail.with_live_badge (
                video.display_thumbnail,
                Config.CARD_WIDTH,
                Config.CARD_HEIGHT,
                video.duration_label
            ));
        } else {
            box.append (new Thumbnail.with_badge (
                video.display_thumbnail,
                Config.CARD_WIDTH,
                Config.CARD_HEIGHT,
                video.duration_label
            ));
        }

        var title = new Gtk.Label (video.title) {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            lines = 2,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 30,
            halign = Gtk.Align.FILL
        };
        box.append (title);

        box.append (secondary_label (video.byline));
        tooltip_text = video.title;
    }

    private void build_channel (Gtk.Box box, Channel channel) {
        var avatar = new Thumbnail.avatar (channel.avatar_uri, 96) {
            halign = Gtk.Align.CENTER
        };
        box.append (avatar);

        var name = new Gtk.Label (channel.name) {
            justify = Gtk.Justification.CENTER,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            lines = 2,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 30,
            halign = Gtk.Align.CENTER
        };
        box.append (name);

        box.append (secondary_label (channel.subscriber_count, Gtk.Align.CENTER));
        tooltip_text = channel.name;
    }

    private void build_playlist (Gtk.Box box, Playlist playlist) {
        // A playlist has no duration, but it is worth marking as a collection.
        box.append (new Thumbnail.with_badge (
            playlist.thumbnail_uri,
            Config.CARD_WIDTH,
            Config.CARD_HEIGHT,
            playlist.video_count
        ));

        var title = new Gtk.Label (playlist.title) {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            lines = 2,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 30,
            halign = Gtk.Align.FILL
        };
        box.append (title);

        var parts = new Gee.ArrayList<string> ();
        if (playlist.channel_name != "") {
            parts.add (playlist.channel_name);
        }

        box.append (secondary_label (string.joinv (" • ", parts.to_array ())));
        tooltip_text = playlist.title;
    }

    private static Gtk.Label secondary_label (string text, Gtk.Align align = Gtk.Align.FILL) {
        var label = new Gtk.Label (text) {
            xalign = 0,
            halign = align,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 34
        };
        label.add_css_class (Granite.CssClass.DIM);
        label.add_css_class (Granite.CssClass.SMALL);
        return label;
    }
}
