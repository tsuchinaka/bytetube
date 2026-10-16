/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * High level navigation.
 *
 * The list of followed channels grows and shrinks as the user follows things,
 * so the whole sidebar sits in a scroller and only the section that has
 * something in it is shown.
 */

public class ByteTube.Sidebar : Gtk.Box {
    public signal void view_requested (string name);
    public signal void channel_requested (ByteTube.Channel channel);

    private unowned Library library;

    private Gtk.ListBox list;
    private Gtk.ListBox channel_list;
    private Gtk.Box channel_section;
    private Gee.HashMap<string, Gtk.ListBoxRow> rows = new Gee.HashMap<string, Gtk.ListBoxRow> ();
    private Gee.HashMap<Gtk.ListBoxRow, string> names = new Gee.HashMap<Gtk.ListBoxRow, string> ();
    private bool updating = false;

    public Sidebar () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            width_request: 220
        );
    }

    construct {
        library = Library.get_default ();

        // The theme's own sidebar classes, so rows, selection and padding
        // match every other elementary app instead of being reinvented.
        add_css_class (Granite.STYLE_CLASS_SIDEBAR);
        add_css_class ("navigation-sidebar");

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
            margin_top = 6,
            margin_bottom = 6,
            margin_start = 6,
            margin_end = 6
        };

        list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.SINGLE,
            activate_on_single_click = true
        };
        list.row_selected.connect (on_row_selected);

        add_row (Config.VIEW_DISCOVER, _("Discover"), "go-home-symbolic");
        add_row (Config.VIEW_CHANNELS, _("Followed Channels"), "user-bookmarks-symbolic");
        add_row (Config.VIEW_HISTORY, _("History"), "document-open-recent-symbolic");
        add_row (Config.VIEW_WATCH_LATER, _("Watch Later"), "playlist-symbolic");
        add_row (Config.VIEW_ACCOUNT, _("Account"), "avatar-default-symbolic");

        content.append (list);

        channel_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE,
            activate_on_single_click = true
        };
        channel_list.row_activated.connect ((row) => {
            if (row is ChannelRow) {
                channel_requested (((ChannelRow) row).channel);
            }
        });

        channel_section = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        channel_section.append (section_header (_("Channels")));
        channel_section.append (channel_list);
        content.append (channel_section);

        var scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            vexpand = true,
            child = content
        };

        append (scrolled);

        refresh_channels ();
        library.channels_changed.connect (refresh_channels);
    }

    /** Highlights the row for `name`, or clears the selection when empty. */
    public void select_view (string name) {
        updating = true;

        var row = rows.get (name);
        if (row != null) {
            list.select_row (row);
        } else {
            list.unselect_all ();
        }

        updating = false;
    }

    private void add_row (string name, string label, string icon_name) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 3,
            margin_bottom = 3,
            margin_start = 3,
            margin_end = 6
        };

        box.append (new Gtk.Image.from_icon_name (icon_name) { pixel_size = 16 });
        box.append (new Gtk.Label (label) {
            xalign = 0,
            halign = Gtk.Align.FILL,
            hexpand = true
        });

        var row = new Gtk.ListBoxRow () { child = box, tooltip_text = label };
        list.append (row);

        rows.set (name, row);
        names.set (row, name);
    }

    private static Gtk.Widget section_header (string text) {
        var label = new Gtk.Label (text) {
            xalign = 0,
            margin_start = 9,
            margin_top = 6
        };
        label.add_css_class (Granite.CssClass.DIM);
        label.add_css_class (Granite.CssClass.SMALL);
        return label;
    }

    private void on_row_selected (Gtk.ListBoxRow? row) {
        if (updating || row == null) {
            return;
        }

        var name = names.get (row);
        if (name != null) {
            view_requested (name);
        }
    }

    private void refresh_channels () {
        var child = channel_list.get_first_child ();
        while (child != null) {
            channel_list.remove (child);
            child = channel_list.get_first_child ();
        }

        foreach (var channel in library.channels) {
            channel_list.append (new ChannelRow (channel));
        }

        channel_section.visible = library.channels.size > 0;
    }
}
