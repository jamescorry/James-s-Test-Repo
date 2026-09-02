import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class WatchKeyApp extends Application.AppBase {
    private var _manager as CommandManager?;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        _manager = new CommandManager(method(:onManagerChange));
        _manager.start();
    }

    function onStop(state as Dictionary?) as Void {
        if (_manager != null) {
            _manager.stop();
        }
    }

    function getInitialView() as Array<Views or InputDelegates>? {
        var view = new MainView(_manager);
        return [view, new MainDelegate(_manager)] as Array<Views or InputDelegates>;
    }

    //! The VIN lives in app settings, so a change from the phone has to be
    //! picked up without restarting the app.
    function onSettingsChanged() as Void {
        if (_manager != null) {
            _manager.reloadVin();
        }
        WatchUi.requestUpdate();
    }

    function onManagerChange() as Void {
        WatchUi.requestUpdate();
    }
}
