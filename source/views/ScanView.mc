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

        // The count matters: if it says four but only two rows are visible,
        // the rest are below the fold rather than absent.
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.86,
            font,
            found.size().toString() + " seen",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

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

        // Four devices, two lines each: identity and signal, then the
        // manufacturer data that has to stand in for a name. Sorted strongest
        // first, so the car leads when you are standing next to it.
        var rows = found.size() > 4 ? 4 : found.size();
        var top = (height * 0.36).toNumber();

        for (var i = 0; i < rows; i++) {
            var entry = found[i] as Dictionary;
            var y = top + i * 2 * lineHeight;

            // Green when this advertisement is one the app would connect to,
            // blue when it carries Tesla's service uuid but did not match.
            if (entry.get(:matches) as Boolean) {
                dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            } else if (entry.get(:tesla) as Boolean) {
                dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            } else {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            }

            dc.drawText(
                width / 2,
                y,
                font,
                truncate(entry.get(:label) as String, 14) + "  " +
                    (entry.get(:rssi) as Number).toString(),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );

            var manufacturer = entry.get(:manufacturer) as String;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                width / 2,
                y + lineHeight,
                font,
                manufacturer.equals("") ? "no mfg data" : manufacturer,
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
