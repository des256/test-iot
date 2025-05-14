#!/bin/bash
rm test-iot.apk
flutter build apk dart-define=DEV=true
$ANDROID_HOME/build-tools/35.0.0/zipalign -v 4 build/app/outputs/flutter-apk/app-release.apk test-iot.apk
$ANDROID_HOME/build-tools/35.0.0/apksigner sign --ks ../admin/vullow.jks test-iot.apk
