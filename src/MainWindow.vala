/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * The app window: navigation on the left, the current view on the right.
 *
 * Views are kept in a back stack the way a browser keeps pages, so Back and
 * Forward work as expected. Views that hold no state of their own (a channel, a
 * playlist, a video) are built fresh each time they are opened, which keeps the
 * player from carrying anything over from the last video.
 */

public class ByteTube.MainWindow : Gtk.ApplicationWindow {
    private const int RESPONSE_CLEAR_HISTORY = 1;

    private unowned Library library;
    private GLib.Settings settings;

    private Gtk.Stack stack;
    private Gtk.Paned paned;
    private Gtk.Box sidebar_box;
    private Gtk.Box content_box;
    private Gtk.Label title_label;
    private Sidebar sidebar;
    private Gtk.SearchEntry search_entry;
    private Gtk.Button back_button;
    private Gtk.Button forward_button;
    private Gtk.Button now_playing_button;
    private Gtk.HeaderBar content_header;

    /** Where the divider sat before fullscreen took the sidebar away. */
    private int sidebar_position_held = 0;

    private DiscoverView discover_view;
    private SearchView search_view;
    private ChannelsView channels_view;
    private HistoryView history_view;
    private WatchLaterView watch_later_view;
    private AccountView account_view;

    private Gee.ArrayList<string> keys = new Gee.ArrayList<string> ();
    private Gee.ArrayList<Gtk.Widget> views = new Gee.ArrayList<Gtk.Widget> ();
    private Gee.ArrayList<string> titles = new Gee.ArrayList<string> ();

    private int position = -1;
    private int sequence = 0;
    private bool position_restored = false;
    private bool accels_registered = false;

    public MainWindow (Gtk.Application app) {
        Object (application: app);
    }

    construct {
        library = Library.get_default ();
        settings = new GLib.Settings (Config.APP_ID);

        default_width = settings.get_int ("window-width");
        default_height = settings.get_int ("window-height");
        maximized = settings.get_boolean ("window-maximized");

        build_header_bar ();
        build_content ();
        build_views ();
        register_actions ();

        // The site config (client version, visitor, signature timestamp) costs
        // two large downloads the first time it is read. Fetching it now,
        // while the user is still looking at the landing page, means opening
        // a video later does not pay for it.
        warm_up.begin ();

        restore_last_view ();

        map.connect (() => register_accels ());

        // The window owns fullscreen, so the panes follow the window rather
        // than the button that may have asked for it: leaving with Escape has
        // to put the sidebar and the headings back just the same.
        notify["fullscreened"].connect (() => apply_fullscreen ());

        close_request.connect (() => {
            save_state ();
            return false;
        });
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    /**
     * The window carries no header bar of its own: each pane has one, the way
     * a multi-pane elementary app is built. The window controls therefore live
     * with the pane they belong to — the close button with the sidebar, and
     * maximize with the content.
     */
    private void build_header_bar () {
        title_label = new Gtk.Label ("") {
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 48
        };
        title_label.add_css_class ("heading");

        var title_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            valign = Gtk.Align.CENTER
        };
        title_box.append (title_label);

        var sidebar_header = new Gtk.HeaderBar () {
            show_title_buttons = false,
            title_widget = new Gtk.Label ("")
        };
        sidebar_header.add_css_class (Granite.STYLE_CLASS_FLAT);
        sidebar_header.pack_start (new Gtk.WindowControls (Gtk.PackType.START));

        content_header = new Gtk.HeaderBar () {
            show_title_buttons = false,
            title_widget = title_box
        };
        content_header.add_css_class (Granite.STYLE_CLASS_FLAT);
        content_header.pack_end (new Gtk.WindowControls (Gtk.PackType.END));

        back_button = new Gtk.Button.from_icon_name ("go-previous-symbolic") {
            action_name = "win.go-back",
            sensitive = false,
            tooltip_markup = Granite.markup_accel_tooltip ({ "<Alt>Left" }, _("Go Back"))
        };

        forward_button = new Gtk.Button.from_icon_name ("go-next-symbolic") {
            action_name = "win.go-forward",
            sensitive = false,
            tooltip_markup = Granite.markup_accel_tooltip ({ "<Alt>Right" }, _("Go Forward"))
        };

        // Shown only while a video is playing somewhere the user is not
        // looking, as the way back to it.
        now_playing_button = new Gtk.Button.with_label (_("Now Playing")) {
            visible = false,
            tooltip_text = _("Return to the video that is playing")
        };
        now_playing_button.clicked.connect (() => return_to_playing ());

        content_header.pack_start (back_button);
        content_header.pack_start (forward_button);
        content_header.pack_start (now_playing_button);

        var refresh_button = new Gtk.Button.from_icon_name ("view-refresh-symbolic") {
            action_name = "win.refresh",
            tooltip_markup = Granite.markup_accel_tooltip ({ "<Control>r" }, _("Reload Results"))
        };

        search_entry = new Gtk.SearchEntry () {
            placeholder_text = _("Search Videos"),
            width_chars = 22,
            search_delay = 450,
            tooltip_markup = Granite.markup_accel_tooltip ({ "<Control>f" }, _("Search Videos"))
        };
        search_entry.search_changed.connect (() => on_search_changed ());
        search_entry.activate.connect (() => on_search_submitted ());

        var menu_button = new Gtk.MenuButton () {
            icon_name = "open-menu-symbolic",
            menu_model = build_menu (),
            tooltip_text = _("Menu")
        };

        content_header.pack_end (menu_button);
        content_header.pack_end (search_entry);
        content_header.pack_end (refresh_button);

        // The panes provide their own headers, so the window's is invisible.
        titlebar = new Gtk.Grid () { visible = false };

        sidebar_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        sidebar_box.add_css_class (Granite.STYLE_CLASS_SIDEBAR);
        sidebar_box.append (sidebar_header);

        content_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        content_box.add_css_class (Granite.STYLE_CLASS_VIEW);
        content_box.append (content_header);
    }

    private static MenuModel build_menu () {
        var menu = new Menu ();

        menu.append (_("Preferences…"), "win.preferences");
        menu.append (_("Keyboard Shortcuts"), "app.shortcuts");
        menu.append (_("Clear Watch History…"), "win.clear-history");
        menu.append (_("About ByteTube"), "app.about");
        menu.append (_("Quit"), "app.quit");

        return menu;
    }

    private void build_content () {
        stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.CROSSFADE,
            hexpand = true,
            vexpand = true
        };

        sidebar = new Sidebar () {
            visible = settings.get_boolean ("sidebar-visible")
        };
        sidebar.view_requested.connect (on_view_requested);
        sidebar.channel_requested.connect (open_channel);

        sidebar_box.append (sidebar);

        content_box.append (stack);

        paned = new Gtk.Paned (Gtk.Orientation.HORIZONTAL) {
            start_child = sidebar_box,
            end_child = content_box,
            resize_start_child = false,
            shrink_start_child = false,
            shrink_end_child = false
        };

        // Neither pane may be crushed below what it needs: that is how the
        // sidebar ended up as an unreadable sliver in a narrow window.
        paned.map.connect (() => {
            if (position_restored) {
                return;
            }

            position_restored = true;

            int minimum = 0;
            int natural = 0;
            sidebar_box.measure (Gtk.Orientation.HORIZONTAL, -1,
                out minimum, out natural, null, null);

            paned.position = int.max (settings.get_int ("sidebar-width"), minimum);
        });

        child = paned;

        settings.bind ("sidebar-visible", sidebar, "visible", SettingsBindFlags.DEFAULT);
    }

    /**
     * Fullscreen is the picture's: the sidebar and the headings are taken away
     * so that the content pane has the whole window, and put back afterwards.
     */
    private void apply_fullscreen () {
        if (fullscreened) {
            sidebar_position_held = paned.position;
            sidebar_box.visible = false;
            content_box.remove_css_class (Granite.STYLE_CLASS_VIEW);
            content_header.visible = false;
            return;
        }

        sidebar_box.visible = settings.get_boolean ("sidebar-visible");
        content_box.add_css_class (Granite.STYLE_CLASS_VIEW);
        content_header.visible = true;

        // The divider is remembered by the paned, but a hidden start child
        // takes its position down with it, so it is put back once the sidebar
        // has been laid out again.
        var restore = sidebar_position_held;
        sidebar_position_held = 0;

        if (restore > 0) {
            Timeout.add (100, () => {
                paned.position = restore;
                return false;
            });
        }
    }

    private void build_views () {
        discover_view = new DiscoverView ();
        discover_view.search_requested.connect (search_for);
        discover_view.search_entry_requested.connect (focus_search_entry);
        discover_view.video_activated.connect (open_video);
        discover_view.channel_activated.connect (open_channel);

        search_view = new SearchView ();
        connect_browse_view (search_view);

        channels_view = new ChannelsView ();
        connect_browse_view (channels_view);

        history_view = new HistoryView ();
        connect_browse_view (history_view);

        watch_later_view = new WatchLaterView ();
        connect_browse_view (watch_later_view);

        account_view = new AccountView ();
        account_view.video_activated.connect (open_video);
        account_view.channel_activated.connect (open_channel);
        account_view.signed_out.connect (() => {
            settings.set_string ("last-view", Config.VIEW_DISCOVER);
            open_discover ();
        });
    }

    private void connect_browse_view (BrowseView view) {
        view.video_activated.connect (open_video);
        view.channel_activated.connect (open_channel);
        view.playlist_activated.connect (open_playlist);
    }

    private void register_actions () {
        var go_back = new SimpleAction ("go-back", null);
        go_back.activate.connect (() => go_back_page ());
        add_action (go_back);

        var go_forward = new SimpleAction ("go-forward", null);
        go_forward.activate.connect (() => go_forward_page ());
        add_action (go_forward);

        var go_home = new SimpleAction ("go-home", null);
        go_home.activate.connect (() => open_discover ());
        add_action (go_home);

        var search = new SimpleAction ("search", null);
        search.activate.connect (() => focus_search_entry ());
        add_action (search);

        var refresh = new SimpleAction ("refresh", null);
        refresh.activate.connect (() => reload_current ());
        add_action (refresh);

        var toggle_sidebar = new SimpleAction ("toggle-sidebar", null);
        toggle_sidebar.activate.connect (() => sidebar.visible = !sidebar.visible);
        add_action (toggle_sidebar);

        var fullscreen_action = new SimpleAction ("fullscreen", null);
        fullscreen_action.activate.connect (() => {
            if (fullscreened) {
                this.unfullscreen ();
            } else {
                this.fullscreen ();
            }
        });
        add_action (fullscreen_action);

        var preferences = new SimpleAction ("preferences", null);
        preferences.activate.connect (() => open_preferences ());
        add_action (preferences);

        var clear_history = new SimpleAction ("clear-history", null);
        clear_history.activate.connect (() => confirm_clear_history ());
        add_action (clear_history);

    }

    /**
     * The window is not yet attached to its application while it is being
     * constructed, so the accelerators for its actions are registered the first
     * time it is shown.
     */
    private void register_accels () {
        if (accels_registered) {
            return;
        }

        var app = application;
        if (app == null) {
            return;
        }

        accels_registered = true;

        app.set_accels_for_action ("win.go-back", { "<Alt>Left" });
        app.set_accels_for_action ("win.go-forward", { "<Alt>Right" });
        app.set_accels_for_action ("win.go-home", { "<Alt>Home" });
        app.set_accels_for_action ("win.search", { "<Control>f" });
        app.set_accels_for_action ("win.refresh", { "<Control>r", "F5" });
        app.set_accels_for_action ("win.toggle-sidebar", { "F9" });
        app.set_accels_for_action ("win.fullscreen", { "F11" });
        app.set_accels_for_action ("win.preferences", { "<Control>comma" });
    }

    private async void warm_up () {
        // The shared session is warmed up along with the config, so later
        // requests reuse its connections instead of opening their own.
        yield SiteConfig.ensure (HttpSession.get_shared ());
    }

    private void restore_last_view () {
        var last = settings.get_string ("last-view");

        if (last == Config.VIEW_ACCOUNT) {
            open_account ();
        } else if (last == Config.VIEW_CHANNELS) {
            open_channels ();
        } else if (last == Config.VIEW_HISTORY) {
            open_history ();
        } else if (last == Config.VIEW_WATCH_LATER) {
            open_watch_later ();
        } else {
            open_discover ();
        }
    }

    // ------------------------------------------------------------------
    // Navigation
    // ------------------------------------------------------------------

    private void open_discover () {
        navigate (Config.VIEW_DISCOVER, discover_view, _("Discover"));
    }

    private void open_channels () {
        navigate (Config.VIEW_CHANNELS, channels_view, _("Followed Channels"));
        channels_view.refresh ();
    }

    private void open_history () {
        navigate (Config.VIEW_HISTORY, history_view, _("History"));
        history_view.refresh ();
    }

    private void open_watch_later () {
        navigate (Config.VIEW_WATCH_LATER, watch_later_view, _("Watch Later"));
        watch_later_view.refresh ();
    }

    /** Opens the account page. */
    public void open_account () {
        navigate (Config.VIEW_ACCOUNT, account_view, _("Account"));
        account_view.refresh ();
    }

    private void on_view_requested (string name) {
        if (name == Config.VIEW_DISCOVER) {
            open_discover ();
        } else if (name == Config.VIEW_CHANNELS) {
            open_channels ();
        } else if (name == Config.VIEW_HISTORY) {
            open_history ();
        } else if (name == Config.VIEW_WATCH_LATER) {
            open_watch_later ();
        } else if (name == Config.VIEW_ACCOUNT) {
            open_account ();
        }
    }

    public void open_video (Video video) {
        present_watch (new WatchView.from_video (video), video.title);
    }

    /** Opens a video that the app was handed as a link. */
    public void open_video_id (string video_id) {
        if (video_id == "") {
            return;
        }

        present_watch (new WatchView (video_id), _("Video"));
    }

    /** Wires a watch page into the window and shows it. */
    private void present_watch (WatchView view, string view_title) {
        var key = "watch:%d".printf (sequence++);
        watch_playback (view);
        stop_other_playback (view);

        view.video_activated.connect (open_video);
        view.channel_activated.connect (open_channel);
        view.sign_in_requested.connect (() => open_account ());
        view.title_changed.connect ((video_title) => {
            if (current_key () == key) {
                titles[position] = video_title;
                title = video_title;
                title_label.label = video_title;
            }
        });

        navigate (key, view, view_title);
    }

    /** Keeps the window told about what this page is doing. */
    private void watch_playback (WatchView view) {
        view.playback_changed.connect (() => update_now_playing ());
    }

    /**
     * Starting a video stops every other one: two of them playing over each
     * other is never what was meant by opening the second.
     */
    private void stop_other_playback (Gtk.Widget opened) {
        foreach (var view in views) {
            if (view == opened || !(view is WatchView)) {
                continue;
            }

            ((WatchView) view).pause_playback ();
        }
    }

    /** The page a video is playing on, if the user is not looking at it. */
    private int playing_page () {
        for (var i = 0; i < views.size; i++) {
            if (!(views[i] is WatchView)) {
                continue;
            }

            var watch = (WatchView) views[i];
            if (!watch.is_playing) {
                continue;
            }

            // A video on the page in front of the user is not somewhere to be
            // taken back to. One in the miniplayer is, even if its page is up.
            if (i == position && !watch.is_miniaturized) {
                return -1;
            }

            return i;
        }

        return -1;
    }

    private void update_now_playing () {
        var index = playing_page ();

        now_playing_button.visible = index >= 0;

        if (index >= 0) {
            now_playing_button.tooltip_text = titles[index];
        }
    }

    /** Brings the picture back to its page and goes there. */
    private void return_to_playing () {
        var index = playing_page ();
        if (index < 0) {
            update_now_playing ();
            return;
        }

        var view = views[index];

        if (view is WatchView && ((WatchView) view).is_miniaturized) {
            ((WatchView) view).close_miniplayer ();
        }

        navigate (keys[index], view, titles[index]);
    }

    public void open_channel (Channel channel) {
        if (channel.id == "") {
            return;
        }

        var view = new ChannelView ();
        connect_browse_view (view);
        navigate ("channel:%d".printf (sequence++), view, channel.name);
        view.show_channel (channel.id, channel);
    }

    public void open_playlist (Playlist playlist) {
        if (playlist.id == "") {
            return;
        }

        var view = new PlaylistView ();
        connect_browse_view (view);
        navigate ("playlist:%d".printf (sequence++), view, playlist.title);
        view.show_playlist (playlist);
    }

    private void navigate (string key, Gtk.Widget view, string view_title) {
        var existing = keys.index_of (key);

        if (existing < 0) {
            while (keys.size > position + 1) {
                drop_entry (keys.size - 1);
            }

            keys.add (key);
            views.add (view);
            titles.add (view_title);
            stack.add_named (view, key);
            position = keys.size - 1;
        } else {
            // The page is already open. Rather than throwing away everything
            // after it — which would take a video the user is still listening
            // to with it — it is moved to the end, so the way back to whatever
            // it was opened over is kept.
            var moved_key = keys[existing];
            var moved_view = views[existing];
            var moved_title = titles[existing];

            keys.remove_at (existing);
            views.remove_at (existing);
            titles.remove_at (existing);
            stack.remove (moved_view);

            keys.add (moved_key);
            views.add (moved_view);
            titles.add (view_title);
            stack.add_named (moved_view, moved_key);
            position = keys.size - 1;
        }

        while (keys.size > Config.MAX_BACK_STACK && position > 0) {
            drop_entry (0);
            position--;
        }

        present_current ();
        update_now_playing ();
    }

    private void drop_entry (int index) {
        var view = views[index];

        // A trimmed page must not keep playing where nobody can see it.
        if (view is WatchView) {
            ((WatchView) view).stop_playback ();
        }
        keys.remove_at (index);
        views.remove_at (index);
        titles.remove_at (index);
        stack.remove (view);
    }

    private void present_current () {
        if (position < 0) {
            return;
        }

        var key = keys[position];
        stack.visible_child_name = key;

        // The heading in the content header, and the window's own title for
        // the window switcher and the dock.
        title_label.label = titles[position];
        title = titles[position];

        back_button.sensitive = position > 0;
        forward_button.sensitive = position < keys.size - 1;

        sidebar.select_view (key);
    }

    private string current_key () {
        if (position < 0 || position >= keys.size) {
            return "";
        }

        return keys[position];
    }

    private Gtk.Widget? current_view () {
        if (position < 0 || position >= views.size) {
            return null;
        }

        return views[position];
    }

    private void go_back_page () {
        if (position <= 0) {
            return;
        }

        position--;
        present_current ();
    }

    private void go_forward_page () {
        if (position >= keys.size - 1) {
            return;
        }

        position++;
        present_current ();
    }

    // ------------------------------------------------------------------
    // Search
    // ------------------------------------------------------------------

    private void focus_search_entry () {
        search_entry.grab_focus ();
    }

    private void on_search_changed () {
        var query = search_entry.text.strip ();

        // One letter matches almost everything, so wait for something to go on.
        if (query.length < 2) {
            return;
        }

        search_for (query);
    }

    private void on_search_submitted () {
        var query = search_entry.text.strip ();
        if (query == "") {
            return;
        }

        search_for (query);
    }

    /** Runs a search and shows the results. */
    public void search_for (string query) {
        if (query.strip () == "") {
            focus_search_entry ();
            return;
        }

        navigate (Config.VIEW_SEARCH, search_view, _("Search"));
        search_view.search (query);
    }

    // ------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------

    private void reload_current () {
        var view = current_view ();

        if (view is BrowseView) {
            ((BrowseView) view).refresh ();
        } else if (view is WatchView) {
            ((WatchView) view).reload ();
        } else if (view is DiscoverView) {
            ((DiscoverView) view).rebuild ();
        } else if (view is AccountView) {
            ((AccountView) view).refresh ();
        }
    }

    private void open_preferences () {
        var preferences = new PreferencesWindow (this);
        preferences.present ();
    }

    private void confirm_clear_history () {
        if (library.history.size == 0) {
            return;
        }

        var dialog = new Granite.MessageDialog.with_image_from_icon_name (
            _("Clear all watch history?"),
            _("Every video will be removed from the history list. This cannot be undone."),
            "edit-clear-symbolic",
            Gtk.ButtonsType.CANCEL
        );

        var clear_button = dialog.add_button (_("Clear History"), RESPONSE_CLEAR_HISTORY);
        clear_button.add_css_class (Granite.CssClass.DESTRUCTIVE);

        dialog.transient_for = this;
        dialog.modal = true;

        dialog.response.connect ((response_id) => {
            if (response_id == RESPONSE_CLEAR_HISTORY) {
                library.clear_history ();
            }

            dialog.destroy ();
        });

        dialog.present ();
    }

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    private void save_state () {
        settings.set_boolean ("window-maximized", maximized);

        if (!maximized) {
            settings.set_int ("window-width", get_width ());
            settings.set_int ("window-height", get_height ());
        }

        if (sidebar.visible) {
            settings.set_int ("sidebar-width", paned.position);
        }

        var key = current_key ();
        if (key == Config.VIEW_DISCOVER
            || key == Config.VIEW_CHANNELS
            || key == Config.VIEW_HISTORY
            || key == Config.VIEW_WATCH_LATER
            || key == Config.VIEW_ACCOUNT) {
            settings.set_string ("last-view", key);
        }
    }
}
