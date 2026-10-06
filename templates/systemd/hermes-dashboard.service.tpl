[Unit]
Description=Hermes web dashboard
After=network-online.target

[Service]
ExecStart=@@HERMES_BIN@@ dashboard --host @@DASHBOARD_BIND@@ --port @@DASHBOARD_PORT@@ --no-open
Restart=always
RestartSec=10
# exit 78 = another dashboard already owns this host; don't restart-loop on it
RestartPreventExitStatus=78

[Install]
WantedBy=default.target
