import json
import os
import httpx

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse

app = FastAPI()

FILEBROWSER_URL = os.environ.get("FILEBROWSER_URL", "http://filebrowser:80")

# NOTA ARCHITETTURALE — decompressione automatica di httpx
# --------------------------------------------------------
# httpx.AsyncClient decomprime SEMPRE automaticamente le risposte (gzip, deflate,
# brotli) a livello di transport, prima che il body arrivi a `upstream.content`.
# Di conseguenza:
#   1. Non inoltriamo Accept-Encoding a FileBrowser → FileBrowser non comprime
#      (difesa primaria, evita anche overhead inutile di compress/decompress)
#   2. Rimuoviamo Content-Encoding dalla risposta → anche se FileBrowser
#      comprimesse comunque, il body è già decompresso e l'header sarebbe falso
#      (difesa secondaria, rende il proxy corretto indipendentemente dal upstream)
#
# Se in futuro httpx venisse sostituito con una libreria che NON decomprime
# automaticamente (es. aiohttp con auto_decompress=False), le due difese
# andrebbero rivalutate: la (2) diventerebbe sbagliata, la (1) rimarrebbe corretta.
# Futuro: PDP_URL = os.environ.get("PDP_URL", "http://pdp:8181")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _is_resources_listing(path: str) -> bool:
    """Ritorna True se la request è una GET su /api/resources che torna una directory."""
    return path.startswith("/api/resources")


def _filter_items(items: list, username: str) -> list:
    """
    PEP: filtra gli item della directory listing.

    Regola attuale: nasconde qualsiasi file/cartella il cui nome
    contiene la parola 'secret' (case-insensitive).

    TODO: sostituire con una chiamata al PDP esterno per policy ABAC.
    """
    # Futuro:
    # allowed = await pdp_client.check(username, items)
    # return [item for item in items if item["path"] in allowed]

    return [
        item for item in items
        if "secret" not in item.get("name", "").lower()
    ]


def _patch_listing_response(body: bytes, username: str) -> bytes:
    """Filtra gli item nella risposta JSON di una directory listing."""
    data = json.loads(body)

    if "items" not in data or data["items"] is None:
        return body

    original_items = data["items"]
    filtered_items = _filter_items(original_items, username)

    # Aggiorna i contatori coerentemente con gli item rimasti
    data["items"]    = filtered_items
    data["numFiles"] = sum(1 for i in filtered_items if not i.get("isDir"))
    data["numDirs"]  = sum(1 for i in filtered_items if i.get("isDir"))

    return json.dumps(data).encode()


# ---------------------------------------------------------------------------
# Healthcheck — dichiarato PRIMA del catch-all altrimenti /{path:path} lo cattura
# ---------------------------------------------------------------------------

@app.get("/health")
async def health() -> JSONResponse:
    return JSONResponse({"status": "ok"})


# ---------------------------------------------------------------------------
# Proxy generico
# ---------------------------------------------------------------------------

@app.api_route(
    "/{path:path}",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"],
)
async def reverse_proxy(path: str, request: Request) -> Response:
    url = f"{FILEBROWSER_URL}/{path}"
    if request.url.query:
        url += f"?{request.url.query}"

    # Legge il body della richiesta (upload, ecc.)
    body = await request.body()

    # Propaga tutti gli header originali tranne:
    # - host: lo riscrive httpx
    # - content-length: verrà ricalcolato
    # - accept-encoding: httpx decomprime automaticamente le risposte, quindi
    #   se propagassimo gzip FileBrowser comprime, httpx decomprime, ma l'header
    #   Content-Encoding: gzip rimane nella risposta → ERR_CONTENT_DECODING_FAILED
    headers = {
        k: v
        for k, v in request.headers.items()
        if k.lower() not in ("host", "content-length", "accept-encoding")
    }

    # DEBUG TEMPORANEO: logga gli header inviati a FileBrowser
    import sys
    print(f"[PEP→FB] {request.method} /{path} | forwarded headers: { {k: v for k, v in headers.items() if 'auth' in k.lower() or 'preferred' in k.lower()} }", file=sys.stderr, flush=True)

    async with httpx.AsyncClient() as client:
        upstream = await client.request(
            method=request.method,
            url=url,
            headers=headers,
            content=body,
            follow_redirects=False,
        )

    response_body    = upstream.content
    response_headers = dict(upstream.headers)
    content_type     = response_headers.get("content-type", "")

    # --- Intercetta solo le listing di directory (GET /api/resources/...) ---
    if (
        request.method == "GET"
        and _is_resources_listing(f"/{path}")
        and "application/json" in content_type
        and upstream.status_code == 200
    ):
        username = request.headers.get("x-user-header", "anonymous")
        response_body = _patch_listing_response(response_body, username)
        # Ricalcola Content-Length dopo la modifica
        response_headers["content-length"] = str(len(response_body))

    # Rimuove header che httpx/FastAPI non deve propagare così com'è:
    # - transfer-encoding: gestito da uvicorn/FastAPI
    # - content-encoding: httpx ha già decompresso il body, propagarlo
    #   causerebbe ERR_CONTENT_DECODING_FAILED nel browser
    for h in ("transfer-encoding", "content-encoding"):
        response_headers.pop(h, None)

    return Response(
        content=response_body,
        status_code=upstream.status_code,
        headers=response_headers,
    )


