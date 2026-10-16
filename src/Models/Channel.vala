/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * A channel that publishes videos.
 */

public class ByteTube.Channel : GLib.Object {
    public string id { get; set; default = ""; }
    public string name { get; set; default = ""; }
    public string avatar_uri { get; set; default = ""; }
    public string handle { get; set; default = ""; }
    public string subscriber_count { get; set; default = ""; }
    public string video_count { get; set; default = ""; }
    public string description { get; set; default = ""; }

    public Json.Object to_json_object () {
        var object = new Json.Object ();
        object.set_string_member ("id", id);
        object.set_string_member ("name", name);
        object.set_string_member ("avatar_uri", avatar_uri);
        object.set_string_member ("handle", handle);
        object.set_string_member ("subscriber_count", subscriber_count);
        object.set_string_member ("description", description);
        return object;
    }

    public static Channel? from_json_object (Json.Object object) {
        var id = object.get_string_member_with_default ("id", "");
        if (id == "") {
            return null;
        }

        var channel = new Channel () { id = id };
        channel.name = object.get_string_member_with_default ("name", "");
        channel.avatar_uri = object.get_string_member_with_default ("avatar_uri", "");
        channel.handle = object.get_string_member_with_default ("handle", "");
        channel.subscriber_count = object.get_string_member_with_default ("subscriber_count", "");
        channel.description = object.get_string_member_with_default ("description", "");
        return channel;
    }
}
