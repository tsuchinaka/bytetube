/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * What signing in with a code hands the app, kept between restarts.
 *
 * Only the refresh token can mint new access, so it is the one that has to
 * survive: it is written to the user's own data directory, readable only by
 * them, next to the session the browser way keeps. The access token lives in
 * memory and is renewed from it whenever it runs out, so the app never asks
 * twice. Everything is deleted again on signing out.
 */

public class ByteTube.TokenStore : GLib.Object {
    private static TokenStore? instance = null;

    private string refresh_token = "";
    private string access_token = "";
    private int64 access_expires_at = 0;

    public signal void changed ();

    /** Whether the app holds a sign-in that survives a restart. */
    public bool signed_in {
        get {
            return refresh_token != "";
        }
    }

    public string account_name { get; private set; default = ""; }
    public string account_email { get; private set; default = ""; }
    public string account_avatar { get; private set; default = ""; }

    public static unowned TokenStore get_default () {
        if (instance == null) {
            instance = new TokenStore ();
        }

        return instance;
    }

    private static string tokens_path () {
        return GLib.Path.build_filename (
            GLib.Environment.get_user_data_dir (),
            "bytetube",
            "tokens"
        );
    }

    private TokenStore () {
        load_saved ();
    }

    /**
     * An access token that works now, renewing it first when it has run out.
     * Null when there is nothing to renew with.
     */
    public async string? valid_token () {
        if (refresh_token == "") {
            return null;
        }

        // A minute of leeway, so the token cannot die between this check and
        // the request that uses it.
        if (access_token != "" && GLib.get_real_time () / 1000000 < access_expires_at - 60) {
            return access_token;
        }

        try {
            var renewed = yield DeviceAuth.refresh (refresh_token);
            access_token = renewed.access_token;
            access_expires_at = GLib.get_real_time () / 1000000 + renewed.expires_in;

            // A renewal does not always repeat the refresh token; when it
            // does not, the old one carries on.
            if (renewed.refresh_token != "") {
                refresh_token = renewed.refresh_token;
            }

            save ();
            return access_token;
        } catch (DeviceError e) {
            debug ("Could not renew the sign-in: %s", e.message);
            return null;
        }
    }

    /** Keeps what an approved code returned, profile included. */
    public void save_tokens (DeviceTokens tokens) {
        if (tokens.refresh_token != "") {
            refresh_token = tokens.refresh_token;
        }

        access_token = tokens.access_token;
        access_expires_at = GLib.get_real_time () / 1000000 + tokens.expires_in;

        if (tokens.id_token != "") {
            string name;
            string email;
            string avatar;
            DeviceAuth.read_profile (tokens.id_token, out name, out email, out avatar);

            if (name != "") {
                account_name = name;
            }

            if (email != "") {
                account_email = email;
            }

            if (avatar != "") {
                account_avatar = avatar;
            }
        }

        save ();
        changed ();
    }

    /** Forgets the sign-in, for signing out. Takes the token with it. */
    public void clear () {
        var handed_back = refresh_token;

        refresh_token = "";
        access_token = "";
        access_expires_at = 0;
        account_name = "";
        account_email = "";
        account_avatar = "";

        GLib.FileUtils.unlink (tokens_path ());
        changed ();

        // Best effort in the background: the local sign-in is already gone
        // either way.
        if (handed_back != "") {
            revoke_later.begin (handed_back);
        }
    }

    private static async void revoke_later (string handed_back) {
        yield DeviceAuth.revoke (handed_back);
    }

    private void load_saved () {
        var path = tokens_path ();
        if (!GLib.FileUtils.test (path, GLib.FileTest.EXISTS)) {
            return;
        }

        try {
            string contents;
            GLib.FileUtils.get_contents (path, out contents);

            var parser = new Json.Parser ();
            parser.load_from_data (contents);

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                return;
            }

            var saved = root.get_object ();
            refresh_token = saved.get_string_member_with_default ("refresh_token", "");
            account_name = saved.get_string_member_with_default ("account_name", "");
            account_email = saved.get_string_member_with_default ("account_email", "");
            account_avatar = saved.get_string_member_with_default ("account_avatar", "");
        } catch (Error e) {
            debug ("Could not read the saved sign-in: %s", e.message);
        }
    }

    private void save () {
        if (refresh_token == "") {
            GLib.FileUtils.unlink (tokens_path ());
            return;
        }

        var saved = new Json.Object ();
        saved.set_string_member ("refresh_token", refresh_token);
        saved.set_string_member ("account_name", account_name);
        saved.set_string_member ("account_email", account_email);
        saved.set_string_member ("account_avatar", account_avatar);

        var generator = new Json.Generator ();
        generator.root = new Json.Node.alloc ().init_object (saved);

        try {
            size_t length = 0;
            var text = generator.to_data (out length);
            GLib.DirUtils.create_with_parents (
                GLib.Path.get_dirname (tokens_path ()), 0700);
            GLib.FileUtils.set_contents (tokens_path (), text);
            GLib.FileUtils.chmod (tokens_path (), 0600);
        } catch (Error e) {
            warning ("Could not save the sign-in: %s", e.message);
        }
    }
}
