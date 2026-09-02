import Toybox.Lang;
import Toybox.WatchUi;

//! Up and down move through the actions, select sends the highlighted one,
//! and the menu button starts pairing. Swipes map onto the same behaviours on
//! touch devices, so one delegate covers both input styles.
class MainDelegate extends WatchUi.BehaviorDelegate {
    private var _manager as CommandManager;

    function initialize(manager as CommandManager) {
        BehaviorDelegate.initialize();
        _manager = manager;
    }

    function onNextPage() as Boolean {
        currentView().selectNext();
        return true;
    }

    function onPreviousPage() as Boolean {
        currentView().selectPrevious();
        return true;
    }

    function onSelect() as Boolean {
        var action = currentView().getSelected();
        if (action == ACTION_LOCK) {
            _manager.sendCommand(Vcsec.rkeAction(Vcsec.RKE_ACTION_LOCK));
        } else if (action == ACTION_TRUNK) {
            _manager.sendCommand(Vcsec.openTrunk());
        } else if (action == ACTION_FRUNK) {
            _manager.sendCommand(Vcsec.openFrunk());
        } else {
            _manager.sendCommand(Vcsec.rkeAction(Vcsec.RKE_ACTION_UNLOCK));
        }
        return true;
    }

    function onMenu() as Boolean {
        WatchUi.pushView(new PairView(_manager), new PairDelegate(_manager), WatchUi.SLIDE_LEFT);
        return true;
    }

    private function currentView() as MainView {
        return WatchUi.getCurrentView()[0] as MainView;
    }
}
