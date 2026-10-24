# beeper-line-settings

Run [beeper/line](https://github.com/beeper/line), a bridge between Matrix
and [LINE](https://line.me/), next to your own Matrix homeserver with Docker
Compose. This repository holds only the deployment: the bridge is built from
upstream's source at a pinned commit.

Each user of your homeserver who is allowed to use the bridge logs in with
their own LINE account; their LINE chats and groups then appear as Matrix
rooms, in any Matrix client.

## Before you start

- **This is an unofficial LINE client.** The bridge talks to LINE as LINE's
  Chrome extension does. LINE does not endorse it, and an account using it
  could be restricted.
- **Not together with the LINE Chrome extension.** LINE allows one Chrome
  extension session per account: logging in to the extension logs the bridge
  out, and the bridge logs back in and logs the extension out. Log out of
  the bridge first to use the extension.
- **The LINE account needs an email address** (LINE app: Settings →
  Account → Email address). You log in with it and its password, then enter
  a PIN in the LINE app on your phone.
- **Your server sees the messages.** Bridged chats are stored on your
  homeserver like any Matrix room. Allow only users of your own server
  (`BRIDGE_USERS`) unless you mean to carry other people's LINE accounts.

## Requirements

- A Matrix homeserver that supports application services (Synapse, for
  one), running in Docker on the same host, on a network the bridge can join
- Docker with Compose v2 (rootful or rootless) and the buildx plugin
  (`docker buildx version`; Arch: `docker-buildx`, Debian/Ubuntu:
  `docker-buildx-plugin`). Upstream's Dockerfile needs BuildKit, and without
  buildx Compose falls back to the legacy builder, which fails with "the
  --mount option requires BuildKit"

## Setup

```sh
git clone <this repository> beeper-line && cd beeper-line
./setup.sh
```

`setup.sh` asks for the settings it needs (through `configure.sh`) and
saves them in `.env`. When a Synapse container is running, it offers what
it finds as defaults: the server name from its config, its network, its
address there and the directory mounted at its `/data`. Press Enter to keep
a default. Run `./setup.sh --configure` (or `./configure.sh`) to change
them later, or write `.env` yourself from `.env.example`; without a
terminal, `setup.sh` only reads `.env`.

The settings:

| Setting | |
|---|---|
| `SERVER_NAME` | Your homeserver's server name, the part after `:` in user IDs |
| `HOMESERVER_URL` | Where the bridge reaches the homeserver, e.g. `http://synapse:8008` |
| `HOMESERVER_NETWORK` | The Docker network the homeserver is on (`docker network ls`); for a Compose stack, usually `<project>_default` |
| `BRIDGE_USERS` | Who may use the bridge: your server name for all of its users, or one user ID |
| `BRIDGE_ADMIN` | A user ID that administers the bridge |
| `REGISTRATION_DIR` | Optional: where `setup.sh` copies the registration for the homeserver |
| `DATABASE_URI` | Optional: a PostgreSQL URI; without it the bridge uses SQLite in `data/` |
| `BEEPER_LINE_REF` | The upstream commit (or tag, or branch) to build |

`setup.sh` builds the image, writes `data/config.yaml` from upstream's
example and the settings above, generates the appservice registration
(`data/registration.yaml`) and starts the bridge. It picks the user the
bridge runs as so that `data/` stays yours (you on rootful Docker, container
root on rootless Docker) and saves it in `.env`.

Run it again after changing the settings. The settings above are applied again;
anything else you change in `data/config.yaml` is kept. The registration is
generated only once, since it holds the tokens the homeserver and the bridge
share; if you change `SERVER_NAME`, delete `data/registration.yaml`, run
`setup.sh` and register the new file.

### Register the bridge with the homeserver

The homeserver must know the registration. For Synapse, make the file
readable by Synapse, list it in `homeserver.yaml` and restart Synapse:

```yaml
app_service_config_files:
  - /data/beeper-line.yaml
```

The homeserver reaches the bridge at `http://beeper-line:29322` on
`HOMESERVER_NETWORK`.

#### With koto

[koto](https://forgejo.genji1024.com/genji1024/koto) registers every file in
its `data/synapse/appservices/`. With koto running, `configure.sh` offers
these itself:

```sh
HOMESERVER_URL=http://synapse:8008
HOMESERVER_NETWORK=koto_default
REGISTRATION_DIR=../koto/data/synapse/appservices
```

then, after `./setup.sh`, in koto's directory:

```sh
./scripts/init.sh && docker compose restart synapse
```

koto shows only its own rooms: use LINE chats from another Matrix client.

### PostgreSQL

SQLite is enough for a few users. For PostgreSQL (16 or newer), create a
database of the bridge's own and set `DATABASE_URI`, for example with the
homeserver's server:

```sh
docker compose exec postgres psql -U synapse \
  -c "CREATE ROLE beeper_line LOGIN PASSWORD '...'" \
  -c "CREATE DATABASE beeper_line OWNER beeper_line"
```

## Logging in

From a Matrix client, start a chat with `@linebot:<SERVER_NAME>` and send
`login`. Enter the LINE account's email address and password, then the PIN
the bridge shows into the LINE app on your phone. `help` lists the other
commands; `logout` ends the session.

## Upgrading

Set `BEEPER_LINE_REF` to a newer upstream commit and run `./setup.sh` (or
`docker compose up -d --build`). Read upstream's README first: some
versions ask you to reset the configuration and log in again.

## Backups

Back up `data/` (the config with its tokens, the registration and, with
SQLite, the database) and `.env`.

## Files

- `compose.yaml`: the bridge, built from upstream at `BEEPER_LINE_REF`, on
  the homeserver's network
- `setup.sh`: the setup above
- `configure.sh`: the questions, writing `.env`
- `lib.sh`: helpers both share
- `.env.example`: the settings

## License

MIT (see [LICENSE](LICENSE)). The bridge itself is upstream's, under its
own license.
