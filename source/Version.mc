import Toybox.Lang;

//! The app version, shown on every screen so a sideloaded build can be told
//! from the one before it. Keep in step with the version attribute in
//! manifest.xml - tools/check_version.mjs fails the build check if they drift.
module Version {
    const APP_VERSION = "0.4.0";

    function label() as String {
        return "v" + APP_VERSION;
    }
}
