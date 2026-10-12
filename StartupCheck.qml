import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("dcalAgenda.depCheck", ["sh", "-c", "command -v dcal"], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }
            done({
                "title": I18n.trFor("dcalAgenda", "DankCalendar (dcal) is required"),
                "details": I18n.trFor("dcalAgenda", "The widget shows events and tasks from dcal. Install DankCalendar, add an account with “dcal account setup google”, then re-enable the plugin.")
            });
        });
    }
}
