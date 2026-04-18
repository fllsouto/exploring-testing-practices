##  Explorando Práticas de Teste (Scrapy)

> **Repositório analisado:** https://github.com/scrapy/scrapy</br>
> **Ferramentas:** MSR X-Ray notebook (metodologia [TestMiner](https://andrehora.github.io/testminer/)) + inspeção direta do código-fonte.</br>
> **Snapshot:** HEAD de `master`, 14 de abril de 2026.</br>
> **Repositório análise**: https://github.com/fllsouto/exploring-testing-practices

---
**Testes de integração contra um *MockServer* embutido, suíte parametrizada por reactor.**

Scrapy é um framework Python open-source de web scraping e crawling: Spiders assíncronas (Twisted/asyncio) navegam sites, extraem dados estruturados e os exportam por pipelines. Em sua base de código há **mais linhas de teste do que de produção** (razão 117 %) e **quase não se usa *mocks*** (apenas 1 arquivo, `tests/mocks/dummydbm.py`). No lugar deles, há um servidor HTTP/HTTPS/FTP de verdade em `tests/mockserver/` (9 arquivos, ~1 300 LOC em Twisted), contra o qual a suíte faz requisições como se fosse um serviço remoto.

### 1. Distribuição por categoria (TestMiner)

| Categoria | Arquivos |
|---|---:|
| Tests | **145** |
| Test Helpers | **137** |
| Mocks | 1 |
| CI Tests | 3 |
| Benchmarks | 1 |
| **Source Files** | **287** |

É possível perceber uma proporção de quase um para um entre **Test Helpers* e *Tests**, ou seja, quase uma estrutura auxiliar auxiliar por teste. São eles que viabilizam a abordagem sem *mocks*. A seção §2 abaixo descreve o que cada grupo faz.

### 2. Test Helpers: o que são e como auxiliam os testes

Os 137 arquivos classificados como *Test Helpers* não são testes propriamente ditos, são **infraestrutura reutilizada por eles**. Todos vivem dentro de `tests/` e se dividem em seis grupos funcionais:

**a) Servidor local em Twisted**
(`tests/mockserver/`, 9 arquivos, ~861 LOC). É o núcleo da abordagem de integração.

- `http.py` e `http_base.py` sobem um servidor HTTP;
- `simple_https.py` adiciona TLS;
- `ftp.py` e `dns.py` cobrem outros protocolos. 
 
O arquivo maior é `http_resources.py` (381 LOC), que expõe *resources* capazes de reproduzir comportamentos específicos como `Echo`, `Delay`, `Drop` (conexão cortada), `Partial` (resposta incompleta), `Chunked` (*Transfer-Encoding* quebrado), `Compress`, `SetCookie`, `RedirectTo`, `Status`, entre outros. Cada teste que precisa exercitar um cenário de servidor real escolhe o *resource* adequado.

Exemplo de um *resource* mínimo (de `http_resources.py`):

```python
class HostHeaderResource(resource.Resource):
    """Renderiza a si mesmo como o valor do header Host da requisição."""
    def render(self, request):
        return request.requestHeaders.getRawHeaders(b"host")[0]
```

Com isso, um teste pode verificar se o Scrapy envia corretamente o cabeçalho `Host` ao baixar `http://localhost:8998/host-header` simplesmente lendo o corpo da resposta.

**b) *Spiders* reutilizáveis** 
(`tests/spiders.py`, 573 LOC). Família de *Spiders* parametrizáveis, com `MockServerSpider` como base. Testes que precisam apenas de um *crawler* básico reaproveitam essas classes em vez de declarar uma *Spider* nova em cada arquivo.

Exemplo (de `tests/spiders.py`):

```python
class MockServerSpider(Spider):
    def __init__(self, *args, mockserver=None, is_secure=False, **kwargs):
        super().__init__(*args, **kwargs)
        self.mockserver = mockserver
        self.is_secure = is_secure

class FollowAllSpider(MetaSpider):
    name = "follow"
    link_extractor = LinkExtractor()

    def __init__(self, total=10, show=20, order="rand", *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.urls_visited = []
        qargs = {"total": total, "show": show, "order": order}
        self.start_urls = [self.mockserver.url(f"/follow?{urlencode(qargs)}")]

    def parse(self, response):
        self.urls_visited.append(response.url)
        for link in self.link_extractor.extract_links(response):
            yield Request(link.url, callback=self.parse)
```

Um teste que precisa exercitar um *crawl* recursivo simplesmente instancia `FollowAllSpider(mockserver=mockserver, total=50)` e roda o *crawler*, sem reescrever a lógica de seguir *links*.

**c) Scripts executados como subprocesso** 
(`tests/CrawlerProcess/`, `tests/CrawlerRunner/`, `tests/AsyncCrawlerProcess/`, `tests/AsyncCrawlerRunner/`, ~70 arquivos Python). Alguns testes precisam rodar o Scrapy em um **processo Python novo**, porque o que se quer medir é a inicialização do *reactor* (que não pode ser reiniciado no mesmo processo). Cada arquivo nesses diretórios é um cenário pronto de configuração, por exemplo `simple.py`, `asyncio_custom_loop.py`, `twisted_reactor_poll.py`, `reactor_select.py`, `sleeping.py`. Em `test_crawler.py`, classes como `CrawlerProcessSubprocess` apenas disparam `python tests/CrawlerProcess/<cenário>.py` e validam o *stdout*. Os *scripts* em si não contêm funções `def test_…`, mas sem eles dezenas de testes em `test_crawler.py` não existiriam.

Exemplo completo de cenário (`tests/CrawlerProcess/simple.py`, 13 linhas):

```python
import scrapy
from scrapy.crawler import CrawlerProcess
from scrapy.utils.reactorless import is_reactorless

class NoRequestsSpider(scrapy.Spider):
    name = "no_request"

    async def start(self):
        self.logger.info(f"is_reactorless(): {is_reactorless()}")
        return
        yield

process = CrawlerProcess(settings={})
process.crawl(NoRequestsSpider)
process.start()
```

O teste correspondente roda `python tests/CrawlerProcess/simple.py`, captura a saída e verifica se `is_reactorless(): False` apareceu no log. É um contrato comportamental testado em isolamento total do processo de teste.

**d) Certificados TLS** 
(`tests/keys/`, 11 arquivos). Pares *cert/key* auto-assinados (`example-com.*`, `localhost.ip.*`) mais o CA do `mitmproxy`. A função `generate_keys()` é invocada no final do `conftest.py` e garante que os certificados existam antes de qualquer teste começar, evitando dependência de arquivos gerados fora do repositório.

**e) Dados fixos** 
(`tests/sample_data/`, múltiplos arquivos não-Python). `test_site/` contém um mini-site HTML (`index.html`, `item1.html`, `item2.html`, `files/`) usado por testes de *crawl* ponta-a-ponta. `compressed/` guarda arquivos em diversos formatos para testar suporte a compressão. `feeds/` e `link_extractor/` contêm *payloads* de entrada para os módulos correspondentes.

**f) Mini-projetos Scrapy** 
(`tests/test_cmdline/`, `tests/test_cmdline_crawl_with_pipeline/`, `tests/test_spiderloader/spiders_from_addons/`, entre outros). Alguns testes de comandos (`scrapy crawl`, `scrapy startproject`) precisam de um projeto Scrapy **real** no disco. Esses diretórios são projetos de verdade, com `scrapy.cfg`, `settings.py`, `spiders/`, prontos para serem invocados pelos testes correspondentes.

**Como auxiliam, em resumo:** 
- O *MockServer* remove a necessidade de *mocks* (grupo **a**);
- As *Spiders* compartilhadas eliminam código duplicado (grupo **b**);
- Os *scripts* de subprocesso permitem testar inicialização de *reactor* sem poluir o processo de teste (grupo **c**);
- Os certificados garantem determinismo TLS (grupo **d**);
- Os dados fixos permitem testar *parsers* e extratores contra HTML real (grupo **e**);
- E os mini-projetos permitem testar o CLI completo sem depender de projeto externo (grupo **f**). A razão de 137 *helpers* para 145 *Tests* é consequência direta dessa divisão: cada teste carrega apenas a lógica de verificação, toda a infraestrutura fica nos *helpers*.

### 3. Tests: quantos são, quais padrões, como se organizam

A categoria *Tests* do TestMiner tem **145 arquivos** (139 `test_*.py` no nível de `tests/` mais 6 pacotes como `tests/test_cmdline/`, `tests/test_settings/`). Juntos eles contêm:

- **1 496 funções `def test_*`** (contando funções livres e métodos de classes);
- **405 classes `class Test*`** agrupadoras;
- **77 usos de `@pytest.mark.parametrize`** espalhados por 41 arquivos;
- Apenas **1 arquivo** herda de `unittest.TestCase`. A suíte é quase 100 % *pytest* puro.

**Padrões dominantes:**

1. **Classes agrupadoras + métodos `test_*`.** 405 classes para 1 496 funções dá uma média de ~3–4 testes por classe. Em vez de funções isoladas, os testes relacionados compartilham *setup* e *fixtures* dentro da classe.
2. **Parametrização densa.** 77 `@pytest.mark.parametrize` (em 41 arquivos) indicam que muitos testes são tabulares: uma função, N cenários.
3. **Integração com Twisted via pytest-twisted.** 22 arquivos usam `inlineCallbacks`, `deferred_to_future` ou os decoradores de `tests/utils/decorators.py` (`coroutine_test`, `inline_callbacks_test`). A suíte roda *reactors* reais, não eventos mockados.
4. ***Fixture* de sessão para o MockServer.** 35 dos 145 arquivos (24 %) importam ou recebem o `mockserver` via *fixture* declarada no `conftest.py` central. Os outros 110 arquivos são unidades puras, sem I/O.
5. **`tests/` tratado como biblioteca interna.** 17 arquivos reaproveitam *Spiders* de `tests/spiders.py`; outros importam de `tests.utils`, `tests.mockserver.http`, `tests.keys`. O pacote `tests/` é um *namespace* normal, importável como qualquer outro.

**Organização por tópico.** Os 139 arquivos no nível superior seguem um esquema de prefixo que agrupa pelo subsistema exercitado. Os 10 maiores *clusters*:

| Cluster | Arquivos | O que cobre |
|---|---:|---|
| `test_utils_*` | 25 | funções utilitárias de `scrapy/utils/` |
| `test_downloadermiddleware_*` | 17 | cada *middleware* de download |
| `test_spidermiddleware_*` | 9 | cada *middleware* de *Spider* |
| `test_command_*` | 9 | cada subcomando CLI |
| `test_http_*` | 7 | *requests* / *responses* / *headers* / cookies |
| `test_downloader_*` | 7 | *handlers* HTTP, HTTPS, FTP, HTTP/2 |
| `test_feedexport_*` | 5 | exportadores de *feeds* |
| `test_spider*` | 4 | classe *Spider* base |
| `test_request*` | 4 | construção de requisições |
| `test_pipeline*` | 4 | *item pipelines* |

A regra prática é **um arquivo por componente**. Quando o componente tem subcomponentes (como *middlewares*), cada um ganha seu próprio `test_<componente>_<subcomponente>.py`. Isso mantém cada arquivo pequeno e permite rodar só os testes de uma área com um *glob*, por exemplo `pytest tests/test_downloadermiddleware_*.py`.

### 4. Organização

- Diretório único `tests/` no topo, não aninhado em `scrapy/`.
- Convenção `test_*.py` **enforçada no `pyproject.toml`**: `python_files = ["test_*.py", "test_*/__init__.py"]`. Isso permite que testes complexos virem pacotes (ex.: `test_cmdline/`, `test_settings/`, `test_spiderloader/`).
- **Um único `conftest.py` central** (126 LOC) expõe a *fixture* de sessão `mockserver`, a opção `--reactor` (`asyncio` | `default` | `none`) e pula testes por *marker* quando falta dependência opcional.
- *Markers*: `only_asyncio`, `requires_reactor`, `requires_uvloop`, `requires_botocore`, `requires_mitmproxy`. O mesmo teste roda (ou é pulado) conforme o reactor. É a matriz Twisted × asyncio sem duplicação de arquivos.
- **Matriz CI/CD**: a mesma suíte roda em três dimensões combinadas:
  - **Sistema operacional**: `tests-ubuntu.yml`, `tests-macos.yml`, `tests-windows.yml` (os 3 *CI Tests* do TestMiner);
  - **Interpretador**: Python 3.10, 3.11, 3.12 e 3.13 em todos os SOs, mais PyPy 3.11 só no Ubuntu;
  - ***tox env***: `py` (padrão), `default-reactor`, `no-reactor`, `pinned` (deps travadas) e `extra-deps` (deps opcionais, ex.: `httpx`).

  Todos os *jobs* rodam em paralelo via *pytest-xdist* (`PYTEST_ADDOPTS=-n auto`).
- Dependências de teste ficam em `tox.ini` (seção `[test-requirements]`), **não** em `pyproject.toml`. São elas *pytest*, *pytest-twisted*, *testfixtures*, *pyftpdlib*, *httpx*, *sybil*, entre outras.

### 5. Evolução em 17 anos (128 releases)

| Release | Ano | Prod LOC | Teste LOC | Razão |
|---|---|---:|---:|---:|
| 0.7-rc1 | 2009 | 19 787 | 6 240 | 32 % |
| 1.0.0rc1 | 2015 | 23 233 | 12 161 | 52 % |
| 1.5.0 | 2018 | 18 369 | 17 163 | 93 % |
| **2.0.0** | 2020 | 19 625 | 21 400 | **109 %** ← cruzamento |
| 2.13.3 | 2025 | 30 533 | 38 516 | 126 % |

Produção cresceu ~1,5×; testes cresceram ~6,2×. O cruzamento em 2.0.0 coincide com a migração para *reactor* configurável. A suíte dobrou na nova dimensão.

### 6. Benchmark testing

A categoria *Benchmarks* tem um único arquivo: **`scrapy/commands/bench.py`** (69 LOC), que implementa o subcomando CLI `scrapy bench`. Ele mede o *throughput* do framework em **páginas/minuto**, ou seja, quantas requisições o motor do Scrapy consegue despachar, baixar e *parsear* por unidade de tempo, isolando esse custo de qualquer latência de rede real.

**Como funciona:**

1. **Sobe um servidor HTTP local** (`scrapy/utils/benchserver.py`) em *subprocesso* separado, escutando em `localhost:8998`. Esse servidor gera sob demanda páginas HTML com vários *links* internos, garantindo que o *crawler* nunca fique sem URLs para seguir.
2. **Instancia `_BenchSpider`**, uma *Spider* mínima cuja única lógica é extrair todos os *links* da resposta e reenfileirá-los, sem *pipelines*, sem *parsing* de itens, sem IO em disco. O que se exercita é apenas o *loop* *fetch → parse → enqueue* do motor.
3. **Executa o *crawler*** contra esse servidor até `CLOSESPIDER_TIMEOUT=10s`. A cada `LOGSTATS_INTERVAL=1s` o Scrapy imprime as estatísticas acumuladas (páginas/min, itens/min, *bytes* baixados). A última linha é o número que o desenvolvedor compara entre *commits* ou configurações.

Como servidor e *crawler* rodam na mesma máquina, o que se mede é o **custo do próprio Scrapy** (*scheduler*, *downloader*, *middlewares*, *reactor*), sem interferência da rede. Isso também explica por que desempenho não entra no CI: o *runner* do GitHub Actions compartilha CPU e I/O com outros *jobs*, então o número oscila demais para virar critério de aceitação. A régua de performance fica com o desenvolvedor, rodando localmente.


