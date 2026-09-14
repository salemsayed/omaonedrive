import QtQuick

QtObject {
  property bool waitForEnd: true
  property string text: ""
  signal streamFinished()
  function feed(value) { text = value; streamFinished() }
}
