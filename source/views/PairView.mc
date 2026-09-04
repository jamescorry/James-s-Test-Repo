import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Pairing screen. Enrolling a key needs physical proof of possession, so the
//! car asks for a key card tap on the centre console and then a confirmation
//! on its screen - this view exists to say so before the request times out,
//! and to show what the link is doing while it waits.
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
        var small = Graphics.FONT_XTINY;
        var lineHeight = dc.getFontHeight(small);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.14,
            Graphics.FONT_SMALL,
            (WatchUi.loadResource(Rez.Strings.PairTitle) as String) + " " + Version.label(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // The instruction until something happens, then the link status. The
        // instruction is three short lines at this size; the status is one.
        var status = _manager.getStatusText();
        var body = status.equals("")
            ? WatchUi.loadResource(Rez.Strings.PairInstructions) as String
            : status;
        dc.setColor(
            _manager.getState() == STATE_ERROR ? Graphics.COLOR_RED : Graphics.COLOR_LT_GRAY,
            Graphics.COLOR_TRANSPARENT
        );
        TextLayout.drawCentered(dc, body, small, width / 2, height * 0.34, (width * 0.80).toNumber());

        // Bytes out, bytes in, whole messages. If tx climbs and rx stays at
        // zero the car is not answering; if rx climbs while messages stay at
        // zero it is answering and the framing is wrong.
        var traffic = _manager.getTraffic();
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.54,
            small,
            "tx " + traffic[0].toString() +
                "  rx " + traffic[1].toString() +
                "  msg " + traffic[2].toString(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // The last few log lines, so the attempt can be read as it happens.
        // The full log is on the main screen under Log.
        var lines = DebugLog.lines();
        var rows = lines.size() < 3 ? lines.size() : 3;
        var y = (height * 0.62).toNumber();
        var maxWidth = (width * 0.72).toNumber();
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        for (var i = lines.size() - rows; i < lines.size(); i++) {
            var line = lines[i];
            if (dc.getTextWidthInPixels(line, small) > maxWidth) {
                line = (line.substring(0, 22) as String) + "~";
            }
            dc.drawText(width / 2, y, small, line, Graphics.TEXT_JUSTIFY_CENTER);
            y += lineHeight;
        }
    }
}
