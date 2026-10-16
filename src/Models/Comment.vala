/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * One comment left on a video.
 */

public class ByteTube.Comment : GLib.Object {
    public string author { get; set; default = ""; }
    public string avatar_uri { get; set; default = ""; }
    public string text { get; set; default = ""; }
    public string published { get; set; default = ""; }
    public string votes { get; set; default = ""; }
    public bool is_owner { get; set; default = false; }
}
