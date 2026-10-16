/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Turns a raw response from the video service into ByteTube's own models.
 *
 * The service reshuffles and renames its response objects regularly, so nothing
 * here depends on a fixed path through the response. Instead the tree is walked
 * once, in document order: any object that looks like a video, a channel or a
 * playlist becomes a model, and any object that carries a section heading opens
 * a new shelf. That keeps the reading order the service intended while
 * surviving changes to how the response is nested.
 */

public class ByteTube.ResponseParser : GLib.Object {
    public static BrowseResult parse (string json, string? video_id = null) throws InnertubeError {
        var parser = new Json.Parser ();
        try {
            parser.load_from_data (json);
        } catch (Error e) {
            throw new InnertubeError.PARSE (
                _("The video service sent a response that could not be read.")
            );
        }

        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new InnertubeError.PARSE (
                _("The video service sent a response that could not be read.")
            );
        }

        var root_object = root.get_object ();
        var result = new BrowseResult ();

        // `shelves` keeps every section in the order it was opened, so that a
        // section which is closed again on the way out is not lost. `stack`
        // tracks which of them results are currently being added to.
        var shelves = new Gee.ArrayList<Shelf> ();
        var stack = new Gee.ArrayList<Shelf> ();

        var untitled = new Shelf ();
        shelves.add (untitled);
        stack.add (untitled);

        walk_object (root_object, shelves, stack);

        foreach (var shelf in shelves) {
            if (!shelf.is_empty) {
                result.shelves.add (shelf);
            }
        }

        result.primary = parse_primary (root_object, video_id);
        result.channel = parse_page_channel (root_object);
        result.continuation = first_continuation (root);

        return result;
    }

    // ------------------------------------------------------------------
    // Comments
    // ------------------------------------------------------------------

    /**
     * The comments, which the service sends as its own response once it is
     * asked for them with a token from the video's own response.
     */
    public static Gee.ArrayList<Comment> parse_comments (string json) throws InnertubeError {
        var comments = new Gee.ArrayList<Comment> ();
        var root = parse_root (json);

        var threads = new Gee.ArrayList<Json.Object> ();
        collect_objects (root, "commentThreadRenderer", threads);

        foreach (var thread in threads) {
            var payload = find_comment_payload (thread);
            if (payload == null) {
                continue;
            }

            var comment = new Comment ();
            comment.author = text_of (payload.get_member ("authorText")) ?? "";
            comment.text = text_of (payload.get_member ("contentText")) ?? "";
            comment.published = text_of (payload.get_member ("publishedTimeText")) ?? "";
            comment.votes = text_of (payload.get_member ("voteCount")) ?? "";
            comment.avatar_uri = fix_url (best_url (payload.get_member ("authorThumbnail")) ?? "");

            if (payload.has_member ("authorIsChannelOwner")) {
                comment.is_owner = payload.get_boolean_member_with_default (
                    "authorIsChannelOwner", false);
            }

            if (comment.text != "" || comment.author != "") {
                comments.add (comment);
            }
        }

        return comments;
    }

    /**
     * The comment payload sits at whatever depth the service currently nests
     * its view models, so it is found by shape rather than by path.
     */
    private static Json.Object? find_comment_payload (Json.Object object) {
        if (object.has_member ("contentText") && object.has_member ("authorText")) {
            return object;
        }

        foreach (unowned string member in object.get_members ()) {
            // Replies are comments too, and would be mistaken for this one.
            if (member == "replies") {
                continue;
            }

            var child = object.get_member (member);
            if (child == null || child.get_node_type () != Json.NodeType.OBJECT) {
                continue;
            }

            var found = find_comment_payload (child.get_object ());
            if (found != null) {
                return found;
            }
        }

        return null;
    }

    /** Every continuation token in the response, in the order they appear. */
    public static Gee.ArrayList<string> parse_continuation_tokens (string json) throws InnertubeError {
        var tokens = new Gee.ArrayList<string> ();
        var root = parse_root (json);

        var commands = new Gee.ArrayList<Json.Object> ();
        collect_objects (root, "continuationCommand", commands);

        foreach (var command in commands) {
            var token = command.get_string_member_with_default ("token", "");
            if (token != "" && !tokens.contains (token)) {
                tokens.add (token);
            }
        }

        return tokens;
    }

    private static Json.Node parse_root (string json) throws InnertubeError {
        var parser = new Json.Parser ();
        try {
            parser.load_from_data (json);
        } catch (Error e) {
            throw new InnertubeError.PARSE (
                _("The video service sent a response that could not be read.")
            );
        }

        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new InnertubeError.PARSE (
                _("The video service sent a response that could not be read.")
            );
        }

        return root;
    }

    /** Every object stored under `key`, anywhere in the response. */
    private static void collect_objects (
        Json.Node? node,
        string key,
        Gee.ArrayList<Json.Object> found
    ) {
        if (node == null) {
            return;
        }

        if (node.get_node_type () == Json.NodeType.OBJECT) {
            var object = node.get_object ();

            if (object.has_member (key)) {
                var child = object.get_member (key);
                if (child != null && child.get_node_type () == Json.NodeType.OBJECT) {
                    found.add (child.get_object ());
                }
            }

            foreach (unowned string member in object.get_members ()) {
                collect_objects (object.get_member (member), key, found);
            }
        } else if (node.get_node_type () == Json.NodeType.ARRAY) {
            var array = node.get_array ();
            for (uint i = 0; i < array.get_length (); i++) {
                collect_objects (array.get_element (i), key, found);
            }
        }
    }

    // ------------------------------------------------------------------
    // Walking the response
    // ------------------------------------------------------------------

    private static void walk_object (
        Json.Object object,
        Gee.ArrayList<Shelf> shelves,
        Gee.ArrayList<Shelf> stack
    ) {
        foreach (unowned string member in object.get_members ()) {
            var child = object.get_member (member);
            if (child == null) {
                continue;
            }

            walk (member, child, shelves, stack);
        }
    }

    private static void walk (
        string member,
        Json.Node node,
        Gee.ArrayList<Shelf> shelves,
        Gee.ArrayList<Shelf> stack
    ) {
        if (is_skipped (member)) {
            return;
        }

        switch (node.get_node_type ()) {
            case Json.NodeType.OBJECT:
                var object = node.get_object ();
                var opened = false;

                if (is_group (member)) {
                    var title = group_title (object);
                    if (title != null && title != "") {
                        var shelf = new Shelf () { title = title };
                        shelves.add (shelf);
                        stack.add (shelf);
                        opened = true;
                    }
                }

                var item = parse_item (member, object);
                if (item != null) {
                    stack[stack.size - 1].items.add (item);
                }

                walk_object (object, shelves, stack);

                if (opened) {
                    stack.remove_at (stack.size - 1);
                }

                break;
            case Json.NodeType.ARRAY:
                var array = node.get_array ();
                for (uint i = 0; i < array.get_length (); i++) {
                    var element = array.get_element (i);
                    if (element != null) {
                        walk (member, element, shelves, stack);
                    }
                }

                break;
            default:
                break;
        }
    }

    /** Response objects that never contain anything worth showing. */
    private static bool is_skipped (string member) {
        switch (member) {
            case "adSlotRenderer":
            case "displayAdRenderer":
            case "promotedSparklesWebRenderer":
            case "compactPromotedVideoRenderer":
            case "searchPyvRenderer":
            case "chipCloudRenderer":
            case "feedFilterChipBarRenderer":
            case "clarificationRenderer":
            case "statementBannerRenderer":
            case "shortsLockupViewModel":
            case "reelItemRenderer":
            case "reelShelfRenderer":
            case "commentThreadRenderer":
            case "commentRenderer":
            case "feedNudgeRenderer":
                return true;
            default:
                return false;
        }
    }

    /** Response objects that can carry a heading for the results inside them. */
    private static bool is_group (string member) {
        switch (member) {
            case "shelfRenderer":
            case "richShelfRenderer":
            case "richSectionRenderer":
            case "expandedShelfContentsRenderer":
            case "itemSectionRenderer":
            case "gridRenderer":
            case "horizontalListRenderer":
            case "sectionListRenderer":
                return true;
            default:
                return false;
        }
    }

    private static string? group_title (Json.Object object) {
        var title = first_text (object, "title");
        if (title != null && title != "") {
            return title;
        }

        var header = object.get_member ("header");
        if (header != null) {
            var shelf_header = find_object (header, "shelfHeaderRenderer");
            if (shelf_header != null) {
                return first_text (shelf_header, "title");
            }
        }

        return null;
    }

    private static GLib.Object? parse_item (string member, Json.Object object) {
        switch (member) {
            case "videoRenderer":
            case "compactVideoRenderer":
            case "gridVideoRenderer":
            case "playlistVideoRenderer":
                return parse_video (object);
            case "channelRenderer":
                return parse_channel (object);
            case "playlistRenderer":
                return parse_playlist (object);
            case "lockupViewModel":
                return parse_lockup (object);
            default:
                return null;
        }
    }

    // ------------------------------------------------------------------
    // Individual result kinds
    // ------------------------------------------------------------------

    private static Video? parse_video (Json.Object object) {
        var id = object.get_string_member_with_default ("videoId", "");
        if (id == "") {
            return null;
        }

        var video = new Video () { id = id };
        video.title = text_of (object.get_member ("title")) ?? "";
        video.channel_name = first_text (object, "ownerText")
            ?? first_text (object, "longBylineText")
            ?? first_text (object, "shortBylineText")
            ?? "";
        video.channel_id = byline_channel_id (object);
        video.channel_avatar = channel_avatar (object);
        video.thumbnail_uri = thumbnail_of (object, "thumbnail");
        video.duration = first_text (object, "lengthText") ?? "";
        video.published = first_text (object, "publishedTimeText") ?? "";
        video.view_count = first_text (object, "viewCountText")
            ?? first_text (object, "shortViewCountText")
            ?? "";
        video.summary = snippet_of (object);

        string? overlay_text;
        string overlay_style;
        read_time_status (object, out overlay_text, out overlay_style);

        if (overlay_style == "LIVE") {
            video.is_live = true;
            video.duration = "";
        } else if (video.duration == "" && overlay_text != null) {
            video.duration = overlay_text;
        }

        return video;
    }

    private static Channel? parse_channel (Json.Object object) {
        var id = object.get_string_member_with_default ("channelId", "");
        if (id == "") {
            return null;
        }

        var channel = new Channel () { id = id };
        channel.name = text_of (object.get_member ("title")) ?? "";
        channel.avatar_uri = thumbnail_of (object, "thumbnail");
        channel.description = first_text (object, "descriptionSnippet") ?? "";
        channel.handle = handle_of (object);
        channel.subscriber_count = subscriber_text (object);
        channel.video_count = video_count_text (object);
        return channel;
    }

    private static Playlist? parse_playlist (Json.Object object) {
        var id = object.get_string_member_with_default ("playlistId", "");
        if (id == "") {
            return null;
        }

        var playlist = new Playlist () { id = id };
        playlist.title = text_of (object.get_member ("title")) ?? "";
        playlist.thumbnail_uri = thumbnail_of (object, "thumbnail");
        playlist.channel_name = first_text (object, "shortBylineText")
            ?? first_text (object, "longBylineText")
            ?? "";
        playlist.video_count = first_text (object, "videoCountShortText")
            ?? first_text (object, "videoCountText")
            ?? "";
        return playlist;
    }

    private static GLib.Object? parse_lockup (Json.Object object) {
        var id = object.get_string_member_with_default ("contentId", "");
        if (id == "") {
            return null;
        }

        var kind = object.get_string_member_with_default ("contentType", "");
        var title = lockup_title (object);
        var thumbnail = thumbnail_of (object, "contentImage");
        var metadata = content_metadata_parts (object.get_member ("metadata"));

        switch (kind) {
            case "LOCKUP_CONTENT_TYPE_PLAYLIST":
                var playlist = new Playlist () {
                    id = id,
                    title = title,
                    thumbnail_uri = thumbnail
                };

                if (metadata.size > 0) {
                    playlist.channel_name = metadata[0];
                }

                playlist.video_count = part_containing (metadata, "video");
                return playlist;
            case "LOCKUP_CONTENT_TYPE_CHANNEL":
                var channel = new Channel () {
                    id = id,
                    name = title,
                    avatar_uri = thumbnail
                };

                channel.subscriber_count = part_containing (metadata, "subscriber");
                channel.video_count = part_containing (metadata, "video");
                return channel;
            default:
                var views = part_containing (metadata, "view");
                var age = part_containing (metadata, "ago");

                var video = new Video () {
                    id = id,
                    title = title,
                    thumbnail_uri = thumbnail,
                    view_count = views,
                    published = age
                };

                // Whatever is left over is the name of the channel.
                foreach (var part in metadata) {
                    if (part != views && part != age) {
                        video.channel_name = part;
                        break;
                    }
                }
                video.duration = lockup_badge_text (object);
                video.channel_id = find_string (object.get_member ("rendererContext"), "browseId") ?? "";

                if (video.duration.casefold () == "live") {
                    video.is_live = true;
                    video.duration = "";
                }

                return video;
        }
    }

    private static Video? parse_primary (Json.Object root, string? video_id) {
        var contents = root.get_member ("contents");
        var info = find_object (contents, "videoPrimaryInfoRenderer");
        if (info == null) {
            return null;
        }

        var video = new Video () { id = video_id ?? "" };
        video.title = first_text (info, "title") ?? "";
        video.view_count = primary_view_count (info);
        video.published = first_text (info, "dateText") ?? "";

        var owner = find_object (contents, "videoOwnerRenderer");
        if (owner != null) {
            video.channel_name = text_of (owner.get_member ("title")) ?? "";
            video.channel_id = find_string (owner.get_member ("title"), "browseId") ?? "";
            video.channel_avatar = fix_url (best_url (owner.get_member ("thumbnail")) ?? "");
        }

        var secondary = find_object (contents, "videoSecondaryInfoRenderer");
        if (secondary != null) {
            var attributed = secondary.get_member ("attributedDescription");
            if (attributed != null && attributed.get_node_type () == Json.NodeType.OBJECT) {
                video.summary = text_of (attributed.get_object ().get_member ("content")) ?? "";
            } else {
                video.summary = first_text (secondary, "description") ?? "";
            }
        }

        return video;
    }

    private static string primary_view_count (Json.Object info) {
        var node = info.get_member ("viewCount");
        if (node == null) {
            return "";
        }

        var renderer = find_object (node, "videoViewCountRenderer");
        if (renderer != null) {
            var text = first_text (renderer, "viewCount");
            if (text != null && text != "") {
                return text;
            }
        }

        return text_of (node) ?? "";
    }

    private static Channel? parse_page_channel (Json.Object root) {
        var metadata = find_object (root.get_member ("metadata"), "channelMetadataRenderer");
        if (metadata == null) {
            return null;
        }

        var channel = new Channel ();
        channel.id = metadata.get_string_member_with_default ("externalId", "");
        channel.name = metadata.get_string_member_with_default ("title", "");
        channel.description = metadata.get_string_member_with_default ("description", "");
        channel.avatar_uri = fix_url (best_url (metadata.get_member ("avatar")) ?? "");

        var vanity = metadata.get_string_member_with_default ("vanityChannelUrl", "");
        var at = vanity.index_of ("/@");
        if (at >= 0) {
            channel.handle = vanity.substring (at + 1);
        }

        var header_parts = content_metadata_parts (root.get_member ("header"));
        channel.subscriber_count = part_containing (header_parts, "subscriber");
        channel.video_count = part_containing (header_parts, "video");

        if (channel.id == "" && channel.name == "") {
            return null;
        }

        return channel;
    }

    // ------------------------------------------------------------------
    // Continuation
    // ------------------------------------------------------------------

    /**
     * Returns the first "show more" token in the response. Only views that ask
     * for one page at a time use this; the watch page and the landing page
     * ignore it because their tokens address individual sections.
     */
    private static string? first_continuation (Json.Node? root) {
        var item = find_object (root, "continuationItemRenderer");
        if (item == null) {
            return null;
        }

        var command = find_object_in (item, "continuationCommand");
        if (command == null) {
            return null;
        }

        var token = command.get_string_member_with_default ("token", "");
        return token == "" ? null : token;
    }

    /** The one line of description the service shows under a result. */
    private static string snippet_of (Json.Object object) {
        var node = object.get_member ("detailedMetadataSnippets");
        if (node == null || node.get_node_type () != Json.NodeType.ARRAY) {
            return "";
        }

        var array = node.get_array ();
        if (array.get_length () == 0) {
            return "";
        }

        var element = array.get_element (0);
        if (element == null || element.get_node_type () != Json.NodeType.OBJECT) {
            return "";
        }

        return first_text (element.get_object (), "snippetText") ?? "";
    }

    // ------------------------------------------------------------------
    // Text helpers
    // ------------------------------------------------------------------

    private static string? text_of (Json.Node? node) {
        if (node == null) {
            return null;
        }

        switch (node.get_node_type ()) {
            case Json.NodeType.VALUE:
                return string_value (node);
            case Json.NodeType.OBJECT:
                var object = node.get_object ();
                foreach (string member in new string[] { "simpleText", "content" }) {
                    if (object.has_member (member)) {
                        var value = string_value (object.get_member (member));
                        if (value != null && value != "") {
                            return value;
                        }
                    }
                }

                return runs_text (object);
            default:
                return null;
        }
    }

    private static string? runs_text (Json.Object object) {
        var node = object.get_member ("runs");
        if (node == null || node.get_node_type () != Json.NodeType.ARRAY) {
            return null;
        }

        var array = node.get_array ();
        var builder = new StringBuilder ();
        for (uint i = 0; i < array.get_length (); i++) {
            var element = array.get_element (i);
            if (element == null || element.get_node_type () != Json.NodeType.OBJECT) {
                continue;
            }

            var text = text_of (element.get_object ().get_member ("text"));
            if (text != null) {
                builder.append (text);
            }
        }

        var result = builder.str;
        return result == "" ? null : result;
    }

    private static string? first_text (Json.Object object, string member) {
        if (!object.has_member (member)) {
            return null;
        }

        return text_of (object.get_member (member));
    }

    private static string? string_value (Json.Node? node) {
        if (node == null || node.get_node_type () != Json.NodeType.VALUE) {
            return null;
        }

        if (node.get_value_type () != typeof (string)) {
            return null;
        }

        return node.get_string ();
    }

    private static string? find_string (Json.Node? node, string key) {
        if (node == null) {
            return null;
        }

        switch (node.get_node_type ()) {
            case Json.NodeType.OBJECT:
                var object = node.get_object ();
                if (object.has_member (key)) {
                    var value = string_value (object.get_member (key));
                    if (value != null && value != "") {
                        return value;
                    }
                }

                foreach (unowned string member in object.get_members ()) {
                    var child = object.get_member (member);
                    if (child == null || child.get_node_type () == Json.NodeType.VALUE) {
                        continue;
                    }

                    var found = find_string (child, key);
                    if (found != null && found != "") {
                        return found;
                    }
                }

                return null;
            case Json.NodeType.ARRAY:
                var array = node.get_array ();
                for (uint i = 0; i < array.get_length (); i++) {
                    var found = find_string (array.get_element (i), key);
                    if (found != null && found != "") {
                        return found;
                    }
                }

                return null;
            default:
                return null;
        }
    }

    private static Json.Object? find_object (Json.Node? node, string key) {
        if (node == null) {
            return null;
        }

        switch (node.get_node_type ()) {
            case Json.NodeType.OBJECT:
                return find_object_in (node.get_object (), key);
            case Json.NodeType.ARRAY:
                var array = node.get_array ();
                for (uint i = 0; i < array.get_length (); i++) {
                    var found = find_object (array.get_element (i), key);
                    if (found != null) {
                        return found;
                    }
                }

                return null;
            default:
                return null;
        }
    }

    /** The first object member named `key` anywhere below `object`. */
    private static Json.Object? find_object_in (Json.Object object, string key) {
        if (object.has_member (key)) {
            var child = object.get_member (key);
            if (child != null && child.get_node_type () == Json.NodeType.OBJECT) {
                return child.get_object ();
            }
        }

        foreach (unowned string member in object.get_members ()) {
            var child = object.get_member (member);
            if (child == null || child.get_node_type () == Json.NodeType.VALUE) {
                continue;
            }

            var found = find_object (child, key);
            if (found != null) {
                return found;
            }
        }

        return null;
    }

    // ------------------------------------------------------------------
    // Thumbnails
    // ------------------------------------------------------------------

    private static string thumbnail_of (Json.Object object, string member) {
        return fix_url (best_url (object.get_member (member)) ?? "");
    }

    /**
     * Finds the largest image referenced anywhere below `node`. Both the
     * `thumbnails` and the newer `sources` arrays are accepted, because the
     * service uses them interchangeably.
     */
    private static string? best_url (Json.Node? node) {
        if (node == null) {
            return null;
        }

        switch (node.get_node_type ()) {
            case Json.NodeType.OBJECT:
                var object = node.get_object ();

                foreach (unowned string member in object.get_members ()) {
                    if (member != "thumbnails" && member != "sources") {
                        continue;
                    }

                    var child = object.get_member (member);
                    if (child == null || child.get_node_type () != Json.NodeType.ARRAY) {
                        continue;
                    }

                    var url = last_url (child.get_array ());
                    if (url != null && url != "") {
                        return url;
                    }
                }

                foreach (unowned string member in object.get_members ()) {
                    var child = object.get_member (member);
                    if (child == null || child.get_node_type () == Json.NodeType.VALUE) {
                        continue;
                    }

                    var url = best_url (child);
                    if (url != null && url != "") {
                        return url;
                    }
                }

                return null;
            case Json.NodeType.ARRAY:
                var array = node.get_array ();
                for (uint i = 0; i < array.get_length (); i++) {
                    var url = best_url (array.get_element (i));
                    if (url != null && url != "") {
                        return url;
                    }
                }

                return null;
            default:
                return null;
        }
    }

    private static string? last_url (Json.Array array) {
        string? url = null;
        for (uint i = 0; i < array.get_length (); i++) {
            var element = array.get_element (i);
            if (element == null || element.get_node_type () != Json.NodeType.OBJECT) {
                continue;
            }

            var candidate = element.get_object ().get_string_member_with_default ("url", "");
            if (candidate != "") {
                url = candidate;
            }
        }

        return url;
    }

    private static string fix_url (string url) {
        if (url.has_prefix ("//")) {
            return "https:%s".printf (url);
        }

        return url;
    }

    // ------------------------------------------------------------------
    // Metadata rows
    // ------------------------------------------------------------------

    /** Flattens the rows of every metadata block found below `node`. */
    private static Gee.ArrayList<string> content_metadata_parts (Json.Node? node) {
        var parts = new Gee.ArrayList<string> ();
        var content = find_object (node, "contentMetadataViewModel");
        if (content == null) {
            return parts;
        }

        var rows = content.get_member ("metadataRows");
        if (rows == null || rows.get_node_type () != Json.NodeType.ARRAY) {
            return parts;
        }

        var array = rows.get_array ();
        for (uint i = 0; i < array.get_length (); i++) {
            var row = array.get_element (i);
            if (row == null || row.get_node_type () != Json.NodeType.OBJECT) {
                continue;
            }

            var row_parts = row.get_object ().get_member ("metadataParts");
            if (row_parts == null || row_parts.get_node_type () != Json.NodeType.ARRAY) {
                continue;
            }

            var part_array = row_parts.get_array ();
            for (uint j = 0; j < part_array.get_length (); j++) {
                var part = part_array.get_element (j);
                if (part == null || part.get_node_type () != Json.NodeType.OBJECT) {
                    continue;
                }

                var text = text_of (part.get_object ().get_member ("text"));
                if (text != null && text != "") {
                    parts.add (text);
                }
            }
        }

        return parts;
    }

    private static string part_containing (Gee.ArrayList<string> parts, string needle) {
        foreach (var part in parts) {
            if (part.casefold ().contains (needle)) {
                return part;
            }
        }

        return "";
    }

    private static string lockup_title (Json.Object object) {
        var view_model = find_object (object.get_member ("metadata"), "lockupMetadataViewModel");
        if (view_model == null) {
            return "";
        }

        return text_of (view_model.get_member ("title")) ?? "";
    }

    private static string lockup_badge_text (Json.Object object) {
        var badge = find_object (object.get_member ("contentImage"), "thumbnailBadgeViewModel");
        if (badge == null) {
            return "";
        }

        return text_of (badge.get_member ("text")) ?? "";
    }

    // ------------------------------------------------------------------
    // Misc field extraction
    // ------------------------------------------------------------------

    private static string byline_channel_id (Json.Object object) {
        foreach (string member in new string[] { "ownerText", "longBylineText", "shortBylineText" }) {
            var id = find_string (object.get_member (member), "browseId");
            if (id != null && id != "") {
                return id;
            }
        }

        return "";
    }

    private static string channel_avatar (Json.Object object) {
        var url = best_url (object.get_member ("channelThumbnailSupportedRenderers"));
        if (url == null || url == "") {
            url = best_url (object.get_member ("avatar"));
        }

        return fix_url (url ?? "");
    }

    private static void read_time_status (Json.Object object, out string? text, out string style) {
        text = null;
        style = "";

        var node = object.get_member ("thumbnailOverlays");
        if (node == null || node.get_node_type () != Json.NodeType.ARRAY) {
            return;
        }

        var array = node.get_array ();
        for (uint i = 0; i < array.get_length (); i++) {
            var element = array.get_element (i);
            if (element == null || element.get_node_type () != Json.NodeType.OBJECT) {
                continue;
            }

            var renderer = find_object (element, "thumbnailOverlayTimeStatusRenderer");
            if (renderer == null) {
                continue;
            }

            text = text_of (renderer.get_member ("text"));
            style = renderer.get_string_member_with_default ("style", "");
            return;
        }
    }

    private static string handle_of (Json.Object object) {
        var candidate = first_text (object, "subscriberCountText") ?? "";
        if (candidate.has_prefix ("@")) {
            return candidate;
        }

        return "";
    }

    private static string subscriber_text (Json.Object object) {
        foreach (string member in new string[] { "videoCountText", "subscriberCountText" }) {
            var candidate = first_text (object, member);
            if (candidate != null && candidate.casefold ().contains ("subscriber")) {
                return candidate;
            }
        }

        return "";
    }

    private static string video_count_text (Json.Object object) {
        var candidate = first_text (object, "videoCountText") ?? "";
        if (candidate.casefold ().contains ("video")) {
            return candidate;
        }

        return "";
    }
}
