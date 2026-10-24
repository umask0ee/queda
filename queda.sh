#!/usr/bin/env bash
# queda vigia a internet de casa de um celular velho e registra cada interrupção,
# separando se a falha foi na rede local, no provedor ou no dns.
# não acessa nada além dos alvos que você configura e não pede root.
# licença MIT

set -u

VERSAO="0.1"
DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$DIR/queda.conf"
LOG="$DIR/queda.log"

# padrões, sobrescritos pelo queda.conf
GATEWAY=""                       # vazio = descobre sozinho
ALVO_EXTERNO="1.1.1.1"           # ip de fora, testado por ping (não por dns)
ALVO_DNS="google.com"            # nome resolvido para testar o dns
INTERVALO=20                     # segundos entre rodadas
FALHAS_P_QUEDA=3                 # rodadas ruins seguidas para contar como queda
PINGS=3                          # pacotes por teste
TIMEOUT=3                        # segundos de espera por teste

uso() {
  cat <<'EOF'
uso
  bash queda.sh init        cria o queda.conf e detecta o gateway
  bash queda.sh vigiar      fica rodando e registra as quedas
  bash queda.sh teste       faz uma rodada e mostra o resultado
  bash queda.sh relatorio   resume o que já foi registrado
EOF
}

erro() { echo "$1" >&2; exit 1; }
inteiro() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }

# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

# ---------- tela ----------

largura="${QUEDA_COLUNAS:-$(stty size 2>/dev/null | cut -d' ' -f2)}"
inteiro "$largura" || largura=80
texto() { printf '%s\n' "$1" | fold -s -w "$largura"; }

# ---------- rede ----------

ROTAS="${QUEDA_ROTAS:-/proc/net/route}"   # trocável só para teste

# tenta três caminhos, do mais direto ao mais frágil
descobre_gateway() {
  local g hex ipdisp base
  # 1. tabela de rotas pelo comando ip
  g=$(ip route 2>/dev/null | awk '/^default/ { print $3; exit }')
  if [ -n "$g" ]; then echo "$g"; return 0; fi

  # 2. tabela de rotas lida direto do kernel, com o gateway em hexadecimal invertido
  if [ -r "$ROTAS" ]; then
    hex=$(awk '$2 == "00000000" && $3 != "00000000" { print $3; exit }' "$ROTAS" 2>/dev/null)
    if [ "${#hex}" -eq 8 ]; then
      g=$(printf '%d.%d.%d.%d' "0x${hex:6:2}" "0x${hex:4:2}" "0x${hex:2:2}" "0x${hex:0:2}" 2>/dev/null)
      if [ -n "$g" ]; then echo "$g"; return 0; fi
    fi
  fi

  # 3. palpite pelo ip do celular no wi-fi (final .1), aceito só se responder a ping
  if command -v termux-wifi-connectioninfo >/dev/null 2>&1; then
    ipdisp=$(timeout 10 termux-wifi-connectioninfo 2>/dev/null \
      | sed -n 's/.*"ip": *"\([0-9]*\.[0-9]*\.[0-9]*\)\.[0-9]*".*/\1/p' | head -n 1)
    if [ -n "$ipdisp" ]; then
      base="$ipdisp.1"
      if ping -c 1 -W "$TIMEOUT" "$base" >/dev/null 2>&1; then
        echo "$base"; return 0
      fi
    fi
  fi
  return 1
}

# devolve 0 se respondeu, 1 se não
pinga() {
  local alvo=$1
  [ -z "$alvo" ] && return 1
  ping -c "$PINGS" -W "$TIMEOUT" "$alvo" >/dev/null 2>&1
}

# resolve um nome sem depender de ferramenta extra
resolve() {
  local nome=$1
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$nome" >/dev/null 2>&1 && return 0
  fi
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$nome" >/dev/null 2>&1 && return 0
    return 1
  fi
  # ping num nome também força a resolução
  ping -c 1 -W "$TIMEOUT" "$nome" >/dev/null 2>&1
}

# classifica uma rodada: ok, dns, provedor ou local
diagnostico() {
  local g=$1
  if pinga "$ALVO_EXTERNO"; then
    if resolve "$ALVO_DNS"; then
      echo ok
    else
      echo dns          # chega na internet, mas não resolve nome
    fi
  elif [ -z "$g" ]; then
    echo semgw          # sem o ip do roteador não dá para separar local de provedor
  elif pinga "$g"; then
    echo provedor       # fala com o roteador, mas não sai para fora
  else
    echo local          # nem o roteador responde
  fi
}

carimbo() { date '+%Y-%m-%d %H:%M:%S'; }

# ---------- init ----------

cmd_init() {
  local g
  if [ -e "$CONF" ]; then
    if [ -n "$GATEWAY" ]; then
      texto "o queda.conf já existe com o gateway $GATEWAY. apaga ele antes se quiser recriar."
      return 0
    fi
    g=$(descobre_gateway)
    if [ -n "$g" ]; then
      sed -i "s/^GATEWAY=.*/GATEWAY=\"$g\"/" "$CONF"
      echo "queda $VERSAO"
      texto "gateway detectado em $g e salvo no queda.conf."
    else
      echo "queda $VERSAO"
      texto "ainda não consegui detectar o gateway. abre o queda.conf e preenche o GATEWAY com o ip do seu roteador."
    fi
    return 0
  fi
  g=$(descobre_gateway)
  cat > "$CONF" <<EOF
# alvos e tempos do queda. edite se precisar.

# ip do roteador. vazio faz o script detectar a cada rodada.
GATEWAY="$g"

# ip de fora, testado por ping. não use um nome aqui.
ALVO_EXTERNO="1.1.1.1"

# nome usado para testar só o dns.
ALVO_DNS="google.com"

# segundos entre rodadas.
INTERVALO=20

# rodadas ruins seguidas para contar como uma queda.
FALHAS_P_QUEDA=3

# pacotes e espera por teste.
PINGS=3
TIMEOUT=3
EOF
  echo "queda $VERSAO"
  if [ -n "$g" ]; then
    texto "gateway detectado em $g e salvo no queda.conf."
  else
    texto "não consegui detectar o gateway. abre o queda.conf e preenche o GATEWAY com o ip do seu roteador. o ip aparece nos detalhes da rede Wi-Fi do Android."
  fi
  texto "confere o queda.conf e depois roda bash queda.sh vigiar."
}

# ---------- uma rodada ----------

rodada() {
  local g estado
  if [ -n "$GATEWAY" ]; then g=$GATEWAY; else g=$(descobre_gateway); fi
  estado=$(diagnostico "$g")
  echo "$estado"
}

# ---------- vigiar ----------
# o log guarda uma linha por evento: inicio e fim de cada queda, com a causa.

registra() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$LOG"; }

cmd_vigiar() {
  command -v ping >/dev/null 2>&1 || erro "o comando ping não está disponível."
  { inteiro "$INTERVALO" && [ "$INTERVALO" -gt 0 ]; } || erro "o INTERVALO precisa ser inteiro e maior que zero."
  inteiro "$FALHAS_P_QUEDA" || erro "o FALHAS_P_QUEDA precisa ser um número."
  if [ -z "$GATEWAY" ] && [ -z "$(descobre_gateway)" ]; then
    erro "sem o ip do roteador o script não separa falha local de falha do provedor. preenche o GATEWAY no queda.conf e roda de novo."
  fi

  if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock >/dev/null 2>&1
    trap 'termux-wake-unlock >/dev/null 2>&1' EXIT
  fi

  touch "$LOG"
  echo "queda $VERSAO"
  texto "vigiando a internet a cada $INTERVALO s. deixa rodando. ctrl-c para parar."
  texto "uma queda é contada após $FALHAS_P_QUEDA rodadas ruins seguidas, para não registrar oscilação de um segundo."
  echo

  local ruins=0 em_queda=0 causa="" primeira="" agora estado
  while :; do
    estado=$(rodada)
    if [ "$estado" = "ok" ]; then
      if [ "$em_queda" -eq 1 ]; then
        agora=$(carimbo)
        registra "$agora" "fim" "$causa"
        texto "$agora  voltou. a queda foi de $causa."
        em_queda=0
      fi
      ruins=0
    else
      ruins=$((ruins + 1))
      causa=$estado
      # o início da queda é a primeira rodada ruim, não a que confirma
      [ "$ruins" -eq 1 ] && primeira=$(carimbo)
      if [ "$em_queda" -eq 0 ] && [ "$ruins" -ge "$FALHAS_P_QUEDA" ]; then
        em_queda=1
        registra "$primeira" "inicio" "$causa"
        texto "$primeira  caiu. causa aparente $causa."
      fi
    fi
    sleep "$INTERVALO"
  done
}

# ---------- teste ----------

cmd_teste() {
  command -v ping >/dev/null 2>&1 || erro "o comando ping não está disponível."
  local g estado nome_g
  if [ -n "$GATEWAY" ]; then g=$GATEWAY; else g=$(descobre_gateway); fi
  nome_g=${g:-não detectado}
  echo "queda $VERSAO"
  echo
  if pinga "$ALVO_EXTERNO"; then ext="responde"; else ext="não responde"; fi
  if resolve "$ALVO_DNS"; then dns="resolve"; else dns="não resolve"; fi
  if [ -n "$g" ] && pinga "$g"; then rot="responde"; else rot="não responde"; fi
  estado=$(diagnostico "$g")
  printf '%-22s %s\n' "roteador ($nome_g)" "$rot"
  printf '%-22s %s\n' "externo ($ALVO_EXTERNO)" "$ext"
  printf '%-22s %s\n' "dns ($ALVO_DNS)" "$dns"
  echo
  case "$estado" in
    ok) texto "tudo certo agora." ;;
    dns) texto "a internet responde, mas o dns não resolve nomes. a falha está no dns." ;;
    semgw) texto "a internet não responde e eu não tenho o ip do roteador, então não dá para separar rede local de provedor. preenche o GATEWAY no queda.conf." ;;
    provedor) texto "o roteador responde, mas não sai para a internet. a falha está no provedor ou no link." ;;
    local) texto "nem o roteador responde. a falha está na sua rede local, no wi-fi ou no próprio roteador." ;;
  esac
}

# ---------- relatorio ----------

cmd_relatorio() {
  [ -r "$LOG" ] || { texto "ainda não há registro. roda bash queda.sh vigiar primeiro."; return 0; }
  echo "queda $VERSAO"
  echo
  awk -F'\t' '
    function dur(s) {
      if (s < 60) return int(s) "s"
      if (s < 3600) return sprintf("%dmin", int(s / 60))
      return sprintf("%.1fh", s / 3600)
    }
    # converte "AAAA-MM-DD" + "HH:MM:SS" em segundos desde uma data base.
    # conta própria, porque nem todo awk no android tem mktime.
    function bissexto(a) { return (a % 4 == 0 && a % 100 != 0) || a % 400 == 0 }
    function epoca(d, h,    a, t, i, dias, md) {
      split(d, a, "-"); split(h, t, ":")
      split("31 28 31 30 31 30 31 31 30 31 30 31", md, " ")
      dias = 0
      for (i = 2000; i < a[1]; i++) dias += bissexto(i) ? 366 : 365
      for (i = 1; i < a[2]; i++) { dias += md[i]; if (i == 2 && bissexto(a[1])) dias += 1 }
      dias += a[3] - 1
      return ((dias * 24 + t[1]) * 60 + t[2]) * 60 + t[3]
    }
    {
      ts = $1; ev = $2; causa = $3
      split(ts, p, " ")          # $1 é "AAAA-MM-DD HH:MM:SS"
      epoch = epoca(p[1], p[2])
    }
    ev == "inicio" { aberto = epoch; acausa = causa; ini_txt = ts; abertos++ }
    ev == "fim" && aberto != "" {
      d = epoch - aberto
      if (d < 0) d = 0
      n++; total += d
      por_causa[acausa] += d; conta[acausa]++
      ultimo = ini_txt " por " dur(d) ", " acausa
      aberto = ""
    }
    END {
      if (n == 0 && abertos == 0) { print "nenhuma queda registrada até agora."; exit }
      print "quedas registradas " n
      if (n > 0) {
        printf "tempo total fora do ar %s\n", dur(total)
        print ""
        print "por causa"
        for (c in conta) printf "  %-10s %d queda(s), %s no total\n", c, conta[c], dur(por_causa[c])
        print ""
        print "última queda " ultimo
      }
      if (aberto != "") print "há uma queda em aberto agora, começada em " ini_txt
    }
  ' "$LOG"
  echo
  texto "o registro completo está em $(basename "$LOG")."
}

# ---------- principal ----------

case "${1:-}" in
  init) cmd_init ;;
  vigiar) cmd_vigiar ;;
  teste) cmd_teste ;;
  relatorio) cmd_relatorio ;;
  -h|--help) uso ;;
  *) uso; exit 1 ;;
esac
