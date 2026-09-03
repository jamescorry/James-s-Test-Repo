import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class WatchKeyApp extends Application.AppBase {
    // Built here rather than in onStart so it is never null: getInitialView
    // hands it straight to the view, and a nullable field there is a type
    // error the compiler will reject.
    private var _manager as CommandManager;

    function initialize() {
        AppBase.initialize();
        _manager = new CommandManager(method(:onManagerChange));
    }

    function onStart(state as Dictionary?) as Void {
        _manager.start();
    }

    function onStop(state as Dictionary?) as Void {
        _manager.stop();
    }

    function getInitialView() as Array<Views or InputDelegates>? {
        var view = new MainView(_manager);
        return [view, new MainDelegate(_manager)] as Array<Views or InputDelegates>;
    }

    //! The VIN lives in app settings, so a change from the phone has to be
    //! picked up without restarting the app.
    function onSettingsChanged() as Void {
        _manager.reloadVin();
        WatchUi.requestUpdate();
    }

    function onManagerChange() as Void {
        WatchUi.requestUpdate();
    }
}
