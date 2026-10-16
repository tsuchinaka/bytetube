/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Wraps an image so that it reports the size it is going to be drawn at.
 *
 * `Gtk.Picture` asks its paintable for an intrinsic size and uses that as the
 * widget's natural size. A thumbnail downloaded from the service is far larger
 * than the card it goes on, so without this the layout would be decided by the
 * resolution of whichever image happened to finish loading first — cards would
 * stretch to the width of their picture and only one would fit per row.
 */

public class ByteTube.SizedPaintable : GLib.Object, Gdk.Paintable {
    public Gdk.Paintable source { get; construct; }
    public int target_width { get; construct; }
    public int target_height { get; construct; }

    public SizedPaintable (Gdk.Paintable source, int target_width, int target_height) {
        Object (
            source: source,
            target_width: target_width,
            target_height: target_height
        );
    }

    public int get_intrinsic_width () {
        return target_width;
    }

    public int get_intrinsic_height () {
        return target_height;
    }

    public double get_intrinsic_aspect_ratio () {
        return (double) target_width / (double) target_height;
    }

    public void snapshot (Gdk.Snapshot snapshot, double width, double height) {
        source.snapshot (snapshot, width, height);
    }
}
