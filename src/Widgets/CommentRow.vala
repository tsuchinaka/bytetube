/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * One comment in the list beside the player.
 */

public class ByteTube.CommentRow : Gtk.ListBoxRow {
    public Comment comment { get; construct; }

    public CommentRow (Comment comment) {
        Object (comment: comment);
    }

    construct {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 6,
            margin_bottom = 6,
            margin_start = 6,
            margin_end = 6
        };

        box.append (new Thumbnail.avatar (comment.avatar_uri, 32) {
            valign = Gtk.Align.START
        });

        var details = new Gtk.Box (Gtk.Orientation.VERTICAL, 3) {
            hexpand = true
        };

        var byline = new Gtk.Label (comment.author) {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            halign = Gtk.Align.FILL
        };
        if (comment.published != "") {
            byline.label = "%s • %s".printf (comment.author, comment.published);
        }
        details.append (byline);

        var body = new Gtk.Label (comment.text) {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            halign = Gtk.Align.FILL
        };
        body.add_css_class (Granite.CssClass.SMALL);
        details.append (body);

        box.append (details);

        child = box;
        activatable = false;
        selectable = false;
    }
}
