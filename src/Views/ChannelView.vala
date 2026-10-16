/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Everything a channel publishes.
 */

public class ByteTube.ChannelView : BrowseView {
    private unowned Library library;

    private Channel? current = null;
    private string requested_id = "";
    private bool updating = false;

    private Gtk.ToggleButton follow_button;
    private Granite.HeaderLabel name_label;
    private Gtk.Label byline_label;
    private Thumbnail avatar;

    construct {
        library = Library.get_default ();

        empty_title = _("No Videos");
        empty_description = _("This channel has not published anything that can be shown here.");
        empty_icon = "folder-videos-symbolic";

        build_header ();
    }

    public void show_channel (string channel_id, Channel? known = null) {
        requested_id = channel_id;
        current = known;

        if (known != null) {
            apply_channel (known);
        }

        refresh ();
    }

    protected override async BrowseResult fetch (string? continuation) throws Error {
        if (requested_id == "") {
            return new BrowseResult ();
        }

        return yield client.browse (requested_id, continuation);
    }

    protected override void on_result (BrowseResult result) {
        if (result.channel != null && result.channel.id != "") {
            current = result.channel;
        }

        if (current != null) {
            apply_channel (current);
        }
    }

    private void build_header () {
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 18) {
            margin_bottom = 12
        };

        avatar = new Thumbnail.avatar ("", 72) {
            valign = Gtk.Align.CENTER
        };
        row.append (avatar);

        var details = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            valign = Gtk.Align.CENTER,
            hexpand = true
        };

        name_label = new Granite.HeaderLabel ("") {
            size = Granite.HeaderLabel.Size.H2,
            halign = Gtk.Align.START
        };
        details.append (name_label);

        byline_label = new Gtk.Label ("") {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            halign = Gtk.Align.FILL
        };
        byline_label.add_css_class (Granite.CssClass.DIM);
        byline_label.add_css_class (Granite.CssClass.SMALL);
        details.append (byline_label);

        follow_button = new Gtk.ToggleButton.with_label (_("Follow")) {
            halign = Gtk.Align.START,
            margin_top = 3
        };
        follow_button.toggled.connect (on_follow_toggled);
        details.append (follow_button);

        row.append (details);
        header_box.append (row);
        header_box.visible = true;
    }

    private void apply_channel (Channel channel) {
        name_label.label = channel.name;

        var parts = new Gee.ArrayList<string> ();
        if (channel.handle != "") {
            parts.add (channel.handle);
        }

        if (channel.subscriber_count != "") {
            parts.add (channel.subscriber_count);
        }

        if (channel.video_count != "") {
            parts.add (channel.video_count);
        }

        byline_label.label = string.joinv (" • ", parts.to_array ());
        byline_label.visible = byline_label.label != "";

        if (channel.avatar_uri != "") {
            avatar.load_uri (channel.avatar_uri);
        }

        follow_button.visible = channel.id != "";
        updating = true;
        follow_button.active = library.is_following (channel.id);
        updating = false;
        update_follow_label ();
        header_box.visible = true;
        tooltip_text = channel.name;
    }

    private void on_follow_toggled () {
        if (updating || current == null || current.id == "") {
            return;
        }

        if (follow_button.active) {
            library.follow (current);
        } else {
            library.unfollow (current.id);
        }

        update_follow_label ();
    }

    private void update_follow_label () {
        if (follow_button.active) {
            follow_button.label = _("Following");
            follow_button.tooltip_text = _("Stop following this channel");
        } else {
            follow_button.label = _("Follow");
            follow_button.tooltip_text = _("See this channel's newest videos first");
        }
    }
}
