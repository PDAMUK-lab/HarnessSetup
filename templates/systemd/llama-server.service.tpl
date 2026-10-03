[Unit]
Description=llama-server (@@LAPTOP_MODEL_ALIAS@@)
After=network-online.target
Wants=network-online.target

[Service]
User=llm
ExecStart=/opt/llama.cpp/bin/llama-server \
  -m /srv/models/@@LAPTOP_MODEL_FILE@@ --alias @@LAPTOP_MODEL_ALIAS@@ \
  --host 127.0.0.1 --port @@LLM_PORT@@ --jinja -ngl 99 -fa on -np 1 \
  -c @@LAPTOP_CTX@@ @@LAPTOP_NKVO_FLAG@@ -ctk f16 -ctv q8_0 \
  --cache-ram @@LAPTOP_CACHE_RAM_MB@@ --slot-save-path /srv/llm/slots \
  --chat-template-kwargs '{"enable_thinking":true}' \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
