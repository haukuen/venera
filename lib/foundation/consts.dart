/// Window size classes from the Material 3 adaptive guidance:
/// compact < 600dp, medium 600-840dp, expanded >= 840dp.
///
/// The app's navigation follows them: below [changePoint] the nav pane takes
/// its phone (bottom bar) form, at [changePoint2] it fully expands into the
/// desktop side rail.
const changePoint = 600;

/// If window width is less than this value, it is considered as tablet.
///
/// If it is more than this value, it is considered as desktop.
const changePoint2 = 1300;

/// Minimum window width for a two-pane master/detail layout (e.g. a side
/// list beside a detail pane). Shared by the favorites and settings shells so
/// the two implementations cannot drift apart.
///
/// 720dp sits inside the medium window size class, where a list-detail
/// layout is recommended over stacking.
const changePointTwoPane = 720;

/// Default user agent for http requests.
const webUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36";

/// Pages for all comics is started from this value.
const firstPage = 1;

/// Chapters for all comics is started from this value.
const firstChapter = 1;
