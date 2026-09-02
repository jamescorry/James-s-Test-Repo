import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Pairing screen. Enrolling a key needs physical proof of possession, so the
//! car asks for a key card tap on the centre console - this screen exists to
//! tell the owner that before the request times out.
class PairView extends WatchUi.View {
    private var _manager as CommandManager;

    function initialize(manager as CommandManager) {
        View.initialize();
        _manager = manager;
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.22,
            Graphics.FONT_SMALL,
            WatchUi.loadResource(Rez.Strings.PairTitle) as String,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var status = _manager.getStatusText();
        var body = status.equals("")
            ? WatchUi.loadResource(Rez.Strings.PairInstructions) as String
            : status;

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height / 2,
            Graphics.FONT_TINY,
            body,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }
}
