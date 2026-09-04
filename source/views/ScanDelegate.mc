import Toybox.Lang;
import Toybox.WatchUi;

//! Back only. Starting and stopping the scan belongs to ScanView, which knows
//! when it is on screen, so this delegate needs no manager of its own.
class ScanDelegate extends WatchUi.BehaviorDelegate {
    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
