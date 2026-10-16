/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * A page full of results.
 *
 * Every page that shows results the service returned works the same way: ask
 * for a page, show a spinner while it is on its way, lay the shelves out in a
 * grid, and offer the next page at the bottom. Subclasses only say where the
 * results come from.
 */

public class ByteTube.BrowseView : Gtk.Box {
    public signal void video_activated (ByteTube.Video video);
    public signal void channel_activated (ByteTube.Channel channel);
    public signal void playlist_activated (ByteTube.Playlist playlist);

    protected InnertubeClient client;

    /** Filled in by subclasses to put something above the first shelf. */
    protected Gtk.Box header_box { get; private set; }

    protected string empty_title = _("Nothing Found");
    protected string empty_description = "";
    protected string empty_icon = "system-search-symbolic";

    private Gtk.Stack stack;
    private Gtk.ScrolledWindow scroller;
    private Gtk.Box results;
    private Gtk.Button load_more;
    private StatusView status;

    private string? continuation = null;
    private bool loading = false;

    public BrowseView () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            hexpand: true,
            vexpand: true
        );
    }

    construct {
        client = new InnertubeClient ();

        header_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            visible = false
        };

        results = new Gtk.Box (Gtk.Orientation.VERTICAL, 18) {
            margin_top = 12,
            margin_bottom = 24,
            margin_start = 12,
            margin_end = 12
        };
        results.append (header_box);

        load_more = new Gtk.Button.with_label (_("Load More")) {
            halign = Gtk.Align.CENTER,
            margin_top = 6
        };
        load_more.clicked.connect (() => load_next_page ());

        scroller = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            hexpand = true,
            vexpand = true,
            child = results
        };

        status = new StatusView ();
        status.action_requested.connect (() => refresh ());

        stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.CROSSFADE,
            hexpand = true,
            vexpand = true,
            hhomogeneous = false,
            vhomogeneous = false
        };
        stack.add_named (scroller, "results");
        stack.add_named (status, "status");

        append (stack);
    }

    /**
     * Where this page gets its results. `continuation` is null for the first
     * page and carries the token from the previous one otherwise.
     */
    protected virtual async BrowseResult fetch (string? continuation) throws Error {
        return new BrowseResult ();
    }

    /** Called with every response, before it is laid out. */
    protected virtual void on_result (BrowseResult result) {
    }

    /** Reloads from the first page. */
    public void refresh () {
        start (null);
    }

    private void load_next_page () {
        if (continuation == null || loading) {
            return;
        }

        start (continuation);
    }

    private void start (string? token) {
        if (loading) {
            return;
        }

        loading = true;

        if (token == null) {
            clear_results ();
        }

        status.show_loading ();
        stack.visible_child_name = "status";

        fetch.begin (token, (obj, res) => {
            loading = false;

            try {
                apply (fetch.end (res), token != null);
            } catch (Error e) {
                show_failure (e.message);
            }
        });
    }

    private void apply (BrowseResult result, bool appended) {
        on_result (result);

        continuation = result.continuation;

        if (load_more.get_parent () == results) {
            results.remove (load_more);
        }

        var added = 0;
        foreach (var shelf in result.shelves) {
            var shelf_view = new ShelfView (shelf);
            shelf_view.item_activated.connect (on_item_activated);
            results.append (shelf_view);
            added++;
        }

        if (added == 0 && !appended) {
            show_empty ();
            return;
        }

        if (continuation != null) {
            results.append (load_more);
        }

        stack.visible_child_name = "results";
        scroller.vadjustment.value = 0;
    }

    private void show_empty () {
        status.show_message (empty_title, empty_description, empty_icon);
        stack.visible_child_name = "status";
    }

    private void show_failure (string message) {
        status.show_message (
            _("Could Not Load Results"),
            message,
            "network-error-symbolic",
            _("Try Again"),
            "view-refresh-symbolic"
        );
        stack.visible_child_name = "status";
    }

    private void clear_results () {
        continuation = null;
        header_box.visible = false;

        var child = results.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            if (child != header_box && child != load_more) {
                results.remove (child);
            }

            child = next;
        }
    }

    private void on_item_activated (GLib.Object item) {
        if (item is Video) {
            video_activated ((Video) item);
        } else if (item is Channel) {
            channel_activated ((Channel) item);
        } else if (item is Playlist) {
            playlist_activated ((Playlist) item);
        }
    }

    protected static void remove_children (Gtk.Widget parent) {
        var child = parent.get_first_child ();
        while (child != null) {
            child.unparent ();
            child = parent.get_first_child ();
        }
    }
}
