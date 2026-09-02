import Toybox.Lang;
import Toybox.WatchUi;

class PairDelegate extends WatchUi.BehaviorDelegate {
    private var _manager as CommandManager;

    function initialize(manager as CommandManager) {
        BehaviorDelegate.initialize();
        _manager = manager;
    }

    function onSelect() as Boolean {
        _manager.sendPairingRequest();
        return true;
    }

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
