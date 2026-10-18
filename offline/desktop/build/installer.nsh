; Let other devices on the shop's Wi-Fi/LAN reach Coconut POS (Windows Firewall rule for the program).
!macro customInstall
  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="Coconut POS"'
  nsExec::ExecToLog 'netsh advfirewall firewall add rule name="Coconut POS" dir=in action=allow program="$INSTDIR\Coconut POS.exe" enable=yes profile=any'
  nsExec::ExecToLog 'netsh advfirewall firewall add rule name="Coconut POS" dir=in action=allow protocol=TCP localport=8080-8090 enable=yes profile=any'
!macroend
!macro customUnInstall
  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="Coconut POS"'
!macroend
