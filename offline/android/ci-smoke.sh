#!/bin/bash
# Android emulator smoke test: install, launch, then ask the app's local server through adb port forwarding.
set +e
adb install -r out/CoconutPOS-Android-test.apk
adb shell pm grant com.coconutpos.standalone android.permission.POST_NOTIFICATIONS 2>/dev/null
adb shell am start -n com.coconutpos.standalone/.MainActivity
adb forward tcp:8080 tcp:8080
for i in $(seq 1 40); do sleep 2; curl -s http://localhost:8080/api/info > smoke-android.json && grep -q coconut-pos-offline smoke-android.json && break; done
{
  echo "--- /api/info"; cat smoke-android.json; echo
  echo "--- index bytes: $(curl -s http://localhost:8080/ | wc -c)"
  echo "--- host script injected: $(curl -s -H 'X-Coconut-Host: android' http://localhost:8080/ | grep -c COCONUT_HOST)"
  curl -s -X PUT http://localhost:8080/api/doc/menu/t1 -H 'Content-Type: application/json' -d '{"data":{"name":"test","createdAt":1,"ok":true}}'
  curl -s -X PATCH http://localhost:8080/api/doc/menu/t1 -H 'Content-Type: application/json' -d '{"patch":{"x":{"y":1}}}'
  curl -s "http://localhost:8080/api/col/menu?w=%5B%5B%22createdAt%22%2C%22%3E%3D%22%2C1%5D%2C%5B%22ok%22%2C%22%3D%3D%22%2Ctrue%5D%5D"; echo
  echo "--- logcat (app)"; adb logcat -d | grep -i -E "coconut|AndroidRuntime" | tail -30
} >> build-android.log 2>&1
adb exec-out screencap -p > android-emu.png
grep -q coconut-pos-offline smoke-android.json
