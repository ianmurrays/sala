FROM python:3.14-slim

COPY --from=ghcr.io/astral-sh/uv:0.9 /uv /bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never

WORKDIR /app
COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --locked --no-dev --no-install-project
COPY sala ./sala

RUN useradd --system --uid 10001 sala && mkdir /data && chown sala /data
USER sala
ENV SALA_DATA_DIR=/data PYTHONUNBUFFERED=1
VOLUME /data
EXPOSE 8000

# One worker only: the Aula session, MitID login and push poller live in process memory.
CMD [".venv/bin/uvicorn", "sala.app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
