# ByteTube

A native desktop client for watching online video, built with Vala, GTK 4 and
Granite for elementary OS.

Browse, search, follow channels, keep a watch history and a Watch Later queue,
and play video natively — no embedded web player, no browser.

## How playback works

ByteTube plays video the way the service's own applications do, not by
embedding a web page:

- **`appsrc` → GStreamer.** Video and audio are demuxed, decoded and rendered by
  GStreamer. Frames are drawn into a `Gtk.Picture`; audio goes to the system
  mixer.
- **SABR, not file downloads.** The service no longer serves a single file to
  download. The client asks its media server for a slice of one video stream and
  one audio stream at a time, reporting how much of each it already holds, and
  the server answers with the next slice as a run of length-delimited parts
  (`src/Services/UmpReader.vala`). See `src/Services/SabrClient.vala` and
  `src/Services/SabrRequest.vala`.
- **Signing in.** The service refuses every signed-out client outright. Instead
  of asking for a password, the app opens the real sign-in page in a web view
  and then reuses the resulting cookies for its own requests
  (`src/Services/CookieStore.vala`).
- **Starting fast.** The client version, visitor identifier and player
  signature the service demands are read from the site, not hard-coded — and
  cached for half a day (`src/Services/SiteConfig.vala`), prefetched at
  startup, and served over one shared HTTP session
  (`src/Services/HttpSession.vala`). A second video starts in about a second.


The protocol work follows the reverse-engineering in
[LuanRT/googlevideo](https://github.com/LuanRT/googlevideo) and
[mthwJsmith/sabr-rs](https://github.com/mthwJsmith/sabr-rs).

## Building

```bash
meson setup build --prefix=/usr
ninja -C build
sudo ninja -C build install
```

### Running without installing

```bash
glib-compile-schemas --targetdir=/tmp/bytetube-schemas .
GSETTINGS_SCHEMA_DIR=/tmp/bytetube-schemas ./build/src/io.github.bytetube.ByteTube
```

## Packaging

```bash
flatpak-builder build io.github.bytetube.ByteTube.yml --user --install --force-clean
```

## Translations

User-facing strings are marked for translation but no catalogues are shipped
yet. To add them, follow
[the translations guide](https://docs.elementary.io/develop/writing-apps/our-first-app/translations)
— the `po/` directory and the `subdir('po')` call in `meson.build` are ready
for it.
