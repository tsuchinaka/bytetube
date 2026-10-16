/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * A single video, playing, with everything about it and what to watch next.
 *
 * The picture comes from a media pipeline of our own, fed either the stream
 * urls the service hands out or the bytes negotiated for them. Nothing here
 * renders web content: the page only ever shows what the pipeline decoded.
 */

public class ByteTube.WatchView : Gtk.Box {
    public string video_id { get; construct; }
    public Video? known { get; construct; default = null; }

    public signal void video_activated (ByteTube.Video video);
    public signal void channel_activated (ByteTube.Channel channel);
    public signal void sign_in_requested ();

    /** Emitted once the real title of the video is known. */
    public signal void title_changed (string title);

    /** Emitted whenever this page starts or stops playing, or moves the
     *  picture to the miniplayer and back. */
    public signal void playback_changed ();

    /** Whether this page is playing something right now. */
    public bool is_playing {
        get {
            return player.is_playing;
        }
    }

    /** Whether the picture is in its own small window rather than on the page. */
    public bool is_miniaturized {
        get {
            return miniaturized;
        }
    }

    private const int RESPONSE_SIGN_IN = 1;

    private unowned Library library;
    private GLib.Settings settings;
    private InnertubeClient client;
    private SabrClient sabr;
    private VideoPlayer player;
    private NoticeBar notice;

    private PlaybackInfo? playback = null;
    private MediaFormat? video_format = null;
    private MediaFormat? audio_format = null;

    // When the service hands out URLs, a stream can still be refused. The
    // alternatives are kept so the next one can be tried instead.
    private Gee.ArrayList<MediaFormat> video_options = new Gee.ArrayList<MediaFormat> ();
    private Gee.ArrayList<MediaFormat> audio_options = new Gee.ArrayList<MediaFormat> ();
    private int video_index = 0;
    private int audio_index = 0;
    private bool using_uris = false;

    /** How often expired stream urls have been refreshed for this video. */
    private int url_refreshes = 0;

    /** Where to carry on from once a newly chosen stream shows pictures. */
    private int64 pending_seek = -1;

    /** Whether the video was playing when its stream was changed. */
    private bool resume_playing = true;

    /** Which option each quality menu row stands for, by menu position. */
    private Gee.ArrayList<int> quality_options = new Gee.ArrayList<int> ();

    private Video? current = null;
    private Channel? channel = null;

    private Gtk.Box player_box;
    private Gtk.Box main_box;
    private Gtk.Widget details;
    private Gtk.Box related_box;
    private Gtk.Box row;
    private Gtk.ScrolledWindow main_scroller;
    private Gtk.ScrolledWindow related_scroller;
    private Gtk.ListBox related_list;
    private Gtk.ListBox comments_list;
    private Gtk.Box comments_section;
    private StatusView related_status;
    private Gtk.Stack related_stack;

    private Gtk.Label title_label;
    private Gtk.Label byline_label;
    private Gtk.Label description_label;
    private Gtk.Button description_toggle;
    private Gtk.ToggleButton save_button;
    private Gtk.Image save_icon;

    /** True while the player lives in the miniplayer instead of this page. */
    private bool miniaturized = false;

    /** True while the window is fullscreen and the page shows only the picture. */
    private bool fullscreen = false;

    /**
     * Held directly rather than looked up when needed: the window forgets
     * itself as soon as it closes, so asking for "the" miniplayer at that
     * point would hand back a new, empty one.
     */
    private MiniplayerWindow? mini_window = null;
    private Thumbnail channel_avatar;
    private Gtk.Button channel_button;
    private Gtk.ToggleButton follow_button;

    private bool stacked = false;

    /**
     * The width the pane was last apportioned at. The split is re-applied
     * while the window is still growing into its size; once it has settled,
     * the handle belongs to the user. Dragging the handle never changes the
     * window's width, so a stored split is never overwritten by this.
     */
    private bool description_expanded = false;
    private bool updating = false;
    private int last_width = 0;

    public WatchView (string video_id) {
        Object (video_id: video_id);
    }

    public WatchView.from_video (Video video) {
        Object (
            video_id: video.id,
            known: video
        );
    }

    construct {
        library = Library.get_default ();
        settings = new GLib.Settings (Config.APP_ID);
        client = new InnertubeClient ();
        sabr = new SabrClient ();

        sabr.video_data.connect ((data) => player.push_video (data));
        sabr.audio_data.connect ((data) => player.push_audio (data));
        sabr.failed.connect ((message) => show_notice (message, false));
        sabr.can_request_more = () => player.can_accept_more ();

        if (known != null) {
            current = known;
            channel = channel_from (known);
            library.record_watch (known);
        }

        orientation = Gtk.Orientation.VERTICAL;
        hexpand = true;
        vexpand = true;

        build_player ();
        build_details ();
        build_related ();

        main_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 18) {
            margin_top = 12,
            margin_bottom = 24,
            margin_start = 12,
            margin_end = 12
        };
        details = details_content ();

        main_box.append (notice);
        main_box.append (player_box);
        main_box.append (details);

        main_scroller = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            hexpand = true,
            vexpand = true,
            child = main_box
        };

        // The column's width is capped, not just requested: a request is only
        // a minimum, and the rows' natural width otherwise decides the split
        // and starves the player.
        related_scroller = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            hexpand = false,
            vexpand = true,
            max_content_width = Config.RELATED_WIDTH,
            child = related_box
        };

        // The suggested videos beside the player are a fixed sidebar: one
        // width in every window, with no divider to drag.
        related_scroller.width_request = Config.RELATED_WIDTH;

        row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
            hexpand = true,
            vexpand = true
        };
        row.append (main_scroller);
        row.append (related_scroller);

        append (row);

        // There is no reliable "the window was resized" signal to hook, so the
        // layout is re-checked from the player's progress tick: it runs several
        // times a second while the page is open, which is plenty for a split
        // and a height to converge after any change.
        player.position_changed.connect (() => update_columns ());

        apply_current ();
        load ();
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    private void build_player () {
        player = new VideoPlayer () {
            hexpand = true,
            vexpand = true
        };

        player.failed.connect ((message) => on_player_failed (message));
        player.quality_selected.connect (on_quality_selected);
        player.first_frame.connect (on_first_frame);
        player.playing_changed.connect (() => playback_changed ());
        player.fullscreen_changed.connect ((now_fullscreen) => set_fullscreen (now_fullscreen));

        notice = new NoticeBar () {
            visible = true
        };
        notice.action.connect ((response) => on_notice_response (response));

        player_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            overflow = Gtk.Overflow.HIDDEN,
            height_request = 400
        };
        player_box.add_css_class ("bytetube-player");
        player_box.append (player);
    }

    private void build_details () {
        title_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            halign = Gtk.Align.FILL,
            selectable = true
        };
        // The standard GTK heading class, so the page title reads as a title
        // without inventing a style for it.
        title_label.add_css_class ("heading");

        byline_label = new Gtk.Label ("") {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            halign = Gtk.Align.FILL
        };
        byline_label.add_css_class (Granite.CssClass.DIM);
        byline_label.add_css_class (Granite.CssClass.SMALL);

        channel_avatar = new Thumbnail.avatar ("", 40);

        channel_button = new Gtk.Button.with_label ("") {
            halign = Gtk.Align.START
        };
        channel_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        channel_button.clicked.connect (() => open_channel ());

        follow_button = new Gtk.ToggleButton.with_label (_("Follow")) {
            halign = Gtk.Align.START,
            margin_start = 6
        };
        follow_button.toggled.connect (() => on_follow_toggled ());

        save_icon = new Gtk.Image.from_icon_name ("non-starred-symbolic");

        var save_content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        save_content.append (save_icon);
        save_content.append (new Gtk.Label (_("Watch Later")));

        save_button = new Gtk.ToggleButton () {
            child = save_content
        };
        save_button.toggled.connect (() => on_save_toggled ());

        description_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            lines = 3,
            ellipsize = Pango.EllipsizeMode.END,
            halign = Gtk.Align.FILL,
            selectable = true
        };

        description_toggle = new Gtk.Button.with_label (_("Show More")) {
            halign = Gtk.Align.START,
            visible = false
        };
        description_toggle.add_css_class (Granite.STYLE_CLASS_FLAT);
        description_toggle.clicked.connect (() => toggle_description ());
    }

    private Gtk.Widget details_content () {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);

        box.append (title_label);
        box.append (byline_label);

        var owner = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        owner.append (channel_avatar);
        owner.append (channel_button);
        owner.append (follow_button);
        box.append (owner);

        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

        var copy_button = new Gtk.Button () {
            child = new Gtk.Image.from_icon_name ("edit-copy-symbolic"),
            tooltip_text = _("Copy a link to this video")
        };
        copy_button.clicked.connect (() => copy_link ());

        var browser_button = new Gtk.Button () {
            child = new Gtk.Image.from_icon_name ("adw-external-link-symbolic"),
            tooltip_text = _("Play this video in your browser")
        };
        browser_button.clicked.connect (() => open_in_browser ());

        var mini_button = new Gtk.Button () {
            child = new Gtk.Image.from_icon_name ("window-new-symbolic"),
            tooltip_text = _("Watch in a small window")
        };
        mini_button.clicked.connect (() => open_miniplayer ());

        actions.append (save_button);
        actions.append (copy_button);
        actions.append (browser_button);
        actions.append (mini_button);
        box.append (actions);

        box.append (description_label);
        box.append (description_toggle);
        return box;
    }

    private void build_related () {
        related_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE,
            activate_on_single_click = true
        };
        related_list.row_activated.connect ((list_row) => {
            if (list_row is VideoRow) {
                video_activated (((VideoRow) list_row).video);
            }
        });

        related_status = new StatusView ();
        related_status.action_requested.connect (() => load ());

        related_stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.CROSSFADE,
            hexpand = false,
            vexpand = true,
            hhomogeneous = false
        };
        related_stack.add_named (related_list, "list");
        related_stack.add_named (related_status, "status");
        related_stack.visible_child_name = "status";

        related_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            hexpand = false,
            margin_top = 12,
            margin_bottom = 24,
            margin_end = 12
        };
        related_box.append (new Granite.HeaderLabel (_("Up Next")) {
            size = Granite.HeaderLabel.Size.H3,
            halign = Gtk.Align.START
        });
        related_box.append (related_stack);

        comments_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE
        };

        comments_section = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            visible = false
        };
        comments_section.append (new Granite.HeaderLabel (_("Comments")) {
            size = Granite.HeaderLabel.Size.H3,
            halign = Gtk.Align.START
        });
        comments_section.append (comments_list);
        related_box.append (comments_section);
    }

    // ------------------------------------------------------------------
    // Loading
    // ------------------------------------------------------------------

    /** Starts the video over: used by Reload Results. */
    public void reload () {
        load ();
    }

    /** Stops everything. Used when the page goes away for good. */
    public void stop_playback () {
        close_miniplayer ();
        sabr.stop ();
        player.stop ();
        pending_seek = -1;
    }

    /**
     * Stops the picture but keeps the video: the page can be returned to and
     * played on, without running over the top of whatever is opened next.
     */
    public void pause_playback () {
        if (miniaturized) {
            // Bring the picture back to its page first, or it would carry on
            // in its own window while another video plays.
            close_miniplayer ();
        }

        player.set_playing (false);
    }

    /**
     * Fullscreen leaves the picture alone on the page. Everything around it
     * steps aside, and the box holding the picture stops being shaped like a
     * 16:9 thumbnail of the window so that it can fill it.
     */
    private void set_fullscreen (bool full) {
        if (fullscreen == full) {
            return;
        }

        fullscreen = full;

        details.visible = !full;
        related_scroller.visible = !full;
        related_box.visible = !full;

        player_box.vexpand = full;
        main_box.vexpand = full;
        main_box.spacing = full ? 0 : 18;

        // The box around the picture is black with rounded corners on the
        // page; on the screen the corners go square so no window background
        // shows through at them.
        if (full) {
            player_box.add_css_class ("fullscreen");
        } else {
            player_box.remove_css_class ("fullscreen");
        }

        // The picture is the page now: no 16:9 box shaping it, and no margins
        // framing it. Leaving puts both back, and the next layout pass works
        // out the 16:9 height again from scratch.
        player_box.height_request = -1;

        main_box.margin_top = full ? 0 : 12;
        main_box.margin_bottom = full ? 0 : 24;
        main_box.margin_start = full ? 0 : 12;
        main_box.margin_end = full ? 0 : 12;

        update_columns ();
    }

    /**
     * Moves the player into a small window so the video keeps playing while
     * other pages are browsed. Opening another miniplayer closes this one.
     */
    public void open_miniplayer () {
        if (miniaturized || current == null) {
            return;
        }

        MiniplayerWindow.close_any ();

        player_box.remove (player);
        player_box.visible = false;

        mini_window = MiniplayerWindow.get ();
        mini_window.title = current.title;
        mini_window.holder.append (player);
        mini_window.close_request.connect (on_mini_closed);
        mini_window.present ();

        miniaturized = true;
        playback_changed ();
        Debug.log ("player: moved to miniplayer");
    }

    /** Brings the player back to the page. Does nothing when it is here. */
    public void close_miniplayer () {
        if (!miniaturized) {
            return;
        }

        // The close handler below does the actual work, whether this or the
        // window's own close button asked for it.
        if (mini_window != null) {
            mini_window.close ();
        }
    }

    private bool on_mini_closed () {
        if (!miniaturized || mini_window == null) {
            return false;
        }

        mini_window.holder.remove (player);

        player_box.append (player);
        player_box.visible = true;

        miniaturized = false;
        mini_window = null;
        playback_changed ();
        Debug.log ("player: restored to the page");
        return false;
    }

    /** Shows something the user has to know about the video, and what to do. */
    private void show_notice (string message, bool needs_sign_in) {
        if (needs_sign_in) {
            notice.set_message (
                Gtk.MessageType.WARNING, message,
                _("Sign In"), RESPONSE_SIGN_IN);
        } else {
            notice.set_message (Gtk.MessageType.ERROR, message);
        }
    }

    /**
     * A stream that will not play is not the end of the video: the next best
     * one is tried, and only when every combination has failed is the user told
     * that this video cannot be played.
     */
    private void on_player_failed (string message) {
        Debug.log ("playback failed: %s".printf (message));

        if (!using_uris || playback == null) {
            show_notice (message, false);
            return;
        }

        // Media urls expire after a few hours. A refusal to serve one usually
        // means the urls went stale while the page was open — long videos are
        // where this bites — so they are resolved again before falling back
        // to other formats.
        if (url_refreshes < 2
            && (message.contains ("403") || message.down ().contains ("forbidden"))) {
            url_refreshes++;
            Debug.log ("refreshing expired urls (attempt %d)".printf (url_refreshes));
            refresh_urls.begin ();
            return;
        }

        video_index++;
        if (video_index >= video_options.size) {
            video_index = 0;
            audio_index++;
        }

        if (audio_index >= audio_options.size) {
            using_uris = false;
            pending_seek = -1;
            show_notice (_("This video cannot be played here."), false);
            return;
        }

        start_format ();
    }

    /** Resolves fresh urls, keeping the current choice of streams. */
    private async void refresh_urls () {
        var reloaded = new SabrClient ();

        try {
            var info = yield reloaded.load (video_id);
            if (!info.is_playable) {
                on_player_failed (_("This video cannot be played here."));
                return;
            }

            playback = info;
            video_options = info.video_candidates ();
            audio_options = info.audio_candidates ();

            video_index = index_of_itag (video_options, video_format);
            audio_index = index_of_itag (audio_options, audio_format);
            Debug.log ("urls refreshed, %d video and %d audio options".printf (
                video_options.size, audio_options.size));
            start_format ();
        } catch (Error e) {
            on_player_failed (e.message);
        }
    }

    /**
     * Lists the offered video qualities in the transport menu, one row per
     * height with the best stream of that height behind it. Several streams
     * can share a height, so the menu positions are translated back to options.
     */
    private void update_quality_menu () {
        var labels = new string[] {};
        quality_options.clear ();

        var seen = new Gee.HashSet<int> ();
        foreach (var option in video_options) {
            if (!seen.add (option.height)) {
                continue;
            }

            /// TRANSLATORS: A video quality, e.g. "720p"
            labels += _("%dp").printf (option.height);
            quality_options.add (video_options.index_of (option));
        }

        var current_menu = 0;
        for (var m = 0; m < quality_options.size; m++) {
            if (quality_options[m] == video_index) {
                current_menu = m;
                break;
            }
        }

        player.set_quality_options (labels, current_menu);
    }

    /**
     * Changes to the chosen quality, carrying on from the same moment. The
     * sound keeps its stream; only the picture is fetched again, and the new
     * stream is sought to where the old one was once it shows pictures.
     */
    private void on_quality_selected (int menu_index) {
        if (!using_uris || playback == null
            || menu_index < 0 || menu_index >= quality_options.size) {
            return;
        }

        var index = quality_options[menu_index];
        if (index == video_index) {
            return;
        }

        pending_seek = player.playback_position;
        resume_playing = player.is_playing;
        video_index = index;
        start_format ();
        player.set_playing (resume_playing);

        Debug.log ("quality changed to %dp".printf (video_options[video_index].height));
    }

    /** The new stream shows pictures: carry on from where the old one was. */
    private void on_first_frame () {
        if (pending_seek < 0) {
            return;
        }

        player.seek (pending_seek);
        pending_seek = -1;
    }

    private static int index_of_itag (Gee.ArrayList<MediaFormat> options, MediaFormat? current) {
        if (current == null) {
            return 0;
        }

        for (int i = 0; i < options.size; i++) {
            if (options[i].itag == current.itag) {
                return i;
            }
        }

        return 0;
    }

    /** Starts the currently selected pair of streams. */
    private void start_format () {
        if (playback == null
            || video_index >= video_options.size
            || audio_index >= audio_options.size) {
            return;
        }

        update_quality_menu ();

        video_format = video_options[video_index];
        audio_format = audio_options[audio_index];
        Debug.log ("starting video itag %d + audio itag %d".printf (
            video_format.itag, audio_format.itag));

        player.set_duration (playback.duration_ms);

        if (player.play_uris (
                video_format.url, audio_format.url,
                video_format.size_bytes, audio_format.size_bytes)
            && !settings.get_boolean ("autoplay")) {
            player.set_playing (false);
        }
    }

    private void on_notice_response (int response) {
        if (response != RESPONSE_SIGN_IN) {
            return;
        }

        notice.revealed = false;
        sign_in_requested ();
    }

    private void load () {
        if (video_id == "") {
            return;
        }

        close_miniplayer ();
        notice.revealed = false;
        pending_seek = -1;
        player.set_quality_options (new string[0], 0);
        start_playback.begin ();

        related_status.show_loading ();
        related_stack.visible_child_name = "status";
        clear_related ();

        comments_section.visible = false;
        clear_comments ();

        client.comments.begin (video_id, (comment_obj, comment_res) => {
            try {
                show_comments (client.comments.end (comment_res));
            } catch (Error e) {
                debug ("Could not load comments: %s", e.message);
            }
        });

        client.watch.begin (video_id, (obj, res) => {
            try {
                apply (client.watch.end (res));
            } catch (Error e) {
                related_status.show_message (
                    _("Could Not Load Suggestions"),
                    e.message,
                    "network-error-symbolic",
                    _("Try Again"),
                    "view-refresh-symbolic"
                );
                related_stack.visible_child_name = "status";
            }
        });
    }

    /**
     * Asks what the service will hand over, then starts the pipeline with one
     * video stream and one audio stream.
     */
    private async void start_playback () {
        player.stop ();

        try {
            var info = yield sabr.load (video_id);

            if (!info.is_playable) {
                // The service refuses every signed-out client, so while there
                // is no sign-in the way forward is to sign in, whatever the
                // service says the reason is.
                if (info.needs_sign_in || !TokenStore.get_default ().signed_in) {
                    show_notice (_("Sign in to watch videos"), true);
                    return;
                }

                show_notice (
                    info.playability_reason != ""
                        ? info.playability_reason
                        : _("This video cannot be played here."),
                    false
                );

                return;
            }

            var video = info.choose_video ();
            var audio = info.choose_audio ();

            if (video == null || audio == null) {
                show_notice (_("This video is not offered in a format this player can use."), false);
                return;
            }

            playback = info;
            video_format = video;
            audio_format = audio;

            player.set_duration (info.duration_ms);

            if (video.has_url && audio.has_url) {
                // Plain URLs: hand them straight to GStreamer, which buffers,
                // synchronises and seeks for us.
                video_options = info.video_candidates ();
                audio_options = info.audio_candidates ();
                video_index = 0;
                audio_index = 0;
                url_refreshes = 0;
                using_uris = true;
                start_format ();
                return;
            }

            using_uris = false;
            player.set_quality_options (new string[0], 0);

            if (!player.start ()) {
                return;
            }

            sabr.start (info, video, audio);

            if (!settings.get_boolean ("autoplay")) {
                player.set_playing (false);
            }
        } catch (Error e) {
            show_notice (e.message, false);
        }
    }

    private void apply (BrowseResult result) {
        if (result.primary != null) {
            current = merge (current, result.primary);
            channel = channel_from (current);
            library.record_watch (current);
            apply_current ();
        }

        clear_related ();

        var added = 0;
        foreach (var shelf in result.shelves) {
            foreach (var item in shelf.items) {
                if (item is Video) {
                    related_list.append (new VideoRow ((Video) item));
                    added++;
                }
            }
        }

        if (added == 0) {
            related_status.show_message (
                _("Nothing to Suggest"),
                _("The service did not suggest anything to watch next."),
                "view-list-video-symbolic"
            );
            related_stack.visible_child_name = "status";
            return;
        }

        related_stack.visible_child_name = "list";
    }

    private void show_comments (Gee.ArrayList<Comment> comments) {
        clear_comments ();

        foreach (var comment in comments) {
            comments_list.append (new CommentRow (comment));
        }

        comments_section.visible = comments.size > 0;
    }

    private void clear_comments () {
        var child = comments_list.get_first_child ();
        while (child != null) {
            comments_list.remove (child);
            child = comments_list.get_first_child ();
        }
    }

    private void clear_related () {
        var child = related_list.get_first_child ();
        while (child != null) {
            related_list.remove (child);
            child = related_list.get_first_child ();
        }
    }

    // ------------------------------------------------------------------
    // Presentation
    // ------------------------------------------------------------------

    private void apply_current () {
        if (current == null) {
            title_label.label = _("Loading…");
            byline_label.visible = false;
            return;
        }

        title_label.label = current.title;

        var parts = new Gee.ArrayList<string> ();
        if (current.view_count != "") {
            parts.add (current.view_count);
        }

        if (current.published != "") {
            parts.add (current.published);
        }

        byline_label.label = string.joinv (" • ", parts.to_array ());
        byline_label.visible = byline_label.label != "";

        description_label.label = current.summary;
        description_label.visible = current.summary != "";
        description_toggle.visible = current.summary.length > 240;

        channel_button.label = current.channel_name;
        channel_button.visible = current.channel_name != "";
        channel_avatar.load_uri (current.channel_avatar);
        channel_avatar.visible = current.channel_avatar != "";

        updating = true;
        follow_button.active = channel != null && library.is_following (channel.id);
        save_button.active = library.is_saved (current.id);
        updating = false;

        follow_button.visible = channel != null && channel.id != "";
        update_follow_label ();
        update_save_icon ();
        tooltip_text = current.title;

        if (current.title != "") {
            title_changed (current.title);

            if (miniaturized && mini_window != null) {
                mini_window.title = current.title;
            }
        }
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

    private void update_save_icon () {
        save_icon.icon_name = save_button.active ? "starred-symbolic" : "non-starred-symbolic";
        save_button.tooltip_text = save_button.active
            ? _("Remove this video from Watch Later")
            : _("Keep this video for later");
    }

    private void toggle_description () {
        description_expanded = !description_expanded;
        description_label.lines = description_expanded ? -1 : 3;
        description_label.ellipsize = description_expanded
            ? Pango.EllipsizeMode.NONE
            : Pango.EllipsizeMode.END;
        description_toggle.label = description_expanded ? _("Show Less") : _("Show More");
    }

    // ------------------------------------------------------------------
    // Layout
    // ------------------------------------------------------------------

    private void update_player_height () {
        // In fullscreen the picture is the page, so the height it should fill
        // comes from the window rather than from a 16:9 box inside it.
        if (fullscreen) {
            return;
        }

        // The box takes the shape of the video in it rather than a fixed 16:9,
        // and is measured from what it was actually given: a 4:3 video gets a
        // 4:3 player with no bars, a 16:9 video a 16:9 one. Tall videos are
        // still capped so they cannot push everything else off the page. The
        // transport floats over the picture, so it needs no room of its own.
        var available = player_box.get_width ();
        if (available <= 0) {
            return;
        }

        var aspect = player.video_aspect;
        if (aspect <= 0) {
            // Nothing decoded yet: assume 16:9 so the box has a sensible
            // shape while the video starts.
            aspect = 16.0 / 9.0;
        }

        var height = (int) (available / aspect);

        if (height < 180) {
            height = 180;
        }

        if (height > Config.PLAYER_MAX_HEIGHT) {
            height = Config.PLAYER_MAX_HEIGHT;
        }

        if (player_box.height_request != height) {
            player_box.height_request = height;
        }
    }

    private void update_columns () {
        update_player_height ();

        last_width = get_width ();
        if (last_width <= 0) {
            return;
        }

        var should_stack = last_width < Config.STACK_BELOW_WIDTH;
        if (should_stack != stacked) {
            stacked = should_stack;

            if (related_box.get_parent () == related_scroller) {
                related_scroller.child = null;
            } else if (related_box.get_parent () == main_box) {
                main_box.remove (related_box);
            }

            if (stacked) {
                row.remove (related_scroller);
                main_box.append (related_box);
            } else {
                related_scroller.child = related_box;
                row.append (related_scroller);
            }
        }
    }

    // ------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------

    private void open_channel () {
        if (channel != null && channel.id != "") {
            channel_activated (channel);
        }
    }

    private void on_follow_toggled () {
        if (updating || channel == null || channel.id == "") {
            return;
        }

        if (follow_button.active) {
            library.follow (channel);
        } else {
            library.unfollow (channel.id);
        }

        update_follow_label ();
    }

    private void on_save_toggled () {
        if (updating || current == null || current.id == "") {
            return;
        }

        if (save_button.active) {
            library.save_for_later (current);
        } else {
            library.remove_saved (current.id);
        }

        update_save_icon ();
    }

    private void copy_link () {
        if (current == null) {
            return;
        }

        var clipboard = get_clipboard ();
        if (clipboard != null) {
            clipboard.set_text (current.watch_uri);
        }
    }

    private void open_in_browser () {
        if (current == null) {
            return;
        }

        var launcher = new Gtk.UriLauncher (current.watch_uri);
        launcher.launch.begin (null, null, (obj, res) => {
            try {
                launcher.launch.end (res);
            } catch (Error e) {
                warning ("Could not open the video in a browser: %s", e.message);
            }
        });
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private static Channel? channel_from (Video video) {
        if (video.channel_id == "") {
            return null;
        }

        return new Channel () {
            id = video.channel_id,
            name = video.channel_name,
            avatar_uri = video.channel_avatar
        };
    }

    /** Keeps what the list already showed when the response has less detail. */
    private static Video merge (Video? existing, Video loaded) {
        if (existing == null) {
            return loaded;
        }

        if (loaded.title == "") {
            loaded.title = existing.title;
        }

        if (loaded.channel_name == "") {
            loaded.channel_name = existing.channel_name;
            loaded.channel_id = existing.channel_id;
            loaded.channel_avatar = existing.channel_avatar;
        }

        if (loaded.thumbnail_uri == "") {
            loaded.thumbnail_uri = existing.thumbnail_uri;
        }

        if (loaded.duration == "") {
            loaded.duration = existing.duration;
        }

        return loaded;
    }
}
