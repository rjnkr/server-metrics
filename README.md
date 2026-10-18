# Server Metrics to Seq

Docker container that sends the host's CPU, load, memory and disk usage to [Seq](https://datalust.co/seq) as a structured event every minute, so you can chart the trend in a Seq dashboard.


# Using

This project uses:
- [alpine](https://hub.docker.com/_/alpine) with `curl`
- Seq's [raw CLEF ingestion API](https://docs.datalust.co/docs/posting-raw-events)

`/proc/stat` and `/proc/meminfo` inside a container report the host's values, so no privileged mode is needed. The host root filesystem is mounted read-only on `/host` for the disk figures.


# Usage / Commands

## Build or pull image

`docker build -t <dockerhub-user>/server-metrics:latest .`  
or  
`docker pull <dockerhub-user>/server-metrics:latest`  

## Run container

```
docker run -d --name server-metrics --restart unless-stopped \
  --network logging \
  -v /:/host:ro \
  -e HOST_NAME=docker-server \
  -e SEQ_URL=http://seq:5341 \
  -e SEQ_API_KEY=myapikey \
  <dockerhub-user>/server-metrics:latest
```

## Portainer stack

Use [compose.yaml](compose.yaml): Stacks → Add stack → paste it (or point to this repository) and set `SEQ_API_KEY` under *Environment variables*.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `HOST_NAME` | container hostname | Value of the `Host` property in Seq |
| `SEQ_URL` | `http://seq:5341` | Seq ingestion URL |
| `SEQ_API_KEY` | *(empty)* | Seq API key; omitted when empty |
| `INTERVAL` | `60` | Seconds between measurements |
| `WARN_PERCENT` | `90` | Event level becomes `Warning` when CPU, memory or disk usage exceeds this |
| `DISK_PATH` | `/host` | Path whose filesystem is measured |


# Event properties

Every event has `Application = 'server-metrics'` and these properties:

| Property | Description |
|---|---|
| `CpuPercent` | Average CPU usage (all cores) since the previous measurement |
| `CpuCores`, `CpuUsedCores` | Number of cores (capacity) and cores in use |
| `Load1`, `Load5`, `Load15` | Load average |
| `MemUsedPercent`, `MemUsedMB`, `MemTotalMB` | Memory used, excluding page cache |
| `DiskUsedPercent`, `DiskUsedGB`, `DiskFreeGB`, `DiskTotalGB` | Filesystem of `DISK_PATH` |

## Seq dashboard queries

```sql
select mean(CpuPercent) as CPU, mean(MemUsedPercent) as Memory from stream where Application = 'server-metrics' group by time(5m)
```
```sql
select min(DiskFreeGB) as DiskFree from stream where Application = 'server-metrics' group by time(1h)
```


# Publishing

GitHub Actions ([docker-publish.yml](.github/workflows/docker-publish.yml)) builds for `linux/amd64`, `linux/arm64` and `linux/arm/v7` and pushes to Docker Hub on every push to `main`, on `v*.*.*` tags and weekly. Set the repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`.
