import Toybox.Lang;
import Toybox.WatchUi;

//! Scrolls the log; back leaves it.
class LogDelegate extends WatchUi.BehaviorDelegate {
    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onNextPage() as Boolean {
        currentView().scrollDown();
        return true;
    }

    function onPreviousPage() as Boolean {
        currentView().scrollUp();
        return true;
    }

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }

    private function currentView() as LogView {
        return WatchUi.getCurrentView()[0] as LogView;
    }
}
