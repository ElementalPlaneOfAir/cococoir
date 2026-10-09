# fortress/media-layout — the ONE place the media directory layout is derived.
#
# jellyfin, media (the *arr wiring), radarr and sonarr all need the same
# paths. They used to each re-derive them from `dataRoot`, which meant
# jellyfin pointed at `mediaRoot` (/media/entertain on amon-sul) while
# media.nix registered root folders under `${dataRoot}/media/...` and the
# wiring failed with a curl 22 on a path that does not exist. One layout,
# one derivation, every consumer reads it.
{
  config,
  lib,
  ...
}: {
  options.fortress.media.layout = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    internal = true;
    readOnly = true;
    description = ''
      Derived media directory layout. Internal: services read it, customers
      never set it. `root` follows `fortress.services.jellyfin.mediaRoot`
      (which defaults to `<dataRoot>/media`), so every consumer agrees with
      Jellyfin about where media actually lives.
    '';
  };

  config = let
    dataRoot = config.fortress.storage.dataRoot;
    jellyfinCfg = config.fortress.services.jellyfin;
    root =
      if (jellyfinCfg.mediaRoot or null) == null
      then "${dataRoot}/media"
      else jellyfinCfg.mediaRoot;
  in {
    assertions = [
      {
        assertion = root != "";
        message = "fortress.media.layout: derived media root must not be empty";
      }
    ];

    fortress.media.layout = {
      inherit root;
      movies = "${root}/movies";
      shows = "${root}/shows";
      music = "${root}/music";
      moviesLibrary = "${root}/movies/library";
      showsLibrary = "${root}/shows/library";
      moviesDownloads = "${root}/movies/downloads";
      showsDownloads = "${root}/shows/downloads";
      metadata = "${dataRoot}/jellyfin/metadata";
    };
  };
}
