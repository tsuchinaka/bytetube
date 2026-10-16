/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Every video in a playlist.
 */

public class ByteTube.PlaylistView : BrowseView {
    private string playlist_id = "";
    private Granite.HeaderLabel title_label;

    construct {
        empty_title = _("Empty Playlist");
        empty_description = _("This playlist has no videos that can be shown here.");
        empty_icon = "playlist-symbolic";

        title_label = new Granite.HeaderLabel ("") {
            size = Granite.HeaderLabel.Size.H2,
            halign = Gtk.Align.START,
            margin_bottom = 6
        };
        header_box.append (title_label);
    }

    public void show_playlist (Playlist playlist) {
        playlist_id = playlist.id;
        title_label.label = playlist.title;
        header_box.visible = playlist.title != "";
        tooltip_text = playlist.title;
        refresh ();
    }

    protected override async BrowseResult fetch (string? continuation) throws Error {
        if (playlist_id == "") {
            return new BrowseResult ();
        }

        return yield client.browse ("VL%s".printf (playlist_id), continuation);
    }
}
