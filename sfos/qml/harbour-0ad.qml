// Progress page for the first-start download of the 0 A.D. game data.
// Run by launch.sh through sailfish-qml; it only displays what launch.sh
// writes to ~/.local/share/0ad/setup-status ("phase|percent|message").
// Closing this window cancels the setup; the next start resumes it.
import QtQuick 2.0
import Sailfish.Silica 1.0

ApplicationWindow {
    id: app

    property string phase: "prepare"
    property int percent: -1
    property string message: qsTr("Preparing…")
    property int misses: 0

    function poll() {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            var text = xhr.responseText || ""
            var sep1 = text.indexOf("|")
            var sep2 = text.indexOf("|", sep1 + 1)
            if (xhr.status !== 200 && xhr.status !== 0 || sep1 < 0 || sep2 < 0) {
                // the launcher removes the file when it starts the game or
                // gives up; allow a few misses for the atomic rename
                if (++misses > 5)
                    Qt.quit()
                return
            }
            misses = 0
            phase = text.substring(0, sep1)
            percent = parseInt(text.substring(sep1 + 1, sep2))
            message = text.substring(sep2 + 1).replace(/\s+$/, "")
        }
        xhr.open("GET", "file://" + StandardPaths.home + "/.local/share/0ad/setup-status")
        xhr.send()
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: app.poll()
    }

    cover: Component {
        CoverBackground {
            Column {
                anchors.centerIn: parent
                width: parent.width - 2 * Theme.paddingLarge
                spacing: Theme.paddingMedium
                Label {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: "0 A.D."
                    font.pixelSize: Theme.fontSizeLarge
                }
                Label {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: app.percent >= 0 ? app.percent + " %" : "…"
                    color: Theme.highlightColor
                }
            }
        }
    }

    initialPage: Component {
        Page {
            allowedOrientations: Orientation.All

            Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.paddingLarge

                PageHeader {
                    title: "0 A.D."
                }

                Label {
                    x: Theme.horizontalPageMargin
                    width: parent.width - 2 * Theme.horizontalPageMargin
                    wrapMode: Text.Wrap
                    text: app.phase === "error" ? qsTr("Setup failed") : qsTr("First start: fetching the game data")
                    font.pixelSize: Theme.fontSizeLarge
                    color: app.phase === "error" ? Theme.errorColor : Theme.highlightColor
                }

                ProgressBar {
                    width: parent.width
                    visible: app.phase !== "error"
                    indeterminate: app.percent < 0
                    minimumValue: 0
                    maximumValue: 100
                    value: Math.max(0, app.percent)
                    valueText: app.percent >= 0 ? app.percent + " %" : ""
                    label: app.phase === "download" ? qsTr("Download")
                         : app.phase === "extract" ? qsTr("Extracting")
                         : app.phase === "verify" ? qsTr("Checking")
                         : app.phase === "done" ? qsTr("Done") : ""
                }

                Label {
                    x: Theme.horizontalPageMargin
                    width: parent.width - 2 * Theme.horizontalPageMargin
                    wrapMode: Text.Wrap
                    text: app.message
                    color: Theme.primaryColor
                }

                Label {
                    x: Theme.horizontalPageMargin
                    width: parent.width - 2 * Theme.horizontalPageMargin
                    wrapMode: Text.Wrap
                    visible: app.phase !== "error"
                    text: qsTr("About 1.4 GB are downloaded and 3.5 GB extracted, Wi-Fi recommended. The game starts by itself afterwards. Closing this window cancels; the next start resumes the download.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.secondaryColor
                }
            }
        }
    }
}
