/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Plays the video and audio streams the client fetches.
 *
 * Each stream arrives as a byte sequence in a standard container, so the work
 * is split in two: a pair of sources fed from the network, and a GStreamer
 * pipeline that demuxes, decodes, sends audio to the sound card and hands
 * finished video frames back as images the app draws itself.
 *
 * Frames are drawn by the app rather than by a video sink widget because no
 * sink that renders into a GTK 4 widget is packaged for this system. A frame is
 * therefore copied once on its way to the screen, and the decode is capped at
 * 720p to keep that cost small.
 *
 * Threading
 * ---------
 * The main loop must never block, so nothing here waits on GStreamer:
 *
 * - Feeding the pipeline happens on a worker thread. Pushing into a source
 *   blocks when the pipeline is full, which is precisely the back-pressure we
 *   want, but it would freeze the window if it happened on the main loop.
 * - Tearing the pipeline down also happens on that worker, because a state
 *   change to NULL waits for the streaming threads to finish.
 * - The main loop only ever appends to a queue and hands over finished frames.
 * - The sink delivers frames on a streaming thread, so the finished frame is
 *   handed to the main loop from there rather than being drawn from the
 *   streaming thread. Only the newest frame is kept: if the window cannot keep
 *   up, older frames are dropped rather than queued.
 */

public class ByteTube.VideoPlayer : Gtk.Box {
    public signal void failed (string message);
    public signal void position_changed (int64 position_ms, int64 duration_ms);

    /** The user picked one of the offered qualities, by menu position. */
    public signal void quality_selected (int index);

    /** Pictures started flowing for the current stream. */
    public signal void first_frame ();

    public signal void fullscreen_changed (bool fullscreen);
    public signal void playing_changed (bool playing);

    /**
     * Presentation time of the frame currently on screen, in milliseconds of
     * stream time. Compared against the pipeline position it says whether the
     * picture is keeping up with the sound.
     */
    public int64 last_frame_ms { get; private set; default = 0; }

    private const int64 MAX_FRAME_WIDTH = 1280;
    private const int64 MAX_FRAME_HEIGHT = 720;

    /** How much undelivered data to allow before pausing the download. */
    private const uint64 HIGH_WATER_BYTES = 16 * 1024 * 1024;

    private Gst.Pipeline? pipeline = null;

    /** Held so that a frame never has to look the sink up mid-stream. */
    private Gst.App.Sink? video_sink = null;

    private Gtk.Picture picture;
    private StatusView status;
    private Gtk.Stack display;
    private Gtk.Revealer buffering_revealer;
    private Gtk.Label buffering_label;
    private int64 last_buffered_at = 0;
    private bool got_frame = false;
    private bool rebuffering = false;
    private int64 last_position_seen = -1;
    private int64 last_position_change_at = 0;

    private Gtk.Button play_button;
    private Gtk.Image play_icon;
    private Gtk.Label elapsed_label;
    private Gtk.Label duration_label;
    private Gtk.Scale seek_scale;
    private Gtk.Adjustment seek_adjustment;
    private Gtk.ToggleButton mute_button;
    private Gtk.Image volume_icon;
    private Gtk.Scale volume_scale;
    private Gtk.Button fullscreen_button;
    private Gtk.Image fullscreen_icon;
    private Gtk.ToggleButton zoom_button;
    private Gtk.Image zoom_icon;
    private Gtk.MenuButton quality_button;
    private Gtk.Overlay overlay;
    private Gtk.Revealer controls_revealer;

    /** Hides the transport and the pointer once the user sits still. */
    private uint hide_controls_timeout = 0;

    /** While the pointer rests on the transport it must not be taken away. */
    private bool controls_hovered = false;

    private Gdk.Cursor? hidden_cursor = null;

    /** The shape of the picture arriving, 0 until the first frame is decoded. */
    private int video_width = 0;
    private int video_height = 0;

    /** Whether the picture fills its box, cropping what does not fit. */
    private bool zoom_fill = false;
    private Gst.Element? volume_element = null;
    private Gst.Element? audio_sink = null;
    private bool fullscreen = false;

    /** Set while the progress reports write to the seek bar themselves. */
    private bool reporting_progress = false;

    /** Where the user has dragged the bar to, while they are still on it. */
    private int64 scrubbed_to = 0;
    private bool holding = false;

    /** Where the user asked to go, kept until the player gets there. */
    private int64 seek_target = -1;
    private int64 seek_hold_until = 0;
    private uint seek_timeout = 0;

    // Handed to the worker thread; guarded by queue_lock.
    private GLib.Mutex queue_lock;
    private GLib.Cond queue_signal;
    private Gee.ArrayList<Gst.Buffer> video_queue = new Gee.ArrayList<Gst.Buffer> ();
    private Gee.ArrayList<Gst.Buffer> audio_queue = new Gee.ArrayList<Gst.Buffer> ();
    private uint64 pending_bytes = 0;
    private bool feeding = false;
    private bool worker_owns_pipeline = false;
    private bool feed_video_next = true;

    // Handed back from the streaming thread; guarded by frame_lock.
    private GLib.Mutex frame_lock;
    private Gdk.Paintable? pending_frame = null;
    private int64 pending_frame_ms = 0;
    private bool frame_posted = false;

    /** The window whose fullscreen state the button follows, while there is one. */
    private unowned Gtk.Window? host_window = null;

    /**
     * Where the read-ahead buffer keeps its ring. It has to be a real file for
     * the demuxer to be able to read backwards and forwards in it, and it is
     * removed as soon as the stream stops.
     */
    private const string TEMP_TEMPLATE = "bytetube-player-XXXXXX";

    private uint tick = 0;
    private int debug_frames = 0;
    private bool playing = false;
    private int64 duration_ms = 0;
    private int64 position_ms = 0;

    public VideoPlayer () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            hexpand: true,
            vexpand: true,
            focusable: true
        );
    }

    construct {
        picture = new Gtk.Picture () {
            content_fit = Gtk.ContentFit.CONTAIN,
            hexpand = true,
            vexpand = true
        };

        status = new StatusView ();
        status.show_loading ();

        display = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.CROSSFADE,
            hexpand = true,
            vexpand = true,
            hhomogeneous = false,
            vhomogeneous = false
        };
        display.add_named (picture, "picture");
        display.add_named (status, "status");
        display.visible_child_name = "status";

        var buffering_spinner = new Gtk.Spinner () {
            width_request = 24,
            height_request = 24
        };
        buffering_spinner.start ();

        buffering_label = new Gtk.Label ("") {
            halign = Gtk.Align.CENTER
        };

        var buffering_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER
        };
        buffering_box.append (buffering_spinner);
        buffering_box.append (buffering_label);

        buffering_revealer = new Gtk.Revealer () {
            transition_type = Gtk.RevealerTransitionType.SLIDE_UP,
            reveal_child = false,
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
            child = buffering_box
        };

        overlay = new Gtk.Overlay () {
            hexpand = true,
            vexpand = true,
            child = display
        };
        overlay.add_overlay (buffering_revealer);

        // The transport floats over the bottom of the picture, in the style
        // for things drawn on top of content, so the picture can use the whole
        // window instead of giving up a strip of it.
        var bar = build_controls ();
        bar.add_css_class (Granite.STYLE_CLASS_OSD);

        controls_revealer = new Gtk.Revealer () {
            transition_type = Gtk.RevealerTransitionType.SLIDE_UP,
            reveal_child = true,
            halign = Gtk.Align.FILL,
            valign = Gtk.Align.END,
            margin_start = 12,
            margin_end = 12,
            margin_bottom = 12,
            child = bar
        };
        overlay.add_overlay (controls_revealer);

        // Any motion is the user coming back: the transport and the pointer
        // return, and the countdown to hiding them starts over.
        var motion = new Gtk.EventControllerMotion ();
        motion.motion.connect (() => poke_controls ());
        overlay.add_controller (motion);

        // …but while the pointer rests on the transport itself, hiding it
        // would pull it out from under them.
        var hover = new Gtk.EventControllerMotion ();
        hover.enter.connect (() => { controls_hovered = true; });
        hover.leave.connect (() => {
            controls_hovered = false;
            poke_controls ();
        });
        bar.add_controller (hover);

        // A click is activity too. Two of them in a row toggle fullscreen,
        // the way video everywhere else behaves.
        var click = new Gtk.GestureClick ();
        click.pressed.connect ((n_press, x, y) => {
            poke_controls ();

            if (n_press == 2) {
                toggle_fullscreen ();
            }
        });
        display.add_controller (click);

        var keys = new Gtk.EventControllerKey ();
        keys.key_pressed.connect (on_key_pressed);
        add_controller (keys);

        add_css_class ("bytetube-player");
        append (overlay);

        hidden_cursor = new Gdk.Cursor.from_name ("none", null);

        playing_changed.connect (() => update_play_icon ());
        playing_changed.connect (() => update_controls_for_state ());
        position_changed.connect (() => update_progress ());

        // The player is moved between the page and the miniplayer, so it is
        // told about a new window each time it is put in one.
        map.connect (() => watch_host_window ());
        unmap.connect (() => watch_host_window ());
    }

    /**
     * Transport controls, always visible under the picture. They act on the
     * pipeline directly, so they work for both ways of feeding it.
     */
    private Gtk.Widget build_controls () {
        play_icon = new Gtk.Image.from_icon_name ("media-playback-start-symbolic");

        play_button = new Gtk.Button () {
            child = play_icon,
            tooltip_text = _("Play")
        };
        play_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        play_button.clicked.connect (() => set_playing (!playing));

        elapsed_label = new Gtk.Label ("0:00") {
            valign = Gtk.Align.CENTER
        };
        elapsed_label.add_css_class (Granite.CssClass.DIM);
        elapsed_label.add_css_class (Granite.CssClass.NUMERIC);

        duration_label = new Gtk.Label ("0:00") {
            valign = Gtk.Align.CENTER
        };
        duration_label.add_css_class (Granite.CssClass.DIM);
        duration_label.add_css_class (Granite.CssClass.NUMERIC);

        seek_adjustment = new Gtk.Adjustment (0, 0, 1, 1000, 10000, 0);
        seek_scale = new Gtk.Scale (Gtk.Orientation.HORIZONTAL, seek_adjustment) {
            hexpand = true,
            draw_value = false,
            round_digits = 0,
            tooltip_text = _("Position")
        };

        // The scale is left to handle dragging and clicking itself. A gesture
        // of this widget's own would take the press away from it and leave the
        // handle unable to move, so the player watches the value instead: any
        // change it did not make is the user scrubbing, and the seek follows
        // once they have settled — which is when they let go.
        seek_adjustment.value_changed.connect (() => {
            if (reporting_progress) {
                return;
            }

            // The value is noted here and not read again later: the progress
            // reports keep writing the position into the bar, and would have
            // put their own value back in before the seek was ever made.
            scrubbed_to = (int64) seek_adjustment.value;
            holding = true;

            if (seek_timeout != 0) {
                Source.remove (seek_timeout);
            }

            seek_timeout = Timeout.add (SEEK_SETTLE_MS, () => {
                seek_timeout = 0;
                seek_to_target (scrubbed_to);
                return false;
            });
        });

        volume_icon = new Gtk.Image.from_icon_name ("audio-volume-high-symbolic");

        mute_button = new Gtk.ToggleButton () {
            child = volume_icon,
            tooltip_text = _("Mute")
        };
        mute_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        mute_button.toggled.connect (() => {
            set_muted (mute_button.active);
            mute_button.tooltip_text = mute_button.active ? _("Unmute") : _("Mute");
        });

        volume_scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 0.0, 1.0, 0.05) {
            width_request = 90,
            draw_value = false
        };
        volume_scale.set_value (1.0);
        volume_scale.value_changed.connect (() => {
            set_volume (volume_scale.get_value ());
            if (volume_scale.get_value () > 0 && mute_button.active) {
                mute_button.active = false;
            }
        });

        zoom_icon = new Gtk.Image.from_icon_name ("zoom-fit-best-symbolic");

        zoom_button = new Gtk.ToggleButton () {
            child = zoom_icon,
            tooltip_text = _("Zoom to Fill")
        };
        zoom_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        zoom_button.toggled.connect (() => set_zoom_fill (zoom_button.active));

        quality_button = new Gtk.MenuButton () {
            tooltip_text = _("Change Quality")
        };
        quality_button.add_css_class (Granite.STYLE_CLASS_FLAT);

        var quality_actions = new GLib.SimpleActionGroup ();
        var select = new GLib.SimpleAction ("select", GLib.VariantType.INT32);
        select.activate.connect ((target) => {
            if (target != null) {
                quality_selected (target.get_int32 ());
            }
        });
        quality_actions.add_action (select);
        quality_button.insert_action_group ("quality", quality_actions);

        fullscreen_icon = new Gtk.Image.from_icon_name ("view-fullscreen-symbolic");

        fullscreen_button = new Gtk.Button () {
            child = fullscreen_icon,
            tooltip_text = _("Toggle fullscreen")
        };
        fullscreen_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        fullscreen_button.clicked.connect (() => toggle_fullscreen ());

        var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            margin_top = 6,
            margin_start = 6,
            margin_end = 6
        };
        bar.append (play_button);
        bar.append (elapsed_label);
        bar.append (seek_scale);
        bar.append (duration_label);
        bar.append (mute_button);
        bar.append (volume_scale);
        bar.append (zoom_button);
        bar.append (quality_button);
        bar.append (fullscreen_button);

        return bar;
    }

    private void update_play_icon () {
        play_icon.icon_name = playing
            ? "media-playback-pause-symbolic"
            : "media-playback-start-symbolic";
        play_button.tooltip_text = playing ? _("Pause") : _("Play");
    }

    private void update_progress () {
        duration_label.label = format_time (duration_ms);

        if (holding) {
            // The user is on the bar: it stays where they put it.
            elapsed_label.label = format_time (scrubbed_to);
            return;
        }

        if (seek_target >= 0) {
            // Reports still on their way describe where the video was before
            // the seek; following them would yank the bar out of the user's
            // hands, so it stays where they put it until the player arrives.
            var difference = position_ms - seek_target;
            var arrived = difference < SEEK_ARRIVED_MS && difference > -SEEK_ARRIVED_MS;
            if (!arrived && GLib.get_monotonic_time () < seek_hold_until) {
                elapsed_label.label = format_time (seek_target);
                return;
            }

            seek_target = -1;
        }

        elapsed_label.label = format_time (position_ms);

        if (duration_ms > 0) {
            seek_adjustment.upper = duration_ms;

            // Writing the value counts as a change to the adjustment, so the
            // handler above has to know these are not the user's doing.
            reporting_progress = true;
            seek_adjustment.value = double.min (position_ms, duration_ms);
            reporting_progress = false;
        }
    }

    /** Jumps to a position the user picked on the progress bar. */
    private void seek_to_target (int64 target) {
        holding = false;
        seek_target = target;
        seek_hold_until = GLib.get_monotonic_time () + SEEK_HOLD_MS;
        elapsed_label.label = format_time (target);
        seek (target);
    }

    private static string format_time (int64 ms) {
        var total = (int) (ms / 1000);
        var hours = total / 3600;
        var minutes = (total % 3600) / 60;
        var seconds = total % 60;

        if (hours > 0) {
            return "%d:%02d:%02d".printf (hours, minutes, seconds);
        }

        return "%d:%02d".printf (minutes, seconds);
    }

    // ------------------------------------------------------------------
    // Pipeline
    // ------------------------------------------------------------------

    /**
     * The pipeline is described as text: it is far shorter than wiring the
     * elements up by hand, and it is the only tidy way to let one decodebin
     * feed a branch without writing a pad-added handler for every element in
     * it.
     */
    private bool build_pipeline () {
        var description =
            "appsrc name=vsrc format=time is-live=false stream-type=stream max-bytes=%lu block=true ! "
            + "queue2 max-size-bytes=16777216 max-size-buffers=0 max-size-time=0 use-buffering=true low-watermark=0.01 high-watermark=0.05 ! decodebin name=vdemux "
            + "vdemux. ! queue max-size-bytes=4194304 ! videoconvert ! videoscale ! "
            + "capsfilter caps=video/x-raw,format=RGBA,width=[1,%lld],height=[1,%lld],pixel-aspect-ratio=1/1 ! "
            + "appsink name=vsink emit-signals=true max-buffers=2 drop=true sync=true "
            + "appsrc name=asrc format=time is-live=false stream-type=stream max-bytes=%lu block=true ! "
            + "queue2 max-size-bytes=4194304 max-size-buffers=0 max-size-time=0 use-buffering=true low-watermark=0.01 high-watermark=0.05 ! decodebin name=ademux "
            + "ademux. ! queue max-size-bytes=2097152 ! audioconvert ! audioresample ! volume name=vol ! autoaudiosink name=aout";

        description = description.printf (
            (ulong) (HIGH_WATER_BYTES * 2),
            MAX_FRAME_WIDTH,
            MAX_FRAME_HEIGHT,
            (ulong) HIGH_WATER_BYTES
        );

        try {
            pipeline = (Gst.Pipeline) Gst.parse_launch (description);
        } catch (Error e) {
            warning ("Could not build the player: %s", e.message);
            pipeline = null;
        }

        if (pipeline == null) {
            failed (_("The playback engine is not available."));
            return false;
        }

        var sink = pipeline.get_by_name ("vsink");
        if (sink == null) {
            failed (_("The playback engine is not available."));
            pipeline = null;
            return false;
        }

        video_sink = (Gst.App.Sink) sink;
        video_sink.new_sample.connect (on_video_sample);

        volume_element = pipeline.get_by_name ("vol");
        audio_sink = pipeline.get_by_name ("aout");

        var session = pipeline;
        var bus = session.get_bus ();
        bus.add_signal_watch ();
        bus.message.connect ((message) => on_bus_message (session, message));

        return true;
    }

    /**
     * Messages are ignored unless they come from the pipeline in use: one that
     * has just been replaced still reports errors as it shuts down, and those
     * are not the user's problem.
     */
    private void on_bus_message (Gst.Pipeline session, Gst.Message message) {
        if (pipeline != session) {
            return;
        }

        switch (message.type) {
            case Gst.MessageType.ERROR:
                GLib.Error error;
                string debug;
                message.parse_error (out error, out debug);
                failed (error.message);
                stop ();
                break;
            case Gst.MessageType.BUFFERING:
                int percent = 0;
                message.parse_buffering (out percent);
                show_buffering (percent);
                break;
            case Gst.MessageType.EOS:
                playing = false;
                playing_changed (false);
                break;
            default:
                break;
        }
    }

    private void show_buffering (int percent) {
        Debug.log ("pipeline buffering: %d%%".printf (percent));

        if (percent < 100) {
            last_buffered_at = GLib.get_monotonic_time ();
        }

        // Once playback begins the queue level rises and falls as the player
        // reads ahead, which says nothing about what the user is waiting for.
        // From then on the overlay follows the position instead.
        if (got_frame) {
            return;
        }

        if (percent >= 100) {
            buffering_revealer.reveal_child = false;
            return;
        }

        /// TRANSLATORS: Percentage of the video buffered so far
        buffering_label.label = _("Buffering… %d%%").printf (percent);
        buffering_revealer.reveal_child = true;
    }

    // ------------------------------------------------------------------
    // Transport
    // ------------------------------------------------------------------

    public void show_waiting () {
        display.visible_child_name = "status";
        status.show_loading ();
    }

    public bool start () {
        Debug.log ("player: starting fed pipeline");
        show_waiting ();

        got_frame = false;
        rebuffering = false;
        last_position_seen = -1;
        last_position_change_at = GLib.get_monotonic_time ();
        last_buffered_at = GLib.get_monotonic_time ();

        if (pipeline == null && !build_pipeline ()) {
            return false;
        }

        change_state (pipeline, Gst.State.PLAYING);

        queue_lock.lock ();
        feeding = true;
        queue_lock.unlock ();

        worker_owns_pipeline = true;
        var session = pipeline;

        new GLib.Thread<bool> ("bytetube-player", () => feed_loop (session));

        playing = true;
        playing_changed (true);
        start_ticking ();

        return true;
    }

    /**
     * A source can refuse to serve a file without reporting an error, leaving
     * the player waiting forever with nothing to show. If no frame has arrived
     * and nothing has buffered for this long, the stream is treated as failed
     * so the caller can try another one.
     */
    private const int STALL_TIMEOUT_MS = 9000;

    /** How long the position may stand still before the user is told why. */
    private const int REBUFFER_SHOW_MS = 1200;

    /** How long the user may be still before the position they picked is used. */
    private const int SEEK_SETTLE_MS = 220;

    /** How close the player must get to a requested position to be believed. */
    private const int64 SEEK_ARRIVED_MS = 2000;

    /** How long to keep showing a requested position if the player never arrives. */
    private const int64 SEEK_HOLD_MS = 4000;

    /**
     * Plays two media URLs directly.
     *
     * When the service hands out plain URLs there is nothing for this app to
     * fetch or negotiate: GStreamer can open them itself, buffer them, keep
     * them in step, and seek in them. That is both simpler and better than
     * feeding the pipeline by hand, so it is the preferred path.
     */
    /**
     * How much of a stream is read ahead, from how large the file is. The
     * buffer reports its level as a fraction of its size, so it has to stay
     * smaller than the file: a file that fits inside it fills the buffer
     * once and then starves it as it drains, and the player waits forever
     * on a stream that is already completely downloaded. A quarter of
     * the file, within limits, keeps the fraction meaningful for anything
     * from a hundred kilobytes to tens of gigabytes.
     */
    private static uint download_ring_for (int64 size_bytes, uint floor, uint ceiling) {
        if (size_bytes <= 0) {
            return 1048576;
        }

        return ((uint) (size_bytes / 4)).clamp (floor, ceiling);
    }

    public bool play_uris (string video_uri, string audio_uri, int64 video_size = 0, int64 audio_size = 0) {
        stop ();
        show_waiting ();
        worker_owns_pipeline = false;
        got_frame = false;
        rebuffering = false;
        last_position_seen = -1;
        last_position_change_at = GLib.get_monotonic_time ();
        last_buffered_at = GLib.get_monotonic_time ();

        var description =
            "souphttpsrc name=vsrc is-live=false ! "
            + "downloadbuffer name=vdown temp-template=\"" + TEMP_TEMPLATE + "\" max-size-bytes=8388608 max-size-time=0 low-percent=1 high-percent=5 ! "
            + "decodebin name=vdemux "
            + "vdemux. ! queue max-size-bytes=8388608 ! videoconvert ! videoscale ! "
            + "capsfilter caps=video/x-raw,format=RGBA,width=[1,%lld],height=[1,%lld],pixel-aspect-ratio=1/1 ! "
            + "appsink name=vsink emit-signals=true max-buffers=2 drop=true sync=true "
            + "souphttpsrc name=asrc is-live=false ! "
            + "downloadbuffer name=adown temp-template=\"" + TEMP_TEMPLATE + "\" max-size-bytes=2097152 max-size-time=0 low-percent=1 high-percent=5 ! "
            + "decodebin name=ademux "
            + "ademux. ! queue max-size-bytes=4194304 ! audioconvert ! audioresample ! volume name=vol ! autoaudiosink name=aout";

        description = description.printf (MAX_FRAME_WIDTH, MAX_FRAME_HEIGHT);

        // Both buffers keep their ring in the temporary directory, which under
        // a sandbox is the app's own.
        var template = GLib.Path.build_filename (GLib.Environment.get_tmp_dir (), TEMP_TEMPLATE);
        // A literal so that a path containing a backslash cannot break the parse.
        description = description.replace (TEMP_TEMPLATE, template);

        Gst.Pipeline? built = null;
        try {
            built = (Gst.Pipeline) Gst.parse_launch (description);
        } catch (Error e) {
            warning ("Could not build the player: %s", e.message);
            built = null;
        }

        if (built == null) {
            failed (_("The playback engine is not available."));
            return false;
        }

        Debug.log ("player: playing direct urls");
        pipeline = built;

        var video_source = built.get_by_name ("vsrc");
        var audio_source = built.get_by_name ("asrc");
        var sink = built.get_by_name ("vsink");

        if (video_source == null || audio_source == null || sink == null) {
            failed (_("The playback engine is not available."));
            stop ();
            return false;
        }

        // Set through the property rather than in the description: the URLs
        // contain characters the parser would otherwise have to be told about.
        video_source.set ("location", video_uri);
        audio_source.set ("location", audio_uri);

        video_sink = (Gst.App.Sink) sink;
        video_sink.new_sample.connect (on_video_sample);

        volume_element = built.get_by_name ("vol");
        audio_sink = built.get_by_name ("aout");

        var video_buffer = built.get_by_name ("vdown");
        if (video_buffer != null) {
            video_buffer.set ("max-size-bytes", download_ring_for (video_size, 32768, 4194304));
        }

        var audio_buffer = built.get_by_name ("adown");
        if (audio_buffer != null) {
            audio_buffer.set ("max-size-bytes", download_ring_for (audio_size, 16384, 1048576));
        }

        var bus = built.get_bus ();
        bus.add_signal_watch ();
        bus.message.connect ((message) => on_bus_message (built, message));

        change_state (built, Gst.State.PLAYING);

        last_buffered_at = GLib.get_monotonic_time ();
        playing = true;
        playing_changed (true);
        start_ticking ();

        return true;
    }

    /**
     * Asks the worker to finish and returns at once. The worker stops the
     * pipeline itself, because waiting for the streaming threads to come back
     * is not something the main loop can afford to do.
     */
    public void stop () {
        stop_ticking ();

        queue_lock.lock ();
        feeding = false;
        video_queue.clear ();
        audio_queue.clear ();
        pending_bytes = 0;
        queue_signal.broadcast ();
        queue_lock.unlock ();

        // The worker tears down a pipeline it was given; anything else would
        // be stopped twice.
        if (!worker_owns_pipeline) {
            release_pipeline (pipeline);
        }

        pipeline = null;
        video_sink = null;
        worker_owns_pipeline = false;
        playing = false;
        rebuffering = false;
        buffering_revealer.reveal_child = false;
        playing_changed (false);
    }

    /**
     * Changes a pipeline's state without waiting for it.
     *
     * Asking a top-level pipeline to play does not return until it has
     * prerolled, and prerolling needs data off the network — seconds, on a slow
     * connection. Doing that on the main loop freezes the window and leaves the
     * player spinning. The pipeline is already built, so a short-lived thread
     * can carry the request instead.
     */
    private static void change_state (Gst.Pipeline? target, Gst.State state) {
        if (target == null) {
            return;
        }

        new GLib.Thread<bool> ("bytetube-state", () => {
            target.set_state (state);
            return true;
        });
    }

    /**
     * Lets go of a pipeline without waiting for it.
     *
     * Dropping the last reference to a pipeline that is still playing leaves
     * GStreamer to tear down the streaming threads from whichever thread
     * happened to release it, which is not safe. Stopping it is quick to ask
     * for but not to wait for, so a short-lived thread does it instead: first
     * the bus watch, then the state change.
     *
     * The one exception is the path that already has a worker thread of its
     * own, which performs the teardown as it exits; there the pipeline is
     * passed to it rather than released here.
     */
    private static void release_pipeline (Gst.Pipeline? old) {
        if (old == null) {
            return;
        }

        new GLib.Thread<bool> ("bytetube-teardown", () => {
                var bus = old.get_bus ();
                if (bus != null) {
                    bus.remove_signal_watch ();
                }

                old.set_state (Gst.State.NULL);
                return true;
            });
    }

    public bool is_playing {
        get {
            return playing;
        }
    }

    public void set_playing (bool should_play) {
        Debug.log ("player: %s".printf (should_play ? "play" : "pause"));

        if (pipeline == null) {
            return;
        }

        change_state (pipeline, should_play ? Gst.State.PLAYING : Gst.State.PAUSED);
        playing = should_play;
        playing_changed (playing);
    }

    /**
     * How long the pointer may sit still in fullscreen before the transport
     * and the pointer itself are taken away.
     */
    private const int HIDE_AFTER_MS = 2500;

    /** How far one press of an arrow key moves through the video. */
    private const int64 SEEK_STEP_MS = 10000;

    /** Where the picture has reached, for resuming after a stream changes. */
    public int64 playback_position {
        get {
            return position_ms;
        }
    }

    /**
     * The shape of the video, as width over height, or 0 while nothing has
     * been decoded yet. The page holding the player sizes the box around the
     * picture from this, so a 4:3 video gets a 4:3 player and a 16:9 video a
     * 16:9 one instead of both being poured into the same mould.
     */
    public double video_aspect {
        get {
            if (video_width <= 0 || video_height <= 0) {
                return 0;
            }

            return (double) video_width / (double) video_height;
        }
    }

    /** Something happened: show the transport and start the countdown again. */
    private void poke_controls () {
        controls_revealer.reveal_child = true;
        overlay.set_cursor (null);

        if (hide_controls_timeout != 0) {
            Source.remove (hide_controls_timeout);
            hide_controls_timeout = 0;
        }

        if (fullscreen && playing) {
            hide_controls_timeout = Timeout.add (HIDE_AFTER_MS, () => {
                hide_controls_timeout = 0;
                maybe_hide_controls ();
                return false;
            });
        }
    }

    /** Puts the transport away, unless the user still needs it. */
    private void maybe_hide_controls () {
        if (!fullscreen || !playing || controls_hovered || controls_focused ()) {
            // Still wanted — or no longer fullscreen or playing, in which case
            // there is nothing to hide. If the pointer is on the transport it
            // will leave soon enough, and that restarts the countdown.
            if (fullscreen && playing) {
                poke_controls ();
            }

            return;
        }

        controls_revealer.reveal_child = false;
        overlay.set_cursor (hidden_cursor);
    }

    /** Whether keyboard focus sits on the transport. */
    private bool controls_focused () {
        Gtk.Widget? focus = null;
        if (host_window != null) {
            focus = host_window.get_focus ();
        }

        return focus != null && focus.is_ancestor (controls_revealer);
    }

    /** A pause always brings the transport back; playing starts the countdown. */
    private void update_controls_for_state () {
        if (playing) {
            poke_controls ();
        } else {
            if (hide_controls_timeout != 0) {
                Source.remove (hide_controls_timeout);
                hide_controls_timeout = 0;
            }

            controls_revealer.reveal_child = true;
            overlay.set_cursor (null);
        }
    }

    public void set_duration (int64 duration) {
        duration_ms = duration;
        update_progress ();
    }

    /** Jumps to a position in the video. Works while paused too. */
    public void seek (int64 position_ms) {
        var session = pipeline;
        if (session == null) {
            return;
        }

        if (duration_ms > 0) {
            position_ms = position_ms.clamp (0, duration_ms);
        }

        // The sinks are asked rather than the pipeline. A sink that performs
        // the seek itself moves its clock along with the position; one that is
        // merely told about a seek carried out elsewhere keeps waiting for a
        // moment that has already passed, which leaves the picture frozen on
        // the frame it had reached while the sound plays on.
        var flags = Gst.SeekFlags.FLUSH | Gst.SeekFlags.KEY_UNIT;
        var asked = false;

        if (video_sink != null) {
            asked = video_sink.seek_simple (Gst.Format.TIME, flags, position_ms * Gst.MSECOND)
                || asked;
        }

        if (audio_sink != null) {
            asked = audio_sink.seek_simple (Gst.Format.TIME, flags, position_ms * Gst.MSECOND)
                || asked;
        }

        if (!asked) {
            session.seek_simple (Gst.Format.TIME, flags, position_ms * Gst.MSECOND);
        }
    }

    public void set_volume (double level) {
        if (volume_element != null) {
            volume_element.set ("volume", level.clamp (0.0, 1.0));
        }
    }

    public void set_muted (bool muted) {
        if (volume_element != null) {
            volume_element.set ("mute", muted);
        }

        volume_icon.icon_name = muted
            ? "audio-volume-muted-symbolic"
            : "audio-volume-high-symbolic";
    }

    /**
     * The transport, from the keyboard. Only Escape works everywhere: the rest
     * stands aside while typing in a field or working a focused control, so a
     * space in search stays a space and arrows keep adjusting the sliders.
     */
    private bool on_key_pressed (uint keyval, uint keycode, Gdk.ModifierType state) {
        if (keyval == Gdk.Key.Escape) {
            if (fullscreen && host_window != null) {
                host_window.unfullscreen ();
                return true;
            }

            return false;
        }

        Gtk.Widget? focus = null;
        if (host_window != null) {
            focus = host_window.get_focus ();
        }

        if (focus is Gtk.Editable || focus is Gtk.Range || focus is Gtk.Button) {
            return false;
        }

        switch (keyval) {
            case Gdk.Key.space:
                set_playing (!playing);
                return true;
            case Gdk.Key.Left:
                seek (position_ms - SEEK_STEP_MS);
                return true;
            case Gdk.Key.Right:
                seek (position_ms + SEEK_STEP_MS);
                return true;
            case Gdk.Key.f:
            case Gdk.Key.F:
                toggle_fullscreen ();
                return true;
            case Gdk.Key.m:
            case Gdk.Key.M:
                mute_button.active = !mute_button.active;
                return true;
            case Gdk.Key.z:
            case Gdk.Key.Z:
                set_zoom_fill (!zoom_fill);
                return true;
            default:
                return false;
        }
    }

    /**
     * Offers the given qualities in the transport menu, marking `current`.
     * With fewer than two there is nothing to choose, so the button steps
     * aside instead of sitting there dead.
     */
    public void set_quality_options (string[] labels, int current) {
        quality_button.visible = labels.length > 1;

        if (labels.length <= 1) {
            return;
        }

        var menu = new GLib.Menu ();
        for (var i = 0; i < labels.length; i++) {
            var item = new GLib.MenuItem (labels[i], null);
            item.set_action_and_target_value ("quality.select", new GLib.Variant.int32 (i));
            menu.append_item (item);
        }

        quality_button.menu_model = menu;

        if (current >= 0 && current < labels.length) {
            quality_button.label = labels[current];
        }
    }

    /**
     * Fills the box with the picture, cropping the overflow, or fits the whole
     * picture inside it. Filling is what makes a 4:3 video use a 16:9 screen;
     * fitting shows every pixel with bars where the shapes disagree.
     */
    public void set_zoom_fill (bool fill) {
        zoom_fill = fill;
        picture.content_fit = fill ? Gtk.ContentFit.COVER : Gtk.ContentFit.CONTAIN;

        if (zoom_button.active != fill) {
            zoom_button.active = fill;
        }

        zoom_button.tooltip_text = fill ? _("Zoom to Fit") : _("Zoom to Fill");
    }

    private void toggle_fullscreen () {
        var root = get_root ();
        if (!(root is Gtk.Window)) {
            return;
        }

        var window = (Gtk.Window) root;

        // The window holds this state, not the button: fullscreen can also be
        // left with Escape, or entered from the window menu, and the button has
        // to follow wherever it was changed from.
        if (window.fullscreened) {
            window.unfullscreen ();
        } else {
            window.fullscreen ();
        }
    }

    /**
     * Follows the fullscreen state of whichever window the player is in. It
     * moves between the page and the miniplayer, so the window it belongs to
     * has to be tracked rather than assumed.
     */
    private void watch_host_window () {
        if (host_window != null) {
            host_window.notify["fullscreened"].disconnect (on_fullscreened_changed);
            host_window = null;
        }

        var root = get_root ();
        if (!(root is Gtk.Window)) {
            return;
        }

        host_window = (Gtk.Window) root;
        host_window.notify["fullscreened"].connect (on_fullscreened_changed);
        on_fullscreened_changed ();
    }

    private void on_fullscreened_changed () {
        var now_fullscreen = host_window != null && host_window.fullscreened;
        if (now_fullscreen == fullscreen) {
            return;
        }

        fullscreen = now_fullscreen;

        // The box around the picture has rounded corners on the page, which is
        // where the window background would show through behind them. On the
        // screen there is nothing behind: every pixel out to the edges is the
        // player's own black.
        if (fullscreen) {
            add_css_class ("fullscreen");
        } else {
            remove_css_class ("fullscreen");
        }

        fullscreen_icon.icon_name = fullscreen
            ? "view-restore-symbolic"
            : "view-fullscreen-symbolic";
        fullscreen_button.tooltip_text = fullscreen
            ? _("Leave fullscreen")
            : _("Toggle fullscreen");

        if (fullscreen) {
            // The keys only work if focus is somewhere in the player, so it
            // is taken when the picture takes the screen.
            grab_focus ();
            poke_controls ();
        } else {
            update_controls_for_state ();
        }

        fullscreen_changed (fullscreen);
    }

    // ------------------------------------------------------------------
    // Handing data to the pipeline
    // ------------------------------------------------------------------

    public bool can_accept_more () {
        queue_lock.lock ();
        var queued = pending_bytes;
        queue_lock.unlock ();

        return queued < HIGH_WATER_BYTES;
    }

    public void push_video (GLib.Bytes data) {
        enqueue (data, true);
    }

    public void push_audio (GLib.Bytes data) {
        enqueue (data, false);
    }

    private void enqueue (GLib.Bytes data, bool is_video) {
        var buffer = new Gst.Buffer.allocate (null, data.get_size (), null);
        buffer.fill (0, data.get_data ());

        queue_lock.lock ();
        if (!feeding) {
            queue_lock.unlock ();
            return;
        }

        if (is_video) {
            video_queue.add (buffer);
        } else {
            audio_queue.add (buffer);
        }

        pending_bytes += buffer.get_size ();
        queue_signal.signal ();
        queue_lock.unlock ();
    }

    /**
     * Runs on its own thread for as long as the pipeline lives. Pushing blocks
     * when the pipeline has enough data, which paces the download without ever
     * touching the main loop.
     */
    private bool feed_loop (Gst.Pipeline session) {
        var video_src = (Gst.App.Src) session.get_by_name ("vsrc");
        var audio_src = (Gst.App.Src) session.get_by_name ("asrc");

        while (true) {
            Gst.Buffer buffer = null;
            var is_video = false;

            queue_lock.lock ();
            while (feeding && video_queue.size == 0 && audio_queue.size == 0) {
                queue_signal.wait (queue_lock);
            }

            if (!feeding) {
                queue_lock.unlock ();
                break;
            }

            // Alternate so that neither stream can starve the other.
            if (feed_video_next && video_queue.size > 0) {
                buffer = video_queue.remove_at (0);
                is_video = true;
            } else if (audio_queue.size > 0) {
                buffer = audio_queue.remove_at (0);
            } else {
                buffer = video_queue.remove_at (0);
                is_video = true;
            }

            feed_video_next = !is_video;
            queue_lock.unlock ();

            if (buffer == null) {
                continue;
            }

            // The size is read before the buffer is handed over, because
            // passing it on gives up ownership of it.
            var size = buffer.get_size ();

            var source = is_video ? video_src : audio_src;
            if (source != null) {
                source.push_buffer ((owned) buffer);
            }

            queue_lock.lock ();
            pending_bytes -= size;
            queue_lock.unlock ();
        }

        var bus = session.get_bus ();
        if (bus != null) {
            bus.remove_signal_watch ();
        }

        session.set_state (Gst.State.NULL);
        return true;
    }

    // ------------------------------------------------------------------
    // Frames
    // ------------------------------------------------------------------

    /**
     * Called on a streaming thread. The frame is prepared here and handed to
     * the main loop; the window is never touched from this thread.
     */
    private Gst.FlowReturn on_video_sample () {
        var sink = video_sink;
        if (sink == null) {
            return Gst.FlowReturn.OK;
        }

        var sample = sink.pull_sample ();
        if (sample == null) {
            return Gst.FlowReturn.OK;
        }

        var buffer = sample.get_buffer ();
        var caps = sample.get_caps ();
        if (buffer == null || caps == null || caps.get_size () == 0) {
            return Gst.FlowReturn.OK;
        }

        unowned Gst.Structure structure = caps.get_structure (0);
        int width = 0;
        int height = 0;
        structure.get_int ("width", out width);
        structure.get_int ("height", out height);

        if (width <= 0 || height <= 0) {
            return Gst.FlowReturn.OK;
        }

        video_width = width;
        video_height = height;

        Gst.MapInfo info;
        if (!buffer.map (out info, Gst.MapFlags.READ)) {
            return Gst.FlowReturn.OK;
        }

        var pixels = new uint8[info.size];
        Memory.copy (pixels, info.data, info.size);
        buffer.unmap (info);

        var texture = new Gdk.MemoryTexture (
            width,
            height,
            Gdk.MemoryFormat.R8G8B8A8,
            new GLib.Bytes (pixels),
            width * 4
        );

        if (GLib.Environment.get_variable ("BYTETUBE_DEBUG_PTS") != null && debug_frames < 6) {
            debug_frames++;
            stderr.printf ("PTS raw=%lu none=%s dts=%lu dur=%lu\n",
                (ulong) buffer.pts,
                (buffer.pts == Gst.CLOCK_TIME_NONE).to_string (),
                (ulong) buffer.dts,
                (ulong) buffer.duration);
        }

        var frame_ms = buffer.pts == Gst.CLOCK_TIME_NONE
            ? 0
            : (int64) (buffer.pts / 1000000);

        // A picture reports its image's resolution as its own natural size, so
        // a low-resolution or 4:3 video would decide how tall the player is and
        // push it out of shape. Reporting the same shape at a tiny size leaves
        // the box in charge of the size while the picture still letterboxes the
        // frame correctly inside it.
        var shrink = 16.0 / double.max (width, height);
        var reported = new SizedPaintable (
            texture,
            int.max (1, (int) (width * shrink)),
            int.max (1, (int) (height * shrink))
        );

        frame_lock.lock ();
        pending_frame = reported;
        pending_frame_ms = frame_ms;
        var post = !frame_posted;
        frame_posted = true;
        frame_lock.unlock ();

        if (post) {
            GLib.Idle.add (deliver_frame);
        }

        return Gst.FlowReturn.OK;
    }

    private bool deliver_frame () {
        frame_lock.lock ();
        var frame = pending_frame;
        var frame_ms = pending_frame_ms;
        pending_frame = null;
        frame_posted = false;
        frame_lock.unlock ();

        if (frame != null) {
            last_frame_ms = frame_ms;

            if (!got_frame) {
                got_frame = true;
                first_frame ();
            }
            buffering_revealer.reveal_child = false;
            picture.paintable = frame;

            if (display.visible_child_name != "picture") {
                display.visible_child_name = "picture";
            }
        }

        return false;
    }

    // ------------------------------------------------------------------
    // Progress
    // ------------------------------------------------------------------

    private void start_ticking () {
        if (tick != 0) {
            return;
        }

        tick = Timeout.add (400, () => {
            report_position ();
            return true;
        });
    }

    private void stop_ticking () {
        if (tick != 0) {
            Source.remove (tick);
            tick = 0;
        }
    }

    private void report_position () {
        var session = pipeline;
        if (session == null) {
            return;
        }

        // The pipeline answers in nanoseconds; everything else here is in
        // milliseconds, including the duration, so the two can be compared.
        int64 nanos = 0;
        if (session.query_position (Gst.Format.TIME, out nanos)) {
            position_ms = nanos / 1000000;
        }

        position_changed (position_ms, duration_ms);

        // A position that stops moving while the player thinks it is playing
        // means the stream ran dry and is filling again.
        if (position_ms != last_position_seen) {
            last_position_seen = position_ms;
            last_position_change_at = GLib.get_monotonic_time ();

            if (rebuffering) {
                rebuffering = false;
                buffering_revealer.reveal_child = false;
            }
        } else if (playing && got_frame && !rebuffering
            && (GLib.get_monotonic_time () - last_position_change_at) / 1000 > REBUFFER_SHOW_MS) {
            rebuffering = true;
            /// TRANSLATORS: Shown while a video that is already playing has to
            /// wait for more of itself to arrive
            buffering_label.label = _("Buffering…");
            buffering_revealer.reveal_child = true;
        }

        if (playing && !got_frame && last_buffered_at > 0
            && (GLib.get_monotonic_time () - last_buffered_at) / 1000 > STALL_TIMEOUT_MS) {
            // Nothing has arrived for a while: stop waiting and let the caller
            // pick something else.
            last_buffered_at = 0;
            Debug.log ("no frame or buffering for %dms: giving up on this stream"
                .printf (STALL_TIMEOUT_MS));
            failed (_("This video is not loading."));
            stop ();
        }
    }
}
