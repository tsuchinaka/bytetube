/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * A video as a compact row. Used where a grid would be too wide or too
 * repetitive: beside the player and in the library lists.
 */

public class ByteTube.VideoRow : Gtk.ListBoxRow {
    public Video video { get; construct; }

    public VideoRow (Video video) {
        Object (video: video);
    }

    construct {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            margin_top = 4,
            margin_bottom = 4,
            margin_start = 4,
            margin_end = 4
        };

        if (video.is_live) {
            box.append (new Thumbnail.with_live_badge (
                video.display_thumbnail,
                128,
                72,
                video.duration_label
            ));
        } else {
            box.append (new Thumbnail.with_badge (
                video.display_thumbnail,
                128,
                72,
                video.duration_label
            ));
        }

        var details = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            valign = Gtk.Align.CENTER,
            vexpand = true
        };

        var title = new Gtk.Label (video.title) {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            lines = 2,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 22,
            halign = Gtk.Align.FILL
        };
        details.append (title);

        var byline = new Gtk.Label (video.byline) {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 24,
            halign = Gtk.Align.FILL
        };
        byline.add_css_class (Granite.CssClass.DIM);
        byline.add_css_class (Granite.CssClass.SMALL);
        details.append (byline);

        box.append (details);

        child = box;
        tooltip_text = video.title;
    }
}
