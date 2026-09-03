import Toybox.Lang;
import Toybox.WatchUi;

class ScanDelegate extends WatchUi.BehaviorDelegate {
    private var _manager as CommandManager;

    function initialize(manager as CommandManager) {
        BehaviorDelegate.initialize();
        _manager = manager;
    }

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
