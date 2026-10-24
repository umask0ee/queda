# queda

Transforma um celular velho ligado na tomada em um vigia da internet de casa. Ele registra cada queda com data, hora e duração, e separa se a falha foi na sua rede, no provedor ou no DNS. Serve para ter prova na hora de reclamar com o provedor.

## Como funciona

A cada rodada o script faz três testes. Primeiro um ping num IP de fora, depois a resolução de um nome para checar o DNS, e um ping no roteador. Com isso ele separa a falha em três casos.

Local quando nem o roteador responde, ou seja, problema no WiFi ou no próprio roteador. Provedor quando o roteador responde mas não sai para a internet. DNS quando a internet responde mas os nomes não resolvem.

Uma queda só é registrada depois de algumas rodadas ruins seguidas, para não anotar uma oscilação de um segundo. Cada queda vira duas linhas no log, início e fim, com a causa.

## Instalando

```
pkg install git
git clone https://github.com/umask0ee/queda
cd queda
bash queda.sh init
```

O `init` cria o arquivo `queda.conf` e tenta detectar o roteador sozinho. Em alguns aparelhos ele não consegue, e nesse caso avisa e deixa o `GATEWAY` vazio. Preencha com o IP do roteador, que aparece nos detalhes da rede WiFi nas configurações do Android, e rode `bash queda.sh init` de novo para confirmar. O `vigiar` não começa sem o IP do roteador, porque sem ele não dá para separar falha local de falha do provedor. O pacote `termux-api` com o app Termux:API só entra como alternativa para detectar o roteador. O script usa o `termux-wake-lock` para o Android não suspender o processador, e ele fica ativo enquanto o `vigiar` roda.

## Usando

```
bash queda.sh teste
```

Faz uma rodada e mostra o estado agora, bom para conferir se os alvos estão certos.

```
bash queda.sh vigiar
```

Fica rodando e registra as quedas. Deixe o celular na tomada, com o WiFi da casa, e é só deixar ligado.

```
bash queda.sh relatorio
```

Resume quantas quedas houve, o tempo total fora do ar e a divisão por causa.

## O que dá para configurar

No `queda.conf` você muda os alvos e os tempos. O `ALVO_EXTERNO` precisa ser um IP, não um nome, porque é o teste que não depende de DNS. O `ALVO_DNS` é o nome usado só para testar a resolução. Dá para ajustar o intervalo entre rodadas e quantas rodadas ruins contam como uma queda.

## O que ele não faz

Não acessa nada além dos alvos que você configura, não pede root e não coleta serial, IMEI, conta ou qualquer coisa que identifique a pessoa.

## Limites

Se o celular estiver com dados móveis ligados, o Android pode mandar o tráfego pelo 4G ou 5G quando a internet do WiFi cai. Nesse caso o teste de fora passa por esse caminho e a queda não é registrada. Desligue os dados móveis do celular que vai vigiar, ou use um sem chip.

Em Android mais novo, o sistema pode encerrar o Termux em segundo plano. Deixe o Termux sem restrição de bateria nas configurações do app e confira de tempos em tempos se o `vigiar` continua rodando.

O script vê a internet a partir do celular. Se o problema for só no WiFi que o celular usa, ele vai marcar como falha local mesmo que o cabo esteja bom. Para vigiar o link em si, o ideal é um celular perto do roteador com sinal forte.

Ping bloqueado atrapalha o diagnóstico. Alguns provedores ou roteadores não respondem a ping, e aí vale trocar o alvo no `queda.conf` por um que responda.

A duração é tão precisa quanto o intervalo entre rodadas. Com intervalo de 20 segundos, uma queda pode ser medida com até 20 segundos de diferença.

## Contribuindo

Esse tipo de medição varia muito por provedor e por cidade. Se quiser, conte no tópico do projeto qual provedor você usa e que tipo de queda apareceu mais, para montar um panorama.

## Licença

MIT.
