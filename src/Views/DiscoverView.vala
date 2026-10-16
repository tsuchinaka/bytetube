/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * The page the app opens on.
 *
 * It is built entirely from what is on the machine, so it appears instantly
 * with no network round trip: what the user was watching, the channels they
 * follow, and a set of topics to explore. Topics run a search, which is the one
 * thing the service still serves to people who are not signed in.
 */

public class ByteTube.DiscoverView : Gtk.Box {
    public signal void search_requested (string query);
    public signal void search_entry_requested ();
    public signal void video_activated (ByteTube.Video video);
    public signal void channel_activated (ByteTube.Channel channel);

    private unowned Library library;

    private Gtk.Box content;
    private bool building = false;

    public DiscoverView () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            hexpand: true,
            vexpand: true
        );
    }

    construct {
        library = Library.get_default ();

        content = new Gtk.Box (Gtk.Orientation.VERTICAL, 18) {
            margin_top = 18,
            margin_bottom = 24,
            margin_start = 12,
            margin_end = 12
        };

        var scroller = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            hexpand = true,
            vexpand = true,
            child = content
        };

        append (scroller);

        library.history_changed.connect (rebuild);
        library.channels_changed.connect (rebuild);

        rebuild ();
    }

    public void rebuild () {
        if (building) {
            return;
        }
        building = true;

        var child = content.get_first_child ();
        while (child != null) {
            content.remove (child);
            child = content.get_first_child ();
        }

        if (library.history.size == 0 && library.channels.size == 0) {
            content.append (build_welcome ());
        }

        var watching = shelf_from_videos (_("Continue Watching"), library.history);
        if (watching != null) {
            var shelf_view = new ShelfView (watching);
            shelf_view.item_activated.connect (on_item_activated);
            content.append (shelf_view);
        }

        var channels = shelf_from_channels (_("Channels You Follow"), library.channels);
        if (channels != null) {
            var shelf_view = new ShelfView (channels);
            shelf_view.item_activated.connect (on_item_activated);
            content.append (shelf_view);
        }

        content.append (build_topics ());

        building = false;
    }

    private Gtk.Widget build_welcome () {
        var placeholder = new Granite.Placeholder (_("Find Something to Watch")) {
            description = _("Search for a video, or start with one of the topics below."),
            icon = new GLib.ThemedIcon ("view-list-video-symbolic")
        };

        var button = placeholder.append_button (
            new GLib.ThemedIcon ("system-search-symbolic"),
            _("Search Videos"),
            ""
        );
        button.add_css_class (Granite.CssClass.SUGGESTED);
        button.clicked.connect (() => search_entry_requested ());

        return placeholder;
    }

    private Gtk.Widget build_topics () {
        var section = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);

        section.append (new Granite.HeaderLabel (_("Browse Topics")) {
            size = Granite.HeaderLabel.Size.H3,
            halign = Gtk.Align.START
        });

        var flow = new Gtk.FlowBox () {
            selection_mode = Gtk.SelectionMode.NONE,
            homogeneous = false,
            column_spacing = 6,
            row_spacing = 6,
            halign = Gtk.Align.START,
            valign = Gtk.Align.START
        };

        foreach (var topic in topics ()) {
            var button = new Gtk.Button.with_label (topic) {
                width_request = 150,
                height_request = 44
            };
            button.clicked.connect (() => search_requested (topic));

            flow.append (new Gtk.FlowBoxChild () { child = button });
        }

        section.append (flow);
        return section;
    }

    private static Shelf? shelf_from_videos (string title, Gee.ArrayList<Video> videos) {
        if (videos.size == 0) {
            return null;
        }

        var shelf = new Shelf () { title = title };
        for (int i = 0; i < int.min (videos.size, 12); i++) {
            shelf.items.add (videos[i]);
        }

        return shelf;
    }

    private static Shelf? shelf_from_channels (string title, Gee.ArrayList<Channel> channels) {
        if (channels.size == 0) {
            return null;
        }

        var shelf = new Shelf () { title = title };
        foreach (var channel in channels) {
            shelf.items.add (channel);
        }

        return shelf;
    }

    private void on_item_activated (GLib.Object item) {
        if (item is Video) {
            video_activated ((Video) item);
        } else if (item is Channel) {
            channel_activated ((Channel) item);
        }
    }

    private static string[] topics () {
        string[] list = {
            _("Music"),
            _("Gaming"),
            _("News"),
            _("Learning"),
            _("Podcasts"),
            _("Live"),
            _("Movies"),
            _("Sports"),
            _("Technology"),
            _("Cooking"),
            _("Travel"),
            _("Comedy")
        };

        return list;
    }
}
