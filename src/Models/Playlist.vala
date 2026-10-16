/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * A playlist of videos.
 */

public class ByteTube.Playlist : GLib.Object {
    public string id { get; set; default = ""; }
    public string title { get; set; default = ""; }
    public string channel_name { get; set; default = ""; }
    public string thumbnail_uri { get; set; default = ""; }
    public string video_count { get; set; default = ""; }
}
