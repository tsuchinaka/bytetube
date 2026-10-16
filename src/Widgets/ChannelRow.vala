/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * One followed channel in the sidebar.
 */

public class ByteTube.ChannelRow : Gtk.ListBoxRow {
    public Channel channel { get; construct; }

    public ChannelRow (Channel channel) {
        Object (channel: channel);
    }

    construct {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 3,
            margin_bottom = 3,
            margin_start = 3,
            margin_end = 6
        };

        box.append (new Thumbnail.avatar (channel.avatar_uri, 24));

        var label = new Gtk.Label (channel.name) {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 18,
            halign = Gtk.Align.FILL,
            hexpand = true
        };
        box.append (label);

        child = box;
        tooltip_text = channel.name;
    }
}
