import time
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from routers import search, debrid, stream, settings, userdata, library, seerr

app = FastAPI(title="Nova API", version="1.1.0")

@app.get("/version")
async def get_version():
    return {"version": "1.1.0", "status": "stable", "features": ["semaphores", "aiostreams", "no-local-search"]}

@app.middleware("http")
async def add_process_time_header(request: Request, call_next):
    start_time = time.time()
    response = await call_next(request)
    process_time = time.time() - start_time
    print(f"Request: {request.method} {request.url.path} - Duration: {process_time:.4f}s")
    response.headers["X-Process-Time"] = str(process_time)
    return response

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(search.router, prefix="/search", tags=["search"])
app.include_router(debrid.router, prefix="/debrid", tags=["debrid"])
app.include_router(stream.router, prefix="/stream", tags=["stream"])
app.include_router(settings.router, prefix="/settings", tags=["settings"])
app.include_router(userdata.router, prefix="/user", tags=["user"])
app.include_router(library.router, prefix="/library", tags=["library"])
app.include_router(seerr.router, prefix="/seerr", tags=["seerr"])

@app.get("/")
def root():
    return {"status": "Nova is running"}
