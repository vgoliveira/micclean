#!/bin/bash
# Remove o MicClean (serviço, app e integração com o Hammerspoon).
# O BlackHole e o Hammerspoon continuam instalados; veja as instruções no final.
UID_DOMAIN="gui/$(id -u)"
for l in io.github.vgoliveira.micclean; do
  launchctl bootout "$UID_DOMAIN/$l" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$l.plist"
done
pkill -x micclean 2>/dev/null || true
rm -rf "$HOME/Applications/MicClean.app"

INIT="$HOME/.hammerspoon/init.lua"
rm -f "$HOME/.hammerspoon/micclean.lua"
if [ -f "$INIT" ]; then
  sed -i '' '/require("micclean")/d' "$INIT"
  pgrep -x Hammerspoon >/dev/null && { killall Hammerspoon; sleep 1; open -a Hammerspoon; }
fi

echo "MicClean removido."
echo "Volte a entrada em Ajustes > Som > Entrada para o seu microfone."
echo "Para remover também:"
echo "  BlackHole:   brew uninstall --cask blackhole-2ch"
echo "  Hammerspoon: brew uninstall --cask hammerspoon && rm -rf ~/.hammerspoon"
