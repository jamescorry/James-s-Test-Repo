import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! What the BLE scan can actually see.
//!
//! "Car not found" is a conclusion, not evidence. This screen shows the
//! advertisements the watch is picking up, so the failure can be told apart:
//! nothing at all means a radio or range problem, a list without the car
//! means it is not advertising or is out of reach, and the car present but
//! unmatched means the name comparison is what is wrong.
class ScanView extends WatchUi.View {
    private var _manager as CommandManager;

    function initialize(manager as CommandManager) {
        View.initialize();
        _manager = manager;
    }

    function onShow() as Void {
        _manager.startDiagnostics();
    }

    function onHide() as Void {
        _manager.stopDiagnostics();
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();
        var font = Graphics.FONT_XTINY;
        var lineHeight = dc.getFontHeight(font);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.14,
            Graphics.FONT_TINY,
            WatchUi.loadResource(Rez.Strings.ScanTitle) as String,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // The name being searched for. If the car shows up in the list below
        // under a different name, this is the mismatch.
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        TextLayout.drawCentered(
            dc,
            (WatchUi.loadResource(Rez.Strings.ScanLooking) as String) + " " + _manager.getExpectedName(),
            font,
            width / 2,
            (height * 0.26).toNumber(),
            (width * 0.78).toNumber()
        );

        var found = _manager.getDiscovered();
        if (found.size() == 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                width / 2,
                height / 2,
                font,
                WatchUi.loadResource(Rez.Strings.ScanEmpty) as String,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
            return;
        }

        // Five rows is all a round screen fits legibly; the strongest signals
        // are the ones worth seeing.
        var rows = found.size() > 5 ? 5 : found.size();
        var top = (height * 0.40).toNumber();

        for (var i = 0; i < rows; i++) {
            var entry = found[i] as Dictionary;
            var label = entry.get(:label) as String;
            var rssi = entry.get(:rssi) as Number;

            // Green when this advertisement is one the app would connect to,
            // blue when it carries Tesla's service uuid but did not match.
            if (entry.get(:matches) as Boolean) {
                dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            } else if (entry.get(:tesla) as Boolean) {
                dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            } else {
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            }

            dc.drawText(
                width / 2,
                top + i * lineHeight,
                font,
                truncate(label, 16) + "  " + rssi.toString(),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }
    }

    private function truncate(text as String, limit as Number) as String {
        if (text.length() <= limit) {
            return text;
        }
        return (text.substring(0, limit) as String) + "~";
    }
}
