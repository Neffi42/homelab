locals {
  library_options = {
    enable_photos                                = true
    enable_realtime_monitor                      = true
    enable_chapter_image_extraction              = false
    extract_chapters_during_library_scan         = false
    enable_trickplay_image_extraction            = false
    extract_trickplay_images_during_library_scan = false
    save_local_metadata                          = false
    enable_automatic_series_grouping             = false
    season_zero_display_name                     = "Specials"
    metadata_savers                              = []
    local_metadata_reader_order                  = ["Nfo"]
    subtitle_fetchers                            = ["Open Subtitles"]
  }
}

resource "jellyfin_library" "movies" {
  name            = "Movies"
  collection_type = "movies"
  paths           = ["/media/Movies"]

  library_options = merge(local.library_options, {
    type_options = [
      {
        type                   = "Movie"
        metadata_fetchers      = ["TheMovieDb", "The Open Movie Database"]
        image_fetchers         = ["TheMovieDb", "The Open Movie Database", "Embedded Image Extractor", "Screen Grabber"]
        similar_item_providers = ["Local Genre/Tag"]
      },
    ]
  })
}

resource "jellyfin_library" "shows" {
  name            = "Shows"
  collection_type = "tvshows"
  paths           = ["/media/Shows"]

  library_options = merge(local.library_options, {
    type_options = [
      {
        type                   = "Series"
        metadata_fetchers      = ["TheMovieDb", "The Open Movie Database"]
        image_fetchers         = ["TheMovieDb"]
        similar_item_providers = ["Local Genre/Tag"]
      },
      {
        type                   = "Season"
        metadata_fetchers      = ["TheMovieDb"]
        image_fetchers         = ["TheMovieDb"]
        similar_item_providers = []
      },
      {
        type                   = "Episode"
        metadata_fetchers      = ["TheMovieDb", "The Open Movie Database"]
        image_fetchers         = ["TheMovieDb", "The Open Movie Database", "Embedded Image Extractor", "Screen Grabber"]
        similar_item_providers = []
      },
    ]
  })
}
