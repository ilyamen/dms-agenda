import QtQuick

QtObject {
    function check(done) {
        if (typeof done === "function") {
            done(null);
        }
    }
}
