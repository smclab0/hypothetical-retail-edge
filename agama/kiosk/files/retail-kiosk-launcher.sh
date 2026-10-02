#!/bin/bash
# Kiosk session for the store box (GNOME autostart for the kiosk user).
# Shows a holding page until this box's till answers, then keeps the till
# open in Firefox kiosk mode, restarting the browser if it ever exits.
till="http://$(hostname -I | awk '{print $1}')/"
holding=file:///usr/share/retail-kiosk/waiting.html

firefox --kiosk "$holding" &
holding_pid=$!
until curl -sf --max-time 3 "${till}healthz" >/dev/null; do sleep 10; done
kill "$holding_pid" 2>/dev/null
sleep 2

while true; do
  firefox --kiosk "$till"
  sleep 3
done
