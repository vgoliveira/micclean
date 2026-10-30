#!/bin/bash
# Instala o MicClean como serviço: inicia com o Mac e reinicia sozinho se cair.
#
# Uso:
#   bash install.sh
#
# Configuração (opcional, por variáveis de ambiente):
#   SOURCE_MIC     nome do microfone, como aparece em Ajustes > Som > Entrada (padrão: ME6S)
#   MICCLEAN_ARGS  opções extras para o micclean (ex.: "--gain 3 --strength 1.5")
#   NO_HAMMERSPOON=1  não instala/configura o Hammerspoon (troca automática do microfone padrão)
#
# Exemplo:
#   SOURCE_MIC="Blue Yeti" MICCLEAN_ARGS="--gain 3" bash install.sh
set -e
cd "$(dirname "$0")"

SOURCE_MIC="${SOURCE_MIC:-ME6S}"
MICCLEAN_ARGS="${MICCLEAN_ARGS:-}"
LABEL="io.github.vgoliveira.micclean"
LEGACY_LABELS=""
APP="$HOME/Applications/MicClean.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/micclean.log"
UID_DOMAIN="gui/$(id -u)"

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

echo "== MicClean =="
echo "Microfone de origem: $SOURCE_MIC"

# Pré-requisitos
if ! command -v swiftc >/dev/null; then
  echo "ERRO: compilador Swift não encontrado. Rode: xcode-select --install" >&2
  exit 1
fi
if ! system_profiler SPAudioDataType 2>/dev/null | grep -q "BlackHole 2ch"; then
  echo "BlackHole 2ch não encontrado."
  if command -v brew >/dev/null; then
    echo "Instalando com o Homebrew (pode pedir sua senha)..."
    brew install --cask blackhole-2ch
    sudo killall coreaudiod || true
    sleep 3
  else
    echo "ERRO: instale o BlackHole 2ch (https://existential.audio/blackhole/) e rode de novo." >&2
    exit 1
  fi
fi

echo "1/5 Compilando..."
swiftc -O -target "$(uname -m)-apple-macos13" micclean.swift -o micclean

echo "2/5 Criando o app MicClean..."
for l in $LABEL $LEGACY_LABELS; do
  launchctl bootout "$UID_DOMAIN/$l" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$l.plist"
done
pkill -x micclean 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS"
cp micclean "$APP/Contents/MacOS/micclean"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>MicClean</string>
  <key>CFBundleExecutable</key><string>micclean</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>O MicClean processa o áudio do microfone para remover eco e ruído.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"

echo "3/5 Permissão de microfone..."
open "$APP" --args --source "$SOURCE_MIC"
echo
echo "   Se aparecer um pedido de acesso ao microfone para o MicClean, clique em Permitir."
read -r -p "   Depois pressione Enter para continuar... "
pkill -x micclean 2>/dev/null || true

echo "4/5 Configurando para iniciar com o Mac..."
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
ARGS_XML="    <string>$(printf '%s' "$APP/Contents/MacOS/micclean" | xml_escape)</string>
    <string>--source</string>
    <string>$(printf '%s' "$SOURCE_MIC" | xml_escape)</string>"
for a in $MICCLEAN_ARGS; do
  ARGS_XML="$ARGS_XML
    <string>$(printf '%s' "$a" | xml_escape)</string>"
done
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
$ARGS_XML
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
launchctl bootstrap "$UID_DOMAIN" "$PLIST"
# A primeira execução logo após conceder a permissão às vezes não recebe áudio; reinicia uma vez.
sleep 3
launchctl kickstart -k "$UID_DOMAIN/$LABEL"

if [ "${NO_HAMMERSPOON:-0}" = "1" ]; then
  echo "5/5 Hammerspoon: ignorado (NO_HAMMERSPOON=1)."
  echo "   Escolha 'BlackHole 2ch' como microfone nos apps."
else
  echo "5/5 Hammerspoon (troca automática do microfone padrão)..."
  if [ ! -d /Applications/Hammerspoon.app ]; then
    if command -v brew >/dev/null; then
      brew install --cask hammerspoon
    else
      echo "   Hammerspoon não encontrado e Homebrew indisponível; pulando."
      echo "   Escolha 'BlackHole 2ch' como microfone nos apps."
      NO_HS=1
    fi
  fi
  if [ "${NO_HS:-0}" != "1" ]; then
    mkdir -p "$HOME/.hammerspoon"
    LUA_SOURCE=$(printf '%s' "$SOURCE_MIC" | sed 's/\\/\\\\/g; s/"/\\"/g')
    cat > "$HOME/.hammerspoon/micclean.lua" <<EOF
-- Gerado pelo install.sh do MicClean. Não edite: rode o install.sh de novo.
-- Microfone de origem plugado  -> entrada padrão = BlackHole 2ch (voz tratada pelo MicClean)
-- Microfone de origem ausente  -> entrada padrão = microfone embutido do Mac
local SOURCE_MIC  = "$LUA_SOURCE"
local VIRTUAL_MIC = "BlackHole 2ch"

local function builtinMic()
  for _, d in ipairs(hs.audiodevice.allInputDevices()) do
    if d:transportType() == "Built-in" then return d end
  end
end

local function setPreferredMic()
  local src  = hs.audiodevice.findInputByName(SOURCE_MIC)
  local virt = hs.audiodevice.findInputByName(VIRTUAL_MIC)
  local target
  if src and virt then target = virt elseif src then target = src else target = builtinMic() end
  local current = hs.audiodevice.defaultInputDevice()
  if target and (not current or current:name() ~= target:name()) then
    target:setDefaultInputDevice()
  end
end

hs.audiodevice.watcher.setCallback(function(event)
  if event == "dev#" or event == "dIn " then hs.timer.doAfter(1, setPreferredMic) end
end)
hs.audiodevice.watcher.start()
setPreferredMic()
EOF
    INIT="$HOME/.hammerspoon/init.lua"
    # Versões antigas do MicClean escreviam o script inteiro no init.lua: substitui.
    if [ -f "$INIT" ] && grep -q 'VIRTUAL_MIC' "$INIT" && ! grep -q 'require("micclean")' "$INIT"; then
      cp "$INIT" "$INIT.bak"
      : > "$INIT"
    fi
    touch "$INIT"
    grep -q 'hs.autoLaunch(true)' "$INIT" || echo 'hs.autoLaunch(true)' >> "$INIT"
    grep -q 'require("micclean")' "$INIT" || echo 'require("micclean")' >> "$INIT"
    killall Hammerspoon 2>/dev/null || true
    sleep 1
    open -a Hammerspoon
  fi
fi

sleep 3
echo
echo "Pronto. Últimas linhas do log ($LOG):"
tail -n 10 "$LOG" 2>/dev/null || echo "(log ainda vazio)"
echo
echo "Nos apps (Meet, Slack, WhatsApp...), deixe o microfone em 'Padrão do sistema'."
echo "Se o log mostrar 'processamento de voz Apple: ligado', ative o Isolamento de Voz:"
echo "  Central de Controle > Modo de Microfone > Isolamento de Voz."
