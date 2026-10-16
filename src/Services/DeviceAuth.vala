/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Signing in the way a TV does: the app shows a code, the user enters it on
 * a device that is already signed in, and the app is handed tokens.
 *
 * Typing a Google password into an embedded browser is exactly what Google
 * tries to stop, so that road only gets worse. A code the user approves
 * elsewhere asks for no password at all, and the tokens it returns refresh
 * themselves until the user signs out.
 *
 * This speaks YouTube TV's own sign-in: its device endpoints with its own
 * OAuth client, the same one every TV app carries and the same one Kodi's
 * YouTube addon has shipped for years. Nobody has to register anything; the
 * consent screen even says YouTube, because as far as Google is concerned
 * this signs in like a TV. If Google ever rotates those credentials, this
 * one place is where the new ones go.
 */

public errordomain ByteTube.DeviceError {
    DENIED,
    EXPIRED,
    FAILED
}

/** A code waiting to be approved, and where to approve it. */
public class ByteTube.DeviceCode : GLib.Object {
    public string device_code { get; set; }
    public string user_code { get; set; }
    public string verification_url { get; set; default = "https://www.youtube.com/activate"; }
    public uint interval_seconds { get; set; default = 5; }
    public uint expires_in { get; set; default = 1800; }

    public DeviceCode (string device_code, string user_code) {
        Object (
            device_code: device_code,
            user_code: user_code
        );
    }
}

/** What the service hands back once a code is approved. */
public class ByteTube.DeviceTokens : GLib.Object {
    public string access_token { get; set; default = ""; }
    public int64 expires_in { get; set; default = 0; }
    public string refresh_token { get; set; default = ""; }
    public string id_token { get; set; default = ""; }
}

public class ByteTube.DeviceAuth : GLib.Object {
    private const string DEVICE_CODE_URI = "https://www.youtube.com/o/oauth2/device/code";
    private const string TOKEN_URI = "https://www.youtube.com/o/oauth2/token";
    private const string REVOKE_URI = "https://www.youtube.com/o/oauth2/revoke";
    private const string DEVICE_GRANT = "http://oauth.net/grant_type/device/1.0";
    private const string REFERER = "https://www.youtube.com/tv";

    /**
     * YouTube TV's own OAuth client, as shipped in every TV app and published
     * with Kodi's YouTube addon. Signing in with it is what makes the consent
     * screen offer the account's YouTube channel rather than some side project.
     */
    public const string CLIENT_ID =
        "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com";
    private const string CLIENT_SECRET = "SboVhoG9s0rNafixCSGGKXAT";

    /** Asks for a code the user can approve elsewhere. */
    public static async DeviceCode request_code () throws DeviceError {
        var body = "client_id=%s&scope=%s".printf (
            GLib.Uri.escape_string (CLIENT_ID),
            GLib.Uri.escape_string ("openid profile email https://www.googleapis.com/auth/youtube")
        );

        var root = yield post_form (DEVICE_CODE_URI, body);

        var device = root.get_string_member_with_default ("device_code", "");
        var user = root.get_string_member_with_default ("user_code", "");

        if (device == "" || user == "") {
            throw new DeviceError.FAILED (describe (root));
        }

        return new DeviceCode (device, user) {
            verification_url = root.get_string_member_with_default (
                "verification_url", "https://www.youtube.com/activate"),
            interval_seconds = (uint) root.get_int_member_with_default ("interval", 5),
            expires_in = (uint) root.get_int_member_with_default ("expires_in", 1800)
        };
    }

    /**
     * Waits until the code is approved, then returns the tokens. Throws
     * DENIED if the user rejects it and EXPIRED if it runs out of time; both
     * just mean asking for a fresh code.
     */
    public static async DeviceTokens poll_for_approval (
        DeviceCode code,
        GLib.Cancellable? cancellable = null
    ) throws DeviceError {
        var wait = code.interval_seconds;
        var deadline = GLib.get_monotonic_time () + (int64) code.expires_in * 1000000;

        while (GLib.get_monotonic_time () < deadline) {
            if (cancellable != null && cancellable.is_cancelled ()) {
                throw new DeviceError.FAILED (_("Cancelled."));
            }

            yield nap (wait);

            var body = "client_id=%s&client_secret=%s&code=%s&grant_type=%s".printf (
                GLib.Uri.escape_string (CLIENT_ID),
                GLib.Uri.escape_string (CLIENT_SECRET),
                GLib.Uri.escape_string (code.device_code),
                GLib.Uri.escape_string (DEVICE_GRANT)
            );

            // A poll that is not an approval still answers HTTP 200 here, with
            // the reason in an error member rather than the status.
            string error = "";
            DeviceTokens? approved = null;
            try {
                var root = yield post_form (TOKEN_URI, body, cancellable);
                if (root.has_member ("error")) {
                    error = root.get_string_member_with_default ("error", "");
                } else {
                    approved = tokens_from (root);
                }
            } catch (DeviceError e) {
                error = e.message;
            }

            if (approved != null) {
                return approved;
            }

            if (error == "" || error == "authorization_pending") {
                continue;
            }

            if (error == "slow_down") {
                wait += 5;
                continue;
            }

            if (error == "access_denied") {
                throw new DeviceError.DENIED (
                    _("The sign-in was not approved."));
            }

            if (error == "expired_token" || error == "invalid_grant") {
                throw new DeviceError.EXPIRED (
                    _("The code expired before it was approved."));
            }

            throw new DeviceError.FAILED (error);
        }

        throw new DeviceError.EXPIRED (
            _("The code expired before it was approved."));
    }

    /** Trades a stored refresh token for a fresh access token. */
    public static async DeviceTokens refresh (string refresh_token) throws DeviceError {
        var body = "client_id=%s&client_secret=%s&refresh_token=%s&grant_type=refresh_token".printf (
            GLib.Uri.escape_string (CLIENT_ID),
            GLib.Uri.escape_string (CLIENT_SECRET),
            GLib.Uri.escape_string (refresh_token)
        );

        return tokens_from (yield post_form (TOKEN_URI, body));
    }

    /** Takes back a refresh token, for signing out for real. */
    public static async void revoke (string refresh_token) {
        var body = "token=%s".printf (GLib.Uri.escape_string (refresh_token));

        try {
            yield post_form (REVOKE_URI, body);
        } catch (DeviceError e) {
            debug ("Could not revoke the sign-in: %s", e.message);
        }
    }

    /**
     * Reads who signed in out of the identity token: its payload is signed by
     * Google and carries the name, address and picture, so no API call with
     * its own key is needed to greet the user.
     */
    public static void read_profile (
        string id_token,
        out string name,
        out string email,
        out string avatar
    ) {
        name = "";
        email = "";
        avatar = "";

        var pieces = id_token.split (".");
        if (pieces.length != 3) {
            return;
        }

        // The web-safe alphabet back to the plain one, with its padding back.
        var encoded = pieces[1].replace ("-", "+").replace ("_", "/");
        while (encoded.length % 4 != 0) {
            encoded += "=";
        }

        var decoded = GLib.Base64.decode (encoded);
        if (decoded.length == 0) {
            return;
        }

        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((string) decoded);

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                return;
            }

            var claims = root.get_object ();
            name = claims.get_string_member_with_default ("name", "");
            email = claims.get_string_member_with_default ("email", "");
            avatar = claims.get_string_member_with_default ("picture", "");
        } catch (Error e) {
            debug ("Could not read the identity token: %s", e.message);
        }
    }

    private static DeviceTokens tokens_from (Json.Object root) throws DeviceError {
        var access = root.get_string_member_with_default ("access_token", "");
        if (access == "") {
            throw new DeviceError.FAILED (describe (root));
        }

        return new DeviceTokens () {
            access_token = access,
            expires_in = root.get_int_member_with_default ("expires_in", 3600),
            refresh_token = root.get_string_member_with_default ("refresh_token", ""),
            id_token = root.get_string_member_with_default ("id_token", "")
        };
    }

    private static string describe (Json.Object root) {
        var error = root.get_string_member_with_default ("error", "");
        if (error != "") {
            return error;
        }

        return _("The sign-in service did not answer as expected.");
    }

    private static async Json.Object post_form (
        string uri,
        string body,
        GLib.Cancellable? cancellable = null
    ) throws DeviceError {
        var message = new Soup.Message ("POST", uri);
        message.request_headers.append ("Referer", REFERER);
        message.set_request_body_from_bytes (
            "application/x-www-form-urlencoded",
            new GLib.Bytes (body.data)
        );

        GLib.Bytes response;
        try {
            response = yield HttpSession.get_shared ().send_and_read_async (
                message, GLib.Priority.DEFAULT, cancellable);
        } catch (Error e) {
            throw new DeviceError.FAILED (e.message);
        }

        Json.Node? root = null;
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((string) response.get_data ());
            root = parser.get_root ();
        } catch (Error e) {
            throw new DeviceError.FAILED (e.message);
        }

        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new DeviceError.FAILED (
                _("The sign-in service did not answer as expected."));
        }

        var object = root.get_object ();
        if (message.status_code != Soup.Status.OK) {
            throw new DeviceError.FAILED (describe (object));
        }

        return object;
    }

    private static async void nap (uint seconds) {
        // Slept off a second at a time; the poll loop checks for giving up
        // between them, and the request itself carries the cancellable, so
        // cancelling stops waiting at once either way.
        for (uint i = 0; i < seconds; i++) {
            var source = new GLib.TimeoutSource.seconds (1);
            source.set_callback (() => {
                nap.callback ();
                return false;
            });
            source.attach (GLib.MainContext.get_thread_default ());
            yield;
        }
    }
}
