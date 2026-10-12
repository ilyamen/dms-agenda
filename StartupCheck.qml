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
                "title": "Нужен DankCalendar (dcal)",
                "details": "Виджет берёт события и задачи из dcal. Установите DankCalendar, подключите аккаунт командой «dcal account setup google» и снова включите плагин."
            });
        });
    }
}
