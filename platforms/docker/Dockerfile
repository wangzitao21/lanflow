FROM rust:1-bookworm AS builder
WORKDIR /src
COPY native/Cargo.toml native/Cargo.lock ./
COPY native/src ./src
RUN cargo build --locked --release --features hub --bin lanflow-hub

FROM debian:bookworm-slim
RUN groupadd -g 10001 lanflow && useradd -u 10001 -g lanflow -M lanflow \
    && mkdir /data && chown lanflow:lanflow /data
COPY --from=builder /src/target/release/lanflow-hub /usr/local/bin/lanflow-hub
USER 10001:10001
ENV LANFLOW_DATA=/data
EXPOSE 53320
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s CMD ["lanflow-hub", "--healthcheck"]
ENTRYPOINT ["lanflow-hub"]
